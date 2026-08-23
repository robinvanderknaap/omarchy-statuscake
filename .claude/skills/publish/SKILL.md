---
name: publish
description: Prepare a new release of this Omarchy plugin — run the release gate, propose a version bump, update CHANGELOG.md, merge to main and tag, then stop before pushing. Use when Robin says "publish", "release", "cut a version", "ship it", or asks to prepare/tag a new version of the plugin.
---

# publish

Prepares a release of `robinvanderknaap.statuscake` and stops one command short of
publishing it.

## Why this is careful

`omarchy plugin update` fetches **`origin/HEAD`** and runs
`git merge --ff-only`. There is no staging, no channel, and no version
negotiation:

- **Whatever sits on `main` is the release.** Tags and `manifest.json`'s
  `version` are documentation; the update path never reads either.
- **Pushing to `main` is the act of publishing.** Every installed copy picks it
  up on the user's next update. That is why this skill never pushes.
- **History on `main` must be append-only.** Users fast-forward; a rebase or
  force-push after publishing leaves them stuck on
  `cannot fast-forward; you have local changes`, with no clean way out.
- **The tip must pass `omarchy-plugin-validate`.** The updater validates after
  merging and hard-resets the user's checkout if it fails.
- **Users read the raw diff.** `omarchy plugin update` prints
  `git diff HEAD FETCH_HEAD` and asks them to confirm, so commit messages and
  the shape of the diff are user-facing.

## Workflow

Development happens on a topic branch; `main` only ever moves at a release.

```
topic branch  →  release gate  →  version bump + CHANGELOG  →  ff-only merge to main  →  tag  →  (human pushes)
```

The plugin directory *is* the git repo *is* the installed plugin, so the
working tree is live code. Never leave it mid-release.

## Steps

### 1. Run the gate

```bash
.claude/skills/publish/release-check.sh
```

It checks, and stops at the first failure:

- the working tree is clean and on a topic branch, not `main`
- `test/run.sh` passes (which includes `omarchy-plugin-validate`)
- **a fresh clone validates** — the single most valuable check here. The
  updater validates the *published* tree, and `manifest.json` entry points must
  exist in it. A `.qml` file that was never `git add`ed passes local validation
  and breaks every install.
- no secrets: no token-shaped strings, no `statuscake-token`, no personal tags
  or account URLs in tracked files
- no symlinks anywhere (validate refuses them, so an install would fail)
- `main` can fast-forward to this branch

Fix anything it reports before going on. Do not work around it.

### 2. Propose a version

Read the diff since the last release:

```bash
git log --oneline "$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD)"..HEAD
git diff "$(git describe --tags --abbrev=0 2>/dev/null)"..HEAD -- manifest.json
```

Propose a bump and say **why**, then confirm with Robin before applying. While
below 1.0, a breaking change takes the minor.

| Bump | When |
|---|---|
| major | after 1.0: a settings key removed or renamed, a manifest schema change, an entry point moved |
| minor | pre-1.0 breaking changes; any new setting, command flag, or user-visible feature |
| patch | fixes and internal work with no change to the settings schema or the user-facing contract |

A **removed or renamed settings key is breaking** even though nothing crashes:
it silently stops honouring a value the user set in `shell.json`, with no
warning. `hideWhenAllUp` was exactly this case. Say so in the changelog.

Check whether the change needs a **shell restart** to take effect. Any `.qml`
change does, because `rescanPlugins` — which the updater runs — does not
rebuild a mounted bar widget. If so, the changelog entry must say
`Run 'omarchy restart shell' after updating.`

### 3. Write the changelog entry

Add a section at the top of `CHANGELOG.md` under the new version and today's
date. Draft it from the commits, then **have Robin edit it before committing** —
it is the one place the version number is explained.

Write for someone deciding whether to accept the update: what changed for them,
what they must do, what breaks. Not a commit dump.

### 4. Bump, commit, merge, tag

```bash
# manifest.json version → the agreed number
git add manifest.json CHANGELOG.md
git commit -m "Release v<version>"

git checkout main
git merge --ff-only <topic-branch>
git tag -a "v<version>" -m "v<version>"
```

`--ff-only` keeps `main` linear, which keeps the diff users read clean. If it
refuses, `main` has commits the branch lacks — stop and work out why rather
than forcing it.

### 5. Stop

Print the push command and hand it over. **Do not run it.**

```
main is ready at v<version>.

  git push origin main --follow-tags
```

Then remind Robin that after users update they need `omarchy restart shell`
for any QML change, and that once this is pushed the history cannot be rewritten.

## Never

- Push, force-push, or rebase `main` — pushing is Robin's call, and rewriting
  breaks every installed copy.
- Tag a commit that is not on `main`.
- Release with a dirty working tree; the tree is the live plugin.
- Bump the version without a changelog entry saying what it means.
- Skip the fresh-clone check because the local tests passed.
