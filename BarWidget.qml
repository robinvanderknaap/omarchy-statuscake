// StatusCake bar pill: up/down counts for the account's uptime checks.
//
// Written against the third-party widget contract documented in
// shell/plugins/bar/README.md -- an Item with implicitWidth/implicitHeight that
// receives `bar`, `moduleName` and `settings` after load.
//
// Two corrections to that README, both found the hard way: a widget must also
// expose triggerPress(button) or the bar silently discards every left click
// (see the comment on that function), and shell-quoting is Util.shellQuote from
// qs.Commons, not the documented and non-existent bar.shellQuote.
//
// All decisions live in Model.js so they can be tested without a running shell;
// this file holds only the Qt objects and the wiring between them.
import QtQuick
import Quickshell
import Quickshell.Io
// Util.shellQuote lives here. The bar README documents it as bar.shellQuote,
// but no such function exists on the bar -- calling it throws at runtime.
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var bar
  property string moduleName: "robinvanderknaap.statuscake"
  property var settings

  readonly property var config: Model.readSettings(settings)
  property var summary: Model.emptySummary()
  readonly property var display: Model.barLabel(summary, config)

  // Snapshot of the previous refresh, for up/down transition detection. Starts
  // empty on purpose: a shell restart must not replay a backlog of alerts.
  property var previousStatuses: ({})
  property bool refreshing: false
  // A refresh asked for while one was already in flight. Set by the token
  // save, whose whole point is that the answer from the poll now running was
  // reached with the old token.
  property bool pendingRefresh: false

  // Qt.resolvedUrl gives a file:// URL; Process wants a plain path.
  readonly property string helperPath:
    Qt.resolvedUrl("bin/statuscake-uptime").toString().replace(/^file:\/\//, "")

  implicitWidth: bar && bar.vertical ? bar.barSize : pill.implicitWidth + 8
  implicitHeight: bar ? bar.barSize : 26

  // Re-fetch when the tag filter changes, not just on the timer, so editing
  // shell.json shows its effect immediately.
  readonly property string fetchSignature: JSON.stringify(Model.fetchArgs(settings))
  onFetchSignatureChanged: refresh()

  function refresh() {
    if (refreshing) {
      pendingRefresh = true
      return
    }
    refreshing = true
    fetchProc.command = [helperPath].concat(Model.fetchArgs(settings))
    fetchProc.running = true
  }

  // Inline shell.json settings are the bar's to hand down: it patches this
  // object in place whenever the file changes. Writing goes the other way,
  // through the host shell, which owns the file IO -- the same path the
  // first-party clock panel uses for its own inline preferences.
  //
  // Applied locally first so the dialog redraws on the click rather than after
  // the file round-trip. With no writable entry -- the widget is loaded but not
  // in any layout -- it stays a session-only preference rather than doing
  // nothing at all.
  function persistSetting(key, value) {
    var entry = Model.settingsEntry(moduleName, settings, key, value)
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  // A token that just appeared or just went away invalidates everything the
  // last poll concluded -- "no token found" under a token already fixed, or a
  // healthy count under a token that no longer exists. Drop the summary, and
  // drop the transition snapshot too: a different account's checks are not
  // transitions of this one's.
  function reloadAfterTokenChange() {
    summary = Model.emptySummary()
    previousStatuses = ({})
    refresh()
  }

  function applyPayload(payload) {
    var next = Model.summarize(payload)
    var nextStatuses = Model.statusMap(next)

    if (config.notify && next.hasData) {
      var note = Model.notificationFor(Model.diffTransitions(previousStatuses, nextStatuses))
      if (note) sendNotification(note)
    }

    // Only advance the snapshot on a successful refresh. A failed poll must not
    // erase what we knew, or the next success would look like a transition.
    if (next.hasData) previousStatuses = nextStatuses
    summary = next
  }

  // The bar owns left-click: its modulePointer MouseArea covers every slot to
  // drive drag-to-reorder, and dispatches a real click by calling triggerPress
  // on the click target -- falling back to the widget root, which is us. A
  // widget without this function is not clickable at all, and does not even get
  // a pointing-hand cursor, because Bar.moduleTargetClickable() tests for it.
  //
  // Right and middle never reach the bar (its MouseArea accepts LeftButton
  // only), so the MouseArea below routes those into the same function. This
  // mirrors Ui/WidgetButton.qml, which is how first-party widgets do it.
  function triggerPress(button) {
    if (bar) bar.hideTooltip(root)

    if (button === Qt.RightButton) {
      if (bar) bar.run("omarchy-launch-browser https://app.statuscake.com/")
      return
    }
    if (button === Qt.MiddleButton) {
      refresh()
      return
    }
    // With no token the check list has nothing to list, so the click that
    // would open the panel opens it on the page that fixes that instead. The
    // next click still closes it: this is a toggle either way.
    if (Model.needsToken(summary) && !panelOpen) {
      openSettings()
      return
    }
    panelOpen = !panelOpen
  }

  // Settings are a view inside the panel rather than a window of their own --
  // see the comment at the top of Panel.qml for why. Asking for them is asking
  // for the panel, already turned to that page.
  function openSettings() {
    panelOpen = true
    panel.showSettings()
  }

  // The bar identifies an open popup by these three on the widget root, which
  // is also what shell summon/hide/toggle routing looks for.
  property bool panelOpen: false
  readonly property bool opened: panelOpen

  function open() { panelOpen = true }
  function close() { panelOpen = false }

  // Registering makes the bar hit-test this item precisely instead of relying
  // on the whole-slot fallback, which is also what turns on the pointing-hand
  // cursor while hovering.
  property var registeredBar: null

  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }

  onBarChanged: syncClickRegistration()
  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
  }

  function sendNotification(note) {
    if (!bar) return
    var glyph = note.urgent ? Model.ICON_DOWN : Model.ICON_OK
    bar.run("omarchy-notification-send -u " + (note.urgent ? "critical" : "low") +
            " -g " + Util.shellQuote(glyph) +
            " " + Util.shellQuote(note.title) +
            " " + Util.shellQuote(note.body))
  }

  Process {
    id: fetchProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.refreshing = false
        var out = String(text || "")
        var oversize = Model.payloadTooLarge(out)
        var raw = oversize ? "" : out.trim()
        if (oversize) {
          // The helper caps its own output far below this, so anything this
          // large is not it answering. Refused rather than parsed: JSON.parse
          // would double it, on the thread that draws the bar.
          root.summary = Model.summarize({ error: "statuscake-uptime returned far more data than it should", data: [] })
        } else if (!raw) {
          // The helper always prints JSON, so silence means it could not run
          // at all -- a missing file or a lost exec bit.
          root.summary = Model.summarize({ error: "could not run statuscake-uptime", data: [] })
        } else {
          try {
            root.applyPayload(JSON.parse(raw))
          } catch (e) {
            root.summary = Model.summarize({ error: "unreadable output from statuscake-uptime", data: [] })
          }
        }

        if (root.pendingRefresh) {
          root.pendingRefresh = false
          root.refresh()
        }
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.config.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Text {
    id: pill
    anchors.centerIn: parent
    horizontalAlignment: Text.AlignHCenter
    // A vertical bar is 28px wide, far too narrow for "󰅚 2/13" on one line.
    text: bar && bar.vertical
      ? (root.display.detail === "" ? root.display.icon : root.display.icon + "\n" + root.display.detail)
      : root.display.text
    color: root.display.urgent && bar ? bar.urgent : (bar ? bar.foreground : "white")
    // A refresh is otherwise invisible when the numbers do not change, which
    // reads as a dead click. Dim briefly while the poll is in flight.
    opacity: root.refreshing ? 0.45 : (root.display.error ? 0.5 : 1.0)
    Behavior on opacity { NumberAnimation { duration: 120 } }
    font.family: bar ? bar.fontFamily : "monospace"
    font.pixelSize: 12
    lineHeight: 0.85
  }

  Panel {
    id: panel
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.panelOpen
    summary: root.summary
    refreshing: root.refreshing
    settings: root.settings

    onRefreshRequested: root.refresh()
    onCheckActivated: function(url) {
      if (bar) bar.run("omarchy-launch-browser " + Util.shellQuote(url))
      root.close()
    }
    onSettingChanged: function(key, value) { root.persistSetting(key, value) }
    // Unlike a check, the token link is somewhere the user goes to fetch
    // something they are coming straight back to paste. Leave the panel up.
    onLinkActivated: function(url) {
      if (bar) bar.run("omarchy-launch-browser " + Util.shellQuote(url))
    }
    onTokenStored: root.reloadAfterTokenChange()
    onTokenRemoved: root.reloadAfterTokenChange()
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: if (bar) bar.showTooltip(root, Model.tooltipText(root.summary))
    onExited: if (bar) bar.hideTooltip(root)

    // Left-click normally never composes here -- the bar's modulePointer holds
    // the press grab and calls triggerPress itself. This path carries right and
    // middle, and left too on any bar that does not claim it.
    onClicked: function(mouse) { root.triggerPress(mouse.button) }
  }
}
