import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Omelette overlay service.
//
//   show    a filmstrip of live window thumbnails centred on the tile while
//           you flip windows through it; the middle one is in the tile now.
//   pick    a searchable list of every window; Enter drops the choice into
//           the tile.
//   attention  windows that want you: urgent, a terminal bell, or an agent
//           that finished since you last looked (same title convention as
//           Ombre: spinner = working, U+2733 = waiting).
//
// All three are driven by the `omelette` script in this folder.
Item {
  id: root

  property var shell: null

  readonly property string scriptPath: String(Qt.resolvedUrl("omelette")).replace(/^file:\/\//, "")

  // ---------------------------------------------------------------- shared

  function norm(a) { return String(a || "").toLowerCase().replace(/^0x/, "") }

  function toplevelFor(address) {
    var key = norm(address)
    var tops = Hyprland.toplevels.values
    for (var i = 0; i < tops.length; i++)
      if (norm(tops[i].address) === key) return tops[i]
    return null
  }

  function screenFor(box) {
    var cx = Number(box.x) + Number(box.w) / 2
    var cy = Number(box.y) + Number(box.h) / 2
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      if (cx >= s.x && cx < s.x + s.width && cy >= s.y && cy < s.y + s.height) return s
    }
    return screens.length > 0 ? screens[0] : null
  }

  function initial(cls) {
    var c = String(cls || "?").replace(/^.*\./, "")
    return c.length > 0 ? c.charAt(0).toUpperCase() : "?"
  }

  // --------------------------------------------------------- attention

  property var agentLast: ({})
  property var finished: ({})

  function agentState(title) {
    var t = String(title || "").replace(/^🔔\s*/, "")
    var c = t.charAt(0)
    if ("◐◑◒◓".indexOf(c) >= 0) return "working"
    if (c === "✳") return "idle"
    return "other"
  }

  function scanAgents() {
    var tops = Hyprland.toplevels.values
    var last = root.agentLast, done = root.finished, seen = {}
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i], a = norm(t.address), s = agentState(t.title)
      seen[a] = true
      if (t.activated) delete done[a]
      else if (last[a] === "working" && s === "idle") done[a] = Date.now()
      last[a] = s
    }
    for (var k in last) if (!seen[k]) delete last[k]
    for (var d in done) if (!seen[d]) delete done[d]
  }

  function wantsAttention(t) {
    return t.urgent || String(t.title || "").indexOf("🔔") === 0 || !!root.finished[norm(t.address)]
  }

  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.scanAgents() }

  // ---------------------------------------------------------- filmstrip

  property bool opened: false
  property bool animate: true
  property real seq: 0
  property string session: ""
  property var ring: []
  property int index: 0
  property var tile: ({ x: 0, y: 0, w: 800, h: 600 })
  property bool sameApp: false
  property string note: ""
  property string screenName: ""
  property int tileX: 0
  property int tileY: 0

  readonly property var currentEntry: ring.length > 0 ? ring[Math.max(0, Math.min(index, ring.length - 1))] : null
  readonly property var currentTop: currentEntry ? toplevelFor(currentEntry.a) : null

  readonly property int thumbH: Math.round(Math.max(64, Math.min(260, tile.h * 0.24, (tile.w - 48) / 3.6 / 1.6)))
  readonly property int thumbW: Math.round(thumbH * 1.6)
  readonly property int stripW: Math.round(Math.min(tile.w - 40, thumbW * 3.6))

  Timer {
    id: hideTimer
    interval: 1500
    onTriggered: root.opened = false
  }

  function place(box) {
    var s = screenFor(box)
    if (!s) return false
    screenName = s.name
    tileX = Math.round(Number(box.x) - s.x)
    tileY = Math.round(Number(box.y) - s.y)
    tile = { x: Number(box.x), y: Number(box.y), w: Number(box.w), h: Number(box.h) }
    return true
  }

  function present(p) {
    if (Number(p.seq || 0) < root.seq) return
    root.seq = Number(p.seq || 0)
    root.picking = false   // a flip or undo always wins over an open search
    if (!place(p.tile)) return
    var fresh = String(p.session) !== root.session || (p.ring || []).length !== root.ring.length || !root.opened
    root.sameApp = !!p.sameApp
    root.note = String(p.note || "")
    if (fresh) {
      root.animate = false
      root.session = String(p.session)
      root.ring = p.ring || []
      root.index = Number(p.index || 0)
      Qt.callLater(function() { root.animate = true })
    } else {
      root.index = Number(p.index || 0)
    }
    root.opened = true
    hideTimer.restart()
  }

  // ------------------------------------------------------------- picker

  property bool picking: false
  property var pickRing: []
  property string pickTile: ""
  property string pickScreen: ""
  property var pickBox: ({ x: 0, y: 0, w: 800, h: 600 })
  property string query: ""
  property int selected: 0

  readonly property var matches: {
    var terms = root.query.toLowerCase().split(/\s+/).filter(function(t) { return t.length > 0 })
    return root.pickRing.filter(function(e) {
      if (e.a === root.pickTile) return false
      var top = root.toplevelFor(e.a)
      var hay = ((top ? top.title : e.t) + " " + e.c + " " + e.w).toLowerCase()
      for (var i = 0; i < terms.length; i++) if (hay.indexOf(terms[i]) < 0) return false
      return true
    })
  }

  function openPicker(p) {
    var s = screenFor(p.tile)
    if (!s) return
    root.opened = false
    root.pickScreen = s.name
    root.pickBox = { x: Number(p.tile.x) - s.x, y: Number(p.tile.y) - s.y, w: Number(p.tile.w), h: Number(p.tile.h) }
    root.pickTile = String(p.tileAddress)
    root.pickRing = p.ring || []
    root.query = ""
    root.selected = 0
    root.picking = true
    pickIdle.restart()
  }

  // The picker holds the keyboard while open; never let it trap input.
  Timer {
    id: pickIdle
    interval: 45000
    onTriggered: root.picking = false
  }

  function choose(entry) {
    if (!entry) return
    root.picking = false
    putProc.command = [root.scriptPath, "put", entry.a, "--window", root.pickTile]
    putProc.running = true
  }

  Process { id: putProc }

  // --------------------------------------------------------------- IPC

  IpcHandler {
    target: "omelette"
    function show(payload: string): string {
      try { root.present(JSON.parse(payload)) } catch (e) { return "bad payload: " + e }
      return "ok"
    }
    function pick(payload: string): string {
      try { root.openPicker(JSON.parse(payload)) } catch (e) { return "bad payload: " + e }
      return "ok"
    }
    function attention(): string {
      root.scanAgents()
      var out = [], tops = Hyprland.toplevels.values
      for (var i = 0; i < tops.length; i++)
        if (root.wantsAttention(tops[i])) out.push("0x" + root.norm(tops[i].address))
      return JSON.stringify(out)
    }
    function hide(): string { root.opened = false; root.picking = false; return "ok" }
    function state(): string { return root.picking ? "picking" : root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  // ------------------------------------------------------ thumbnail cell

  component Thumb: Rectangle {
    id: thumb
    property var entry: null
    property bool current: false
    property bool liveFeed: false
    readonly property var win: entry ? root.toplevelFor(entry.a) : null
    radius: 10
    clip: true
    color: Util.alpha(Color.foreground, 0.06)
    border.width: current ? 3 : 1
    border.color: current ? Color.accent : Util.alpha(Color.foreground, 0.2)

    ScreencopyView {
      id: shot
      anchors.centerIn: parent
      captureSource: thumb.visible && thumb.win ? thumb.win.wayland : null
      live: thumb.liveFeed
      constraintSize: Qt.size(Math.max(1, thumb.width - 8), Math.max(1, thumb.height - 8))
      width: implicitWidth
      height: implicitHeight
      onCaptureSourceChanged: if (captureSource && !live) captureFrame()
    }

    Text {
      anchors.centerIn: parent
      visible: !shot.hasContent
      text: root.initial(thumb.entry ? thumb.entry.c : "")
      color: Color.muted
      font.family: Style.font.resolvedFamily
      font.pixelSize: Math.round(thumb.height * 0.42)
      font.bold: true
    }

    Rectangle {
      visible: !!(thumb.entry && (thumb.entry.att || (thumb.win && root.wantsAttention(thumb.win))))
      width: Math.max(10, Math.round(thumb.height * 0.11))
      height: width
      radius: width / 2
      color: Color.accent
      border.color: Color.background
      border.width: 2
      anchors { top: parent.top; right: parent.right; margins: 6 }
    }
  }

  // ---------------------------------------------------- filmstrip layer

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      screen: modelData
      visible: root.opened && modelData.name === root.screenName
      color: "transparent"
      WlrLayershell.namespace: "omelette"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Visual only: an empty input region keeps the pointer and wheel on the window below.
      mask: Region {}

      anchors { top: true; left: true }
      margins {
        left: Math.max(0, root.tileX + (root.tile.w - card.width) / 2)
        top: Math.max(0, root.tileY + (root.tile.h - card.height) / 2)
      }
      implicitWidth: card.width
      implicitHeight: card.height

      Rectangle {
        id: card
        width: root.stripW + 24
        height: column.implicitHeight + 28
        radius: Math.round(root.thumbH * 0.08)
        clip: true
        color: Util.alpha(Color.background, 0.9)
        border.color: Util.alpha(Color.accent, 0.85)
        border.width: 2

        Column {
          id: column
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: 14
          width: root.stripW
          spacing: Math.round(root.thumbH * 0.05)

          PathView {
            id: strip
            width: root.stripW
            height: root.thumbH + 8
            model: root.ring
            interactive: false
            pathItemCount: Math.min(root.ring.length, 5)
            preferredHighlightBegin: 0.5
            preferredHighlightEnd: 0.5
            highlightRangeMode: PathView.StrictlyEnforceRange
            highlightMoveDuration: root.animate ? 240 : 0
            currentIndex: root.index
            movementDirection: PathView.Shortest

            path: Path {
              startX: -root.thumbW * 0.15
              startY: strip.height / 2
              PathAttribute { name: "itemScale"; value: 0.6 }
              PathAttribute { name: "itemOpacity"; value: 0.42 }
              PathAttribute { name: "itemZ"; value: 0 }
              PathLine { x: strip.width / 2; y: strip.height / 2 }
              PathAttribute { name: "itemScale"; value: 1.0 }
              PathAttribute { name: "itemOpacity"; value: 1.0 }
              PathAttribute { name: "itemZ"; value: 10 }
              PathLine { x: strip.width + root.thumbW * 0.15; y: strip.height / 2 }
              PathAttribute { name: "itemScale"; value: 0.6 }
              PathAttribute { name: "itemOpacity"; value: 0.42 }
              PathAttribute { name: "itemZ"; value: 0 }
            }

            delegate: Thumb {
              required property var modelData
              required property int index
              entry: modelData
              current: PathView.isCurrentItem
              liveFeed: root.opened
              width: root.thumbW
              height: root.thumbH
              scale: PathView.itemScale
              opacity: PathView.itemOpacity
              z: PathView.itemZ
            }
          }

          Text {
            width: parent.width
            text: root.note.length > 0 ? root.note
                : root.currentTop && root.currentTop.title ? root.currentTop.title
                : root.currentEntry ? (root.currentEntry.t || root.currentEntry.c) : ""
            color: Color.foreground
            font.family: Style.font.resolvedFamily
            font.pixelSize: Math.max(Style.font.heading + 4, Math.round(root.thumbH * 0.14))
            font.bold: true
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            visible: !!root.currentEntry
            text: root.currentEntry
                ? (root.index + 1) + " / " + root.ring.length + "  ·  " + root.currentEntry.c
                  + "  ·  " + root.currentEntry.w + (root.sameApp ? "  ·  same app" : "")
                : ""
            color: Color.muted
            font.family: Style.font.resolvedFamily
            font.pixelSize: Math.max(Style.font.title, Math.round(root.thumbH * 0.085))
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // ------------------------------------------------------- picker layer

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: pickPanel
      required property var modelData
      screen: modelData
      visible: root.picking && modelData.name === root.pickScreen
      color: "transparent"
      WlrLayershell.namespace: "omelette-picker"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; left: true; right: true; bottom: true }

      // Scale with the display so the picker reads the same on 1440p and 4K.
      readonly property real k: Math.max(1, modelData.height / 1440)
      readonly property int cardW: Math.min(Math.round(760 * k), modelData.width - 40)
      readonly property int rowH: Math.round(76 * k)
      readonly property int rows: Math.min(7, Math.max(1, root.matches.length))
      readonly property int cardH: Math.round(74 * k) + rows * rowH + 16

      // Click anywhere outside the card to close.
      MouseArea { anchors.fill: parent; onClicked: root.picking = false }

      // The target tile, dimmed and outlined so you can see where the pick lands.
      Rectangle {
        x: root.pickBox.x
        y: root.pickBox.y
        width: root.pickBox.w
        height: root.pickBox.h
        radius: 12
        color: Util.alpha(Color.background, 0.45)
        border.color: Color.accent
        border.width: 3
      }

      Rectangle {
        id: pickCard
        width: pickPanel.cardW
        height: pickPanel.cardH
        x: Math.max(20, Math.min(pickPanel.width - width - 20, root.pickBox.x + (root.pickBox.w - width) / 2))
        y: Math.max(20, Math.min(pickPanel.height - height - 20, root.pickBox.y + (root.pickBox.h - height) / 2))
        radius: 16
        color: Color.background
        border.color: Color.accent
        border.width: 2

        MouseArea { anchors.fill: parent }  // swallow clicks so the card doesn't close itself

        Column {
          anchors.fill: parent
          anchors.margins: 14
          spacing: 10

          Rectangle {
            width: parent.width
            height: Math.round(50 * pickPanel.k)
            radius: 10
            color: Util.alpha(Color.foreground, 0.07)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: 16
              visible: search.text.length === 0
              text: "Flip a window into this tile…"
              color: Color.muted
              font.family: Style.font.resolvedFamily
              font.pixelSize: Math.round(Style.font.heading * pickPanel.k)
            }

            TextInput {
              id: search
              anchors.verticalCenter: parent.verticalCenter
              x: 16
              width: parent.width - 32
              color: Color.foreground
              font.family: Style.font.resolvedFamily
              font.pixelSize: Math.round(Style.font.heading * pickPanel.k)
              focus: root.picking
              text: root.query
              onTextChanged: { root.query = text; root.selected = 0 }
              Keys.onPressed: function(event) {
                pickIdle.restart()
                var n = root.matches.length
                if (event.key === Qt.Key_Escape) { root.picking = false; event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (n > 0) root.choose(root.matches[root.selected]); event.accepted = true
                } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
                  if (n > 0) root.selected = (root.selected + 1) % n; event.accepted = true
                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) {
                  if (n > 0) root.selected = (root.selected - 1 + n) % n; event.accepted = true
                }
              }
            }
          }

          ListView {
            id: list
            width: parent.width
            height: pickPanel.rows * pickPanel.rowH
            clip: true
            model: root.matches
            currentIndex: root.selected
            highlightMoveDuration: 120
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property var win: root.toplevelFor(modelData.a)
              width: list.width
              height: pickPanel.rowH
              radius: 10
              color: index === root.selected ? Util.alpha(Color.accent, 0.22) : "transparent"

              Thumb {
                id: rowThumb
                entry: row.modelData
                current: row.index === root.selected
                liveFeed: false
                x: 8
                anchors.verticalCenter: parent.verticalCenter
                height: pickPanel.rowH - 14
                width: Math.round(height * 1.6)
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: rowThumb.right
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 12
                spacing: 3

                Text {
                  width: parent.width
                  text: row.win && row.win.title ? row.win.title : (row.modelData.t || row.modelData.c)
                  color: Color.foreground
                  font.family: Style.font.resolvedFamily
                  font.pixelSize: Math.round(Style.font.heading * pickPanel.k)
                  font.bold: row.index === root.selected
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: row.modelData.c + "  ·  " + row.modelData.w
                  color: Color.muted
                  font.family: Style.font.resolvedFamily
                  font.pixelSize: Math.round(Style.font.body * pickPanel.k)
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.selected = row.index
                onClicked: root.choose(row.modelData)
              }
            }
          }
        }
      }
    }
  }
}
