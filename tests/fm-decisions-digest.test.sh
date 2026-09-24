#!/usr/bin/env bash
# tests/fm-decisions-digest.test.sh - the captain's daily decisions digest.
#
# Covers gather (open decisions folded from status logs, recorded PRs with their
# live state), the project-first page and Slack renderings, the first publish
# recording the fixed page URL and later runs republishing to it, the compose
# and publish failure paths, and the systemd timer install. Claude, Slack, gh,
# tasks-axi, and systemctl are PATH fakes; the live claude.ai publish is
# verified by hand (see the script header).
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decisions-digest)
BIN="$ROOT/bin/fm-decisions-digest.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/calls.log"
: > "$LOG"

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# compose: -p reads the prompt on stdin and answers with the fixture digest.
# publish: --bg takes the prompt as its last argument and writes the result file.
log=${FAKE_LOG:?}
case "$1" in
  -p)
    cat > "$FAKE_DIR/compose-prompt.txt"
    printf 'compose model=%s\n' "$3" >> "$log"
    [ -z "${FAKE_COMPOSE_FAIL:-}" ] || { printf '{"is_error":true,"result":"You<ve hit your weekly limit"}\n'; exit 1; }
    jq -c '{is_error:false, structured_output:.}' "$FAKE_DIGEST"
    ;;
  stop|rm) printf '%s %s\n' "$1" "$2" >> "$log" ;;
  logs) printf '\033[1m❯ publish\033[0m\nYou'"'"'ve hit your weekly limit · resets Sep 28, 3am\n' ;;
  *)
    prompt=${!#}
    printf '%s' "$prompt" > "$FAKE_DIR/publish-prompt.txt"
    printf 'bg\n' >> "$log"
    result=$(printf '%s' "$prompt" | sed -n 's/.*write one line of JSON to "\(.*\)":.*/\1/p')
    url=$(printf '%s' "$prompt" | sed -n 's/.*action "read" and url "\([^"]*\)".*/\1/p' | head -n 1)
    if [ -n "${FAKE_PUBLISH_SILENT:-}" ]; then
      :
    elif [ -n "${FAKE_PUBLISH_FAIL:-}" ]; then
      printf '{"ok":false,"error":"not a writer"}\n' > "$result"
    else
      printf '{"ok":true,"url":"%s"}\n' "${FAKE_LAND_URL:-${url:-https://claude.ai/artifact/NEWPAGE123}}" > "$result"
    fi
    printf 'Starting background service…\nbackgrounded · abc123 · firstmate-decisions-digest\n'
    ;;
esac
SH
cat > "$FAKEBIN/firstmate-slack" <<'SH'
#!/usr/bin/env bash
printf 'slack %s %s\n' "$1" "$2" >> "$FAKE_LOG"
cat > "$FAKE_DIR/slack-posted.txt"
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$3" in
  */pull/1) printf '{"state":"OPEN","isDraft":false}\n' ;;
  */pull/2) printf '{"state":"MERGED","isDraft":false}\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'count: 1\ntasks[1]{id,state,kind,repo,title,hold_reason}:\n  fixture-held,queued,task,alpha,Fixture held item,"Waits on the captain"\n'
SH
cat > "$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$FAKE_LOG"
if [ "$2" = link ]; then
  shift 2
  for f in "$@"; do ln -sf "$f" "$XDG_CONFIG_HOME/systemd/user/$(basename "$f")"; done
fi
SH
chmod +x "$FAKEBIN"/*

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_digest() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" PATH="$FAKEBIN:$PATH" \
    FAKE_LOG="$LOG" FAKE_DIR="$TMP_ROOT" FAKE_DIGEST="$TMP_ROOT/digest.json" \
    XDG_CONFIG_HOME="$TMP_ROOT/xdg" "$BIN" "$@"
}

cat > "$TMP_ROOT/digest.json" <<'JSON'
{
  "summary": "Two things need you today; the <b>alpha</b> merge matters most.",
  "sections": [
    {"name": "Parked Things", "items": [
      {"kind": "parked", "title": "Later work", "line": "Waits for phase two."}
    ]},
    {"name": "Alpha Product", "items": [
      {"kind": "decision", "title": "Pick a <script>shape</script>", "line": "See `docs/plan.md` first.", "rec": "take the small one", "alt": "or: wait"},
      {"kind": "merge", "title": "Merge the alpha fix", "line": "Green and idle.", "tag": "green", "tone": "go", "link": "https://github.com/o/r/pull/1"},
      {"kind": "hands", "title": "Sign in once", "line": "One login on OG1.", "tag": "today", "tone": "now"}
    ]}
  ]
}
JSON

# --- gather -------------------------------------------------------------------

home=$(make_home gather)
printf 'needs-decision [key=shape]: pick a shape\nworking: still going\n' > "$home/state/alpha.status"
printf 'needs-decision [key=old]: old question\nresolved [key=old]: answered\n' > "$home/state/beta.status"
fm_write_meta "$home/state/alpha.meta" kind=ship "pr=https://github.com/o/r/pull/1"
fm_write_meta "$home/state/beta.meta" kind=ship "pr=https://github.com/o/r/pull/2"
out=$(run_digest "$home" gather) || fail "gather failed"
assert_equals "alpha shape needs-decision pick a shape" \
  "$(printf '%s' "$out" | jq -r '.open_decisions | map("\(.task) \(.key) \(.verb) \(.note)") | join(",")')" \
  "gather keeps a buried open decision and drops a resolved one"
assert_equals "alpha:OPEN,beta:MERGED" \
  "$(printf '%s' "$out" | jq -r '.prs | map("\(.task):\(.live_state)") | join(",")')" \
  "gather records each PR with its live forge state"
assert_contains "$(printf '%s' "$out" | jq -r .held_backlog)" "fixture-held" "gather includes the held backlog"
pass "gather folds open decisions, recorded PRs, and the held backlog"

# --- first run: publish, record the URL, post -------------------------------

home=$(make_home first)
: > "$LOG"
run_digest "$home" run >/dev/null || fail "first run failed"
assert_equals "https://claude.ai/artifact/NEWPAGE123" "$(cat "$home/data/decisions-digest/artifact-url")" \
  "the first publish records the fixed page URL"
assert_not_contains "$(cat "$TMP_ROOT/publish-prompt.txt")" 'action "read"' "a first publish reads no earlier page"
assert_grep "stop abc123" "$LOG" "the publish session is stopped after its result"
assert_grep "rm abc123" "$LOG" "the publish session is removed after its result"
assert_grep "slack post decisions" "$LOG" "the digest is posted to #decisions"
assert_contains "$(cat "$TMP_ROOT/compose-prompt.txt")" "Group everything waiting on the captain by project" \
  "the composer is asked to group by project first"

page="$home/data/decisions-digest/run/index.html"
assert_grep "Pick a &lt;script&gt;shape&lt;/script&gt;" "$page" "item text is HTML-escaped"
assert_no_grep "<script>" "$page" "no raw markup from the digest reaches the page"
assert_grep "<code>docs/plan.md</code>" "$page" "backticked paths render as code"
assert_grep '<span class="tag now">today</span>' "$page" "an urgent tag keeps its own tone"
alpha_at=$(grep -n "Alpha Product" "$page" | cut -d: -f1)
parked_at=$(grep -n "Parked Things" "$page" | cut -d: -f1)
[ "$alpha_at" -lt "$parked_at" ] || fail "an all-parked section sorts after sections needing the captain"
merge_at=$(grep -n "Merge the alpha fix" "$page" | cut -d: -f1)
hands_at=$(grep -n "Sign in once" "$page" | cut -d: -f1)
decision_at=$(grep -n "Pick a &lt;script" "$page" | cut -d: -f1)
[ "$merge_at" -lt "$hands_at" ] && [ "$hands_at" -lt "$decision_at" ] \
  || fail "items inside a project run merge word, then hands, then decision"

slack=$(cat "$TMP_ROOT/slack-posted.txt")
assert_contains "$slack" "<https://claude.ai/artifact/NEWPAGE123|Open the full page>" "Slack links the fixed page"
assert_contains "$slack" "*Alpha Product*" "Slack groups by project"
# shellcheck disable=SC2016 # literal Slack backticks, not a command substitution
assert_contains "$slack" '• `Merge word` Merge the alpha fix → _merge it_ <https://github.com/o/r/pull/1|PR>' \
  "a Slack bullet carries the answer kind, title, recommendation (merge it by default), and PR link"
assert_contains "$slack" "&lt;b&gt;alpha&lt;/b&gt;" "Slack text is escaped"
assert_not_contains "$slack" "Parked Things" "an all-parked project stays off the Slack post"
assert_contains "$slack" "Parked, no action needed: 1" "Slack counts the parked items"
pass "a first run publishes a new page, records its URL, and posts the project-first digest"

# --- later run: republish the same URL --------------------------------------

: > "$LOG"
run_digest "$home" run >/dev/null || fail "second run failed"
assert_contains "$(cat "$TMP_ROOT/publish-prompt.txt")" \
  'action "read" and url "https://claude.ai/artifact/NEWPAGE123"' "a later run reads the fixed page first"
assert_contains "$(cat "$TMP_ROOT/publish-prompt.txt")" \
  'and url "https://claude.ai/artifact/NEWPAGE123".' "a later run republishes to the fixed page"
code=0
FAKE_LAND_URL=https://claude.ai/artifact/OTHER999 run_digest "$home" run >/dev/null 2>&1 || code=$?
expect_code 1 "$code" "a publish that lands on another page fails the run"
assert_equals "https://claude.ai/artifact/NEWPAGE123" "$(cat "$home/data/decisions-digest/artifact-url")" \
  "a stray publish never replaces the fixed URL"
assert_contains "$(cat "$TMP_ROOT/slack-posted.txt")" "could not be updated" "Slack says the page was not updated"
pass "later runs republish the fixed page and refuse a stray one"

# --- failures -----------------------------------------------------------------

home=$(make_home publish-fail)
code=0
FAKE_PUBLISH_FAIL=1 run_digest "$home" run >/dev/null 2>&1 || code=$?
expect_code 1 "$code" "a refused publish fails the run"
assert_absent "$home/data/decisions-digest/artifact-url" "a refused publish records no URL"
assert_contains "$(cat "$TMP_ROOT/slack-posted.txt")" "*Alpha Product*" "the digest is still posted when the page is not"
assert_contains "$(cat "$TMP_ROOT/slack-posted.txt")" "could not be updated this morning (publish failed: not a writer)" \
  "Slack says why the page was not updated"
pass "a refused publish still posts the digest and exits nonzero"

home=$(make_home publish-silent)
: > "$LOG"
code=0
err=$(FAKE_PUBLISH_SILENT=1 FM_DECISIONS_DIGEST_PUBLISH_TIMEOUT=5 run_digest "$home" run --no-post 2>&1 >/dev/null) || code=$?
expect_code 1 "$code" "a publish session that writes nothing fails the run"
assert_contains "$err" "You've hit your weekly limit · resets Sep 28, 3am" "the failure names why the session stopped"
assert_grep "hit your weekly limit" "$home/data/decisions-digest/run/publish-session.log" "the session screen is kept"
assert_no_grep $'\033' "$home/data/decisions-digest/run/publish-session.log" "the kept screen has no terminal escapes"
assert_grep "rm abc123" "$LOG" "a silent publish session is still removed"
pass "a publish session that never answers is cleaned up and its reason reported"

home=$(make_home compose-fail)
: > "$LOG"
code=0
FAKE_COMPOSE_FAIL=1 run_digest "$home" run >/dev/null 2>&1 || code=$?
expect_code 1 "$code" "a failed compose fails the run"
assert_no_grep "bg" "$LOG" "nothing is published without a digest"
assert_contains "$(cat "$TMP_ROOT/slack-posted.txt")" "could not be written this morning: You&lt;ve hit your weekly limit." \
  "Slack says the digest failed and why, escaped"
pass "a failed compose posts a short notice instead of a digest"

home=$(make_home dry)
: > "$LOG"
run_digest "$home" run --dry-run >/dev/null || fail "dry run failed"
assert_no_grep "bg" "$LOG" "a dry run publishes nothing"
assert_no_grep "slack" "$LOG" "a dry run posts nothing"
assert_present "$home/data/decisions-digest/run/index.html" "a dry run still renders the page"
pass "a dry run renders without publishing or posting"

# --- install ------------------------------------------------------------------

home=$(make_home install)
mkdir -p "$TMP_ROOT/xdg/systemd/user"
: > "$LOG"
run_digest "$home" install --at 07:00 --tz America/St_Lucia >/dev/null || fail "install failed"
timer="$home/config/systemd/firstmate-decisions-digest.timer"
service="$home/config/systemd/firstmate-decisions-digest.service"
assert_grep "OnCalendar=*-*-* 07:00:00 America/St_Lucia" "$timer" "the timer fires daily at the chosen time"
assert_grep "Persistent=true" "$timer" "a missed run fires once after a reboot"
assert_grep "Environment=\"FM_HOME=$home\"" "$service" "the service pins this home"
assert_grep "fm-decisions-digest.sh\" run" "$service" "the service runs the digest"
assert_grep "systemctl --user enable --now firstmate-decisions-digest.timer" "$LOG" "the timer is enabled"
assert_equals "$timer" "$(readlink "$TMP_ROOT/xdg/systemd/user/firstmate-decisions-digest.timer")" \
  "the timer is linked into the user manager"
other=$(make_home other)
code=0
run_digest "$other" install >/dev/null 2>&1 || code=$?
expect_code 1 "$code" "a second home cannot take over the installed timer"
code=0
run_digest "$home" install --at 7am >/dev/null 2>&1 || code=$?
expect_code 2 "$code" "a malformed time is refused"
run_digest "$home" uninstall >/dev/null || fail "uninstall failed"
assert_absent "$TMP_ROOT/xdg/systemd/user/firstmate-decisions-digest.timer" "uninstall unlinks the timer"
pass "install links and enables a daily timer for this home and uninstall removes it"
