#!/bin/bash
#
# Exercises bin/statuscake-setup's non-interactive path -- the one the bar
# panel drives: --stdin to take the token, --json to answer in one parseable
# shape, --status to report where a token lives.
#
# The rule that matters most here is verify-before-store: a rejected token must
# never overwrite a working one, because the panel makes it one keystroke to
# paste something wrong into a widget that was fine a second ago.
#
# The script under test is copied to a temp file with its API constant pointed
# at localhost, and runs against a stub keyring and a throwaway HOME. The real
# script, your keyring and your real token are never touched.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

SETUP="../bin/statuscake-setup"
[[ -x $SETUP ]] || { echo "setup-test: $SETUP not found or not executable" >&2; exit 1; }

for tool in python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "setup-test: $tool is required" >&2; exit 1; }
done

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

UNDER_TEST="$WORK/statuscake-setup"
sed 's|^API=.*|API="http://127.0.0.1:8933/v1/uptime"|' "$SETUP" > "$UNDER_TEST"
chmod +x "$UNDER_TEST"
cp mock-api.py "$WORK/"

# Stub keyring. Backed by a file so the test can assert what was stored and can
# simulate a box with no keyring at all by pointing PATH somewhere else.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/secret-tool" <<'STUB'
#!/bin/bash
STORE="$KEYRING_FILE"
case "$1" in
lookup) [[ -s $STORE ]] && cat "$STORE" || exit 1 ;;
store)  cat > "$STORE" ;;
clear)  [[ -e $STORE ]] && rm -f "$STORE" || exit 1 ;;
*) exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/secret-tool"

# A keyring that is present but refuses to store -- a locked or unrunning
# session keyring, which is the case the file fallback exists for.
mkdir -p "$WORK/lockedkeyring"
cat > "$WORK/lockedkeyring/secret-tool" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$WORK/lockedkeyring/secret-tool"

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

# Fresh HOME and keyring for each case, so one test's stored token can never
# make the next one pass.
reset_state() {
  rm -rf "$WORK/home" "$WORK/keyring"
  mkdir -p "$WORK/home"
}

# Runs the script under test with the mock API in $1, everything after -- as
# arguments, and $STDIN_TOKEN piped in. Sets $OUT and $RC.
run_setup() {
  local mode="$1"; shift
  # $WORK/bin always sits on PATH ahead of the system one, whatever a case
  # prepends, so a stub is guaranteed to shadow the real secret-tool. Without
  # that backstop a test case reaches the developer's own keyring and
  # overwrites their real token.
  local stub_path="${PATH_PREFIX:+$PATH_PREFIX:}$WORK/bin"
  local dir_before=$PWD
  cd "$WORK" || return 1

  coproc MOCK { python3 mock-api.py "$mode"; }
  read -r _ready <&"${MOCK[0]}"

  OUT=$(printf '%s' "${STDIN_TOKEN-}" |
    env -u STATUSCAKE_API_TOKEN ${ENV_TOKEN:+STATUSCAKE_API_TOKEN="$ENV_TOKEN"} \
      HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" \
      KEYRING_FILE="$WORK/keyring" PATH="$stub_path:$PATH" \
      "$UNDER_TEST" "$@" 2>"$WORK/err")
  RC=$?

  echo "" >&"${MOCK[1]}" 2>/dev/null
  wait "$MOCK_PID" 2>/dev/null
  cd "$dir_before" || return 1
}

echo "setup-test: bin/statuscake-setup"

# --- storing a good token --------------------------------------------------

reset_state
STDIN_TOKEN="GOODTOKEN" run_setup ok --stdin --json
check_eq "stdin store exits 0" "0" "$RC"
check_eq "stdin store reports ok" "true" "$(jq -r '.ok' <<<"$OUT")"
check_eq "prefers the keyring" "keyring" "$(jq -r '.stored' <<<"$OUT")"
check_eq "stores the token verbatim" "GOODTOKEN" "$(cat "$WORK/keyring" 2>/dev/null)"
check_eq "emits exactly one JSON object" "1" "$(jq -s 'length' <<<"$OUT")"
check_eq "says nothing on stdout but the JSON" "true" "$(jq -e 'has("ok")' <<<"$OUT")"

# The keyring is the only destination. A locked one is reported, not worked
# around: writing the token to a plaintext file instead would be a silent
# downgrade at the one moment the user is least likely to notice.
reset_state
STDIN_TOKEN="GOODTOKEN" PATH_PREFIX="$WORK/lockedkeyring" run_setup ok --stdin --json
check_eq "a refusing keyring exits 1" "1" "$RC"
check_eq "a refusing keyring reports failure" "false" "$(jq -r '.ok' <<<"$OUT")"
check_eq "a refusing keyring is coded as store_failed" "store_failed" "$(jq -r '.code' <<<"$OUT")"
check_contains "the locked keyring is named as the likely cause" "locked" "$(jq -r '.error' <<<"$OUT")"
check_eq "a refusing keyring stores the token nowhere" "" \
  "$(find "$WORK/home" -type f 2>/dev/null)"

reset_state
STDIN_TOKEN="GOODTOKEN" run_setup ok --stdin --json --file
check_eq "--file is gone, not silently accepted" "usage" "$(jq -r '.code' <<<"$OUT")"

reset_state
STDIN_TOKEN=$'GOODTOKEN\n' run_setup ok --stdin --json
check_eq "a trailing newline is not part of the token" "GOODTOKEN" "$(cat "$WORK/keyring" 2>/dev/null)"

reset_state
STDIN_TOKEN="  GOODTOKEN  " run_setup ok --stdin --json
check_eq "pasted whitespace is trimmed" "GOODTOKEN" "$(cat "$WORK/keyring" 2>/dev/null)"

# --- verify before store ---------------------------------------------------
# The panel makes it one keystroke to paste something wrong. A token that the
# API rejects must leave whatever was working in place.

reset_state
printf 'WORKINGTOKEN' > "$WORK/keyring"
STDIN_TOKEN="BADTOKEN" run_setup 401 --stdin --json
check_eq "a rejected token exits 1" "1" "$RC"
check_eq "a rejected token reports failure" "false" "$(jq -r '.ok' <<<"$OUT")"
check_eq "a rejected token is named as rejected" "rejected" "$(jq -r '.code' <<<"$OUT")"
check_contains "the rejection is explained" "read access to uptime tests" "$(jq -r '.error' <<<"$OUT")"
check_eq "the working token survives a rejected one" "WORKINGTOKEN" "$(cat "$WORK/keyring")"

reset_state
printf 'WORKINGTOKEN' > "$WORK/keyring"
STDIN_TOKEN="MAYBEGOOD" run_setup 429 --stdin --json
check_eq "rate limiting is not a bad token" "rate_limited" "$(jq -r '.code' <<<"$OUT")"
check_eq "nothing is stored while rate limited" "WORKINGTOKEN" "$(cat "$WORK/keyring")"

reset_state
printf 'WORKINGTOKEN' > "$WORK/keyring"
STDIN_TOKEN="MAYBEGOOD" run_setup 500 --stdin --json
check_eq "an API fault is not a bad token" "http" "$(jq -r '.code' <<<"$OUT")"
check_eq "nothing is stored on an API fault" "WORKINGTOKEN" "$(cat "$WORK/keyring")"

reset_state
STDIN_TOKEN="" run_setup ok --stdin --json
check_eq "an empty token exits 1" "1" "$RC"
check_eq "an empty token is named as empty" "empty" "$(jq -r '.code' <<<"$OUT")"
check_eq "an empty token stores nothing" "" "$(cat "$WORK/keyring" 2>/dev/null)"

reset_state
STDIN_TOKEN="   " run_setup ok --stdin --json
check_eq "whitespace alone is an empty token" "empty" "$(jq -r '.code' <<<"$OUT")"

# --- reporting where the token lives ---------------------------------------

reset_state
run_setup ok --status --json --no-verify
check_eq "no token is reported as no_token" "no_token" "$(jq -r '.code' <<<"$OUT")"
check_eq "no token exits 1" "1" "$RC"

reset_state
printf 'GOODTOKEN' > "$WORK/keyring"
run_setup ok --status --json --no-verify
check_eq "--no-verify finds the keyring token" "keyring" "$(jq -r '.source' <<<"$OUT")"
check_eq "--no-verify does not claim the token works" "null" "$(jq -r '.valid' <<<"$OUT")"
check_eq "--no-verify calls no API at all" "0" "$(jq 'length' "$WORK/seen.json" 2>/dev/null || echo 0)"

reset_state
printf 'GOODTOKEN' > "$WORK/keyring"
ENV_TOKEN="ENVTOKEN" run_setup ok --status --json --no-verify
check_eq "\$STATUSCAKE_API_TOKEN outranks the keyring" "env" "$(jq -r '.source' <<<"$OUT")"

reset_state
printf 'GOODTOKEN' > "$WORK/keyring"
run_setup ok --status --json
check_eq "a verified token is reported valid" "true" "$(jq -r '.valid' <<<"$OUT")"

reset_state
printf 'STALETOKEN' > "$WORK/keyring"
run_setup 401 --status --json
check_eq "a stale token is found but not valid" "false" "$(jq -r '.valid' <<<"$OUT")"
check_eq "a stale token still names its source" "keyring" "$(jq -r '.source' <<<"$OUT")"
check_eq "a stale token exits 1" "1" "$RC"

# --- removal ---------------------------------------------------------------

reset_state
printf 'GOODTOKEN' > "$WORK/keyring"
run_setup ok --remove --json
check_eq "--remove exits 0" "0" "$RC"
check_eq "--remove clears the keyring" "1" "$([[ -e $WORK/keyring ]] && echo 0 || echo 1)"

# --- bad invocations -------------------------------------------------------

reset_state
run_setup ok --bogus --json
check_eq "an unknown option exits 1" "1" "$RC"
check_eq "an unknown option answers in JSON anyway" "usage" "$(jq -r '.code' <<<"$OUT")"
check_contains "an unknown option is named" "--bogus" "$(jq -r '.error' <<<"$OUT")"

reset_state
run_setup ok --json --bogus
check_eq "--json before the bad option works too" "usage" "$(jq -r '.code' <<<"$OUT")"

echo
if (( failed > 0 )); then
  echo "setup-test: $passed passed, $failed failed"
  exit 1
fi
echo "setup-test: $passed passed"
