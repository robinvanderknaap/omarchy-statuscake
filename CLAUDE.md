# CLAUDE.md

An Omarchy shell bar widget showing StatusCake uptime counts. `README.md` says
what it does for a user; this file is what a session needs to work on it.

Target: **Omarchy 4.0.0**, Quickshell 0.3.0, Hyprland.

## Ground rules

**Never let a test reach the real keyring, token file, or account.** Anything
that might call `secret-tool` runs with a stub ahead of the real binary on
`PATH` — `command -v secret-tool` finds the system one through an empty
directory, and `secret-tool store` then overwrites the developer's own token
with a fixture. That happened once and the token was unrecoverable.
`test/setup-test.sh` keeps `$WORK/bin` on `PATH` in every case; a case wanting a
*failing* keyring gets a failing stub, never an empty directory.

**All decisions live in `Model.js` as pure functions.** No QML types, no I/O, no
timers; the QML files hold Qt objects and wiring. That is what makes the states
that matter — checks down, transitions between polls, API errors, a refused
token — testable under `node`, since none of them occur on a healthy account. A
conditional in QML that could be wrong belongs in `Model.js` with a test.

**The token never touches a command line, `shell.json`, or a log.** It reaches
`curl` via `-H @-` on stdin and `bin/statuscake-setup` via `--stdin`, and is
verified against the live API before storage, so a typo cannot replace a working
token.

**The pill has no hidden state.** It is the only route to the panel, and the
panel the only route to the settings, so any option hiding the widget hides its
own off switch. `hideWhenAllUp` shipped once and had to be undone by hand in
`shell.json`; `visible` is gone from the label shape so it cannot come back.

**Nothing personal ships:** no token, no real tag names, no account URLs — not
in code, comments, or example output.

## Dev loop

```bash
test/run.sh              # manifest validation + Model.js + the shell helpers
omarchy restart shell    # the only way to see a QML change
```

`test/run.sh` needs no network and no account: `test/mock-api.py` stands in for
the API. A pre-commit hook runs `omarchy-plugin-validate`.

`omarchy-shell shell rescanPlugins` does **not** rebuild a mounted bar widget —
it logs `Local plugin changed, reloading` and leaves the running instance alone,
so you keep testing stale code. Always a full restart.

QML cannot be type-checked here: `qmllint` is syntax-only and cannot resolve
`QtQuick`, let alone `qs.Ui`, so a wrong property name shows up only at runtime.
Restart the shell and read `journalctl -t omarchy-shell` before claiming a QML
change works.

## Layout

| | |
|---|---|
| `manifest.json` | id, entry point, settings schema + defaults |
| `Model.js` | every decision, pure, `module.exports` guard for node |
| `BarWidget.qml` | the pill; owns `settings`, the fetch `Process`, the refresh `Timer` |
| `Panel.qml` | the only window: check list, and settings behind the cog — a `KeyboardPanel` under the pill |
| `bin/statuscake-uptime` | auth, pagination, tag filter → one JSON document |
| `bin/statuscake-setup` | verify and store a token; interactive or `--stdin --json` |
| `bin/statuscake-tags` | every distinct tag on the account, as a JSON array, for the picker |
| `assets/statuscake.svg` | StatusCake's mark, in the panel header — their trademark, see README |
| `CHANGELOG.md` | user-facing; written at release time by the `publish` skill |

## One window, and why `KeyboardPanel`

**`PopupCard` cannot be typed into.** It is an xdg-popup on the bar's layer
surface, and the bar never asks for keyboard focus (`BarPanel` at
`plugins/bar/Bar.qml:989` sets no `keyboardFocus`, so it defaults to `None`), so
a field there takes the caret and receives no keystroke.

So `Panel.qml` is one `KeyboardPanel` — the base every first-party panel that
must be typed into uses (`panels/network`, `panels/weather`) — with settings as
a second view in the same card, reached by the cog and left by Escape.
`PanelKeyCatcher` sits inside it: `blocked` while a field has focus so the field
owns its keys, and each field hands Escape back through `Panel.goBack()`, which
leaves settings first and the panel second.

**Never hold `WlrKeyboardFocus.Exclusive` while a surface is up**, which a
screen-centered settings modal did here once. Hyprland then routes *every*
pointer event to it whatever output the cursor is over, so no other window can
be clicked; `KeyboardPanel` primes `Exclusive` for 75ms and settles on
`OnDemand` for exactly that reason. A layer surface is also not a toplevel, so
anything that looks like a window is one `SUPER+W` cannot close.

## Undocumented bar-widget contracts

`shell/plugins/bar/README.md` is wrong or silent on these:

- **A plain `MouseArea` does not receive left clicks.** The bar covers every
  slot with its own MouseArea for drag-to-reorder and dispatches a click by
  calling `triggerPress(button)` on the widget root;
  `Bar.moduleTargetClickable()` tests for that function, and without it the
  widget is not clickable and gets no pointing-hand cursor. Right and middle
  *do* reach your own MouseArea.
- **`bar.shellQuote()` does not exist.** Use `Util.shellQuote()` from
  `qs.Commons`; the documented name throws at runtime.
- **`rescanPlugins` does not rebuild a mounted widget** (see Dev loop).
- **There is no uninstall hook, or any lifecycle hook.**
  `omarchy-plugin-remove` unsets `enabled`, deletes (or backs up) the folder,
  and rescans — it runs nothing from the plugin on the way out, and the
  manifest has no field that would let it. Anything a plugin leaves outside its
  own folder — here the keyring entry — outlives the plugin unless the user
  deletes it first, which is why the settings view carries **Remove token**
  (`Model.tokenRemovable`) and the README an uninstall section.

## Settings

Declared in `manifest.json` (`barWidget.defaults` + `barWidget.schema`), stored
inline on the widget's entry in `~/.config/omarchy/shell.json`, and read through
`Model.readSettings()`, which clamps and type-guards because that file is
hand-editable and unvalidated. Manifest, `readSettings` defaults and the
settings view all list the keys — keep them in step.

Writing goes through `bar.shell.updateEntryInline(moduleName, entry)`, the
in-process path the clock panel uses — never `omarchy bar set`. Apply locally
first (`BarWidget.persistSetting`) so the control redraws on the click rather
than after the file round-trip. `Model.settingsEntry()` copies unrecognised keys
through, so the panel cannot drop a key another version wrote.

**Every control writes on the click**, and nothing here should grow a commit
step. Tags are picked from a `MultiSelect` fed by `bin/statuscake-tags`, not
typed: the API matches tags literally, so a typo is not an error but a pill
reading `0 up, 0 down`. `tags` stays a comma-separated string in `shell.json`
(`Model.tagList()` in, `Model.joinTags()` out), so a hand-edited value still
shows up selected and a tag since deleted still displays.

`matchAnyTag` and `notify` default **on**, and `Model.readSettings()` is what
enforces that (`!== false`, not `=== true`): nothing in the shell reads
`barWidget.defaults` — `shell.qml:694` carries it into plugin metadata and no
consumer exists — so the manifest block is documentation and this function is
the only thing that decides. Match-any is on because one tag per check is the
common account shape, and matching *all* of two tags there returns nothing.

`Model.tokenState()` produces the line above the token field: tone, glyph,
sentence. "Works" is deliberately not the status probe's word — that runs
`--no-verify` and can only say a token exists and where. What proves one is a
poll coming back with data: no extra API call, and a revoked token reads as
rejected the moment the next poll says so. `tone` maps to `Color.accent` /
`Color.urgent` / `Color.muted` — Omarchy palettes carry no success colour, and a
hardcoded green would be the only thing here ignoring the theme.

The API token section is one either/or, and `Model.tokenBlocksSettings()`
decides it — the same predicate that gates the rest of the view. No working
token shows the paste field, the verified-before-saved hint and the create-a-
token link; a working one shows a **Remove token** button and the warning that
uninstalling leaves the token behind. Never both: replacing a working token is
removing it and pasting the next one, and a token worth rotating in a hurry is
usually one the API has already rejected, which shows the form anyway. That
also means a rejected token cannot be deleted from the panel — pasting over it
is the fix, and the README carries `secret-tool clear` for the rest.

`Model.tokenRemovable()` gates the removal control on a token this can
actually delete: a keyring entry or the file, never `$STATUSCAKE_API_TOKEN`,
where `--remove` would clear something nothing is reading and leave the
environment still winning. A working environment token therefore leaves the
section as its status line alone, which is the honest shape: nothing to paste
that would win, nothing here that can delete it. Removal is two clicks — the
first arms the button and names what it would delete — because there is no undo.

Until `Model.tokenBlocksSettings()` clears, the view is the token form alone,
hidden rather than disabled. The rest lives in one gated `Column`: put a new
section inside it unless it works with no token.

`allowMultiple` is `false`. Differently tag-filtered pills would need it `true`;
flipping it later breaks no existing install.

## Helper contracts

`bin/statuscake-uptime` always prints one JSON object, success or failure, and
the exit code is redundant:

```
{"error": null,      "code": null,   "data": [...]}
{"error": "message", "code": "slug", "data": []}
```

`error` is prose for a human; `code` is a stable slug — `missing_dep`, `usage`,
`no_token`, `unauthorized`, `rate_limited`, `network`, `http`, `parse`,
`too_large`. Branch on `code`, never the prose (`Model.needsToken()`,
`Model.tokenRejected()`).

**Nothing unbounded reaches QML.** A response is read whole into a shell
variable and `StdioCollector` buffers the whole stream before QML sees a byte,
and neither has a limit of its own, so the size of both is whatever the far end
decides to send unless something caps it. Three things do: `--max-filesize`
(curl aborts the transfer at 4 MB, mid-stream and with no declared
`Content-Length` — verified on curl 8.21), a length check behind it for a curl
that would not, and `MAX_DOC_BYTES` on the merged document, since 50 pages that
each pass the per-page cap still add up. `Model.payloadTooLarge()` is the last
line, in front of `JSON.parse`, which would double the string on the thread that
draws the bar. `test/mock-api.py huge` and `huge-nolength` cover both shapes.
`statuscake-setup --json` follows the same one-object rule with its own codes.

`bin/statuscake-tags` is the deliberate exception: a bare JSON array on success,
nothing on failure with the reason on stderr and a non-zero exit. That is the
whole contract `MultiSelect.optionsCommand` has — it parses stdout as JSON only
when it starts with `[`, and on failure keeps its last good list.

## The API

`GET https://api.statuscake.com/v1/uptime`, `Authorization: Bearer <token>` —
the only host this plugin contacts.

Per-test fields: `{id, name, website_url, test_type, status: "up"|"down",
paused, uptime, tags}`, plus `metadata.page_count` on the envelope.

Paginate with `limit=100&page=N`; **100 is the API maximum** and the helper
merges pages into one document. Optional `tags=` and `matchany=true`: tags match
literally, so the helper normalizes `"prod, web"` to `"prod,web"` or a stray
space silently matches nothing, and `matchany` without `tags` is rejected by the
API, which is why `fetchArgs` drops it. Rate limits are real — a low refresh
interval burns through them and 429 comes back as `rate_limited`.

## Shell internals

`qs.Ui` and `qs.Commons` are shell internals with **no compatibility promise to
plugins**. Read them rather than guessing: source at
`/usr/share/omarchy/shell/`, `Ui/qmldir` lists every component. Precedents worth
reading: `panels/weather` (polling widget, inline editing), `panels/network`
(secret entry in a panel), `panels/clock` (persisting inline settings),
`dev-gallery` (every control in one place), `plugins/agents` (brand marks as
`assets/<id>.svg` rendered as `Image` — set `sourceSize`, since an SVG
rasterises at that size and scales from there).

`MultiSelect` deserves its own warning: **nothing else in the shell uses it.** It
works — its QQC popup reparents to the layer surface's contentItem and takes
keystrokes there, verified by hand — but it is the least-exercised thing this
plugin depends on and the likeliest to change without notice.

If an Omarchy update breaks the panel, that coupling is the first place to look.

## Repo

Developed in place at `~/.config/omarchy/plugins/robinvanderknaap.statuscake/`,
which *is* the git repo *is* the installed plugin. Source cannot live elsewhere
and be symlinked in: `omarchy-plugin-validate` hard-fails on any symlink inside
a plugin folder, and `omarchy-plugin-add` refuses a symlinked target.

The manifest `id` is permanent and global: it is the install path
(`$PLUGINS_DIR/<id>`), `plugin add` refuses one already in use, it must match
`^[A-Za-z0-9][A-Za-z0-9._-]*$`, `omarchy.*` is reserved, and renaming it orphans
every existing install.

`omarchy-plugin-catalog` only walks local directories, so discovery is someone
sharing the git URL (`github.com/robinvanderknaap/omarchy-statuscake`) and
`README.md` carries the weight a listing page otherwise would.

**Pushing `main` is the act of publishing** — `omarchy plugin update`
fast-forwards every install to `origin/HEAD`, so there is no staging and no way
back: **never force-push or rebase `main`**. Until 0.1.0 ships there is nothing
to break and work goes straight onto `main`, unpushed; after it, use a topic
branch and move `main` only at a release.

Releasing is the `publish` skill (`.claude/skills/publish/`): it runs
`release-check.sh`, agrees a version bump, updates `CHANGELOG.md`, merges and
tags, and stops before pushing, which is Robin's call. Do not hand-roll a
release around it.
