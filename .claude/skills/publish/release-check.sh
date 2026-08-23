#!/bin/bash
#
# Release gate for robinvanderknaap.statuscake. Everything that must be true before a
# commit is allowed to become what every installed copy fast-forwards to.
#
# Run from anywhere in the repo:
#   .claude/skills/publish/release-check.sh
#
# Exits 0 only if every check passes. Nothing here writes to the repo, pushes,
# or touches the network.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "release-check: not inside a git repository" >&2
  exit 1
}
cd "$ROOT" || exit 1

MAIN_BRANCH="main"

passed=0
failed=0

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; passed=$((passed + 1)); }
no() {
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [[ -n ${2:-} ]] && printf '      %s\n' "$2"
  failed=$((failed + 1))
}

echo "release-check: robinvanderknaap.statuscake"
echo

# --- the tree is releasable ------------------------------------------------

branch=$(git rev-parse --abbrev-ref HEAD)
if [[ $branch == "$MAIN_BRANCH" ]]; then
  no "on a topic branch" "you are on $MAIN_BRANCH; release from a branch so main only moves at a release"
else
  ok "on a topic branch ($branch)"
fi

if [[ -n $(git status --porcelain) ]]; then
  no "working tree is clean" "this directory is the installed plugin; a release must not be cut mid-edit"
else
  ok "working tree is clean"
fi

# Untracked files are the ones that bite: they work locally and do not ship.
untracked=$(git ls-files --others --exclude-standard)
if [[ -n $untracked ]]; then
  no "nothing untracked" "$(tr '\n' ' ' <<<"$untracked")"
else
  ok "nothing untracked"
fi

# --- what the shell refuses ------------------------------------------------

# omarchy-plugin-validate refuses any symlink in a plugin folder, so one here
# means the install fails outright rather than degrading.
symlinks=$(find . -path ./.git -prune -o -type l -print 2>/dev/null)
if [[ -n $symlinks ]]; then
  no "no symlinks" "$(tr '\n' ' ' <<<"$symlinks")"
else
  ok "no symlinks"
fi

# --- the test suite --------------------------------------------------------
# Includes omarchy-plugin-validate against the working tree.

if out=$(bash test/run.sh 2>&1); then
  ok "test/run.sh passes"
else
  no "test/run.sh passes" "run it directly to see the failures"
  printf '%s\n' "$out" | sed 's/^/      /' | tail -20
fi

# --- what a user actually installs -----------------------------------------
#
# The updater validates the published tree, and manifest.json entry points must
# exist in it. A file that was never committed passes every local check and
# breaks every install, so validate a clone of HEAD rather than this directory.

if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  clone=$(mktemp -d) || exit 1
  trap 'rm -rf "$clone"' EXIT
  if git clone --quiet --no-local --depth 1 "file://$ROOT" "$clone/plugin" 2>/dev/null &&
    git -C "$clone/plugin" checkout --quiet --detach "$(git rev-parse HEAD)" 2>/dev/null; then
    if omarchy-plugin-validate "$clone/plugin" >/dev/null 2>&1; then
      ok "a fresh clone validates"
    else
      no "a fresh clone validates" \
        "$(omarchy-plugin-validate "$clone/plugin" 2>&1 | head -3)"
    fi

    # validate only checks manifest entry points. The file most likely to be
    # missing is one they import -- a new Panel or Model that was never added --
    # which validates clean and then fails at runtime. Compare the whole source
    # set instead.
    while IFS= read -r src; do
      [[ -n $src ]] || continue
      [[ -e "$clone/plugin/$src" ]] && continue
      no "source file is committed: $src" "present here, missing from HEAD"
    done < <(cd "$ROOT" && find . -name '*.qml' -o -name '*.js' | sed 's|^\./||' | grep -v '^\.git/')

    # Entry points spelled out, because validate's message names the field and
    # not what is missing from the commit.
    while IFS= read -r ep; do
      [[ -n $ep ]] || continue
      if [[ -e "$clone/plugin/$ep" ]]; then
        ok "entry point is committed: $ep"
      else
        no "entry point is committed: $ep" "exists here but is not in HEAD"
      fi
    done < <(jq -r '.entryPoints // {} | .[]' manifest.json 2>/dev/null)
  else
    no "a fresh clone validates" "could not clone HEAD for checking"
  fi
else
  echo "  – skipped fresh-clone validation (omarchy-plugin-validate not on PATH)"
fi

# --- nothing personal ships ------------------------------------------------

# The token is 40+ chars of base64-ish text. Matching the assignment shapes
# rather than the alphabet alone keeps the plugin's own sample text clean.
if git grep -nIE '(token|secret|api_key|apikey)[[:space:]]*[=:][[:space:]]*["'"'"'][A-Za-z0-9_-]{20,}' \
  -- . ':!CHANGELOG.md' >/dev/null 2>&1; then
  no "no token-shaped strings in tracked files" \
    "$(git grep -nIE '(token|secret|api_key|apikey)[[:space:]]*[=:][[:space:]]*["'"'"'][A-Za-z0-9_-]{20,}' -- . ':!CHANGELOG.md' | head -3)"
else
  ok "no token-shaped strings in tracked files"
fi

if git ls-files | grep -q 'statuscake-token'; then
  no "no token file committed" "$(git ls-files | grep 'statuscake-token')"
else
  ok "no token file committed"
fi

# The account URL is fine; a specific account's dashboard is not.
if git grep -nI 'app\.statuscake\.com/[A-Za-z]*/[0-9]' -- . >/dev/null 2>&1; then
  no "no account-specific URLs" "$(git grep -nI 'app\.statuscake\.com/[A-Za-z]*/[0-9]' | head -3)"
else
  ok "no account-specific URLs"
fi

# --- main can take it ------------------------------------------------------

if git rev-parse --verify --quiet "$MAIN_BRANCH" >/dev/null; then
  if git merge-base --is-ancestor "$MAIN_BRANCH" HEAD; then
    ok "$MAIN_BRANCH fast-forwards to this branch"
  else
    no "$MAIN_BRANCH fast-forwards to this branch" \
      "$MAIN_BRANCH has commits this branch lacks; merge them in first, never force"
  fi
else
  no "$MAIN_BRANCH exists" "no $MAIN_BRANCH branch in this repo"
fi

# Published history is append-only: warn if the branch rewrites what origin has.
if git rev-parse --verify --quiet "origin/$MAIN_BRANCH" >/dev/null; then
  if git merge-base --is-ancestor "origin/$MAIN_BRANCH" HEAD; then
    ok "origin/$MAIN_BRANCH history is preserved"
  else
    no "origin/$MAIN_BRANCH history is preserved" \
      "this branch does not contain origin/$MAIN_BRANCH; publishing would need a force-push, which breaks every install"
  fi
fi

# --- version and changelog -------------------------------------------------
# Reported, not enforced: the bump is agreed with a human in the skill's step 2.

version=$(jq -r '.version // ""' manifest.json 2>/dev/null)
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
echo
echo "  manifest version : ${version:-<missing>}"
echo "  last tag         : ${last_tag:-<none, never released>}"
if [[ -n $last_tag && "v$version" == "$last_tag" ]]; then
  echo "  note             : version still matches $last_tag — bump it before releasing"
fi
if [[ -f CHANGELOG.md ]] && ! grep -q "\[\?$version\]\?" CHANGELOG.md 2>/dev/null; then
  echo "  note             : CHANGELOG.md has no entry for $version yet"
fi

echo
if (( failed > 0 )); then
  echo "release-check: $passed passed, $failed failed — not releasable"
  exit 1
fi
echo "release-check: $passed passed — releasable"
