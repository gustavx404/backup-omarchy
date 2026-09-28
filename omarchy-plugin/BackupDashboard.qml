import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "local.backup-status"
  ipcTarget: "local.backup-status"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property string backupState: "never"
  property string failureCode: ""
  property string lastRun: ""
  property int ageSeconds: 0
  property int failures: 0
  property int jobsCount: 0
  property string favoritesState: "missing"
  property int favoritesAgeSeconds: 0
  property string configState: "missing"
  property bool omarchySnapshotsEnabled: true
  property bool favoritesSnapshotsEnabled: true
  property bool snapshotFormOpen: false
  property string snapshotSyncId: ""
  property string snapshotPath: "Backups"
  property string snapshotMessage: ""
  property string timerState: "unknown"
  property var jobs: []
  property var syncs: []
  property var history: []
  property int selectedAction: 0
  property bool baselineOptionsOpen: false
  property bool activityExpanded: false
  property bool syncManagerOpen: false
  property bool syncFormOpen: false
  property string editingSyncId: ""
  property string formName: ""
  property string formSource: ""
  property string formRemote: ""
  property string formRemotePath: ""
  property string formMode: "bisync"
  property string formExcludes: ""
  property string formError: ""
  property string managerMessage: ""
  property var remoteList: []
  property string remoteError: ""
  property var remoteOptions: root.remoteList.map(function(remote) {
    return { value: String(remote.name), label: String(remote.name), description: String(remote.type || "rclone") }
  })
  property var modeOptions: [
    { value: "bisync", label: "Bidirecional", description: "Propaga alterações dos dois lados" },
    { value: "copy", label: "Cópia", description: "Envia sem apagar o destino" },
    { value: "sync", label: "Espelho", description: "Pode apagar itens extras do destino" }
  ]
  property var snapshotSyncOptions: root.syncs.map(function(sync) {
    return { value: String(sync.id), label: String(sync.name), description: String(sync.destination || "") }
  })
  property var pendingSync: null
  property string pendingSyncAction: ""
  property string commandAction: ""
  property string commandOutput: ""
  property string commandError: ""
  property int commandExitCode: -1
  property bool commandStdoutDone: false
  property bool commandStderrDone: false

  readonly property var actionItems: {
    var items = []
    if (baselineOptionsOpen) {
      items.push({ label: "Mais recente", action: "newer" })
      items.push({ label: "PC vence", action: "pc" })
      items.push({ label: "Destino vence", action: "remote" })
    } else items.push({ label: "Mudar baseline", action: "baseline" })
    items.push({ label: "Executar backup", action: "run" })
    items.push({ label: "Abrir logs", action: "logs" })
    items.push({ label: "Atualizar painel", action: "refresh" })
    return items
  }
  property string pendingResyncMode: ""

  readonly property string stateLabel: {
    if (backupState === "running") return "Em andamento"
    if (backupState === "ok") return "Atualizado"
    if (backupState === "warning") return "Parcial"
    if (backupState === "stale") return "Atrasado"
    if (backupState === "fail" && failureCode === "resync-required") return "Baseline precisa ser recriado"
    if (backupState === "fail") return "Falhou"
    return "Ainda não executado"
  }
  readonly property string stateIcon: {
    if (backupState === "running") return "\uf021"
    if (backupState === "ok") return "\uf058"
    if (backupState === "fail" || backupState === "stale" || backupState === "warning") return "\uf071"
    return "\uf0c2"
  }
  readonly property string diagnosis: {
    if (failureCode === "resync-required") return "O filtro mudou. Escolha se a origem, o destino ou o arquivo mais recente vence antes de recriar o baseline."
    if (backupState === "fail") return "A última execução falhou. Abra os logs para ver o motivo e tente novamente quando estiver corrigido."
    if (backupState === "stale") return "A última cópia passou do intervalo esperado. Confira o timer e execute uma rodada."
    if (backupState === "warning" && configState !== "ok") return "A cópia pessoal terminou, mas o snapshot de configurações do Omarchy está ausente."
    if (backupState === "warning") return "A cópia pessoal terminou, mas os favoritos precisam de atenção."
    if (backupState === "never") return "Faça a primeira execução para criar snapshots e iniciar a sincronização."
    return "Suas pastas pessoais e snapshots estão sendo acompanhados pelo Omarchy."
  }

  function ageText(seconds) {
    if (seconds < 120) return "agora"
    if (seconds < 7200) return "há " + Math.floor(seconds / 60) + " min"
    if (seconds < 172800) return "há " + Math.floor(seconds / 3600) + " h"
    return "há " + Math.floor(seconds / 86400) + " dias"
  }

  function formatDuration(seconds) {
    if (seconds < 60) return seconds + " s"
    return Math.floor(seconds / 60) + " min " + (seconds % 60) + " s"
  }

  function weeklyDays() {
    var days = []
    var now = new Date()
    now.setHours(0, 0, 0, 0)
    for (var offset = 6; offset >= 0; offset--) {
      var date = new Date(now.getTime() - offset * 86400000)
      var key = date.getFullYear() + "-" + String(date.getMonth() + 1).padStart(2, "0") + "-" + String(date.getDate()).padStart(2, "0")
      var count = 0
      var failed = 0
      for (var i = 0; i < history.length; i++) {
        if (history[i].day === key) {
          count += 1
          if (history[i].state !== "ok") failed += 1
        }
      }
      if (history.length === 0 && root.lastRun.slice(0, 10) === key) {
        count = 1
        if (root.backupState === "fail") failed = 1
      }
      days.push({ label: ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"][date.getDay()], count: count, failed: failed })
    }
    return days
  }

  function weeklySummary() {
    var days = weeklyDays()
    var total = 0
    var failed = 0
    for (var i = 0; i < days.length; i++) {
      total += days[i].count
      failed += days[i].failed
    }
    if (total === 0) return "Sem execuções"
    return (total - failed) + "/" + total + " ok"
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function refreshRemotes() {
    if (remoteProcess.running) return
    remoteError = ""
    remoteProcess.running = true
  }

  function beginNewSync() {
    syncManagerOpen = true
    syncFormOpen = true
    editingSyncId = ""
    formName = ""
    formSource = "~/personal"
    formRemote = remoteList.length > 0 ? String(remoteList[0].name) : ""
    formRemotePath = ""
    formMode = "bisync"
    formExcludes = ""
    formError = ""
    managerMessage = ""
    refreshRemotes()
    Qt.callLater(function() { syncNameField.forceActiveFocus() })
  }

  function editSync(sync) {
    var separator = String(sync.destination || "").indexOf(":")
    syncManagerOpen = true
    syncFormOpen = true
    editingSyncId = String(sync.id || "")
    formName = String(sync.name || "")
    formSource = String(sync.source || "")
    formRemote = separator > 0 ? String(sync.destination).slice(0, separator) : ""
    formRemotePath = separator > 0 ? String(sync.destination).slice(separator + 1) : ""
    formMode = String(sync.mode || "bisync")
    formExcludes = (sync.exclude || []).join("\n")
    formError = ""
    managerMessage = ""
    refreshRemotes()
    Qt.callLater(function() { syncNameField.forceActiveFocus() })
  }

  function closeSyncForm() {
    syncFormOpen = false
    formError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openSnapshotForm() {
    var target = root.syncs.find(function(sync) { return sync.snapshotTarget === true })
    var fallback = root.syncs.find(function(sync) { return sync.enabled === true }) || root.syncs[0]
    root.snapshotSyncId = target ? String(target.id) : fallback ? String(fallback.id) : ""
    root.snapshotPath = target && target.snapshotPath ? String(target.snapshotPath) : "Backups"
    root.snapshotMessage = ""
    root.snapshotFormOpen = true
  }

  function snapshotPreview() {
    var sync = root.syncs.find(function(item) { return String(item.id) === root.snapshotSyncId })
    if (!sync) return "Adicione um sync antes de definir o destino."
    var source = String(sync.source || "").replace(/\/$/, "")
    var remote = String(sync.destination || "")
    var path = root.snapshotPath.trim().replace(/^\/+|\/+$/g, "")
    return source + "/" + path + "/{Omarchy,Favoritos}  →  " + remote + "/" + path + "/{Omarchy,Favoritos}"
  }

  function snapshotTargetSummary() {
    var sync = root.syncs.find(function(item) { return item.snapshotTarget === true })
    if (!sync) return "Destino: não configurado · escolha um sync"
    var path = String(sync.snapshotPath || "Backups").replace(/^\/+|\/+$/g, "")
    return "Destino: " + String(sync.name || "Sync") + " · " + path + "/Omarchy + Favoritos"
  }

  function snapshotStatusSummary() {
    var configText = root.configState === "ok" ? "Omarchy salvo" : root.configState === "disabled" ? "Omarchy pausado" : "Omarchy sem cópia"
    var favoritesText = root.favoritesState === "ok" || root.favoritesState === "stale" ? "Favoritos " + root.ageText(root.favoritesAgeSeconds) : root.favoritesState === "pending" ? "Favoritos pendentes" : root.favoritesState === "disabled" ? "Favoritos pausados" : "Favoritos sem cópia"
    return configText + " · " + favoritesText
  }

  function saveSnapshotTarget() {
    if (!root.snapshotSyncId || !root.snapshotPath.trim()) {
      root.snapshotMessage = "Escolha um sync e informe a subpasta."
      return
    }
    root.runSyncCommand(["syncs", "snapshot-target", "--json", JSON.stringify({
      syncId: root.snapshotSyncId,
      path: root.snapshotPath.trim().replace(/^\/+|\/+$/g, "")
    })], "snapshot-target")
  }

  function toggleSnapshotOption(option) {
    if (commandProcess.running) return
    var options = {
      omarchy: root.omarchySnapshotsEnabled,
      favorites: root.favoritesSnapshotsEnabled
    }
    options[option] = !options[option]
    root.snapshotMessage = ""
    root.runSyncCommand(["syncs", "snapshot-options", "--json", JSON.stringify(options)], "snapshot-options")
  }

  function saveSync() {
    var name = formName.trim()
    var source = formSource.trim()
    var remotePath = formRemotePath.trim().replace(/^\/+|\/+$/g, "")
    if (!name || !source || !formRemote || !remotePath) {
      formError = "Preencha nome, origem, provider e pasta de destino."
      return
    }
    if (remoteError || !remoteList.some(function(remote) { return String(remote.name) === formRemote })) {
      formError = "Atualize ou configure um remote no rclone antes de salvar."
      return
    }
    var excludes = formExcludes.split("\n").map(function(value) { return value.trim() }).filter(function(value) { return value.length > 0 })
    var id = editingSyncId || Qt.createUuid().replace(/[{}-]/g, "")
    var item = {
      id: id,
      name: name,
      source: source,
      destination: formRemote + ":" + remotePath,
      mode: formMode,
      enabled: true,
      exclude: excludes
    }
    if (editingSyncId) {
      for (var i = 0; i < syncs.length; i++) {
        if (String(syncs[i].id) === editingSyncId) item.enabled = syncs[i].enabled === true
      }
    }
    formError = ""
    runSyncCommand(["syncs", "upsert", "--json", JSON.stringify(item)], "save")
  }

  function runSyncCommand(args, action) {
    if (commandProcess.running) return
    commandAction = action
    commandOutput = ""
    commandError = ""
    commandExitCode = -1
    commandStdoutDone = false
    commandStderrDone = false
    if (action === "run" || action === "resync") {
      managerMessage = "Executando “" + String(args[1] || "sync") + "”…"
      backupState = "running"
    }
    commandProcess.command = [Quickshell.env("HOME") + "/.local/bin/backup_multiplo"].concat(args)
    commandProcess.running = true
  }

  function finishSyncCommand() {
    if (commandExitCode < 0 || !commandStdoutDone || !commandStderrDone) return
    var action = commandAction
    commandAction = ""
    if (commandExitCode !== 0) {
      var message = String(commandError || commandOutput || "A ação não foi concluída.").trim()
      if (action === "save") formError = message
      else if (action === "snapshot-target" || action === "snapshot-options") snapshotMessage = message
      else managerMessage = message
      return
    }
    if (action === "save") {
      syncFormOpen = false
      managerMessage = editingSyncId ? "Sync atualizado." : "Sync adicionado. Ele ainda não foi executado."
      editingSyncId = ""
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else if (action === "snapshot-target") {
      snapshotFormOpen = false
      snapshotMessage = ""
    } else if (action === "snapshot-options") {
      snapshotMessage = ""
    } else if (action === "remove") managerMessage = "Configuração removida; os arquivos continuam nos dois lados."
    else if (action === "toggle") managerMessage = "Estado do sync atualizado."
    else if (action === "run" || action === "resync") managerMessage = "Execução iniciada; acompanhe o resultado em Últimas tarefas ou Logs."
    refresh()
    refreshSoon.restart()
  }

  function requestSyncRun(sync, resync) {
    if (!sync || sync.enabled !== true) return
    if (resync) {
      pendingSyncAction = "resync"
      confirmSync.message = "Recriar o baseline de “" + sync.name + "” pode propagar alterações entre origem e destino. O arquivo mais recente vence em conflitos."
    } else if (sync.mode === "sync") {
      pendingSyncAction = "run"
      confirmSync.message = "O espelho deixa o destino igual à origem e pode apagar itens extras. As exclusões ficam no arquivo-morto configurado."
    } else if (sync.mode === "bisync" && sync.baselineReady !== true) {
      pendingSyncAction = "resync"
      confirmSync.message = "Este sync ainda não tem baseline. A primeira execução compara os dois lados e pode propagar mudanças; em conflitos, o arquivo mais recente vence."
    } else {
      runSyncCommand(["syncs", "run", String(sync.id)], "run")
      return
    }
    pendingSync = sync
    confirmSync.selectedIndex = 1
    confirmSync.opened = true
  }

  function requestSyncRemoval(sync) {
    pendingSync = sync
    pendingSyncAction = "remove"
    confirmSync.message = "Remover “" + sync.name + "” apaga somente sua configuração. Nenhum arquivo será apagado da origem ou do destino."
    confirmSync.selectedIndex = 1
    confirmSync.opened = true
  }

  function confirmSyncAction() {
    if (!pendingSync) return
    var sync = pendingSync
    var action = pendingSyncAction
    pendingSync = null
    pendingSyncAction = ""
    confirmSync.opened = false
    if (action === "remove") runSyncCommand(["syncs", "remove", String(sync.id)], "remove")
    else if (action === "resync") runSyncCommand(["syncs", "run", String(sync.id), "--resync", "--mode", "newer"], "resync")
    else if (action === "run") runSyncCommand(["syncs", "run", String(sync.id)], "run")
  }

  function toggleSync(sync) {
    runSyncCommand(["syncs", "set-enabled", String(sync.id), sync.enabled === true ? "0" : "1"], "toggle")
  }

  function activateConfirmSync() {
    if (confirmSync.selectedIndex === 0) {
      confirmSync.opened = false
      pendingSync = null
      pendingSyncAction = ""
    } else confirmSyncAction()
  }

  function runBackup() {
    if (backupState === "running") return
    Quickshell.execDetached(["systemctl", "--user", "start", "backup-multiplo.service"])
    backupState = "running"
    refreshSoon.restart()
  }

  function requestResync(mode, label) {
    pendingResyncMode = mode
    confirmResync.selectedIndex = 1
    confirmResync.message = "Usar " + label + " para recriar o baseline pode propagar alterações entre origem e destino."
    confirmResync.opened = true
  }

  function confirmPendingResync() {
    if (!pendingResyncMode) return
    var argument = pendingResyncMode === "newer" ? "--resync" : "--resync-from-" + pendingResyncMode
    confirmResync.opened = false
    Quickshell.execDetached([Quickshell.env("HOME") + "/.local/bin/backup_multiplo", argument])
    backupState = "running"
    refreshSoon.restart()
  }

  function openLogs() {
    Quickshell.execDetached(["xdg-open", Quickshell.env("HOME") + "/logs/backup"])
  }

  function activateSelected() {
    if (confirmResync.opened) {
      if (confirmResync.selectedIndex === 0) confirmResync.opened = false
      else confirmPendingResync()
      return
    }
    var action = actionItems[selectedAction] ? actionItems[selectedAction].action : "refresh"
    if (action === "refresh") refresh()
    else if (action === "run") runBackup()
    else if (action === "baseline") { baselineOptionsOpen = true; selectedAction = 0 }
    else if (action === "newer") requestResync("newer", "mais recente entre origem e destino")
    else if (action === "pc") requestResync("pc", "PC")
    else if (action === "remote") requestResync("remote", "destino")
    else if (action === "logs") openLogs()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Process {
    id: remoteProcess
    command: [Quickshell.env("HOME") + "/.local/bin/backup_multiplo", "syncs", "remotes", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const value = JSON.parse(text || "{}")
          root.remoteList = value.remotes || []
          root.remoteError = ""
          if (root.formRemote === "" && root.remoteList.length > 0) root.formRemote = String(root.remoteList[0].name)
        } catch (e) {
          root.remoteList = []
          root.remoteError = "Não foi possível ler os remotes configurados no rclone."
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.remoteError = String(text).trim()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.remoteError === "") root.remoteError = "rclone não conseguiu listar os remotes."
    }
  }

  Process {
    id: commandProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.commandOutput = String(text || "").trim()
        root.commandStdoutDone = true
        root.finishSyncCommand()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.commandError = String(text || "").trim()
        root.commandStderrDone = true
        root.finishSyncCommand()
      }
    }
    onExited: function(exitCode) {
      root.commandExitCode = exitCode
      root.finishSyncCommand()
    }
  }

  Process {
    id: statusProcess
    command: [Quickshell.env("HOME") + "/.local/bin/backup_multiplo", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const value = JSON.parse(text || "{}")
          const previousFailureCode = root.failureCode
          root.backupState = String(value.state || "never")
          root.failureCode = String(value.failureCode || "")
          root.ageSeconds = Number(value.ageSeconds || 0)
          root.lastRun = String(value.lastRun || "")
          root.failures = Number(value.failures || 0)
          root.jobsCount = Number(value.jobsCount || 0)
          root.favoritesState = String(value.favoritesState || "missing")
          root.favoritesAgeSeconds = Number(value.favoritesAgeSeconds || 0)
          root.configState = String(value.configState || "missing")
          root.omarchySnapshotsEnabled = !value.snapshotOptions || value.snapshotOptions.omarchy !== false
          root.favoritesSnapshotsEnabled = !value.snapshotOptions || value.snapshotOptions.favorites !== false
          root.timerState = String(value.timerState || "unknown")
          root.jobs = value.jobs || []
          root.syncs = value.syncs || []
          root.history = value.history || []
          if (root.failureCode === "resync-required" && previousFailureCode !== "resync-required") {
            root.baselineOptionsOpen = true
            root.selectedAction = 0
          }
          if (root.selectedAction >= root.actionItems.length) root.selectedAction = 0
        } catch (e) {
          root.backupState = "fail"
          root.failureCode = "status-unavailable"
        }
      }
    }
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: refreshSoon
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(root.syncFormOpen ? 680 : 700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.syncFormOpen && (syncNameField.activeFocus || syncSourceField.activeFocus || syncRemotePathField.activeFocus || syncExcludeArea.activeFocus || syncRemotePicker.popupOpen || syncModePicker.popupOpen)
      onMoveRequested: function(dx, dy) {
        if (confirmSync.opened) confirmSync.selectedIndex = confirmSync.selectedIndex === 0 ? 1 : 0
        else if (confirmResync.opened) confirmResync.selectedIndex = confirmResync.selectedIndex === 0 ? 1 : 0
        else root.selectedAction = Math.max(0, Math.min(root.actionItems.length - 1, root.selectedAction + (dy < 0 || dx < 0 ? -1 : 1)))
      }
      onActivateRequested: confirmSync.opened ? root.activateConfirmSync() : root.activateSelected()
      onCloseRequested: confirmSync.opened ? confirmSync.canceled() : confirmResync.opened ? confirmResync.canceled() : root.syncFormOpen ? root.closeSyncForm() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: root.syncFormOpen ? Style.space(5) : Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              text: root.stateIcon
              color: root.backupState === "ok" ? Color.accent : (root.backupState === "fail" || root.backupState === "warning" || root.backupState === "stale" ? Color.urgent : Color.foreground)
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }
            Column {
              width: parent.width - Style.space(42)
              anchors.verticalCenter: parent.verticalCenter
              Text { width: parent.width; text: "Backup Omarchy"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.title; elide: Text.ElideRight }
              Text { width: parent.width; text: root.stateLabel; color: root.backupState === "ok" ? Color.accent : (root.backupState === "fail" ? Color.urgent : Color.foreground); font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
            }
          }

          BorderSurface {
            id: summarySurface
            visible: !root.syncFormOpen
            width: parent.width
            padding: root.backupState === "ok" ? Style.space(6) : Style.space(10)
            height: summaryContent.implicitHeight + contentTopInset + contentBottomInset
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Column {
              id: summaryContent
              x: summarySurface.contentLeftInset
              y: summarySurface.contentTopInset
              width: summarySurface.width - summarySurface.contentLeftInset - summarySurface.contentRightInset
              spacing: Style.space(3)
              Text {
                visible: root.backupState !== "ok"
                width: parent.width
                text: root.diagnosis
                color: root.backupState === "fail" || root.backupState === "warning" ? Color.urgent : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Text {
                visible: root.lastRun !== ""
                text: "Última execução · " + root.ageText(root.ageSeconds) + " · " + root.lastRun
                color: Color.foreground
                opacity: 0.65
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          BorderSurface {
            id: localSnapshotSurface
            width: parent.width
            padding: root.syncFormOpen ? Style.space(5) : Style.space(8)
            height: localSnapshotContent.implicitHeight + contentTopInset + contentBottomInset
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Column {
              id: localSnapshotContent
              x: localSnapshotSurface.contentLeftInset
              y: localSnapshotSurface.contentTopInset
              width: localSnapshotSurface.width - localSnapshotSurface.contentLeftInset - localSnapshotSurface.contentRightInset
              spacing: root.syncFormOpen ? Style.space(2) : Style.space(4)
              Row {
                visible: !root.syncFormOpen
                width: parent.width
                spacing: Style.space(4)
                Text {
                  width: parent.width - snapshotTargetButton.width - Style.space(4)
                  text: "Backups locais"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
                BorderSurface {
                  id: snapshotTargetButton
                  width: Style.space(96)
                  height: Style.space(26)
                  color: Style.hoverFillFor(Color.foreground, Color.accent)
                  borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                  Text { anchors.centerIn: parent; text: root.snapshotFormOpen ? "Fechar" : "Configurar"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.snapshotFormOpen ? root.snapshotFormOpen = false : root.openSnapshotForm()
                  }
                }
              }
              Row {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: [
                    { id: "omarchy", label: "Omarchy", enabled: root.omarchySnapshotsEnabled },
                    { id: "favorites", label: "Favoritos", enabled: root.favoritesSnapshotsEnabled }
                  ]
                  delegate: BorderSurface {
                    required property var modelData
                    width: (parent.width - Style.space(6)) / 2
                    height: Style.space(28)
                    color: modelData.enabled ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
                    borderSpec: Border.controlSpec("normal", Color.foreground, modelData.enabled ? Color.accent : Color.popups.border)
                    Text {
                      width: parent.width - Style.space(10)
                      anchors.centerIn: parent
                      horizontalAlignment: Text.AlignHCenter
                      text: modelData.label + " · " + (modelData.enabled ? "Ativo" : "Pausado")
                      color: modelData.enabled ? Color.accent : Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                    MouseArea {
                      anchors.fill: parent
                      enabled: !commandProcess.running
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleSnapshotOption(modelData.id)
                    }
                  }
                }
              }
              Text {
                width: parent.width
                text: root.snapshotStatusSummary()
                color: Color.foreground
                opacity: 0.65
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              Text {
                visible: root.snapshotMessage !== ""
                width: parent.width
                text: root.snapshotMessage
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                text: root.snapshotTargetSummary()
                color: Color.foreground
                opacity: 0.7
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              Column {
                visible: root.snapshotFormOpen
                width: parent.width
                spacing: Style.space(4)
                SearchableDropdown {
                  width: parent.width
                  label: "Sync que enviará os snapshots"
                  placeholderText: "Selecione um sync"
                  emptyText: "Crie um sync primeiro"
                  options: root.snapshotSyncOptions
                  value: root.snapshotSyncId
                  rowHeight: Style.space(32)
                  onChanged: function(value) { root.snapshotSyncId = value }
                }
                TextField {
                  width: parent.width
                  text: root.snapshotPath
                  placeholderText: "Subpasta dentro da origem · ex.: Backups"
                  onTextChanged: root.snapshotPath = text
                }
                Text {
                  width: parent.width
                  text: root.snapshotPreview()
                  color: Color.foreground
                  opacity: 0.75
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.snapshotMessage !== ""
                  width: parent.width
                  text: root.snapshotMessage
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: ["Salvar destino", "Cancelar"]
                    delegate: BorderSurface {
                      required property string modelData
                      width: (parent.width - Style.space(6)) / 2
                      height: Style.space(28)
                      color: modelData === "Salvar destino" ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
                      borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                      Text { anchors.centerIn: parent; text: modelData; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: modelData === "Salvar destino" ? root.saveSnapshotTarget() : root.snapshotFormOpen = false
                      }
                    }
                  }
                }
              }
            }
          }

          BorderSurface {
            id: syncManagerSurface
            width: parent.width
            padding: root.syncFormOpen ? Style.space(6) : Style.space(10)
            height: syncManagerContent.implicitHeight + contentTopInset + contentBottomInset
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Column {
              id: syncManagerContent
              x: syncManagerSurface.contentLeftInset
              y: syncManagerSurface.contentTopInset
              width: syncManagerSurface.width - syncManagerSurface.contentLeftInset - syncManagerSurface.contentRightInset
              spacing: root.syncFormOpen ? Style.space(4) : Style.space(7)

              Row {
                id: syncManagerHeader
                width: parent.width
                spacing: Style.space(6)
                Text { id: syncManagerTitle; text: "Sincronizações"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
                Item { width: Math.max(0, syncManagerHeader.width - syncManagerTitle.implicitWidth - (root.syncFormOpen ? 0 : syncManagerAddButton.width) - Style.space(12)); height: 1 }
                BorderSurface {
                  id: syncManagerAddButton
                  visible: !root.syncFormOpen
                  width: Style.space(92)
                  height: Style.space(28)
                  color: Style.hoverFillFor(Color.foreground, Color.accent)
                  borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                  Text { width: parent.width - Style.space(8); anchors.centerIn: parent; horizontalAlignment: Text.AlignHCenter; text: "+ Novo sync"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.beginNewSync() }
                }
              }

              Text {
                visible: root.managerMessage !== ""
                width: parent.width
                text: root.managerMessage
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Column {
                visible: !root.syncFormOpen
                width: parent.width
                spacing: Style.space(5)
                Text {
                  visible: root.syncs.length === 0
                  text: "Nenhum sync configurado."
                  color: Color.foreground
                  opacity: 0.7
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Repeater {
                  model: root.syncManagerOpen ? root.syncs : root.syncs.slice(0, 1)
                  delegate: BorderSurface {
                    id: syncCard
                    required property var modelData
                    width: parent.width
                    padding: Style.space(8)
                    height: syncCardContent.implicitHeight + contentTopInset + contentBottomInset
                    color: Style.hoverFillFor(Color.foreground, Color.accent)
                    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
                    Column {
                      id: syncCardContent
                      x: syncCard.contentLeftInset
                      y: syncCard.contentTopInset
                      width: syncCard.width - syncCard.contentLeftInset - syncCard.contentRightInset
                      spacing: Style.space(4)
                      Row {
                        width: parent.width
                        Text {
                          width: parent.width - syncEnabledBadge.width - Style.space(5)
                          text: syncCard.modelData.name
                          color: Color.foreground
                          font.family: Style.font.family
                          font.pixelSize: Style.font.body
                          elide: Text.ElideRight
                        }
                        Text {
                          id: syncEnabledBadge
                          text: syncCard.modelData.enabled ? "Ativo" : "Pausado"
                          color: syncCard.modelData.enabled ? Color.accent : Color.foreground
                          opacity: syncCard.modelData.enabled ? 1 : 0.6
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }
                      Text {
                        width: parent.width
                        text: syncCard.modelData.source + "  →  " + syncCard.modelData.destination
                        color: Color.foreground
                        opacity: 0.7
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }
                      Text {
                        width: parent.width
                        text: (syncCard.modelData.mode === "bisync" ? "Bidirecional" : syncCard.modelData.mode === "sync" ? "Espelho" : "Cópia") +
                          "  ·  " + (syncCard.modelData.lastResult ? syncCard.modelData.lastResult.result : "Ainda não executado") +
                          (syncCard.modelData.mode === "bisync" && syncCard.modelData.baselineReady !== true ? "  ·  Baseline pendente" : "")
                        color: syncCard.modelData.lastResult && syncCard.modelData.lastResult.result !== "OK" ? Color.urgent : Color.foreground
                        opacity: 0.8
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                      Row {
                        width: parent.width
                        spacing: Style.space(4)
                        Repeater {
                          model: [
                            { label: "Editar", action: "edit" },
                            { label: syncCard.modelData.enabled ? "Pausar" : "Ativar", action: "toggle" },
                            { label: "Rodar", action: "run" },
                            { label: "Base", action: "resync" },
                            { label: "Remover", action: "remove" }
                          ]
                          delegate: BorderSurface {
                            required property var modelData
                            width: (parent.width - Style.space(16)) / 5
                            height: Style.space(28)
                            visible: modelData.action !== "resync" || syncCard.modelData.mode === "bisync"
                            opacity: modelData.action === "resync" && syncCard.modelData.mode !== "bisync" ? 0.3 : 1
                            color: "transparent"
                            borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                            Text { anchors.centerIn: parent; text: modelData.label; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                            MouseArea {
                              anchors.fill: parent
                              cursorShape: Qt.PointingHandCursor
                              enabled: modelData.action !== "resync" || syncCard.modelData.mode === "bisync"
                              onClicked: {
                                if (modelData.action === "edit") root.editSync(syncCard.modelData)
                                else if (modelData.action === "toggle") root.toggleSync(syncCard.modelData)
                                else if (modelData.action === "run") root.requestSyncRun(syncCard.modelData, false)
                                else if (modelData.action === "resync") root.requestSyncRun(syncCard.modelData, true)
                                else if (modelData.action === "remove") root.requestSyncRemoval(syncCard.modelData)
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
                Text {
                  visible: root.syncs.length > 1
                  width: parent.width
                  horizontalAlignment: Text.AlignRight
                  text: root.syncManagerOpen ? "Mostrar menos" : "Ver todos (" + root.syncs.length + ")"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.syncManagerOpen = !root.syncManagerOpen }
                }
              }

              Column {
                visible: root.syncFormOpen
                width: parent.width
                spacing: Style.space(4)
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    width: parent.width - closeSyncFormButton.width - Style.space(6)
                    text: root.editingSyncId ? "Editar sync" : "Novo sync"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  BorderSurface {
                    id: closeSyncFormButton
                    width: Style.space(66)
                    height: Style.space(28)
                    color: Style.hoverFillFor(Color.foreground, Color.accent)
                    borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                    Text { width: parent.width - Style.space(8); anchors.centerIn: parent; horizontalAlignment: Text.AlignHCenter; text: "Fechar"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.closeSyncForm() }
                  }
                }
                TextField {
                  id: syncNameField
                  width: parent.width
                  text: root.formName
                  placeholderText: "Nome do sync"
                  onTextChanged: root.formName = text
                  Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.closeSyncForm(); event.accepted = true } }
                }
                TextField {
                  id: syncSourceField
                  width: parent.width
                  text: root.formSource
                  placeholderText: "Origem local · ex.: ~/personal/Documentos"
                  onTextChanged: root.formSource = text
                  Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.closeSyncForm(); event.accepted = true } }
                }
                SearchableDropdown {
                  id: syncRemotePicker
                  width: parent.width
                  label: "Provider configurado no rclone"
                  placeholderText: "Buscar provider..."
                  emptyText: "Nenhum remote correspondente"
                  options: root.remoteOptions
                  value: root.formRemote
                  rowHeight: Style.space(32)
                  onChanged: function(value) { root.formRemote = value }
                }
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  TextField {
                    id: syncRemotePathField
                    width: parent.width - refreshRemotesButton.width - Style.space(6)
                    text: root.formRemotePath
                    placeholderText: "Pasta remota · ex.: arquivos/pessoal"
                    onTextChanged: root.formRemotePath = text
                    Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.closeSyncForm(); event.accepted = true } }
                  }
                  BorderSurface {
                    id: refreshRemotesButton
                    width: Style.space(34)
                    height: syncRemotePathField.height
                    color: Style.hoverFillFor(Color.foreground, Color.accent)
                    borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                    Text { anchors.centerIn: parent; text: "↻"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.body }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.refreshRemotes() }
                  }
                }
                SearchableDropdown {
                  id: syncModePicker
                  width: parent.width
                  label: "Modo"
                  options: root.modeOptions
                  value: root.formMode
                  rowHeight: Style.space(32)
                  onChanged: function(value) { root.formMode = value }
                }
                Text {
                  visible: root.formMode === "sync"
                  width: parent.width
                  text: "Espelho pode apagar arquivos extras do destino; os removidos serão arquivados."
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.formMode === "bisync"
                  width: parent.width
                  text: "Bidirecional propaga mudanças dos dois lados. O primeiro baseline será confirmado antes de executar."
                  color: Color.foreground
                  opacity: 0.75
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.remoteError !== ""
                  width: parent.width
                  text: root.remoteError
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.remoteList.length === 0 && root.remoteError === ""
                  width: parent.width
                  text: "Nenhum remote encontrado. Configure um no rclone e atualize a lista."
                  color: Color.foreground
                  opacity: 0.7
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  text: "Exclusões adicionais · um padrão por linha"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                BorderSurface {
                  width: parent.width
                  height: Style.space(48)
                  padding: Style.space(5)
                  color: Style.controlFill(syncExcludeArea.activeFocus, false, Color.foreground, Color.accent)
                  borderSpec: Border.controlSpec(syncExcludeArea.activeFocus ? "focus" : "normal", Color.foreground, Color.accent)
                  TextArea {
                    id: syncExcludeArea
                    anchors.fill: parent
                    text: root.formExcludes
                    placeholderText: "Ex.: cache/**"
                    wrapMode: TextEdit.NoWrap
                    color: Color.foreground
                    selectionColor: Style.selectionFillFor(Color.foreground, Color.accent)
                    selectedTextColor: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    background: Item {}
                    onTextChanged: root.formExcludes = text
                    Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) { root.closeSyncForm(); event.accepted = true } }
                  }
                }
                Text {
                  visible: root.formError !== ""
                  width: parent.width
                  text: root.formError
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: ["Salvar", "Remotes", "Cancelar"]
                    delegate: BorderSurface {
                      required property string modelData
                      required property int index
                      width: (parent.width - Style.space(12)) / 3
                      height: Style.space(32)
                      color: root.selectedAction === index ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
                      borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                      Text { width: parent.width - Style.space(10); anchors.centerIn: parent; horizontalAlignment: Text.AlignHCenter; text: modelData; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          if (modelData === "Salvar") root.saveSync()
                          else if (modelData === "Remotes") root.refreshRemotes()
                          else root.closeSyncForm()
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          BorderSurface {
            id: baselineSurface
            visible: !root.syncFormOpen
            width: parent.width
            padding: Style.space(10)
            height: baselineContent.implicitHeight + contentTopInset + contentBottomInset
            color: Style.hoverFillFor(Color.foreground, Color.accent)
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Column {
              id: baselineContent
              x: baselineSurface.contentLeftInset
              y: baselineSurface.contentTopInset
              width: baselineSurface.width - baselineSurface.contentLeftInset - baselineSurface.contentRightInset
              spacing: Style.space(7)
              Row {
                id: baselineHeader
                width: parent.width
                spacing: Style.space(6)
                Text { id: baselineIcon; text: "↻"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
                Text { id: baselineTitle; text: root.baselineOptionsOpen ? "Mudar baseline" : "Baseline"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
                Item { width: Math.max(0, baselineHeader.width - baselineIcon.implicitWidth - baselineTitle.implicitWidth - baselineDefault.implicitWidth - Style.space(18)); height: 1 }
                Text {
                  id: baselineDefault
                  text: root.baselineOptionsOpen ? "Fechar" : "Padrão: recente"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.baselineOptionsOpen = !root.baselineOptionsOpen; root.selectedAction = 0 }
                  }
                }
              }
              BorderSurface {
                visible: !root.baselineOptionsOpen
                width: parent.width
                height: Style.space(36)
                color: root.selectedAction === 0 ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
                borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                Text { anchors.centerIn: parent; text: "Mudar baseline · padrão: mais recente"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedAction = 0
                  onClicked: { root.selectedAction = 0; root.baselineOptionsOpen = true }
                }
              }
              BorderSurface {
                visible: root.baselineOptionsOpen
                width: parent.width
                height: Style.space(36)
                color: Color.accent
                borderSpec: Border.controlSpec("hover-cursor", Color.foreground, Color.accent)
                Text { anchors.centerIn: parent; text: "Usar versão mais recente"; color: Color.background; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedAction = 0
                  onClicked: { root.selectedAction = 0; root.activateSelected() }
                }
              }
              Row {
                visible: root.baselineOptionsOpen
                width: parent.width
                spacing: Style.space(7)
                Repeater {
                  model: [
                    { label: "PC vence", actionIndex: 1 },
                    { label: "Destino vence", actionIndex: 2 }
                  ]
                  delegate: BorderSurface {
                    required property var modelData
                    width: (parent.width - Style.space(7)) / 2
                    height: Style.space(32)
                    color: root.selectedAction === modelData.actionIndex ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
                    borderSpec: Border.controlSpec(root.selectedAction === modelData.actionIndex ? "hover-cursor" : "normal", Color.foreground, Color.accent)
                    Text { anchors.centerIn: parent; text: modelData.label; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onEntered: root.selectedAction = modelData.actionIndex
                      onClicked: { root.selectedAction = modelData.actionIndex; root.activateSelected() }
                    }
                  }
                }
              }
              Row {
                visible: root.baselineOptionsOpen
                width: parent.width
                spacing: Style.space(6)
                Text { text: "O resync pode propagar alterações entre os lados."; color: Color.foreground; opacity: 0.65; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
              }
            }
          }

          BorderSurface {
            id: activitySurface
            visible: !root.syncFormOpen
            width: parent.width
            padding: Style.space(10)
            height: activityContent.implicitHeight + contentTopInset + contentBottomInset
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
            Column {
              id: activityContent
              x: activitySurface.contentLeftInset
              y: activitySurface.contentTopInset
              width: activitySurface.width - activitySurface.contentLeftInset - activitySurface.contentRightInset
              spacing: Style.space(7)
              Row {
                id: activityHeader
                width: parent.width
                spacing: Style.space(8)
                Text {
                  id: activityTitle
                  text: (root.activityExpanded ? "⌄ " : "› ") + "Atividade · 7 dias"
                  width: Math.max(0, activityHeader.width - activitySummary.implicitWidth - Style.space(8))
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text { id: activitySummary; text: root.weeklySummary(); color: Color.foreground; opacity: 0.7; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.activityExpanded = !root.activityExpanded }
              }
              Row {
                visible: root.activityExpanded
                width: parent.width
                height: Style.space(44)
                spacing: Style.space(5)
                Repeater {
                  model: root.weeklyDays()
                  delegate: Item {
                    required property var modelData
                    width: (parent.width - Style.space(30)) / 7
                    height: parent.height
                    Rectangle {
                      width: Style.space(16)
                      height: modelData.count === 0 ? Style.space(4) : Math.min(Style.space(28), Style.space(6) + modelData.count * Style.space(6))
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: dayLabel.top
                      radius: Style.cornerRadius
                      color: modelData.failed > 0 ? Color.urgent : Color.accent
                      opacity: modelData.count === 0 ? 0.25 : 0.9
                    }
                    Text {
                      id: dayLabel
                      anchors.bottom: parent.bottom
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: modelData.label
                      color: Color.foreground
                      opacity: 0.65
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.activityExpanded && root.jobs.length > 0 && !root.syncFormOpen
            width: parent.width
            spacing: Style.space(3)
            Text { text: "Últimas tarefas"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body }
            Repeater {
              model: root.jobs.slice(0, 3)
              delegate: Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(6)
                Text { text: modelData.result === "OK" ? "✓" : "!"; color: modelData.result === "OK" ? Color.accent : Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                Text { text: String(modelData.destination || ""); color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight; width: parent.width - Style.space(100) }
                Text { text: root.formatDuration(Number(modelData.durationSeconds || 0)); color: Color.foreground; opacity: 0.65; font.family: Style.font.family; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignRight; width: Style.space(88) }
              }
            }
          }

          Row {
            visible: !root.syncFormOpen
            width: parent.width
            spacing: Style.space(7)
            Repeater {
              model: root.actionItems.slice(root.backupState === "never" || root.failureCode === "resync-required" ? 3 : 0)
              delegate: BorderSurface {
                required property var modelData
                required property int index
                readonly property int actionIndex: index + (root.backupState === "never" || root.failureCode === "resync-required" ? 3 : 0)
                width: (parent.width - Style.space(14)) / 3
                height: Style.space(34)
                color: root.selectedAction === actionIndex ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
                borderSpec: Border.controlSpec(root.selectedAction === actionIndex ? "hover-cursor" : "normal", Color.foreground, Color.accent)
                Text { anchors.centerIn: parent; text: modelData.label === "Executar backup" ? "Executar" : modelData.label === "Abrir logs" ? "Logs" : "Atualizar"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedAction = actionIndex
                  onClicked: { root.selectedAction = actionIndex; root.activateSelected() }
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmSync
        anchors.fill: parent
        cancelText: "Cancelar"
        confirmText: root.pendingSyncAction === "remove" ? "Remover configuração" : root.pendingSyncAction === "resync" ? "Criar baseline" : "Executar espelho"
        onCanceled: { opened = false; root.pendingSync = null; root.pendingSyncAction = "" }
        onConfirmed: root.confirmSyncAction()
      }

      ConfirmDialog {
        id: confirmResync
        anchors.fill: parent
        cancelText: "Cancelar"
        confirmText: "Recriar baseline"
        onCanceled: opened = false
        onConfirmed: root.confirmPendingResync()
      }
    }
  }
}
