import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "local.backup-status"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function injectPanel() {
    if (!panelItem) return
    if ("bar" in panelItem) panelItem.bar = root.bar
    if ("anchorItem" in panelItem) panelItem.anchorItem = button
    if ("hostWidget" in panelItem) panelItem.hostWidget = root
  }

  function refresh() {
    if (panelItem && panelItem.refresh) panelItem.refresh()
  }

  function open() {
    if (panelItem && panelItem.open) panelItem.open()
  }

  function close() {
    if (panelItem && panelItem.close) panelItem.close()
  }

  function togglePanel() {
    if (panelItem && panelItem.toggle) panelItem.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelItem && panelItem.closeForPopoutSwitch) panelItem.closeForPopoutSwitch()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("BackupDashboard.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  onBarChanged: injectPanel()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: panelItem ? panelItem.stateIcon : "\uf0c2"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: panelItem ? "Backup: " + panelItem.stateLabel + " · clique para abrir painel" : "Backup Omarchy"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
