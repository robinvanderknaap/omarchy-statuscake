// The one window this widget has: the check list, and -- behind the cog --
// the settings for it.
//
// Built on qs.Ui's KeyboardPanel, which is what every first-party panel that
// has to be typed into uses (network's wifi passphrase, weather's location
// search). It is a layer surface that asks for keyboard focus, so a TextField
// inside it actually receives keystrokes. PopupCard, which this was before,
// is an xdg-popup on a bar that sets WlrKeyboardFocus.None: a field there
// takes the caret and then never sees a key.
//
// Settings are a second view in this same card rather than a window of their
// own. A screen-centered modal shipped first and was wrong for the shell in
// two ways. It held WlrKeyboardFocus.Exclusive for as long as it was up, and
// Hyprland then routes every pointer event to that surface whatever monitor
// the cursor is over, so no other window could be clicked. And being a layer
// surface rather than a toplevel, it looked like a window SUPER+W should
// close while SUPER+W actually closed whatever real window was behind it.
// KeyboardPanel primes Exclusive for 75ms and settles on OnDemand for exactly
// these reasons; see the comment at the top of Ui/KeyboardPanel.qml.
//
// That couples this file to qs.Ui and qs.Commons, which are shell internals
// with no compatibility promise to plugins; see README for what to check
// after an Omarchy update.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

KeyboardPanel {
  id: root

  property var summary: Model.emptySummary()
  property bool refreshing: false

  // Inline shell.json settings, handed down from the widget. Writing goes back
  // through it: the bar owns this object and the host shell owns the file.
  property var settings: ({})
  readonly property var config: Model.readSettings(settings)

  signal refreshRequested()
  signal checkActivated(string url)
  signal settingChanged(string key, var value)
  signal linkActivated(string url)
  // A token was verified and stored. What the widget last concluded about the
  // account is now stale in a way a plain refresh cannot express.
  signal tokenStored()
  // The stored token was deleted. Same staleness, other direction: the widget
  // is still showing an account it can no longer reach.
  signal tokenRemoved()

  // Until a token works, the token form is the whole settings view: the rest
  // configures a fetch that cannot happen, and the defaults are fine to arrive
  // with. See Model.tokenBlocksSettings for what counts as working.
  readonly property bool tokenBlocked: Model.tokenBlocksSettings(summary, tokenStatus)

  readonly property bool needsToken: Model.needsToken(summary)

  // Whether there is a token, whether it is known to work, and where it lives.
  readonly property var tokenState: Model.tokenState(summary, tokenStatus)
  // Themed, not a fixed green. Omarchy palettes carry no success colour, and a
  // hardcoded one would be the only thing in this plugin that ignores the
  // theme; on palettes where accent equals foreground the tick reads as plain
  // rather than green, which is the price of belonging to the theme. Either
  // way the line lifts out of the muted text around it.
  readonly property color tokenToneColor: {
    if (tokenState.tone === "ok") return Color.accent
    if (tokenState.tone === "bad") return Color.urgent
    return Color.muted
  }
  readonly property bool tokenRejected: Model.tokenRejected(summary)

  readonly property int rowHeight: Style.spacing.popupRowHeight
  readonly property int maxListHeight: Style.space(360)

  // Qt.resolvedUrl gives a file:// URL; Process wants a plain path.
  readonly property string setupPath:
    Qt.resolvedUrl("bin/statuscake-setup").toString().replace(/^file:\/\//, "")
  readonly property string tagsPath:
    Qt.resolvedUrl("bin/statuscake-tags").toString().replace(/^file:\/\//, "")

  // Which of the two views the card is showing.
  property bool showingSettings: false

  // Result of the last `--status --no-verify` run: where the token lives, or
  // that there is none. Re-read every time the settings view is entered, so
  // the line is never a report of what was true the last time it was up.
  property var tokenStatus: null
  property bool saving: false
  // Removal is two clicks, not one: it sits a control away from Save, and a
  // slip deletes a credential the panel cannot get back.
  property bool confirmingRemove: false
  property bool removing: false
  // Whatever the last save or removal went wrong with. One line for both:
  // only one of them is on screen at a time. Cleared the moment the field is
  // edited, so a stale rejection never sits under a token already corrected.
  property string tokenError: ""

  // One width for both views: the card would otherwise resize under the
  // pointer every time the cog is clicked.
  contentWidth: fittedContentWidth(Style.space(380))
  contentHeight: fittedContentHeight(content.implicitHeight)
  focusTarget: keyCatcher

  function showSettings() {
    if (showingSettings) return
    showingSettings = true
    refreshTokenStatus()
    // Set rather than bound: MultiSelect assigns its own `values` as rows are
    // clicked, which would break the binding on the first click anyway.
    tagsSelect.values = Model.tagList(config.tags)
    focusTimer.restart()
  }

  function hideSettings() {
    if (!showingSettings) return
    showingSettings = false
    tokenField.text = ""
    tokenError = ""
    confirmingRemove = false
    keyCatcher.forceActiveFocus()
  }

  // Escape, and the only place that decides what it means: out of an armed
  // removal first, out of settings next, out of the panel last.
  function goBack() {
    if (confirmingRemove) confirmingRemove = false
    else if (showingSettings) hideSettings()
    else close()
  }

  function refreshTokenStatus() {
    confirmingRemove = false
    if (statusProc.running) return
    statusProc.command = [root.setupPath, "--status", "--json", "--no-verify"]
    statusProc.running = true
  }

  function saveToken() {
    var token = tokenField.text
    if (saving || token === "") return
    saving = true
    tokenError = ""
    // The token reaches the script on stdin, never as an argument, so it stays
    // out of ps and /proc/<pid>/cmdline exactly as the fetch path keeps it.
    saveProc.pendingToken = token
    saveProc.command = [root.setupPath, "--stdin", "--json"]
    saveProc.running = true
  }

  // Deletes the keyring entry and the token file. Nothing in Omarchy does this
  // when the plugin is removed -- omarchy-plugin-remove deletes the folder and
  // stops -- so this button is the whole story for a user who wants their
  // credential gone.
  function removeToken() {
    if (removing) return
    removing = true
    tokenError = ""
    removeProc.command = [root.setupPath, "--remove", "--json"]
    removeProc.running = true
  }

  // Every control in here writes on the spot, the tag picker included: there is
  // no edit to commit, only rows going on and off.
  function applyTagSelection(values) {
    settingChanged("tags", Model.joinTags(values))
  }

  // The panel always comes back up on the check list. Settings is somewhere
  // you went, not a state the widget remembers.
  onOpenChanged: {
    if (!open) hideSettings()
  }

  // AfterItem priority: the fields below own their own keys, and only what
  // they ignore bubbles back here. `blocked` covers the rest -- j/k/x/Space
  // are navigation to this catcher and characters to a focused field.
  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    blocked: tokenField.activeFocus || refreshField.field.activeFocus || tagsSelect.popupOpen

    onCloseRequested: root.goBack()

    Timer {
      id: focusTimer
      // Later than KeyboardPanel's own Qt.callLater onto focusTarget, which
      // would otherwise pull focus straight back out of the token field.
      interval: 100
      onTriggered: {
        if (!root.open || !root.showingSettings) return
        if (root.tokenBlocked) tokenField.forceActiveFocus()
        else keyCatcher.forceActiveFocus()
      }
    }

    Process {
      id: statusProc
      running: false
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: root.tokenStatus = Model.parseSetupResult(text)
      }
    }

    Process {
      id: saveProc
      // Held only for the moment between starting the process and writing to its
      // stdin, then dropped.
      property string pendingToken: ""

      running: false
      stdinEnabled: true

      onStarted: {
        write(pendingToken + "\n")
        pendingToken = ""
        // Closing stdin is what tells the script it has the whole token.
        stdinEnabled = false
      }

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          root.saving = false
          var result = Model.parseSetupResult(text)
          if (!result.ok) {
            root.tokenError = result.error
            tokenField.forceActiveFocus()
            return
          }
          root.tokenStored()
          root.hideSettings()
        }
      }
    }

    Process {
      id: removeProc
      running: false
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          root.removing = false
          root.confirmingRemove = false
          var result = Model.parseSetupResult(text)
          if (!result.ok) {
            root.tokenError = result.error
            return
          }
          // The status line and the token form both read from what the probe
          // finds, so re-read it rather than assume the removal took.
          root.refreshTokenStatus()
          root.tokenRemoved()
        }
      }
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.spacing.md

      // ---- header, shared by both views ---------------------------------

      Item {
        width: parent.width
        height: Math.max(heading.implicitHeight, actions.implicitHeight)

        Row {
          id: heading
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.controlGap

          // StatusCake's own mark, cropped out of their horizontal logo -- see
          // the comment in the file. Only on the check list: the settings view
          // puts a back arrow in this spot, and two glyphs before one word is
          // one too many. An SVG rasterises at sourceSize and is then scaled,
          // so that is set to the height it is actually drawn at.
          Image {
            id: logo
            visible: !root.showingSettings
            source: Qt.resolvedUrl("assets/statuscake.svg")
            sourceSize.height: Math.round(Style.font.subtitle * 1.15)
            fillMode: Image.PreserveAspectFit
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: title
            text: root.showingSettings ? "󰁍  Settings" : "StatusCake"
            color: root.showingSettings && backHover.hovered ? Color.accent : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            anchors.verticalCenter: parent.verticalCenter

            HoverHandler {
              id: backHover
              enabled: root.showingSettings
              cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
              enabled: root.showingSettings
              onTapped: root.hideSettings()
            }
          }
        }

        Row {
          id: actions
          visible: !root.showingSettings
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.controlGap

          Text {
            id: refreshButton
            text: "󰑐"
            color: refreshHover.hovered ? Color.popups.text : Color.muted
            opacity: root.refreshing ? 0.4 : 1.0
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter

            Behavior on opacity { NumberAnimation { duration: 120 } }

            HoverHandler { id: refreshHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.refreshRequested() }
          }

          Text {
            id: settingsButton
            text: "󰒓"
            color: settingsHover.hovered ? Color.popups.text : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter

            HoverHandler { id: settingsHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.showSettings() }
          }
        }
      }

      PanelSeparator { width: parent.width }

      // ---- body: whichever of the two views is up ------------------------

      Item {
        width: parent.width
        implicitHeight: root.showingSettings ? settingsView.implicitHeight : listView.implicitHeight

        Column {
          id: listView
          width: parent.width
          visible: !root.showingSettings
          spacing: Style.spacing.md

          // Counts, or the reason there are none.
          Text {
            width: parent.width
            text: {
              if (root.needsToken) return "No API token yet."
              if (root.summary.error) return root.summary.error
              if (!root.summary.hasData) return "Loading…"
              var parts = [root.summary.up + " up", root.summary.down + " down"]
              if (root.summary.paused > 0) parts.push(root.summary.paused + " paused")
              return parts.join("  ·  ")
            }
            color: root.summary.error ? Color.urgent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.needsToken || root.tokenRejected
            text: (root.needsToken ? "Set one up" : "Replace the token") + " →"
            color: actionHover.hovered ? Color.popups.text : Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap

            HoverHandler { id: actionHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.showSettings() }
          }

          PanelSeparator {
            width: parent.width
            visible: root.summary.checks.length > 0
          }

          ListView {
            id: list
            width: parent.width
            height: Math.min(root.maxListHeight, contentHeight)
            visible: root.summary.checks.length > 0
            model: root.summary.checks
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.spacing.xxs

            delegate: Item {
              required property var modelData
              readonly property bool isDown: Model.isDown(modelData)
              readonly property bool isPaused: Model.isPaused(modelData)

              width: list.width
              height: root.rowHeight

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Color.popups.text
                opacity: rowHover.hovered ? 0.08 : 0
                Behavior on opacity { NumberAnimation { duration: 100 } }
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: Style.spacing.sm
                spacing: Style.spacing.controlGap

                Text {
                  text: parent.parent.isDown ? Model.ICON_DOWN : (parent.parent.isPaused ? "󰏤" : "󰄬")
                  color: parent.parent.isDown
                    ? Color.urgent
                    : (parent.parent.isPaused ? Color.muted : Color.popups.text)
                  opacity: parent.parent.isPaused ? 0.7 : 1.0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  width: parent.width - Style.space(96)
                  text: modelData.name
                  color: parent.parent.isPaused ? Color.muted : Color.popups.text
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: Model.formatUptime(modelData.uptime)
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              HoverHandler {
                id: rowHover
                cursorShape: modelData.url !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
              }

              TapHandler {
                onTapped: {
                  if (modelData.url !== "") root.checkActivated(modelData.url)
                }
              }
            }
          }
        }

        Column {
          id: settingsView
          width: parent.width
          visible: root.showingSettings
          spacing: Style.spacing.md

          // Everything a working token unlocks. Hidden rather than disabled
          // on a first run: a column of controls you cannot use yet is noise
          // in front of the one thing that has to happen first.
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: !root.tokenBlocked

            PanelSectionHeader {
              text: "FILTERS"
              foreground: Color.popups.text
            }

            Item {
              width: parent.width
              height: Math.max(tagsLabel.implicitHeight, tagsSelect.implicitHeight)

              Text {
                id: tagsLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Tags"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              // The account's own tags, not a field to spell them into. The API
              // matches literally, so a typo used to mean a pill reading 0 up,
              // 0 down with nothing anywhere saying why.
              MultiSelect {
                id: tagsSelect
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(200)
                showLabel: false
                noSelectionText: "no tags selected"
                placeholderText: "Search tags…"
                emptyText: "No tags on this account"
                // Only while the view is up: MultiSelect refreshes on every
                // change to this, on construction, and on every popup open, and
                // each refresh is an unfiltered fetch against the rate limit.
                optionsCommand: root.showingSettings ? [root.tagsPath] : []
                foreground: Color.popups.text
                accent: Color.accent
                fontFamily: Style.font.family

                onChanged: function(values) { root.applyTagSelection(values) }
              }
            }

            Toggle {
              width: parent.width
              label: "Match any tag"
              description: root.config.tags === ""
                ? "Add tags above to use this."
                : "Show uptime checks carrying any of those tags, not only those carrying all of them."
              checked: root.config.matchAnyTag
              // The API rejects matchany with no tags, and fetchArgs drops it, so
              // an enabled switch here would be a lie.
              enabled: root.config.tags !== ""
              opacity: enabled ? 1.0 : 0.5
              foreground: Color.popups.text
              accent: Color.accent
              fontFamily: Style.font.family
              titleSize: Style.font.bodySmall
              onClicked: root.settingChanged("matchAnyTag", !root.config.matchAnyTag)
            }

            PanelSeparator { width: parent.width }

            PanelSectionHeader {
              text: "POLLING"
              foreground: Color.popups.text
            }

            Item {
              width: parent.width
              height: Math.max(refreshLabel.implicitHeight, refreshField.implicitHeight)

              Text {
                id: refreshLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Refresh every (seconds)"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              NumberField {
                id: refreshField
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                // Matches the manifest, and is the only place the bounds are
                // enforced before the value reaches shell.json.
                from: 60
                to: 3600
                stepSize: 30
                value: root.config.refreshIntervalSec
                foreground: Color.popups.text
                fontFamily: Style.font.family
                onModified: function(value) { root.settingChanged("refreshIntervalSec", value) }
              }
            }

            PanelSeparator { width: parent.width }

            PanelSectionHeader {
              text: "NOTIFICATIONS"
              foreground: Color.popups.text
            }

            Toggle {
              width: parent.width
              label: "Notify on state changes"
              description: "A desktop notification when a check flips up to down, or back."
              checked: root.config.notify
              foreground: Color.popups.text
              accent: Color.accent
              fontFamily: Style.font.family
              titleSize: Style.font.bodySmall
              onClicked: root.settingChanged("notify", !root.config.notify)
            }

            PanelSeparator { width: parent.width }
          }

          PanelSectionHeader {
            text: "API TOKEN"
            foreground: Color.popups.text
          }

          // Glyph and line share a colour, so the state reads before the
          // sentence does.
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            Text {
              text: root.tokenState.icon
              color: root.tokenToneColor
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width - x
              text: root.tokenState.text
              color: root.tokenToneColor
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // Either/or, and `tokenBlocked` decides: a working token has nothing
          // to paste, and a section that is not working has nothing worth
          // removing -- the fix for a rejected token is a new one over the top
          // of it. That is the same predicate that hides the rest of the
          // settings view, so the form is up exactly when the widget cannot
          // fetch.

          // ---- no working token: paste one -------------------------------

          Item {
            width: parent.width
            visible: root.tokenBlocked
            height: Math.max(tokenField.implicitHeight, saveButton.implicitHeight)

            TextField {
              id: tokenField
              anchors.left: parent.left
              anchors.right: saveButton.left
              anchors.rightMargin: Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              password: true
              enabled: !root.saving
              placeholderText: "Paste your API token"
              foreground: Color.popups.text
              font.family: Style.font.family

              onTextChanged: root.tokenError = ""
              onAccepted: root.saveToken()
              // The field owns its keys while it has focus, so Escape has to
              // be handed back or it would go nowhere.
              Keys.onEscapePressed: root.goBack()
            }

            Button {
              id: saveButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.saving ? "Saving…" : "Save"
              bordered: true
              enabled: !root.saving && tokenField.text !== ""
              opacity: enabled ? 1.0 : 0.45
              foreground: Color.popups.text
              fontFamily: Style.font.family
              onClicked: root.saveToken()
            }
          }

          // The save result, or what the field is for when there is nothing to
          // report yet.
          Text {
            width: parent.width
            visible: root.tokenBlocked
            text: root.tokenError !== "" ? root.tokenError : Model.tokenSaveHint(root.tokenStatus)
            color: root.tokenError !== "" ? Color.urgent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Only earns its place next to the field: with a token that works
          // there is nothing to go and create.
          Text {
            width: parent.width
            visible: root.tokenBlocked
            text: "Create a token at app.statuscake.com →"
            color: linkHover.hovered ? Color.popups.text : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap

            // Opens the browser without closing the panel: the whole point is
            // to come back and paste what you copied there.
            HoverHandler { id: linkHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.linkActivated("https://app.statuscake.com/User/Account") }
          }

          // ---- a working token: the only thing left to do is delete it ----
          //
          // Removing the plugin leaves the token where it is: Omarchy has no
          // uninstall hook, so nothing runs on the way out. This is the only
          // route to deleting it that does not need a terminal, which is why
          // the warning is here rather than only in the README.
          //
          // Replacing a working token is removing it and pasting the next one:
          // that lands in this same section a click later, and a token worth
          // rotating in a hurry is usually one the API has already rejected,
          // which shows the form anyway.

          Item {
            width: parent.width
            visible: !root.tokenBlocked && Model.tokenRemovable(root.tokenStatus)
            height: Math.max(removeLabel.implicitHeight, removeButton.implicitHeight)

            Text {
              id: removeLabel
              anchors.left: parent.left
              anchors.right: cancelRemoveButton.visible
                ? cancelRemoveButton.left : removeButton.left
              anchors.rightMargin: Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              text: {
                if (root.tokenError !== "") return root.tokenError
                if (root.removing) return "Removing…"
                if (root.confirmingRemove) return Model.tokenRemoveConfirm(root.tokenStatus)
                return "Removing the plugin will not remove this token. Clear it here first."
              }
              color: {
                if (root.tokenError !== "") return Color.urgent
                if (root.confirmingRemove) return Color.popups.text
                return Color.muted
              }
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              id: cancelRemoveButton
              anchors.right: removeButton.left
              anchors.rightMargin: Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              visible: root.confirmingRemove && !root.removing
              text: "Cancel"
              foreground: Color.popups.text
              fontFamily: Style.font.family
              onClicked: root.confirmingRemove = false
            }

            Button {
              id: removeButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.confirmingRemove ? "Delete" : "Remove token"
              bordered: true
              enabled: !root.removing
              opacity: enabled ? 1.0 : 0.45
              // Urgent only once it would actually delete something: the first
              // click arms, and colouring that one urgent would cry wolf.
              foreground: root.confirmingRemove ? Color.urgent : Color.popups.text
              fontFamily: Style.font.family
              onClicked: {
                if (root.confirmingRemove) root.removeToken()
                else root.confirmingRemove = true
              }
            }
          }
        }
      }
    }
  }
}
