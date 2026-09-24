#!/usr/bin/env bash
# fm-decisions-digest.sh - the captain's daily decisions digest.
#
# Once a day it gathers everything waiting on the captain, groups it by project
# or domain first, marks each item with the answer it needs - a merge word, the
# captain's hands, a decision, or nothing yet (parked) - and gives it one line
# and a short recommendation. It republishes one fixed claude.ai artifact page
# with it and posts a short version to Slack. A systemd --user timer runs it,
# so it survives firstmate session restarts.
#
# Usage:
#   fm-decisions-digest.sh gather
#   fm-decisions-digest.sh run [--dry-run | --no-post]
#   fm-decisions-digest.sh install [--at HH:MM] [--tz <zone>]
#   fm-decisions-digest.sh uninstall
#
#   gather     Print the digest input as JSON and change nothing.
#   run        Gather, compose, render, publish the page, and post to Slack.
#              --dry-run stops after rendering; --no-post publishes but skips
#              Slack. Exits 1 when composing, publishing, or posting failed.
#   install    Write this home's timer and service into <config>/systemd/,
#              link them into the systemd user manager, and enable the timer.
#              --at defaults to 07:00, --tz to this machine's timezone. Rerun it
#              to change the time. Linux with systemd only.
#   uninstall  Disable the timer and unlink both units.
#
# What it gathers (read-only):
#   - every still-open needs-decision/blocked record in this home's status logs,
#     through fm-classify-lib.sh's scan_open_decisions - the same fold behind the
#     wake drain's OPEN DECISIONS section, so a secondmate's routed decisions
#     appear exactly as they do there;
#   - this home's held backlog items with their hold reasons, and its blocked
#     items, through fm-tasks-axi.sh;
#   - every recorded task PR (`pr=` in state/<id>.meta) with its task's latest
#     status event and its live forge state from `gh pr view`.
#
# Why two model calls. Grouping and marking items and writing a recommendation
# is judgment, so a headless `claude -p` with no tools returns them as
# schema-checked JSON, and this script renders the page and the Slack text from
# that JSON itself, so the page shape never drifts. Publishing is different:
# the Artifact tool that republishes a fixed URL exists only in an interactive
# Claude Code session, never under `claude -p` (verified 2026-09-24 with Claude
# Code 2.1.281). `claude --bg` starts exactly such a session with no terminal,
# so the publish step launches one, has it read and republish the page, waits
# for its one-line result file, then stops and removes it.
# Both calls run from the home root, which a Claude-driven home has already
# trusted, with `--setting-sources user` so firstmate's project hooks (session
# start, turn-end guard, auto-arm) never fire, and with the home's CLAUDE.md and
# AGENTS.md excluded so the session never mistakes itself for firstmate.
# A home whose root is not trusted in Claude Code makes the publish step fail
# with Claude's own "Workspace not trusted" message; run `claude` once there.
#
# Files, under FM_DECISIONS_DIGEST_DIR (default <data>/decisions-digest):
#   artifact-url   the fixed page URL. The first successful publish records it;
#                  every later run republishes to it. Write an existing URL here
#                  to adopt that page instead. The page belongs to the claude.ai
#                  account this machine is signed in to; after a sign-in change
#                  the publish is refused as inaccessible, and deleting this file
#                  lets the next run start a new page (a new link) under the new
#                  account. The script never does that on its own, so a
#                  bookmarked link never changes silently.
#   run/           the latest run: input.json, digest.json, index.html,
#                  slack.txt, publish.json, the publisher's launch output,
#                  publish-session.log (its screen when it wrote no result), and
#                  publish-error.txt (why the last publish failed).
#
# Failure posture: a failed compose posts a short notice to Slack instead of a
# digest; a failed publish still posts the digest with a line saying the page
# was not updated; every failure exits 1 so the timer's journal records it.
#
# Environment:
#   FM_DECISIONS_DIGEST_DIR              output directory (above)
#   FM_DECISIONS_DIGEST_MODEL            compose model (default sonnet)
#   FM_DECISIONS_DIGEST_PUBLISH_MODEL    publish-session model (default haiku)
#   FM_DECISIONS_DIGEST_CHANNEL          Slack channel (default decisions)
#   FM_DECISIONS_DIGEST_PUBLISH_TIMEOUT  seconds to wait for the publish (default 600)
#   FM_DECISIONS_DIGEST_SLACK_ITEMS      items shown per project in Slack (default 4)
#   FM_DECISIONS_DIGEST_CLAUDE / _SLACK / _GH / _SYSTEMCTL
#                                        command overrides (claude, firstmate-slack,
#                                        gh, systemctl), mainly for tests
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SELF_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SELF_DIR/fm-timeout-lib.sh"

DIR="${FM_DECISIONS_DIGEST_DIR:-$DATA/decisions-digest}"
RUN_DIR="$DIR/run"
URL_FILE="$DIR/artifact-url"
MODEL="${FM_DECISIONS_DIGEST_MODEL:-sonnet}"
PUBLISH_MODEL="${FM_DECISIONS_DIGEST_PUBLISH_MODEL:-haiku}"
CHANNEL="${FM_DECISIONS_DIGEST_CHANNEL:-decisions}"
PUBLISH_TIMEOUT="${FM_DECISIONS_DIGEST_PUBLISH_TIMEOUT:-600}"
CLAUDE_BIN="${FM_DECISIONS_DIGEST_CLAUDE:-claude}"
SLACK_BIN="${FM_DECISIONS_DIGEST_SLACK:-firstmate-slack}"
GH_BIN="${FM_DECISIONS_DIGEST_GH:-gh}"
SYSTEMCTL_BIN="${FM_DECISIONS_DIGEST_SYSTEMCTL:-systemctl}"
UNIT=firstmate-decisions-digest

die() { printf 'fm-decisions-digest: %s\n' "$*" >&2; exit "${2:-1}"; }
# A publish failure is also kept as one line for the Slack notice.
publish_fail() { printf '%s\n' "$*" > "$RUN_DIR/publish-error.txt"; say "$*"; }
say() { printf 'fm-decisions-digest: %s\n' "$*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^# What it gathers/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit "${1:-2}"
}

case "$PUBLISH_TIMEOUT" in ''|*[!0-9]*|0) die "FM_DECISIONS_DIGEST_PUBLISH_TIMEOUT must be a positive whole number of seconds" 2 ;; esac

# The flags that keep both model calls out of firstmate's own session contract.
claude_isolation() {
  printf '%s\n' --setting-sources user --settings \
    "$(jq -cn --arg a "$FM_HOME/CLAUDE.md" --arg b "$FM_HOME/AGENTS.md" '{claudeMdExcludes:[$a,$b]}')"
}

# --- gather -------------------------------------------------------------------

open_decisions_json() {
  scan_open_decisions "$STATE" | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t")
      | {task: .[0], key: .[1], verb: .[2], note: (.[3:] | join("\t"))})'
}

pr_state() {  # <url>
  local out
  if out=$(fm_run_timed 30 "$GH_BIN" pr view "$1" --json state,isDraft 2>/dev/null) \
    && printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r 'if .isDraft then "DRAFT" else (.state // "UNKNOWN") end'
  else
    printf 'UNKNOWN'
  fi
}

prs_json() {
  local meta task pr last state out='[]'
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    pr=$(sed -n 's/^pr=//p' "$meta" | tail -n 1)
    case "$pr" in https://*) ;; *) continue ;; esac
    task=$(basename "$meta" .meta)
    last=$(last_status_line "$STATE/$task.status")
    state=$(pr_state "$pr")
    out=$(printf '%s' "$out" | jq -c --arg task "$task" --arg pr "$pr" \
      --arg state "$state" --arg last "$last" \
      '. + [{task: $task, pr: $pr, live_state: $state, latest_status: $last}]')
  done
  printf '%s' "$out"
}

backlog_list() {  # <tasks-axi list args...>
  local out
  if out=$("$SELF_DIR/fm-tasks-axi.sh" list "$@" --limit 500 2>&1); then
    printf '%s' "$out"
  else
    printf 'UNAVAILABLE: %s' "$out"
  fi
}

gather() {
  local open prs held blocked
  open=$(open_decisions_json) || return 1
  prs=$(prs_json) || return 1
  held=$(backlog_list --state held --fields hold_kind,hold_reason,hold_until,blocked_by)
  blocked=$(backlog_list --blocked --fields blocked_by)
  jq -n --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson open "$open" --argjson prs "$prs" \
    --arg held "$held" --arg blocked "$blocked" \
    '{generated: $generated, open_decisions: $open, prs: $prs,
      held_backlog: $held, blocked_backlog: $blocked}'
}

# --- compose ------------------------------------------------------------------

SCHEMA='{
  "type": "object",
  "required": ["summary", "sections"],
  "properties": {
    "summary": {"type": "string"},
    "sections": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "items"],
        "properties": {
          "name": {"type": "string"},
          "items": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["kind", "title", "line"],
              "properties": {
                "kind": {"enum": ["merge", "hands", "decision", "parked"]},
                "title": {"type": "string"},
                "line": {"type": "string"},
                "rec": {"type": "string"},
                "alt": {"type": "string"},
                "tag": {"type": "string"},
                "tone": {"enum": ["now", "go", "wait"]},
                "link": {"type": "string"}
              }
            }
          }
        }
      }
    }
  }
}'

compose_prompt() {
  cat <<'EOF'
You write the captain's morning decisions digest for the software fleet firstmate runs for him.
The JSON input below holds, as of its "generated" time:
- open_decisions: questions and blockers workers raised that are still unanswered (task, key, verb, note).
- prs: recorded pull requests with live_state (OPEN, DRAFT, MERGED, CLOSED, UNKNOWN) and the task's latest status line.
- held_backlog: a table of backlog items held for the captain, each with its repo, hold_reason, and optional hold_until date.
- blocked_backlog: items waiting on other items.

Group everything waiting on the captain by project or domain first: one section per project or area of work, such as a product, a client, the estate master plan, or firstmate itself.
Name each section in his words, two to four words, never a raw repository slug. Order sections by how much needs him today, most first.
Within its section, mark each item with the kind of answer it needs:
- merge: a finished pull request waiting only on his word to merge. Only a PR whose live_state is OPEN; skip MERGED and CLOSED ones entirely.
- hands: a sign-in, a click, a purchase, a key, or a physical step only he can do.
- decision: a real product, scope, priority, or spending call.
- parked: held until another phase, another item, or a later date, with nothing for him to do today. An item whose hold_until date is still in the future is parked.
Use blocked_backlog only to say what an answer would unblock; never list a blocked item on its own.
When several records are the same ask, write it once.

For each item:
- title: a short plain-English name, three to seven words.
- line: one sentence on what is waiting and why, in his words. Never task ids, decision keys, branch names, or internal terms such as worktree, brief, status, hold, wake, crewmate, harness, lane, or pipeline. Name a file path only when he needs it to act, wrapped in backticks.
- rec: every merge and decision item carries one, as a short imperative phrase. Use the record's own recommendation when it states one; otherwise recommend the most conservative option the record names, or "talk it through with firstmate" when it names none. Hands and parked items carry one only when the record recommends something. Never invent facts.
- alt: optional, the main alternative, starting with "or: ".
- tag: optional two-to-five-word label such as "green" or "not urgent - due 2027"; tone "now" for urgent today, "go" for ready, "wait" for can-wait.
- link: for merge items, the PR URL exactly as given.
Within a section, order items most important first.
summary: one sentence saying how many things need him today and which one matters most.
Never use the em dash; use a plain dash. If nothing waits on him, return no sections and say so in the summary.

Input:
EOF
}

COMPOSE_ERROR=
compose() {  # <input.json> <digest.json>; sets COMPOSE_ERROR on failure
  local out
  local -a iso
  mapfile -t iso < <(claude_isolation)
  if ! out=$(cd "$FM_HOME" && { compose_prompt; cat "$1"; } \
    | fm_run_timed 900 "$CLAUDE_BIN" -p --model "$MODEL" --tools "" "${iso[@]}" \
      --no-session-persistence --output-format json --json-schema "$SCHEMA" 2>&1); then
    COMPOSE_ERROR=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)
    [ -n "$COMPOSE_ERROR" ] || COMPOSE_ERROR=$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')
    say "compose failed: $COMPOSE_ERROR"
    return 1
  fi
  if ! printf '%s' "$out" | jq -e '.is_error != true and (.structured_output.sections | type == "array")' >/dev/null 2>&1; then
    COMPOSE_ERROR=$(printf '%s' "$out" | jq -r '.result // .' 2>/dev/null | head -c 300)
    say "compose returned no digest: $COMPOSE_ERROR"
    return 1
  fi
  printf '%s' "$out" | jq '.structured_output' > "$2"
}

# --- render -------------------------------------------------------------------

# Shared by both renderers: drop empty sections, keep each section's items in
# answer-kind order (merge, hands, decision, parked) while preserving the
# composer's importance order inside a kind, move all-parked sections last, and
# give a merge item without a recommendation the obvious one.
# shellcheck disable=SC2016 # a jq program; its $names are jq's, not the shell's
JQ_NORMALIZE='
def rank: {"merge": 0, "hands": 1, "decision": 2, "parked": 3}[.kind] // 3;
def normalized:
  .sections = ((.sections // [])
    | map(.items = ((.items // []) | to_entries | sort_by((.value | rank), .key) | map(.value)
        | map(if .kind == "merge" and ((.rec // "") == "") then .rec = "merge it" else . end)))
    | map(select(.items | length > 0))
    | to_entries
    | sort_by((.value.items | all(.kind == "parked")), .key)
    | map(.value));
def count($k): [.sections[].items[] | select(.kind == $k)] | length;
def kindlabel: {"merge": "Merge word", "hands": "Your hands", "decision": "Your decision", "parked": "Parked"}[.kind] // "Parked";
'

render_html() {  # <digest.json> <built-label>
  jq -r --arg built "$2" "$JQ_NORMALIZE"'
def esc: tostring | @html | gsub("`(?<c>[^`]+)`"; "<code>\(.c)</code>");
def has($k): (.[$k] // "") | tostring | length > 0;
def tag: if has("tag") then "<span class=\"tag \(if .tone == "go" or .tone == "now" then .tone else "wait" end)\">\(.tag | esc)</span>" else "" end;
def card:
  "<div class=\"card \(.kind)\"><span class=\"kind \(.kind)\">\(kindlabel)</span><b>\(.title | esc)\(tag)</b>\n<p class=\"ask\">\(.line | esc)</p>"
  + (if has("rec") then "<p class=\"pick\">\(.rec | esc)</p>" else "" end)
  + (if has("alt") then "<p class=\"alt\">\(.alt | esc)</p>" else "" end)
  + (if has("link") and (.link | test("^https://[^\"<>\\s]+$")) then "<p class=\"alt\"><a href=\"\(.link)\">\(.link | esc)</a></p>" else "" end)
  + "</div>";
def section:
  ([.items[] | select(.kind != "parked")] | length) as $open
  | "<h2><span class=\"n\">\($open)</span>\(.name | esc)</h2>\n"
  + (.items | map(card) | join("\n")) + "\n";
def tally:
  [["merge", "merge word", "merge words"], ["hands", "for your hands", "for your hands"],
   ["decision", "decision", "decisions"], ["parked", "parked", "parked"]] as $kinds
  | . as $d
  | [$kinds[] as $k | ($d | count($k[0])) as $n | select($n > 0)
     | "<span class=\"kind \($k[0])\">\($n) \(if $n == 1 then $k[1] else $k[2] end)</span>"]
  | join(" ");
normalized |
"<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>Morning Decisions</title>
<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=Archivo:wght@600;800&family=Source+Serif+4:opsz,wght@8..60,400;8..60,600&family=JetBrains+Mono:wght@500&display=swap\">
<style>
:root{--bg:#f2f0eb;--card:#fffefb;--ink:#1c1a16;--mut:#6b6558;--line:#ddd7c9;--acc:#8a4a2c;--accbg:#f3e3d8;--go:#2f6b3f;--gobg:#e3efe4;--wait:#9a6b12;--waitbg:#f6ecd6;--pick:#1d5f7a;--pickbg:#dfeaf0;--parked:#7a7566;--parkedbg:#ebe8df;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){--bg:#171512;--card:#221f1a;--ink:#ece7dc;--mut:#a79e8c;--line:#3a352b;--acc:#e0a37c;--accbg:#3a2417;--go:#8fd39f;--gobg:#1c3324;--wait:#e6c26a;--waitbg:#3a2d10;--pick:#8fc6de;--pickbg:#173341;--parked:#a8a290;--parkedbg:#2a271f;color-scheme:dark}}
:root[data-theme=\"dark\"]{--bg:#171512;--card:#221f1a;--ink:#ece7dc;--mut:#a79e8c;--line:#3a352b;--acc:#e0a37c;--accbg:#3a2417;--go:#8fd39f;--gobg:#1c3324;--wait:#e6c26a;--waitbg:#3a2d10;--pick:#8fc6de;--pickbg:#173341;--parked:#a8a290;--parkedbg:#2a271f;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 \"Source Serif 4\",Georgia,serif}
main{max-width:760px;margin:0 auto;padding-inline:16px;padding-block:28px 72px}
h1{font:800 30px/1.1 Archivo,system-ui,sans-serif;margin:0 0 6px;letter-spacing:-.01em;text-wrap:balance}
.sub{color:var(--mut);margin:0 0 8px;max-width:60ch;font-size:15px}
.tally{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 6px}
.upd{font:500 11px \"JetBrains Mono\",ui-monospace,monospace;color:var(--mut);margin:0 0 22px}
h2{font:800 12px Archivo,system-ui,sans-serif;letter-spacing:.09em;text-transform:uppercase;color:var(--acc);margin:34px 0 10px;display:flex;align-items:baseline;gap:8px}
h2 .n{background:var(--accbg);color:var(--acc);border-radius:20px;padding:1px 9px;font:600 11px \"JetBrains Mono\",ui-monospace,monospace}
.none{color:var(--mut);font-size:15px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 16px 14px;margin:0 0 10px;overflow-wrap:anywhere}
.card b{font:600 16px Archivo,system-ui,sans-serif;display:block;margin:4px 0 6px}
.kind{display:inline-block;font:600 10.5px \"JetBrains Mono\",ui-monospace,monospace;letter-spacing:.04em;text-transform:uppercase;border-radius:5px;padding:2px 7px}
.kind.merge{background:var(--gobg);color:var(--go)}
.kind.hands{background:var(--waitbg);color:var(--wait)}
.kind.decision{background:var(--pickbg);color:var(--pick)}
.kind.parked{background:var(--parkedbg);color:var(--parked)}
.ask{margin:0 0 8px;font-size:14.5px}
.pick{display:inline-block;background:var(--gobg);color:var(--go);border-radius:6px;padding:3px 9px;font:600 12px \"JetBrains Mono\",ui-monospace,monospace;margin:0 0 6px}
.alt{margin:0;font-size:13px;color:var(--mut)}
.alt a{color:var(--pick)}
.tag{display:inline-block;font:600 10.5px \"JetBrains Mono\",ui-monospace,monospace;letter-spacing:.04em;text-transform:uppercase;border-radius:5px;padding:2px 7px;margin-left:6px;vertical-align:2px}
.tag.wait{background:var(--waitbg);color:var(--wait)}
.tag.go{background:var(--gobg);color:var(--go)}
.tag.now{background:var(--accbg);color:var(--acc)}
.card.parked{background:var(--parkedbg);border-color:transparent}
.card.parked .ask{color:var(--parked);margin:0}
code{font-family:\"JetBrains Mono\",ui-monospace,monospace;font-size:.9em;background:var(--pickbg);color:var(--pick);padding:1px 5px;border-radius:4px}
</style></head>
<body><main>
<h1>Morning Decisions</h1>
<p class=\"sub\">\(.summary | esc)</p>
<p class=\"tally\">\(tally)</p>
<p class=\"upd\">Built \($built) from the live backlog and open questions. Recommendation first on every item - reply \"go\" to take it, or say otherwise.</p>
"
+ (if (.sections | length) == 0 then "<p class=\"none\">Nothing needs you this morning.</p>\n" else (.sections | map(section) | join("")) end)
+ "</main></body></html>"
' "$1"
}

# Slack gets the headline, the tally, the page link, and per project one short
# bullet per item (answer kind, title, recommendation); the full lines live on
# the page. A section shows at most FM_DECISIONS_DIGEST_SLACK_ITEMS items (default
# 4) and names how many more are on the page, so the post stays readable.
render_slack() {  # <digest.json> <date-label> <page-line>
  jq -r --arg day "$2" --arg page "$3" --argjson cap "${FM_DECISIONS_DIGEST_SLACK_ITEMS:-4}" "$JQ_NORMALIZE"'
def sesc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
def has($k): (.[$k] // "") | tostring | length > 0;
def bullet:
  "• `\(kindlabel)` \(.title | sesc)"
  + (if has("rec") then " → _\(.rec | sesc)_" else "" end)
  + (if has("link") and (.link | test("^https://[^|<>\\s]+$")) then " <\(.link)|PR>" else "" end);
def section:
  [.items[] | select(.kind != "parked")] as $open
  | if ($open | length) == 0 then ""
    else "\n*\(.name | sesc)*\n" + ($open[:$cap] | map(bullet) | join("\n"))
      + (if ($open | length) > $cap then "\n_+\(($open | length) - $cap) more on the page_" else "" end) + "\n"
    end;
def tally:
  [["merge", "merge word", "merge words"], ["hands", "for your hands", "for your hands"],
   ["decision", "decision", "decisions"]] as $kinds
  | . as $d
  | [$kinds[] as $k | ($d | count($k[0])) as $n | select($n > 0)
     | "`\($n) \(if $n == 1 then $k[1] else $k[2] end)`"]
  | join("  ");
normalized
| count("parked") as $parked
| "*Morning decisions - \($day)*\n\(.summary | sesc)\n"
+ (tally | if length > 0 then . + "\n" else "" end)
+ "\($page)\n"
+ (.sections | map(section) | join(""))
+ (if $parked > 0 then "\n_Parked, no action needed: \($parked) - listed on the page._" else "" end)
' "$1"
}

# --- publish ------------------------------------------------------------------

publish_prompt() {  # <html> <result-file> <url-or-empty>
  local steps
  if [ -n "$3" ]; then
    steps="1. Call the Artifact tool with action \"read\" and url \"$3\".
2. Call the Artifact tool with action \"publish\", file_path \"$1\", and url \"$3\"."
  else
    steps="1. Skip; there is no existing page yet.
2. Call the Artifact tool with action \"publish\", file_path \"$1\", icon \"calendar\", and description \"The captain's daily decisions digest: merge words, hands-on steps, and decisions, each with a recommendation.\"."
  fi
  cat <<EOF
You are a one-shot page publisher. You are not firstmate and not a worker, and nothing else is asked of you.
Do exactly these steps and nothing else:
$steps
   The page file is final: publish it exactly as it is. Do not edit, rewrite, or restyle it, and do not publish any other file.
3. Use the Write tool to write one line of JSON to "$2":
   {"ok":true,"url":"<the artifact URL the publish result printed>"} when the publish succeeded, or
   {"ok":false,"error":"<the refusal or error in one line>"} when any step failed.
4. Stop.
EOF
}

publish() {  # <html> <result-file> <url-or-empty>; prints the page URL
  local html=$1 result=$2 url=$3 launch id waited=0 got
  local -a iso
  mapfile -t iso < <(claude_isolation)
  rm -f -- "$result" "$RUN_DIR/publish-session.log" "$RUN_DIR/publish-error.txt"
  if ! launch=$(cd "$FM_HOME" && fm_run_timed 120 "$CLAUDE_BIN" --bg --model "$PUBLISH_MODEL" \
      --dangerously-skip-permissions "${iso[@]}" -n "$UNIT" \
      "$(publish_prompt "$html" "$result" "$url")" < /dev/null 2>&1); then
    printf '%s\n' "$launch" > "$RUN_DIR/publish-launch.txt"
    publish_fail "could not start the publish session: $(printf '%s' "$launch" | tail -n 2 | tr '\n' ' ')"
    return 1
  fi
  printf '%s\n' "$launch" > "$RUN_DIR/publish-launch.txt"
  id=$(printf '%s' "$launch" | sed -n 's/.*backgrounded[^0-9a-f]*\([0-9a-f]\{6,\}\).*/\1/p' | head -n 1)
  if [ -z "$id" ]; then
    publish_fail "the publish session did not start: $(printf '%s' "$launch" | tail -n 2 | tr '\n' ' ')"
    return 1
  fi
  while [ ! -s "$result" ] && [ "$waited" -lt "$PUBLISH_TIMEOUT" ]; do
    sleep 5
    waited=$((waited + 5))
  done
  if [ ! -s "$result" ]; then
    # Keep the session's own screen, ANSI-stripped, before removing it: it is
    # the only record of why it stopped (a usage limit, a sign-in prompt).
    "$CLAUDE_BIN" logs "$id" 2>&1 | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -s ' ' \
      > "$RUN_DIR/publish-session.log" || :
  fi
  "$CLAUDE_BIN" stop "$id" >/dev/null 2>&1 || :
  "$CLAUDE_BIN" rm "$id" >/dev/null 2>&1 || :
  if [ ! -s "$result" ]; then
    publish_fail "the publish session wrote no result within ${PUBLISH_TIMEOUT}s$(
      grep -o -i "you've hit your[^·]*limit[^·]*\(· resets [^·]*\)\{0,1\}" "$RUN_DIR/publish-session.log" 2>/dev/null \
        | tail -n 1 | sed 's/^/ - /'); its screen is in $RUN_DIR/publish-session.log"
    return 1
  fi
  if ! jq -e '.ok == true and (.url | type == "string") and (.url | test("^https://claude\\.ai/\\S*artifact/\\S+$"))' "$result" >/dev/null 2>&1; then
    publish_fail "publish failed: $(jq -r '.error // .' "$result" 2>/dev/null | head -c 300)"
    return 1
  fi
  got=$(jq -r '.url' "$result")
  if [ -n "$url" ] && [ "$got" != "$url" ]; then
    publish_fail "publish landed on $got, not the fixed page $url"
    return 1
  fi
  printf '%s' "$got"
}

post() {  # <text-file>
  local out
  # Piped, not redirected: fm_run_timed backgrounds the command, and bash hands
  # a backgrounded command /dev/null in place of a redirected file.
  if ! out=$(cat -- "$1" | fm_run_timed 120 "$SLACK_BIN" post "$CHANNEL" - 2>&1); then
    say "Slack post failed: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"
    return 1
  fi
}

# --- run ----------------------------------------------------------------------

run() {
  local mode=full url='' page_url page_line rc=0 notice
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) mode=dry ;;
      --no-post) mode=no-post ;;
      -h|--help) usage 0 ;;
      *) die "unknown run option: $1" 2 ;;
    esac
    shift
  done
  command -v jq >/dev/null 2>&1 || die "jq is required"
  mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
  chmod 700 "$DIR" "$RUN_DIR" 2>/dev/null || :
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$DIR/.run.lock" || die "cannot open $DIR/.run.lock"
    flock -n 9 || die "another digest run is still going"
  fi

  gather > "$RUN_DIR/input.json" || die "gather failed"
  if ! compose "$RUN_DIR/input.json" "$RUN_DIR/digest.json"; then
    notice="*Morning decisions - $(date '+%a %-d %b')*"$'\n'"The digest could not be written this morning: $(printf '%s' "$COMPOSE_ERROR" \
      | tr '\n' ' ' | cut -c 1-200 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'). Nothing was lost - every open item is still on the backlog."
    printf '%s\n' "$notice" > "$RUN_DIR/slack.txt"
    [ "$mode" = full ] && post "$RUN_DIR/slack.txt"
    return 1
  fi
  render_html "$RUN_DIR/digest.json" "$(date '+%a %-d %b %Y, %H:%M %Z')" > "$RUN_DIR/index.html" \
    || die "rendering the page failed"

  [ -s "$URL_FILE" ] && url=$(head -n 1 "$URL_FILE")
  if [ "$mode" = dry ]; then
    page_line="<${url:-https://claude.ai/}|Open the full page> (dry run, not republished)"
  elif page_url=$(publish "$RUN_DIR/index.html" "$RUN_DIR/publish.json" "$url"); then
    [ -n "$url" ] || { printf '%s\n' "$page_url" > "$URL_FILE"; chmod 600 "$URL_FILE" 2>/dev/null || :; }
    page_line="<$page_url|Open the full page>"
  else
    rc=1
    page_line="_The page could not be updated this morning ($(head -n 1 "$RUN_DIR/publish-error.txt" 2>/dev/null \
      | cut -c 1-160 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')); the list below is current._"
    [ -n "$url" ] && page_line="$page_line Yesterday's page: <$url|open>"
  fi
  render_slack "$RUN_DIR/digest.json" "$(date '+%a %-d %b')" "$page_line" > "$RUN_DIR/slack.txt" \
    || die "rendering the Slack text failed"

  case "$mode" in
    dry)
      printf 'page: %s\nslack: %s\n' "$RUN_DIR/index.html" "$RUN_DIR/slack.txt"
      ;;
    no-post)
      printf 'page: %s\n' "${page_url:-not published}"
      ;;
    full)
      post "$RUN_DIR/slack.txt" || rc=1
      ;;
  esac
  return "$rc"
}

# --- install ------------------------------------------------------------------

unit_escape() { printf '%s' "$1" | sed 's/%/%%/g'; }

install_units() {
  local at=07:00 tz='' unit_dir link_dir f target
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) [ $# -ge 2 ] || die "--at needs HH:MM" 2; at=$2; shift ;;
      --tz) [ $# -ge 2 ] || die "--tz needs a timezone" 2; tz=$2; shift ;;
      -h|--help) usage 0 ;;
      *) die "unknown install option: $1" 2 ;;
    esac
    shift
  done
  case "$at" in [0-2][0-9]:[0-5][0-9]) ;; *) die "--at must be HH:MM, got: $at" 2 ;; esac
  command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 || die "systemd is required to install the timer"
  if [ -z "$tz" ]; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null) || tz=''
  fi
  [ -n "$tz" ] || die "could not read this machine's timezone; pass --tz <zone>" 2
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "*-*-* $at:00 $tz" >/dev/null 2>&1 \
      || die "systemd rejects the schedule \"$at $tz\"" 2
  fi
  unit_dir="$CONFIG/systemd"
  link_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  for f in "$UNIT.service" "$UNIT.timer"; do
    if [ -L "$link_dir/$f" ]; then
      target=$(readlink "$link_dir/$f")
      [ "$target" = "$unit_dir/$f" ] || die "$link_dir/$f already links to $target, another home's digest; uninstall it there first"
    elif [ -e "$link_dir/$f" ]; then
      die "$link_dir/$f exists and is not this home's link; remove it by hand first"
    fi
  done
  mkdir -p "$unit_dir" || die "cannot create $unit_dir"
  cat > "$unit_dir/$UNIT.service" <<EOF || die "cannot write $unit_dir/$UNIT.service"
# Written by bin/fm-decisions-digest.sh install; rerun that to change it.
[Unit]
Description=Firstmate daily decisions digest for $(unit_escape "$FM_HOME")
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart="$(unit_escape "$SELF_DIR/fm-decisions-digest.sh")" run
Environment="FM_HOME=$(unit_escape "$FM_HOME")"
Environment="PATH=$(unit_escape "$PATH")"
TimeoutStartSec=45min
# The publish step may start Claude Code's background service inside this
# unit; process mode leaves that shared service running when the run ends.
KillMode=process
UMask=0077
EOF
  cat > "$unit_dir/$UNIT.timer" <<EOF || die "cannot write $unit_dir/$UNIT.timer"
# Written by bin/fm-decisions-digest.sh install; rerun that to change it.
[Unit]
Description=Firstmate daily decisions digest at $at $tz

[Timer]
OnCalendar=*-*-* $at:00 $tz
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
  "$SYSTEMCTL_BIN" --user link "$unit_dir/$UNIT.service" "$unit_dir/$UNIT.timer" >/dev/null \
    || die "systemctl --user link failed"
  "$SYSTEMCTL_BIN" --user daemon-reload || die "systemctl --user daemon-reload failed"
  "$SYSTEMCTL_BIN" --user enable --now "$UNIT.timer" >/dev/null 2>&1 \
    || die "systemctl --user enable --now $UNIT.timer failed"
  printf 'installed: %s.timer runs daily at %s %s\n' "$UNIT" "$at" "$tz"
}

uninstall_units() {
  "$SYSTEMCTL_BIN" --user disable --now "$UNIT.timer" >/dev/null 2>&1 || :
  "$SYSTEMCTL_BIN" --user stop "$UNIT.service" >/dev/null 2>&1 || :
  local f link_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  for f in "$UNIT.service" "$UNIT.timer"; do
    [ -L "$link_dir/$f" ] && [ "$(readlink "$link_dir/$f")" = "$CONFIG/systemd/$f" ] && rm -f -- "$link_dir/$f"
  done
  "$SYSTEMCTL_BIN" --user daemon-reload >/dev/null 2>&1 || :
  printf 'uninstalled: %s\n' "$UNIT"
}

case "${1:-}" in
  gather) shift; [ $# -eq 0 ] || usage; gather ;;
  run) shift; run "$@" ;;
  install) shift; install_units "$@" ;;
  uninstall) shift; [ $# -eq 0 ] || usage; uninstall_units ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
