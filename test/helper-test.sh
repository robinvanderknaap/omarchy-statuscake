#!/bin/bash
#
# Exercises bin/statuscake-uptime against mock-api.py: pagination, tag handling,
# the Authorization header, and every documented failure mode. bin/statuscake-tags
# rides along at the end, since it is a reader of the same helper.
#
# The script under test is copied to a temp file with its API constant pointed
# at localhost. The real script is never modified.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

HELPER="../bin/statuscake-uptime"
[[ -x $HELPER ]] || { echo "helper-test: $HELPER not found or not executable" >&2; exit 1; }

for tool in python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "helper-test: $tool is required" >&2; exit 1; }
done

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

UNDER_TEST="$WORK/statuscake-uptime"
sed 's|^API=.*|API="http://127.0.0.1:8933/v1/uptime"|' "$HELPER" > "$UNDER_TEST"
chmod +x "$UNDER_TEST"
cp mock-api.py "$WORK/"

passed=0
failed=0

ok() { printf '  ok    %s\n' "$1"; passed=$((passed + 1)); }
no() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failed=$((failed + 1)); }

check_eq() {
  local name="$1" want="$2" got="$3"
  [[ $want == "$got" ]] && ok "$name" || no "$name" "expected [$want], got [$got]"
}

check_contains() {
  local name="$1" needle="$2" haystack="$3"
  [[ $haystack == *"$needle"* ]] && ok "$name" || no "$name" "expected to contain [$needle], got [$haystack]"
}

# Runs the helper against a mock in the given mode. Sets $OUT and $RC, and
# leaves the recorded requests in $WORK/seen.json.
run_mode() {
  local mode="$1"; shift
  ( cd "$WORK" && rm -f seen.json )
  local dir_before=$PWD
  cd "$WORK" || return 1

  coproc MOCK { python3 mock-api.py "$mode"; }
  read -r _ready <&"${MOCK[0]}"

  OUT=$(STATUSCAKE_API_TOKEN=TESTTOKEN "$UNDER_TEST" "$@")
  RC=$?

  echo "" >&"${MOCK[1]}" 2>/dev/null
  wait "$MOCK_PID" 2>/dev/null
  cd "$dir_before" || return 1
}

echo "helper-test: bin/statuscake-uptime"

# --- success path ----------------------------------------------------------

run_mode ok
check_eq "exits 0 on success" "0" "$RC"
check_eq "no error reported" "null" "$(jq -c '.error' <<<"$OUT")"
check_eq "no failure code on success" "null" "$(jq -c '.code' <<<"$OUT")"
check_eq "merges all pages (100+100+7)" "207" "$(jq '.data | length' <<<"$OUT")"
check_eq "no check counted twice" "207" "$(jq '[.data[].id] | unique | length' <<<"$OUT")"
check_eq "requests exactly one page each" "3" "$(jq 'length' "$WORK/seen.json")"
check_eq "requests the pages in order" '["1","2","3"]' "$(jq -c '[.[].query.page[0]]' "$WORK/seen.json")"
check_eq "asks for the API maximum page size" '["100","100","100"]' "$(jq -c '[.[].query.limit[0]]' "$WORK/seen.json")"
check_eq "sends the token on every page" '["Bearer TESTTOKEN","Bearer TESTTOKEN","Bearer TESTTOKEN"]' \
  "$(jq -c '[.[].auth]' "$WORK/seen.json")"
check_eq "preserves down status through the merge" "2" "$(jq '[.data[] | select(.status=="down")] | length' <<<"$OUT")"
check_eq "preserves paused flag through the merge" "1" "$(jq '[.data[] | select(.paused)] | length' <<<"$OUT")"

# --- tag handling ----------------------------------------------------------

run_mode ok --tags "prod"
check_eq "sends a single tag" '["prod"]' "$(jq -c '.[0].query.tags' "$WORK/seen.json")"
check_eq "omits matchany unless asked" "null" "$(jq -c '.[0].query.matchany' "$WORK/seen.json")"

run_mode ok --tags "prod, web" --match-any
check_eq "strips whitespace after commas" '["prod,web"]' "$(jq -c '.[0].query.tags' "$WORK/seen.json")"
check_eq "sends matchany when asked" '["true"]' "$(jq -c '.[0].query.matchany' "$WORK/seen.json")"

run_mode ok --tags " prod ,, staging , "
check_eq "drops empty tags and outer whitespace" '["prod,staging"]' "$(jq -c '.[0].query.tags' "$WORK/seen.json")"

# --- failure modes ---------------------------------------------------------
# Every one must produce the documented {"error": ..., "data": []} shape and
# exit 1, so the QML side parses one shape and never inspects exit codes.

for mode in 401 403 429 500 garbage; do
  run_mode "$mode"
  check_eq "$mode exits 1" "1" "$RC"
  check_eq "$mode returns an empty data array" "0" "$(jq '.data | length' <<<"$OUT")"
  check_eq "$mode reports a non-null error" "true" "$(jq '.error != null' <<<"$OUT")"
  check_eq "$mode reports a machine-readable code" "true" "$(jq '.code != null and .code != ""' <<<"$OUT")"
done

run_mode 401
check_contains "401 names the token as the problem" "rejected the API token" "$(jq -r '.error' <<<"$OUT")"
check_eq "401 is coded as unauthorized" "unauthorized" "$(jq -r '.code' <<<"$OUT")"
run_mode 429
check_contains "429 suggests the fix" "refresh interval" "$(jq -r '.error' <<<"$OUT")"
check_eq "429 is coded as rate_limited" "rate_limited" "$(jq -r '.code' <<<"$OUT")"
run_mode garbage
check_contains "garbage body is reported as unparseable" "unparseable" "$(jq -r '.error' <<<"$OUT")"
check_eq "garbage is coded as parse" "parse" "$(jq -r '.code' <<<"$OUT")"

# The panel offers the token form on this code alone, so a wrong one here means
# either a form that never appears or one that hijacks unrelated failures.
run_mode 500
check_eq "an API fault is not coded as a token problem" "http" "$(jq -r '.code' <<<"$OUT")"

# --- oversized responses ---------------------------------------------------
# The response is read whole into a shell variable and then handed to QML, so
# without a cap the ceiling on both is whatever the far end chooses to send.
# Both shapes matter: a declared Content-Length curl refuses before reading the
# body, and an undeclared one it has to abandon mid-transfer.

for mode in huge huge-nolength; do
  run_mode "$mode"
  check_eq "$mode exits 1" "1" "$RC"
  check_eq "$mode is coded as too_large" "too_large" "$(jq -r '.code' <<<"$OUT")"
  check_eq "$mode returns an empty data array" "0" "$(jq '.data | length' <<<"$OUT")"
  # The point of the cap: what reaches QML stays small whatever the API sends.
  small=false; (( ${#OUT} < 4096 )) && small=true
  check_eq "$mode keeps the helper's own output small" "true" "$small"
done

# --- argument and token errors (no server needed) --------------------------

OUT=$(STATUSCAKE_API_TOKEN=x "$UNDER_TEST" --bogus 2>/dev/null); RC=$?
check_eq "unknown option exits 1" "1" "$RC"
check_contains "unknown option is named" "unknown option" "$(jq -r '.error' <<<"$OUT")"
check_eq "unknown option is coded as usage" "usage" "$(jq -r '.code' <<<"$OUT")"

OUT=$(STATUSCAKE_API_TOKEN=x "$UNDER_TEST" --tags 2>/dev/null)
check_contains "--tags without a value is rejected" "needs a value" "$(jq -r '.error' <<<"$OUT")"

# A missing token must be actionable, not just "failed". The developer running
# this very likely has a working token in their keyring, so shadow secret-tool
# with a stub that finds nothing and point HOME at an empty dir -- otherwise
# this case silently passes by reaching the real API instead.
mkdir -p "$WORK/stub"
printf '#!/bin/sh\nexit 1\n' > "$WORK/stub/secret-tool"
chmod +x "$WORK/stub/secret-tool"

OUT=$(env -u STATUSCAKE_API_TOKEN HOME="$WORK" PATH="$WORK/stub:$PATH" "$UNDER_TEST" 2>/dev/null); RC=$?
check_eq "missing token exits 1" "1" "$RC"
check_eq "missing token is coded so the panel can offer the form" "no_token" "$(jq -r '.code' <<<"$OUT")"
check_eq "missing token returns the documented shape" "0" "$(jq '.data | length' <<<"$OUT")"

# --- bin/statuscake-tags ---------------------------------------------------
# The tag picker's option list. It shells out to statuscake-uptime through its
# own directory, so a copy sitting beside the rewritten helper reaches the mock
# without the tags script knowing anything about it.

TAGS_UNDER_TEST="$WORK/statuscake-tags"
cp ../bin/statuscake-tags "$TAGS_UNDER_TEST"
chmod +x "$TAGS_UNDER_TEST"

run_tags() {
  local mode="$1"; shift
  ( cd "$WORK" && rm -f seen.json )
  local dir_before=$PWD
  cd "$WORK" || return 1

  coproc MOCK { python3 mock-api.py "$mode"; }
  read -r _ready <&"${MOCK[0]}"

  OUT=$(STATUSCAKE_API_TOKEN=TESTTOKEN "$TAGS_UNDER_TEST" "$@" 2>"$WORK/err")
  RC=$?
  ERR=$(<"$WORK/err")

  echo "" >&"${MOCK[1]}" 2>/dev/null
  wait "$MOCK_PID" 2>/dev/null
  cd "$dir_before" || return 1
}

echo
echo "helper-test: bin/statuscake-tags"

run_tags ok
check_eq "tags exits 0" "0" "$RC"
check_eq "every distinct tag, once, sorted" '["page1","page2","page3","prod","web"]' "$OUT"
# A filtered fetch only returns the checks that already match, so the picker
# would lose every tag the moment one was selected.
check_eq "asks for every check, not the filtered slice" "null" "$(jq -c '.[0].query.tags' "$WORK/seen.json")"
check_eq "reads every page" "3" "$(jq 'length' "$WORK/seen.json")"

# MultiSelect keeps its last good list when the options command fails, so a
# failure must not reach stdout as something listable.
run_tags 401
check_eq "a rejected token exits 1" "1" "$RC"
check_eq "and prints nothing the picker could list" "" "$OUT"
check_contains "and says why on stderr" "rejected the API token" "$ERR"

echo
if (( failed > 0 )); then
  echo "helper-test: $passed passed, $failed failed"
  exit 1
fi
echo "helper-test: $passed passed"
