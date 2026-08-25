// Pure functions behind the StatusCake widget. No QML types, no I/O, no timers
// -- everything here takes data and returns data, so the states that matter
// most (checks down, transitions, API errors) can be tested without waiting for
// a real outage. BarWidget.qml and Panel.qml hold the Qt objects; this file
// holds the decisions.
//
// Loadable both as a QML .js import and as a CommonJS module under node; see
// the module.exports guard at the bottom.

// Nerd Font glyphs, hoisted so they are trivial to swap without hunting
// through string concatenation.
var ICON_OK = "󰸞"
var ICON_DOWN = "󰅚"
var ICON_UNKNOWN = "󰋖"

function isPaused(check) {
  return check && check.paused === true
}

function isDown(check) {
  return !!check && !isPaused(check) && String(check.status || "").toLowerCase() === "down"
}

function isUp(check) {
  return !!check && !isPaused(check) && String(check.status || "").toLowerCase() === "up"
}

// The API returns uptime as a float percentage; a check can legitimately lack
// one (a brand new test), so an absent value formats as an em dash rather than
// a misleading 0%.
function formatUptime(value) {
  if (value === undefined || value === null || value === "") return "—"
  var n = parseFloat(String(value))
  if (isNaN(n)) return "—"
  // Two decimals below 100 keeps 99.99 and 99.87 distinguishable, while a flat
  // 100 reads better than 100.00.
  return (n >= 100 ? "100" : n.toFixed(2)) + "%"
}

function elide(text, max) {
  var s = String(text === undefined || text === null ? "" : text)
  var limit = parseInt(String(max), 10)
  if (isNaN(limit) || limit <= 1 || s.length <= limit) return s
  return s.slice(0, limit - 1) + "…"
}

function normalizeCheck(raw) {
  if (!raw || typeof raw !== "object") return null
  var status = String(raw.status || "").toLowerCase()
  return {
    id: String(raw.id === undefined || raw.id === null ? "" : raw.id),
    name: String(raw.name || ""),
    url: String(raw.website_url || ""),
    testType: String(raw.test_type || ""),
    status: status === "up" || status === "down" ? status : "unknown",
    paused: raw.paused === true,
    uptime: raw.uptime === undefined || raw.uptime === null ? null : parseFloat(String(raw.uptime)),
    tags: Array.isArray(raw.tags) ? raw.tags.map(String) : []
  }
}

// Down first (that is what the user opened the panel for), then up, then
// paused; alphabetical within each group so the list does not reshuffle
// between refreshes.
function sortChecks(checks) {
  function rank(c) {
    if (isPaused(c)) return 2
    if (isDown(c)) return 0
    return 1
  }
  return (checks || []).slice().sort(function(a, b) {
    var ra = rank(a), rb = rank(b)
    if (ra !== rb) return ra - rb
    return String(a.name || "").localeCompare(String(b.name || ""))
  })
}

// The ceiling on one helper run's output, in characters, checked before any of
// it is parsed. bin/statuscake-uptime caps what it prints (MAX_DOC_BYTES there)
// and is the only thing that can stop an oversized response being read at all:
// StdioCollector buffers the whole stream before QML sees a byte of it, and has
// no limit of its own. This is the second line -- a helper that has been
// replaced, broken, or shadowed on PATH is refused here rather than handed to
// JSON.parse, which would double it and block the shell's UI thread doing so.
// Well above what the helper will ever emit, so it fires on nothing legitimate.
var MAX_PAYLOAD_CHARS = 12 * 1024 * 1024

function payloadTooLarge(text) {
  return String(text === undefined || text === null ? "" : text).length > MAX_PAYLOAD_CHARS
}

// Turns the helper's {error, code, data} envelope into everything the UI needs.
// An error yields zeroed counts and an empty list rather than a partial state,
// so a failed refresh can never be mistaken for "all clear".
//
// `code` carries the helper's failure slug (see bin/statuscake-uptime) so the
// panel can branch on the kind of failure without matching English prose. It is
// "" whenever there is nothing to say, including on success.
function emptySummary() {
  return { error: null, code: "", total: 0, up: 0, down: 0, paused: 0, checks: [], hasData: false }
}

function summarize(payload) {
  var empty = emptySummary()

  if (!payload || typeof payload !== "object") {
    empty.error = "no response"
    empty.code = "no_response"
    return empty
  }
  if (payload.error) {
    empty.error = String(payload.error)
    empty.code = payload.code ? String(payload.code) : ""
    return empty
  }

  var raw = Array.isArray(payload.data) ? payload.data : []
  var checks = []
  for (var i = 0; i < raw.length; i++) {
    var c = normalizeCheck(raw[i])
    if (c) checks.push(c)
  }

  var up = 0, down = 0, paused = 0
  for (var j = 0; j < checks.length; j++) {
    if (isPaused(checks[j])) paused++
    else if (isDown(checks[j])) down++
    else if (isUp(checks[j])) up++
  }

  return {
    error: null,
    code: "",
    total: up + down,          // paused checks are not part of the health count
    up: up,
    down: down,
    paused: paused,
    checks: sortChecks(checks),
    hasData: true
  }
}

// What the bar pill shows. There is no hidden state: the pill is the only way
// to reach the panel and the settings behind it, so a widget that can vanish
// takes its own settings with it -- which is exactly how an early
// `hideWhenAllUp` option had to be undone by hand-editing shell.json.
//
// `icon` and `detail` are returned alongside `text` so a vertical bar can stack
// them on two lines instead of eliding a horizontal pill.
function label(icon, detail, opts) {
  var extra = opts || {}
  return {
    icon: icon,
    detail: detail,
    text: detail === "" ? icon : icon + " " + detail,
    urgent: extra.urgent === true,
    error: extra.error === true
  }
}

// `settings` is unused since hideWhenAllUp was removed, and kept only so the
// call site does not have to change if a display option ever returns.
function barLabel(summary, settings) {
  var s = summary || {}

  if (s.error) return label(ICON_UNKNOWN, "", { error: true })
  if (!s.hasData) return label(ICON_UNKNOWN, "")
  if (s.down > 0) return label(ICON_DOWN, s.down + "/" + s.total, { urgent: true })
  return label(ICON_OK, String(s.up))
}

function tooltipText(summary) {
  var s = summary || {}
  // The one error the user can fix from here. Saying so beats repeating the
  // helper's report of a thing they never set up in the first place.
  if (s.code === "no_token") return "StatusCake — no API token yet. Click to add one."
  if (s.error) return "StatusCake: " + s.error
  if (!s.hasData) return "StatusCake: loading…"

  var parts = [s.up + " up", s.down + " down"]
  if (s.paused > 0) parts.push(s.paused + " paused")
  var text = "StatusCake — " + parts.join(", ")

  if (s.down > 0) {
    var names = []
    for (var i = 0; i < s.checks.length && names.length < 5; i++) {
      if (isDown(s.checks[i])) names.push(elide(s.checks[i].name, 40))
    }
    text += "\n" + names.join("\n")
    if (s.down > names.length) text += "\n+" + (s.down - names.length) + " more"
  }
  return text
}

// Snapshot used to detect transitions across refreshes. Keyed by id so a
// renamed check is still tracked, and paused checks are dropped so pausing
// something never reads as a recovery.
function statusMap(summary) {
  var out = {}
  var checks = (summary && summary.checks) || []
  for (var i = 0; i < checks.length; i++) {
    if (isPaused(checks[i])) continue
    if (checks[i].status !== "up" && checks[i].status !== "down") continue
    out[checks[i].id] = { status: checks[i].status, name: checks[i].name }
  }
  return out
}

// Only ids present in BOTH snapshots produce a transition. A check that is new,
// deleted, unpaused, or appearing for the first time after a shell restart is
// not an event -- otherwise every startup would replay a backlog of alerts.
function diffTransitions(previous, current) {
  var prev = previous || {}
  var next = current || {}
  var out = []
  for (var id in next) {
    if (!Object.prototype.hasOwnProperty.call(next, id)) continue
    if (!Object.prototype.hasOwnProperty.call(prev, id)) continue
    if (prev[id].status === next[id].status) continue
    out.push({
      id: id,
      name: next[id].name,
      from: prev[id].status,
      to: next[id].status
    })
  }
  return out.sort(function(a, b) {
    if (a.to !== b.to) return a.to === "down" ? -1 : 1
    return String(a.name).localeCompare(String(b.name))
  })
}

// One notification per refresh, not one per check: a provider outage taking
// twenty checks down at once should not fire twenty notifications.
function notificationFor(transitions) {
  var list = transitions || []
  if (list.length === 0) return null

  var downs = list.filter(function(t) { return t.to === "down" })
  var ups = list.filter(function(t) { return t.to === "up" })

  if (downs.length === 1 && ups.length === 0) {
    return { title: "StatusCake", body: elide(downs[0].name, 60) + " is DOWN", urgent: true }
  }
  if (ups.length === 1 && downs.length === 0) {
    return { title: "StatusCake", body: elide(ups[0].name, 60) + " recovered", urgent: false }
  }

  var parts = []
  if (downs.length > 0) parts.push(downs.length + " down")
  if (ups.length > 0) parts.push(ups.length + " recovered")
  return {
    title: "StatusCake",
    body: parts.join(", "),
    urgent: downs.length > 0
  }
}

// --- token state ----------------------------------------------------------
//
// The widget learns about the token from its ordinary refresh: no token and a
// rejected token are two of the failure codes bin/statuscake-uptime reports.
// That means the panel offers to fix the token without any extra API call.

// Nothing is stored anywhere the fetch helper looks. The panel opens straight
// into settings for this one, since the check list has nothing to show.
function needsToken(summary) {
  return !!summary && summary.code === "no_token"
}

// A token exists but the API refuses it -- revoked, mistyped, or lacking read
// access to uptime tests. Worth offering the same form, but not worth hijacking
// the panel: the user may have opened it for something else.
function tokenRejected(summary) {
  return !!summary && summary.code === "unauthorized"
}

// Until a token works there is nothing else in the settings view worth showing:
// every other setting shapes a fetch that cannot happen, and the defaults are
// the right thing to arrive with anyway. Three sources, because no one of them
// covers the case on its own -- the summary carries the API's own verdict from
// the last poll and is the only one that notices a token revoked since it was
// stored; `ok === false` is no token stored anywhere; and `valid === false` is
// a token that was checked against the API and refused.
function tokenBlocksSettings(summary, tokenStatus) {
  if (needsToken(summary) || tokenRejected(summary)) return true
  if (!tokenStatus) return false
  return tokenStatus.ok === false || tokenStatus.valid === false
}

// Normalizes one JSON object from bin/statuscake-setup into a fixed shape, so
// QML reads the same fields whether the run succeeded, failed, or produced
// something unparseable. Never throws.
function parseSetupResult(raw) {
  var out = { ok: false, error: "", code: "", stored: "", source: "", path: "", valid: null }
  var text = String(raw === undefined || raw === null ? "" : raw).replace(/^\s+|\s+$/g, "")

  if (text === "") {
    out.error = "statuscake-setup produced no output"
    out.code = "no_output"
    return out
  }

  var payload
  try {
    payload = JSON.parse(text)
  } catch (e) {
    out.error = "unreadable output from statuscake-setup"
    out.code = "unparseable"
    return out
  }
  if (!payload || typeof payload !== "object") {
    out.error = "unreadable output from statuscake-setup"
    out.code = "unparseable"
    return out
  }

  out.ok = payload.ok === true
  out.error = payload.error ? String(payload.error) : ""
  out.code = payload.code ? String(payload.code) : ""
  out.stored = payload.stored ? String(payload.stored) : ""
  out.source = payload.source ? String(payload.source) : ""
  out.path = payload.path ? String(payload.path) : ""
  out.valid = payload.valid === true ? true : (payload.valid === false ? false : null)

  // A run that neither succeeded nor said why would leave the panel with an
  // empty status line and no idea what happened.
  if (!out.ok && out.error === "") out.error = "statuscake-setup failed"
  return out
}

// Where the token actually lives, as a phrase that finishes a sentence. The
// wording differs by source on purpose: the keyring holds a token, the
// environment merely sets one, and the difference matters because the fetch
// helper reads the environment first.
function tokenLocation(status) {
  if (!status || !status.ok) return ""
  if (status.source === "env") return "set by $STATUSCAKE_API_TOKEN"
  if (status.source === "keyring") return "stored in your keyring"
  return ""
}

// The one line above the token field: whether there is a token, whether it is
// known to work, and where it is. `tone` is what the panel colours the line and
// its glyph by -- styling stays there, the decision stays here.
//
// "Works" is not the status probe's word. It runs --no-verify, so it can only
// report that a token exists and where; what proves the token is the last poll
// coming back with data. That way the claim costs no extra API call and cannot
// be stale in the direction that matters -- a token revoked an hour ago shows
// as rejected here the moment the next poll says so.
function tokenState(summary, status) {
  if (!status) return { tone: "unknown", icon: ICON_UNKNOWN, text: "Looking for a token…" }
  if (!status.ok) return { tone: "none", icon: ICON_UNKNOWN, text: "No token stored yet." }

  var where = tokenLocation(status)
  if (tokenRejected(summary) || status.valid === false)
    return { tone: "bad", icon: ICON_DOWN, text: "StatusCake rejected the token " + where + "." }
  if (summary && summary.hasData)
    return { tone: "ok", icon: ICON_OK, text: "Token works — " + where + "." }

  // Found, but nothing has proved it yet: a first poll still in flight, or one
  // that failed for a reason that is not the token's fault.
  return { tone: "none", icon: ICON_UNKNOWN, text: where.charAt(0).toUpperCase() + where.slice(1) + "." }
}

// Whether the panel offers to delete the stored token. Removing a plugin
// leaves the keyring entry behind -- Omarchy has no uninstall hook, and
// `omarchy-plugin-remove` deletes the folder and nothing else -- so the panel
// is the only route a user has to their own credential while the plugin is
// still installed to show one.
//
// An environment token is not ours to delete: `--remove` would clear a keyring
// entry the user cannot currently see, and leave $STATUSCAKE_API_TOKEN still
// winning, which is the one outcome that looks like the button did nothing.
function tokenRemovable(status) {
  if (!status || !status.ok) return false
  return status.source === "keyring"
}

// What removing would actually delete, named so the confirm step says it
// rather than asking "are you sure?" about an unstated thing.
function tokenRemoveConfirm(status) {
  if (!tokenRemovable(status)) return ""
  return "Delete the token from your keyring?"
}

// Where a Save would put the token, said before the user commits to it.
function tokenSaveHint(status) {
  if (status && status.ok && status.source === "env")
    return "Saving stores a token in your keyring, but $STATUSCAKE_API_TOKEN keeps winning until you unset it."
  return "Token is verified against the API before it is saved."
}

// Mirrors the manifest's barWidget.defaults. QML hands us whatever the user put
// in shell.json, which may be missing keys or carry the wrong types.
function readSettings(settings) {
  var s = settings || {}
  var seconds = parseInt(String(s.refreshIntervalSec), 10)
  if (isNaN(seconds)) seconds = 300
  // Matches the manifest's min/max. Clamped here too: shell.json is hand-edited
  // and nothing validates it on the way in.
  seconds = Math.max(60, Math.min(3600, seconds))

  return {
    refreshIntervalSec: seconds,
    tags: String(s.tags === undefined || s.tags === null ? "" : s.tags).replace(/^\s+|\s+$/g, ""),
    // Absent means on, matching the manifest. `=== true` would default an entry
    // written before these keys existed to off whatever the manifest says,
    // since nothing in the shell actually reads barWidget.defaults.
    matchAnyTag: s.matchAnyTag !== false,
    notify: s.notify !== false
  }
}

// This widget's inline shell.json entry with one key changed, ready to hand to
// the host shell. `id` is written first and always: the bar matches layout
// entries by it, and an entry that loses it stops being this widget's.
//
// Everything else present is copied through untouched, including keys this
// version knows nothing about -- a settings dialog must not quietly drop a key
// a newer or older build of the plugin put there.
function settingsEntry(moduleName, settings, key, value) {
  var entry = { id: String(moduleName) }
  var current = settings || {}
  for (var k in current) {
    if (!Object.prototype.hasOwnProperty.call(current, k)) continue
    if (k === "id") continue
    entry[k] = current[k]
  }
  entry[key] = value
  return entry
}

// The stored comma-separated tag string, split into the array the tag picker
// selects from. Tolerant of what a hand-edited shell.json can hold -- spaces
// around the commas, empty slots, a repeat -- because nothing validates that
// file on the way in.
function tagList(tags) {
  var raw = String(tags === undefined || tags === null ? "" : tags).split(",")
  var out = []
  var seen = ({})
  for (var i = 0; i < raw.length; i++) {
    var tag = raw[i].replace(/^\s+|\s+$/g, "")
    if (tag === "" || seen[tag]) continue
    seen[tag] = true
    out.push(tag)
  }
  return out
}

// The picker's selection as it goes into shell.json. The API matches tags
// literally, so this is also the last place a stray space could turn a real
// tag into one that matches nothing.
function joinTags(values) {
  return tagList(Array.prototype.join.call(values || [], ",")).join(",")
}

// Argument vector for bin/statuscake-uptime. Built here so the shape is
// testable and so QML never string-concatenates a command line.
function fetchArgs(settings) {
  var s = readSettings(settings)
  var args = []
  if (s.tags !== "") {
    args.push("--tags")
    args.push(s.tags)
    if (s.matchAnyTag) args.push("--match-any")
  }
  return args
}

if (typeof module !== "undefined") {
  module.exports = {
    ICON_OK: ICON_OK,
    ICON_DOWN: ICON_DOWN,
    ICON_UNKNOWN: ICON_UNKNOWN,
    isPaused: isPaused,
    isDown: isDown,
    isUp: isUp,
    formatUptime: formatUptime,
    elide: elide,
    normalizeCheck: normalizeCheck,
    sortChecks: sortChecks,
    emptySummary: emptySummary,
    MAX_PAYLOAD_CHARS: MAX_PAYLOAD_CHARS,
    payloadTooLarge: payloadTooLarge,
    summarize: summarize,
    needsToken: needsToken,
    tokenRejected: tokenRejected,
    tokenBlocksSettings: tokenBlocksSettings,
    parseSetupResult: parseSetupResult,
    tokenLocation: tokenLocation,
    tokenState: tokenState,
    tokenSaveHint: tokenSaveHint,
    tokenRemovable: tokenRemovable,
    tokenRemoveConfirm: tokenRemoveConfirm,
    barLabel: barLabel,
    tooltipText: tooltipText,
    statusMap: statusMap,
    diffTransitions: diffTransitions,
    notificationFor: notificationFor,
    readSettings: readSettings,
    settingsEntry: settingsEntry,
    tagList: tagList,
    joinTags: joinTags,
    fetchArgs: fetchArgs
  }
}
