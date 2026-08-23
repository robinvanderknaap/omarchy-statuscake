// Unit tests for Model.js. Run via test/run.sh, or directly: node test/model-test.js
//
// These cover the states live data cannot reach on a healthy account: checks
// down, mixed up/down/paused, transitions between refreshes, and API errors.
const assert = require("node:assert")
const M = require("../Model.js")

let passed = 0
const failures = []

function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failures.push({ name, message: e.message })
  }
}

// Build an API-shaped check; only the interesting fields need naming per test.
function check(over = {}) {
  return Object.assign({
    id: "1",
    name: "example",
    website_url: "https://example.test",
    test_type: "HTTP",
    status: "up",
    paused: false,
    uptime: 99.9,
    tags: []
  }, over)
}

function payload(checks) {
  return { error: null, data: checks }
}

// --- summarize -------------------------------------------------------------

test("summarize counts up, down and paused separately", () => {
  const s = M.summarize(payload([
    check({ id: "a", status: "up" }),
    check({ id: "b", status: "down" }),
    check({ id: "c", status: "down" }),
    check({ id: "d", status: "up", paused: true })
  ]))
  assert.strictEqual(s.up, 1)
  assert.strictEqual(s.down, 2)
  assert.strictEqual(s.paused, 1)
  assert.strictEqual(s.error, null)
  assert.strictEqual(s.hasData, true)
})

test("summarize excludes paused checks from the total", () => {
  const s = M.summarize(payload([
    check({ id: "a", status: "up" }),
    check({ id: "b", status: "up", paused: true })
  ]))
  // total is the health denominator: 1/1, never 1/2 with one permanently absent.
  assert.strictEqual(s.total, 1)
})

test("summarize treats a paused DOWN check as paused, not down", () => {
  const s = M.summarize(payload([check({ status: "down", paused: true })]))
  assert.strictEqual(s.down, 0)
  assert.strictEqual(s.paused, 1)
})

test("summarize reports helper errors and never invents a healthy state", () => {
  const s = M.summarize({ error: "rate limited by StatusCake (HTTP 429)", data: [] })
  assert.strictEqual(s.error, "rate limited by StatusCake (HTTP 429)")
  assert.strictEqual(s.hasData, false)
  assert.strictEqual(s.up, 0)
  assert.strictEqual(s.down, 0)
})

test("summarize survives malformed input", () => {
  assert.strictEqual(M.summarize(null).error, "no response")
  assert.strictEqual(M.summarize(undefined).error, "no response")
  assert.strictEqual(M.summarize("nonsense").error, "no response")
  assert.strictEqual(M.summarize({ error: null, data: null }).hasData, true)
  assert.strictEqual(M.summarize({ error: null, data: null }).total, 0)
})

test("summarize skips unparseable entries instead of crashing", () => {
  const s = M.summarize({ error: null, data: [null, check({ status: "down" }), "junk"] })
  assert.strictEqual(s.down, 1)
  assert.strictEqual(s.checks.length, 1)
})

test("summarize maps an unrecognised status to unknown, counting it as neither", () => {
  const s = M.summarize(payload([check({ status: "wobbling" })]))
  assert.strictEqual(s.checks[0].status, "unknown")
  assert.strictEqual(s.up, 0)
  assert.strictEqual(s.down, 0)
})

// --- sorting ---------------------------------------------------------------

test("sortChecks puts down first, then up, then paused", () => {
  const s = M.summarize(payload([
    check({ id: "a", name: "zeta", status: "up" }),
    check({ id: "b", name: "alpha", status: "up", paused: true }),
    check({ id: "c", name: "mid", status: "down" })
  ]))
  assert.deepStrictEqual(s.checks.map(c => c.name), ["mid", "zeta", "alpha"])
})

test("sortChecks is alphabetical within a group, so the list is stable", () => {
  const s = M.summarize(payload([
    check({ id: "a", name: "delta", status: "down" }),
    check({ id: "b", name: "bravo", status: "down" })
  ]))
  assert.deepStrictEqual(s.checks.map(c => c.name), ["bravo", "delta"])
})

// --- barLabel --------------------------------------------------------------

test("barLabel shows a plain count when everything is up", () => {
  const l = M.barLabel(M.summarize(payload([check(), check({ id: "2" })])), {})
  assert.strictEqual(l.text, M.ICON_OK + " 2")
  assert.strictEqual(l.urgent, false)
})

test("barLabel goes urgent and shows down/total when a check is down", () => {
  const l = M.barLabel(M.summarize(payload([
    check({ id: "1", status: "down" }),
    check({ id: "2", status: "up" }),
    check({ id: "3", status: "up" })
  ])), {})
  assert.strictEqual(l.text, M.ICON_DOWN + " 1/3")
  assert.strictEqual(l.urgent, true)
})

// The pill is the only route to the panel and the settings behind it, so it
// has no hidden state to test -- an early hideWhenAllUp option had to be undone
// by hand-editing shell.json once it fired.
test("the pill is never asked to disappear", () => {
  const allUp = M.summarize(payload([check()]))
  assert.strictEqual(M.barLabel(allUp, {}).visible, undefined)
  assert.strictEqual(M.barLabel(allUp, { hideWhenAllUp: true }).visible, undefined)
})

// --- tooltip ---------------------------------------------------------------

test("barLabel splits icon and detail so a vertical bar can stack them", () => {
  const l = M.barLabel(M.summarize(payload([
    check({ id: "1", status: "down" }),
    check({ id: "2", status: "up" })
  ])), {})
  assert.strictEqual(l.icon, M.ICON_DOWN)
  assert.strictEqual(l.detail, "1/2")
  assert.strictEqual(l.text, `${M.ICON_DOWN} 1/2`)
})

test("an icon-only label carries no stray separator", () => {
  const l = M.barLabel(M.summarize({ error: "no token", data: [] }), {})
  assert.strictEqual(l.detail, "")
  assert.strictEqual(l.text, M.ICON_UNKNOWN)
})

test("tooltip names the down checks", () => {
  const t = M.tooltipText(M.summarize(payload([
    check({ id: "1", name: "api.example.test", status: "down" }),
    check({ id: "2", name: "www.example.test", status: "up" })
  ])))
  assert.ok(t.includes("1 up"))
  assert.ok(t.includes("1 down"))
  assert.ok(t.includes("api.example.test"))
})

test("tooltip caps the list and says how many more", () => {
  const many = []
  for (let i = 0; i < 9; i++) many.push(check({ id: String(i), name: `check-${i}`, status: "down" }))
  const t = M.tooltipText(M.summarize(payload(many)))
  assert.ok(t.includes("+4 more"), t)
})

test("tooltip surfaces the error text verbatim", () => {
  const t = M.tooltipText(M.summarize({ error: "no StatusCake API token found", data: [] }))
  assert.ok(t.includes("no StatusCake API token found"))
})

// --- transitions -----------------------------------------------------------

const upSnap = M.statusMap(M.summarize(payload([
  check({ id: "a", name: "alpha", status: "up" }),
  check({ id: "b", name: "bravo", status: "up" })
])))

test("no transitions when nothing changed", () => {
  assert.deepStrictEqual(M.diffTransitions(upSnap, upSnap), [])
})

test("detects up to down", () => {
  const next = M.statusMap(M.summarize(payload([
    check({ id: "a", name: "alpha", status: "down" }),
    check({ id: "b", name: "bravo", status: "up" })
  ])))
  const t = M.diffTransitions(upSnap, next)
  assert.strictEqual(t.length, 1)
  assert.strictEqual(t[0].name, "alpha")
  assert.strictEqual(t[0].from, "up")
  assert.strictEqual(t[0].to, "down")
})

test("first run fires nothing, so a shell restart replays no backlog", () => {
  // The critical case: empty previous snapshot, several checks already down.
  const next = M.statusMap(M.summarize(payload([
    check({ id: "a", name: "alpha", status: "down" }),
    check({ id: "b", name: "bravo", status: "down" })
  ])))
  assert.deepStrictEqual(M.diffTransitions({}, next), [])
})

test("a newly added check is not a transition", () => {
  const next = M.statusMap(M.summarize(payload([
    check({ id: "a", name: "alpha", status: "up" }),
    check({ id: "b", name: "bravo", status: "up" }),
    check({ id: "c", name: "charlie", status: "down" })
  ])))
  assert.deepStrictEqual(M.diffTransitions(upSnap, next), [])
})

test("pausing a down check is not a recovery", () => {
  const down = M.statusMap(M.summarize(payload([check({ id: "a", name: "alpha", status: "down" })])))
  const paused = M.statusMap(M.summarize(payload([check({ id: "a", name: "alpha", status: "down", paused: true })])))
  assert.deepStrictEqual(M.diffTransitions(down, paused), [])
})

test("a check that vanishes from the account is not a transition", () => {
  assert.deepStrictEqual(M.diffTransitions(upSnap, M.statusMap(M.summarize(payload([])))), [])
})

test("down transitions sort ahead of recoveries", () => {
  const prev = M.statusMap(M.summarize(payload([
    check({ id: "a", name: "alpha", status: "up" }),
    check({ id: "b", name: "bravo", status: "down" })
  ])))
  const next = M.statusMap(M.summarize(payload([
    check({ id: "a", name: "alpha", status: "down" }),
    check({ id: "b", name: "bravo", status: "up" })
  ])))
  assert.deepStrictEqual(M.diffTransitions(prev, next).map(t => t.to), ["down", "up"])
})

// --- notifications ---------------------------------------------------------

test("no transitions means no notification", () => {
  assert.strictEqual(M.notificationFor([]), null)
  assert.strictEqual(M.notificationFor(null), null)
})

test("a single outage names the check", () => {
  const n = M.notificationFor([{ id: "a", name: "api.example.test", from: "up", to: "down" }])
  assert.ok(n.body.includes("api.example.test"))
  assert.ok(n.body.includes("DOWN"))
  assert.strictEqual(n.urgent, true)
})

test("a single recovery reads as recovered and is not urgent", () => {
  const n = M.notificationFor([{ id: "a", name: "api.example.test", from: "down", to: "up" }])
  assert.ok(n.body.includes("recovered"))
  assert.strictEqual(n.urgent, false)
})

test("a mass outage is one summary notification, not twenty", () => {
  const t = []
  for (let i = 0; i < 20; i++) t.push({ id: String(i), name: `c${i}`, from: "up", to: "down" })
  const n = M.notificationFor(t)
  assert.strictEqual(n.body, "20 down")
  assert.strictEqual(n.urgent, true)
})

test("mixed transitions report both directions and stay urgent", () => {
  const n = M.notificationFor([
    { id: "a", name: "a", from: "up", to: "down" },
    { id: "b", name: "b", from: "up", to: "down" },
    { id: "c", name: "c", from: "down", to: "up" }
  ])
  assert.strictEqual(n.body, "2 down, 1 recovered")
  assert.strictEqual(n.urgent, true)
})

// --- formatting ------------------------------------------------------------

test("formatUptime keeps 100 flat and two decimals below it", () => {
  assert.strictEqual(M.formatUptime(100), "100%")
  assert.strictEqual(M.formatUptime(99.874), "99.87%")
  assert.strictEqual(M.formatUptime(98.77), "98.77%")
})

test("formatUptime shows an em dash rather than a misleading zero", () => {
  assert.strictEqual(M.formatUptime(null), "—")
  assert.strictEqual(M.formatUptime(undefined), "—")
  assert.strictEqual(M.formatUptime("not a number"), "—")
  assert.strictEqual(M.formatUptime(0), "0.00%")
})

test("elide only truncates past the limit", () => {
  assert.strictEqual(M.elide("short", 10), "short")
  assert.strictEqual(M.elide("abcdefghij", 5), "abcd…")
  assert.strictEqual(M.elide(null, 5), "")
})

// --- settings --------------------------------------------------------------

// These have to track manifest.json's barWidget.defaults exactly: nothing in
// the shell reads that block, so this function is what actually decides what a
// fresh install gets.
test("readSettings falls back to the manifest defaults", () => {
  const s = M.readSettings({})
  assert.strictEqual(s.refreshIntervalSec, 300)
  assert.strictEqual(s.tags, "")
  assert.strictEqual(s.matchAnyTag, true)
  assert.strictEqual(s.notify, true)
})

test("readSettings clamps a hand-edited interval into range", () => {
  // shell.json is hand-edited and nothing validates it on the way in.
  assert.strictEqual(M.readSettings({ refreshIntervalSec: 5 }).refreshIntervalSec, 60)
  assert.strictEqual(M.readSettings({ refreshIntervalSec: 99999 }).refreshIntervalSec, 3600)
  assert.strictEqual(M.readSettings({ refreshIntervalSec: "banana" }).refreshIntervalSec, 300)
  assert.strictEqual(M.readSettings({ refreshIntervalSec: "120" }).refreshIntervalSec, 120)
})

// Only a real `false` turns one of these off. Anything else -- absent, or the
// junk a hand-edited shell.json can hold -- lands on the manifest default, so
// an entry written before a key existed keeps behaving like a fresh install
// rather than silently opting out.
test("readSettings turns a switch off only for an explicit false", () => {
  assert.strictEqual(M.readSettings({ notify: false }).notify, false)
  assert.strictEqual(M.readSettings({ notify: true }).notify, true)
  assert.strictEqual(M.readSettings({ notify: "yes" }).notify, true)
  assert.strictEqual(M.readSettings({}).notify, true)
})

test("fetchArgs passes tags through and omits them when empty", () => {
  assert.deepStrictEqual(M.fetchArgs({}), [])
  // match-any rides along by default now, so tags alone carry it.
  assert.deepStrictEqual(M.fetchArgs({ tags: "prod" }), ["--tags", "prod", "--match-any"])
  assert.deepStrictEqual(M.fetchArgs({ tags: "prod", matchAnyTag: false }), ["--tags", "prod"])
})

test("fetchArgs ignores match-any with no tags, which the API would reject", () => {
  assert.deepStrictEqual(M.fetchArgs({ matchAnyTag: true }), [])
})

// --- token state -----------------------------------------------------------

test("summarize carries the helper's failure code through", () => {
  const s = M.summarize({ error: "no StatusCake API token found", code: "no_token", data: [] })
  assert.strictEqual(s.code, "no_token")
  assert.strictEqual(s.hasData, false)
})

test("a success carries no code, so nothing reads as a failure", () => {
  assert.strictEqual(M.summarize(payload([check()])).code, "")
  assert.strictEqual(M.emptySummary().code, "")
})

test("needsToken fires only on a missing token, never on other failures", () => {
  assert.strictEqual(M.needsToken(M.summarize({ error: "x", code: "no_token", data: [] })), true)
  assert.strictEqual(M.needsToken(M.summarize({ error: "x", code: "unauthorized", data: [] })), false)
  assert.strictEqual(M.needsToken(M.summarize({ error: "x", code: "network", data: [] })), false)
  assert.strictEqual(M.needsToken(M.summarize(payload([check()]))), false)
  assert.strictEqual(M.needsToken(null), false)
})

// A helper too old to send codes must not make the panel hijack itself into a
// token form on every unrelated error.
test("an error with no code is not a missing token", () => {
  assert.strictEqual(M.needsToken(M.summarize({ error: "no StatusCake API token found", data: [] })), false)
})

test("tokenRejected fires only on a refused token", () => {
  assert.strictEqual(M.tokenRejected(M.summarize({ error: "x", code: "unauthorized", data: [] })), true)
  assert.strictEqual(M.tokenRejected(M.summarize({ error: "x", code: "no_token", data: [] })), false)
})

test("a missing token gets a tooltip saying what to do, not what failed", () => {
  const t = M.tooltipText(M.summarize({ error: "no StatusCake API token found", code: "no_token", data: [] }))
  assert.ok(t.includes("Click to add one"), t)
})

// --- setup results ---------------------------------------------------------

test("parseSetupResult reads a successful store", () => {
  const r = M.parseSetupResult('{"ok":true,"error":null,"code":null,"stored":"keyring","path":null}')
  assert.strictEqual(r.ok, true)
  assert.strictEqual(r.stored, "keyring")
  assert.strictEqual(r.error, "")
})

test("parseSetupResult reads a rejection and keeps its reason", () => {
  const r = M.parseSetupResult('{"ok":false,"error":"StatusCake rejected that token (HTTP 401).","code":"rejected"}')
  assert.strictEqual(r.ok, false)
  assert.strictEqual(r.code, "rejected")
  assert.ok(r.error.includes("401"))
})

test("parseSetupResult reads a status report", () => {
  const r = M.parseSetupResult('{"ok":true,"source":"file","path":"/home/x/.config/omarchy/statuscake-token","valid":null}')
  assert.strictEqual(r.source, "file")
  assert.strictEqual(r.valid, null)
  assert.strictEqual(r.path, "/home/x/.config/omarchy/statuscake-token")
})

test("parseSetupResult distinguishes an unverified token from a bad one", () => {
  assert.strictEqual(M.parseSetupResult('{"ok":true,"source":"keyring","valid":false}').valid, false)
  assert.strictEqual(M.parseSetupResult('{"ok":true,"source":"keyring","valid":true}').valid, true)
})

// The panel has no other way to report a script that died before printing.
test("parseSetupResult never throws, and never reports silence as success", () => {
  for (const junk of ["", "   ", "not json", "null", "[]", "42", undefined, null]) {
    const r = M.parseSetupResult(junk)
    assert.strictEqual(r.ok, false)
    assert.ok(r.error !== "", `no error text for ${JSON.stringify(junk)}`)
  }
})

test("a failure with no message still says something", () => {
  assert.strictEqual(M.parseSetupResult('{"ok":false}').error, "statuscake-setup failed")
})

const KEYRING = M.parseSetupResult('{"ok":true,"source":"keyring"}')
const LIVE = { code: "", hasData: true }

test("tokenState says a token works, and where it is", () => {
  const state = M.tokenState(LIVE, KEYRING)
  assert.strictEqual(state.tone, "ok")
  assert.strictEqual(state.icon, M.ICON_OK)
  assert.ok(state.text.includes("works"), state.text)
  assert.ok(state.text.includes("keyring"), state.text)
  assert.ok(M.tokenState(LIVE, M.parseSetupResult('{"ok":true,"source":"file","path":"/tmp/t"}')).text.includes("/tmp/t"))
})

// The probe runs --no-verify, so it can only say a token exists. What proves it
// is a poll coming back with data -- claiming more than that would be a green
// tick over a token the API has never seen.
test("tokenState does not claim a token works until a poll says so", () => {
  const state = M.tokenState(M.emptySummary(), KEYRING)
  assert.strictEqual(state.tone, "none")
  assert.ok(!state.text.includes("works"), state.text)
  assert.ok(state.text.includes("keyring"), state.text)
})

test("tokenState reports a rejection against the place it came from", () => {
  const state = M.tokenState({ code: "unauthorized" }, KEYRING)
  assert.strictEqual(state.tone, "bad")
  assert.ok(state.text.includes("rejected"), state.text)
  assert.ok(state.text.includes("keyring"), state.text)
  // A verified failure from the setup script alone is enough, with no poll.
  assert.strictEqual(M.tokenState(LIVE, M.parseSetupResult('{"ok":true,"source":"keyring","valid":false}')).tone, "bad")
})

test("tokenState distinguishes no token from not knowing yet", () => {
  assert.strictEqual(M.tokenState(LIVE, M.parseSetupResult('{"ok":false,"code":"no_token"}')).tone, "none")
  assert.ok(M.tokenState(LIVE, M.parseSetupResult('{"ok":false,"code":"no_token"}')).text.includes("No token"))
  // Null is the probe not having answered yet, which is not the same as none.
  assert.strictEqual(M.tokenState(LIVE, null).tone, "unknown")
})

// Storing a token while the environment sets one looks like a no-op from the
// panel, because the fetch helper reads the environment first. Say so.
test("an environment token is called out as the one that wins", () => {
  const env = M.parseSetupResult('{"ok":true,"source":"env"}')
  assert.ok(M.tokenState(LIVE, env).text.includes("STATUSCAKE_API_TOKEN"))
  // "set by", not "stored in": the environment is not somewhere this can write.
  assert.ok(M.tokenState(LIVE, env).text.includes("set by"))
  assert.ok(M.tokenSaveHint(env).includes("unset"))
})

test("the ordinary save hint promises verification", () => {
  const hint = M.tokenSaveHint(M.parseSetupResult('{"ok":true,"source":"keyring"}'))
  assert.ok(/verified/i.test(hint), hint)
})

// Omarchy has no uninstall hook -- omarchy-plugin-remove deletes the folder and
// nothing else -- so the panel is the only route to deleting the token without
// a terminal, and it has to offer that route exactly when there is one to take.
test("removal is offered for a token this can actually delete", () => {
  assert.strictEqual(M.tokenRemovable(M.parseSetupResult('{"ok":true,"source":"keyring"}')), true)
  assert.strictEqual(M.tokenRemovable(M.parseSetupResult('{"ok":true,"source":"file","path":"/tmp/t"}')), true)
})

// An environment token is not this plugin's to delete: --remove would clear a
// keyring entry nothing is currently reading and leave $STATUSCAKE_API_TOKEN
// still winning, which reads as a button that did nothing.
test("removal is not offered for an environment token, or for none at all", () => {
  assert.strictEqual(M.tokenRemovable(M.parseSetupResult('{"ok":true,"source":"env"}')), false)
  assert.strictEqual(M.tokenRemovable(M.parseSetupResult('{"ok":false,"code":"no_token"}')), false)
  // The probe has not answered yet.
  assert.strictEqual(M.tokenRemovable(null), false)
})

test("the confirm step names what it would delete", () => {
  const file = M.parseSetupResult('{"ok":true,"source":"file","path":"/home/x/.config/omarchy/statuscake-token"}')
  assert.ok(M.tokenRemoveConfirm(file).includes("/home/x/.config/omarchy/statuscake-token"))
  assert.ok(/keyring/.test(M.tokenRemoveConfirm(M.parseSetupResult('{"ok":true,"source":"keyring"}'))))
  // Nothing to delete, nothing to ask about.
  assert.strictEqual(M.tokenRemoveConfirm(M.parseSetupResult('{"ok":true,"source":"env"}')), "")
})

// A file token whose path came back empty still gets a sentence rather than a
// question with a hole in it.
test("the confirm step survives a status with no path", () => {
  const confirm = M.tokenRemoveConfirm(M.parseSetupResult('{"ok":true,"source":"file"}'))
  assert.ok(confirm.length > 0 && !confirm.includes("undefined"), confirm)
})

// --- settings write-back ---------------------------------------------------

test("settingsEntry changes one key and keeps the rest", () => {
  const e = M.settingsEntry("robinvanderknaap.statuscake", { notify: true, tags: "prod" }, "tags", "web")
  assert.deepStrictEqual(e, { id: "robinvanderknaap.statuscake", notify: true, tags: "web" })
})

// The bar matches layout entries by id. One written without it stops being
// this widget's entry, and the settings vanish from the running widget.
test("settingsEntry always carries the module id", () => {
  assert.strictEqual(M.settingsEntry("robinvanderknaap.statuscake", {}, "notify", true).id, "robinvanderknaap.statuscake")
  assert.strictEqual(M.settingsEntry("robinvanderknaap.statuscake", null, "notify", true).id, "robinvanderknaap.statuscake")
  assert.strictEqual(M.settingsEntry("robinvanderknaap.statuscake", { id: "wrong" }, "notify", true).id, "robinvanderknaap.statuscake")
})

// A dialog that only knows this version's five keys must not drop a sixth that
// a newer build, or a hand edit, put in shell.json.
test("settingsEntry preserves keys it knows nothing about", () => {
  const e = M.settingsEntry("robinvanderknaap.statuscake", { somethingNew: [1, 2] }, "notify", true)
  assert.deepStrictEqual(e.somethingNew, [1, 2])
})

test("settingsEntry writes falsy values rather than skipping them", () => {
  assert.strictEqual(M.settingsEntry("x", { notify: true }, "notify", false).notify, false)
  assert.strictEqual(M.settingsEntry("x", { tags: "prod" }, "tags", "").tags, "")
})

// A first run has no token, and every other setting shapes a fetch that cannot
// happen yet -- so the view is the token form alone until one works.
test("tokenBlocksSettings hides the rest until a token works", () => {
  assert.strictEqual(M.tokenBlocksSettings({ code: "no_token" }, null), true)
  assert.strictEqual(M.tokenBlocksSettings({ code: "unauthorized" }, null), true)
  assert.strictEqual(M.tokenBlocksSettings({ code: "" }, { ok: false, valid: null }), true)
  assert.strictEqual(M.tokenBlocksSettings({ code: "" }, { ok: true, valid: false }), true)
})

test("tokenBlocksSettings shows everything once one does", () => {
  assert.strictEqual(M.tokenBlocksSettings({ code: "" }, { ok: true, valid: null }), false)
  assert.strictEqual(M.tokenBlocksSettings({ code: "" }, { ok: true, valid: true }), false)
  // A poll that failed for some other reason is not a token problem.
  assert.strictEqual(M.tokenBlocksSettings({ code: "rate_limited" }, { ok: true, valid: null }), false)
})

// The probe runs on every open, so there is a moment with no answer yet. It
// must not read as "no token" or the view would collapse and reflow under the
// pointer a frame later.
test("tokenBlocksSettings waits for the probe rather than assuming", () => {
  assert.strictEqual(M.tokenBlocksSettings(M.emptySummary(), null), false)
})

// shell.json is hand-editable and nothing validates it on the way in, so the
// picker has to make sense of whatever spacing someone typed there.
test("tagList splits what shell.json can hold", () => {
  assert.deepStrictEqual(M.tagList("prod,web"), ["prod", "web"])
  assert.deepStrictEqual(M.tagList("  prod , web ,, prod "), ["prod", "web"])
  assert.deepStrictEqual(M.tagList(""), [])
  assert.deepStrictEqual(M.tagList(null), [])
  assert.deepStrictEqual(M.tagList(undefined), [])
})

// The API matches tags literally: a stray space is a tag that matches nothing,
// which shows up as a pill reading 0 up, 0 down and no error anywhere.
test("joinTags writes a list the API can match", () => {
  assert.strictEqual(M.joinTags(["prod", "web"]), "prod,web")
  assert.strictEqual(M.joinTags([" prod ", "", "web", "prod"]), "prod,web")
  assert.strictEqual(M.joinTags([]), "")
  assert.strictEqual(M.joinTags(null), "")
})

test("a picked selection round-trips through the stored string", () => {
  assert.deepStrictEqual(M.tagList(M.joinTags(["prod", "web"])), ["prod", "web"])
})

// What the dialog writes has to survive the trip back through readSettings, or
// a setting appears to revert the moment the bar hands the object back.
test("a written setting round-trips through readSettings", () => {
  const written = M.settingsEntry("robinvanderknaap.statuscake", { notify: false }, "refreshIntervalSec", 900)
  const read = M.readSettings(written)
  assert.strictEqual(read.refreshIntervalSec, 900)
  assert.strictEqual(read.notify, false)
  assert.deepStrictEqual(M.readSettings(M.settingsEntry("x", {}, "tags", "prod")).tags, "prod")
  assert.strictEqual(M.readSettings(M.settingsEntry("x", {}, "matchAnyTag", true)).matchAnyTag, true)
})

// --- report ----------------------------------------------------------------

if (failures.length > 0) {
  for (const f of failures) console.error(`  FAIL  ${f.name}\n        ${f.message}`)
  console.error(`\n${passed} passed, ${failures.length} failed`)
  process.exit(1)
}
console.log(`${passed} passed`)
