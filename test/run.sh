#!/bin/bash
#
# Runs everything: manifest validation, Model.js unit tests, and the shell
# helpers against a mock API. No network access and no StatusCake account
# needed -- which is the point, since the states that matter most (checks down,
# transitions, API errors, a token the API refuses) never show up on a healthy
# account.
#
# Nothing here touches your real keyring, token file or StatusCake account.
#
#   test/run.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

rc=0
run() {
  local name="$1"; shift
  echo "── $name"
  if "$@"; then
    echo
  else
    rc=1
    echo "   ^ FAILED"
    echo
  fi
}

# Only available on an Omarchy system; skipped elsewhere so the suite still
# runs in CI or on a plain Linux box.
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  run "manifest" omarchy-plugin-validate .
else
  echo "── manifest"
  echo "   skipped (omarchy-plugin-validate not on PATH)"
  echo
fi

if command -v node >/dev/null 2>&1; then
  run "Model.js" node test/model-test.js
else
  echo "── Model.js"
  echo "   SKIPPED -- node is required to test the model"
  echo
  rc=1
fi

run "fetch helper" bash test/helper-test.sh

run "setup helper" bash test/setup-test.sh

if (( rc != 0 )); then
  echo "FAILED"
  exit 1
fi
echo "All good."
