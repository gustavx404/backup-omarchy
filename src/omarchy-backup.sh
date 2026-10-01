#!/usr/bin/env bash
#
# omarchy-backup.sh - backup do Omarchy via rclone.
#
# Antes de cada rodada, cria snapshots restauraveis das configuracoes seguras do
# Omarchy e somente dos favoritos dos navegadores. Perfis, cookies, logins,
# historico e sessoes nunca entram nos arquivos enviados.
#
# Uso:
#   omarchy-backup                   # roda todos os jobs
#   omarchy-backup status [--brief]  # estado da ultima rodada (offline)
#   omarchy-backup --dry-run         # simula, nao grava nada
#   omarchy-backup snapshot          # atualiza/testa configuracoes e favoritos
#   omarchy-backup verify --download # restaura amostra e compara todo o remoto
#   omarchy-backup --resync          # (re)cria o baseline do bisync; em
#                                          #   empate vence o arquivo mais NOVO
#   omarchy-backup --resync-from-pc      # em empate o PC vence
#   omarchy-backup --resync-from-remote  # em empate o destino vence
#
# Precisa de --resync: 1a vez, depois de formatar, ou depois de mexer no filtro.
#
# Depois de formatar a maquina:
#   1) instale o rclone pelo Omarchy e recrie o remote: rclone config
#   2) clone este projeto e restaure os arquivos pessoais pelo remote configurado
#      conforme necessario.
#   3) omarchy-backup --resync-from-remote
#   4) dai em diante e so omarchy-backup (ou o timer systemd)
#
set -euo pipefail
umask 077

# ------------------------------------------------------------------ config ---
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" &>/dev/null && pwd)"

PERSONAL_DIR="${BACKUP_PERSONAL_DIR:-$HOME/personal}"
FILEN_REMOTE="${BACKUP_FILEN_REMOTE:-Filen}"
CONFIG_ROOT="${BACKUP_CONFIG_ROOT:-$HOME/.config}"
CONFIG_BACKUP_DIR="${BACKUP_CONFIG_DEST:-$PERSONAL_DIR/Backups/Omarchy}"
CONFIG_EXCLUDES="${BACKUP_CONFIG_EXCLUDES:-$SCRIPT_DIR/config-excludes.txt}"
FAVORITES_BACKUP_DIR="${BACKUP_FAVORITES_DEST:-$PERSONAL_DIR/Backups/Favoritos}"

LOG_DIR="${BACKUP_LOG_DIR:-$HOME/logs/backup}"
LOCK_FILE="${BACKUP_LOCK:-$HOME/.cache/backup_multiplo.lock}"
STATE_DIR="${BACKUP_STATE_DIR:-$HOME/.cache/backup_multiplo}"
STATUS_FILE="$STATE_DIR/status.tsv"    # 1 linha por job da ultima rodada real
LASTRUN_FILE="$STATE_DIR/last-run"     # resumo geral da ultima rodada real
HISTORY_FILE="$STATE_DIR/history.tsv" # ultimas 100 execucoes para o painel
SYNC_CONFIG_FILE="${BACKUP_SYNC_CONFIG:-$HOME/.config/backup-multiplo/syncs.json}"
ARCHIVE_LOCAL="${BACKUP_ARCHIVE_LOCAL:-$HOME/.local/share/backup-multiplo/archive}"
ARCHIVE_REMOTE="${BACKUP_ARCHIVE_REMOTE:-$FILEN_REMOTE:backup/_archive-personal}"
CHECK_FILE=".backup_multiplo_ok"       # marcador do --check-access (bisync)
STALE_HOURS="${BACKUP_STALE_HOURS:-24}"  # acima disso o 'status' avisa "atrasado"
FAVORITES_STALE_HOURS="${BACKUP_FAVORITES_STALE_HOURS:-24}"
NOTIFY_FAILURE="${BACKUP_NOTIFY_FAILURE:-1}"

RCLONE_MAX_SECONDS="${RCLONE_MAX_SECONDS:-3600}"
RCLONE_TENTATIVAS="${RCLONE_TENTATIVAS:-4}"
RCLONE_BACKOFF="${RCLONE_BACKOFF:-20}"

# Lista positiva: apenas configuracoes portateis e sem dados de conta. Tudo que
# nao estiver aqui fica fora, inclusive rclone.conf, Discord e autenticacoes.
SAFE_CONFIG_PATHS=(
    omarchy hypr kitty alacritty foot ghostty waybar walker mako swaync
    fontconfig imv btop fastfetch nvim tmux starship.toml
    mimeapps.list user-dirs.dirs user-dirs.locale
    gtk-3.0/settings.ini gtk-4.0/settings.ini
    systemd/user/omarchy-backup.service systemd/user/omarchy-backup.timer
)

# Syncs sao migrados/carregados de SYNC_CONFIG_FILE. Este array so existe como
# fonte da migracao inicial, para preservar o comportamento instalado atual.
LEGACY_SOURCE="$PERSONAL_DIR"
LEGACY_DESTINATION="$FILEN_REMOTE:personal"
LEGACY_MODE="bisync"
JOB_IDS=() JOB_NAMES=() JOB_SOURCES=() JOB_DESTINATIONS=() JOB_MODES=() JOB_ENABLED=() JOB_EXCLUDES_JSON=()
MANUAL_JOB_ID="" MANUAL_RESYNC=0 RESYNC=0 RESYNC_MODE="newer" COMMAND="run" VERIFY_DOWNLOAD=0
SNAPSHOT_OMARCHY_ENABLED=true SNAPSHOT_FAVORITES_ENABLED=true

sync_config_validate_file() {
    jq -e '
        type == "object" and ((keys - ["version","jobs","snapshotTarget","snapshotOptions"]) | length == 0) and .version == 1 and (.jobs | type == "array" and length <= 64) and
        ((.snapshotTarget // null) == null or ((.snapshotTarget | type == "object") and ((.snapshotTarget | keys - ["syncId","path"]) | length == 0) and (.snapshotTarget.syncId | type == "string" and test("^[A-Za-z0-9_-]{1,48}$")) and (.snapshotTarget.path | type == "string" and length > 0 and length <= 240 and (test("^[A-Za-z0-9._/-]+$") and (startswith("/") | not) and (test("(^|/)\\.{1,2}(/|$)") | not) and (contains("//") | not))))) and
        ((.snapshotOptions // {}) as $options | (($options | keys - ["omarchy","favorites"]) | length == 0) and all(["omarchy","favorites"][]; . as $key | (if $options | has($key) then ($options[$key] | type == "boolean") else true end))) and
      ([.jobs[].id] | length == (unique | length)) and
      all(.jobs[];
        ((keys - ["id","name","source","destination","mode","enabled","exclude"]) | length == 0) and
        (.id | type == "string" and test("^[A-Za-z0-9_-]{1,48}$")) and
        (.name | type == "string" and length > 0 and length <= 80 and (gsub("^\\s+|\\s+$"; "") | length > 0) and (test("[\u0000-\u001f]") | not)) and
        (.source | type == "string" and startswith("/") and length > 1 and (test("[\u0000-\u001f]") | not)) and
        (.destination | type == "string" and length > 2 and (contains(":") and (split(":")[0] | length > 0)) and (test("[\u0000-\u001f]") | not)) and
        (.mode | (. == "bisync" or . == "sync" or . == "copy")) and
        (.enabled | type == "boolean") and
        (.exclude | type == "array" and length <= 64 and all(.[]; type == "string" and length > 0 and length <= 256 and (test("[\u0000-\u001f]") | not) and ((ltrimstr(" ") | (startswith("+") or startswith("!"))) | not)))
      )
    ' "$1" >/dev/null
}

sync_config_ensure() {
    local dir lock_fd tmp
    dir="$(dirname -- "$SYNC_CONFIG_FILE")"
    install -d -m 700 -- "$dir"
    exec {lock_fd}>"$SYNC_CONFIG_FILE.lock"
    flock -x "$lock_fd"
    [[ ! -L "$SYNC_CONFIG_FILE" ]] || { echo 'syncs: o arquivo de configuracao nao pode ser um link simbolico' >&2; exec {lock_fd}>&-; return 2; }
    if [[ -e "$SYNC_CONFIG_FILE" ]]; then
        if ! sync_config_validate_file "$SYNC_CONFIG_FILE"; then
            echo "syncs: configuracao invalida em $SYNC_CONFIG_FILE; nenhuma sincronizacao foi iniciada" >&2
            exec {lock_fd}>&-
            return 2
        fi
        if ! sync_config_destinations_validate "$SYNC_CONFIG_FILE"; then
            echo 'syncs: destinos sobrepostos na configuracao; nenhum sync foi iniciado' >&2
            exec {lock_fd}>&-
            return 2
        fi
        chmod 600 -- "$SYNC_CONFIG_FILE"
        exec {lock_fd}>&-
        return 0
    fi
    tmp="$(mktemp "$dir/.syncs.XXXXXX")"
    if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qxF "$FILEN_REMOTE:"; then
        if ! jq -n --arg id "personal-filen" --arg name "Pessoal · Filen" \
            --arg source "$LEGACY_SOURCE" --arg destination "$LEGACY_DESTINATION" \
            '{version:1,jobs:[{id:$id,name:$name,source:$source,destination:$destination,mode:"bisync",enabled:true,exclude:[]}]}' > "$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi
    else
        if ! jq -n '{version:1,jobs:[]}' > "$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi
    fi
    chmod 600 -- "$tmp"
    mv -- "$tmp" "$SYNC_CONFIG_FILE"
    exec {lock_fd}>&-
}

sync_config_list_json() {
    sync_config_ensure || return $?
    jq -c '.jobs' "$SYNC_CONFIG_FILE"
}

sync_remote_list_json() {
    local raw
    command -v rclone >/dev/null 2>&1 || { echo 'syncs: rclone nao esta instalado' >&2; return 3; }
    raw="$(rclone --ask-password=false listremotes --json 2>/dev/null)" || { echo 'syncs: nao foi possivel ler os remotes do rclone; confira a configuracao com rclone config' >&2; return 3; }
    jq -ce '[.[] | {name, type}] | sort_by(.name)' <<< "$raw"
}

sync_config_source_validate() {
    local source="$1" protected path
    [[ "$source" == "~" ]] && source="$HOME"
    [[ "$source" == "~/"* ]] && source="$HOME/${source#\~/}"
    [[ "$source" == /* && -d "$source" ]] || { echo 'syncs: origem precisa ser uma pasta absoluta existente' >&2; return 2; }
    source="$(realpath -e -- "$source")" || return 2
    [[ "$source" != / && "$source" != "$HOME" ]] || { echo 'syncs: nao use / ou sua pasta pessoal inteira como origem' >&2; return 2; }
    local -a protected_roots=(
        "$HOME/.config" "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws"
        "$HOME/.azure" "$HOME/.mozilla" "$HOME/.config/chromium"
        "$HOME/.config/google-chrome" "$HOME/.config/BraveSoftware"
        "$PERSONAL_DIR/Vault" "$PERSONAL_DIR/Firefox"
        "$PERSONAL_DIR/Backups/Chromium" "$PERSONAL_DIR/Backups/Firefox" "$ARCHIVE_LOCAL"
    )
    for protected in "${protected_roots[@]}"; do
        [[ -e "$protected" ]] || continue
        path="$(realpath -m -- "$protected")"
        [[ "$source" == "$path" || "$source" == "$path/"* || "$path" == "$source/"* ]] && {
            echo "syncs: pasta protegida nao pode ser origem: $path" >&2
            return 2
        }
    done
    printf '%s' "$source"
}

sync_config_item_validate() {
    local item="$1" id name source destination mode enabled remote remote_json path reserved
    id="$(jq -r '.id // empty' <<< "$item")"
    name="$(jq -r '.name // empty' <<< "$item")"
    source="$(jq -r '.source // empty' <<< "$item")"
    destination="$(jq -r '.destination // empty' <<< "$item")"
    mode="$(jq -r '.mode // empty' <<< "$item")"
    enabled="$(jq -r '.enabled // empty' <<< "$item")"
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || { echo 'syncs: id invalido' >&2; return 2; }
    [[ -n "$name" && ${#name} -le 80 && "$name" != *$'\n'* && "$name" != *$'\t'* ]] || { echo 'syncs: nome invalido' >&2; return 2; }
    source="$(sync_config_source_validate "$source")" || return $?
    [[ "$mode" == bisync || "$mode" == sync || "$mode" == copy ]] || { echo 'syncs: modo invalido' >&2; return 2; }
    [[ "$enabled" == true || "$enabled" == false ]] || { echo 'syncs: enabled precisa ser booleano' >&2; return 2; }
    [[ "$destination" == *:* ]] || { echo 'syncs: destino precisa ser remote:pasta' >&2; return 2; }
    remote="${destination%%:*}"; path="${destination#*:}"
    while [[ "$path" == */ ]]; do path="${path%/}"; done
    [[ -n "$remote" && -n "$path" && "$path" != /* && "/$path/" != *"/../"* && "/$path/" != *"/./"* ]] || { echo 'syncs: caminho remoto invalido' >&2; return 2; }
    for reserved in backup/_archive-personal backup/_archive-backup-multiplo; do
        if [[ "$path" == "$reserved" || "$path" == "$reserved/"* || "$reserved" == "$path/"* ]]; then
            echo 'syncs: destino sobrepoe uma pasta reservada para arquivo-morto' >&2
            return 2
        fi
    done
    [[ "$destination" != *$'\n'* && "$destination" != *$'\t'* ]] || { echo 'syncs: destino contem caractere de controle' >&2; return 2; }
    remote_json="$(sync_remote_list_json)" || return $?
    jq -e --arg remote "$remote" 'any(.[]; .name == $remote)' <<< "$remote_json" >/dev/null || { echo "syncs: remote nao configurado no rclone: $remote" >&2; return 2; }
    jq -e '(.exclude | type == "array" and length <= 64) and all(.exclude[]; type == "string" and length > 0 and length <= 256 and (test("[\\u0000-\\u001f]") | not) and ((ltrimstr(" ") | (startswith("+") or startswith("!"))) | not))' <<< "$item" >/dev/null || { echo 'syncs: exclusoes invalidas; use um padrao por linha, sem + ou !' >&2; return 2; }
}

sync_config_destinations_validate() {
    jq -e '
      [.jobs[].destination | split(":") as $d | {remote:$d[0],path:($d[1:] | join(":"))}] as $destinations |
      all(range(0; ($destinations|length)); . as $i |
        all(range(($i + 1); ($destinations|length)); . as $j |
          ($destinations[$i].remote != $destinations[$j].remote) or
          ((($destinations[$i].path | rtrimstr("/")) != ($destinations[$j].path | rtrimstr("/"))) and
           (($destinations[$i].path | rtrimstr("/")) | startswith(($destinations[$j].path | rtrimstr("/")) + "/") | not) and
           (($destinations[$j].path | rtrimstr("/")) | startswith(($destinations[$i].path | rtrimstr("/")) + "/") | not))
        )
      )
    ' "$1" >/dev/null
}

sync_config_write() {
    local json="$1" expected="$2" dir tmp lock_fd current
    dir="$(dirname -- "$SYNC_CONFIG_FILE")"
    install -d -m 700 -- "$dir"
    exec {lock_fd}>"$SYNC_CONFIG_FILE.lock"
    flock -x "$lock_fd"
    current="$(cat -- "$SYNC_CONFIG_FILE")"
    if [[ "$current" != "$expected" ]]; then
        echo 'syncs: configuracao mudou durante a edicao; atualize o painel e tente novamente' >&2
        exec {lock_fd}>&-
        return 75
    fi
    sync_config_validate_file <(printf '%s' "$json") || { echo 'syncs: configuracao rejeitada' >&2; exec {lock_fd}>&-; return 2; }
    sync_config_destinations_validate <(printf '%s' "$json") || { echo 'syncs: destinos sobrepostos entre jobs' >&2; exec {lock_fd}>&-; return 2; }
    tmp="$(mktemp "$dir/.syncs.XXXXXX")"
    jq -c . <<< "$json" > "$tmp"
    chmod 600 -- "$tmp"
    mv -f -- "$tmp" "$SYNC_CONFIG_FILE"
    exec {lock_fd}>&-
}

sync_config_upsert() {
    local item="$1" id source current updated
    sync_config_ensure || return $?
    jq -e 'type == "object" and (.exclude | type == "array")' <<< "$item" >/dev/null || { echo 'syncs: objeto de job invalido' >&2; return 2; }
    sync_config_item_validate "$item" || return $?
    id="$(jq -r '.id' <<< "$item")"
    source="$(sync_config_source_validate "$(jq -r '.source' <<< "$item")")" || return $?
    item="$(jq -c --arg source "$source" '.source = $source' <<< "$item")"
    current="$(cat -- "$SYNC_CONFIG_FILE")"
    updated="$(jq -c --arg id "$id" --argjson item "$item" '.jobs = ([.jobs[] | select(.id != $id)] + [$item])' <<< "$current")"
    sync_config_write "$updated" "$current"
}

sync_config_set_enabled() {
    local id="$1" enabled="$2" current updated
    [[ "$enabled" == 0 || "$enabled" == 1 ]] || { echo 'syncs: enabled deve ser 0 ou 1' >&2; return 2; }
    sync_config_ensure || return $?
    current="$(cat -- "$SYNC_CONFIG_FILE")"
    jq -e --arg id "$id" 'any(.jobs[]; .id == $id)' <<< "$current" >/dev/null || { echo 'syncs: job nao encontrado' >&2; return 2; }
    updated="$(jq -c --arg id "$id" --argjson enabled "$([[ "$enabled" == 1 ]] && echo true || echo false)" '.jobs |= map(if .id == $id then .enabled = $enabled else . end)' <<< "$current")"
    sync_config_write "$updated" "$current"
}

sync_config_remove() {
    local id="$1" current updated
    sync_config_ensure || return $?
    current="$(cat -- "$SYNC_CONFIG_FILE")"
    jq -e --arg id "$id" 'any(.jobs[]; .id == $id)' <<< "$current" >/dev/null || { echo 'syncs: job nao encontrado' >&2; return 2; }
    updated="$(jq -c --arg id "$id" '.jobs |= map(select(.id != $id)) | if .snapshotTarget.syncId == $id then .snapshotTarget = null else . end' <<< "$current")"
    sync_config_write "$updated" "$current"
}

sync_config_set_snapshot_target() {
    local id="$1" path="$2" current updated source resolved
    sync_config_ensure || return $?
    [[ "$path" =~ ^[A-Za-z0-9._/-]{1,240}$ && "$path" != /* && "$path" != *//* && ! "$path" =~ (^|/)\.\.?(/|$) ]] || {
        echo 'snapshots: informe uma subpasta relativa, sem segmentos . ou ..' >&2
        return 2
    }
    current="$(cat -- "$SYNC_CONFIG_FILE")"
    source="$(jq -r --arg id "$id" '.jobs[] | select(.id == $id) | .source' <<< "$current")"
    [[ -n "$source" ]] || {
        echo 'snapshots: selecione um sync existente' >&2
        return 2
    }
    source="$(sync_config_source_validate "$source")" || return $?
    resolved="$(realpath -m -- "$source/$path")" || return 2
    [[ "$resolved" == "$source/"* ]] || {
        echo 'snapshots: a pasta escolhida precisa permanecer dentro da origem do sync' >&2
        return 2
    }
    updated="$(jq -c --arg id "$id" --arg path "$path" '.snapshotTarget = {syncId:$id,path:$path}' <<< "$current")"
    sync_config_write "$updated" "$current"
}

snapshot_target_apply() {
    local target id path source resolved
    target="$(jq -c '.snapshotTarget // empty' "$SYNC_CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$target" ]] || return 0
    id="$(jq -r '.syncId' <<< "$target")"
    path="$(jq -r '.path' <<< "$target")"
    source="$(jq -r --arg id "$id" '.jobs[] | select(.id == $id) | .source' "$SYNC_CONFIG_FILE")"
    [[ -n "$source" ]] || { echo 'snapshots: sync de destino nao existe; configure o destino no painel' >&2; return 2; }
    source="$(sync_config_source_validate "$source")" || return $?
    resolved="$(realpath -m -- "$source/$path")" || return 2
    [[ "$resolved" == "$source/"* ]] || {
        echo 'snapshots: o destino configurado sai da origem do sync; ajuste-o no painel' >&2
        return 2
    }
    CONFIG_BACKUP_DIR="$resolved/Omarchy"
    FAVORITES_BACKUP_DIR="$resolved/Favoritos"
}

sync_config_set_snapshot_options() {
    local options="$1" current updated
    jq -e 'type == "object" and ((keys - ["omarchy","favorites"]) | length == 0) and (.omarchy | type == "boolean") and (.favorites | type == "boolean")' <<< "$options" >/dev/null || {
        echo 'snapshots: opções inválidas' >&2
        return 2
    }
    sync_config_ensure || return $?
    current="$(cat -- "$SYNC_CONFIG_FILE")"
    updated="$(jq -c --argjson options "$options" '.snapshotOptions = $options' <<< "$current")"
    sync_config_write "$updated" "$current"
}

snapshot_options_load() {
    local options
    options="$(jq -c '.snapshotOptions // {omarchy:true,favorites:true}' "$SYNC_CONFIG_FILE")"
    SNAPSHOT_OMARCHY_ENABLED="$(jq -r 'if has("omarchy") then .omarchy else true end' <<< "$options")"
    SNAPSHOT_FAVORITES_ENABLED="$(jq -r 'if has("favorites") then .favorites else true end' <<< "$options")"
}

load_sync_jobs() {
    local row
    sync_config_ensure || return $?
    JOB_IDS=() JOB_NAMES=() JOB_SOURCES=() JOB_DESTINATIONS=() JOB_MODES=() JOB_ENABLED=() JOB_EXCLUDES_JSON=()
    while IFS=$'\t' read -r id name source destination mode enabled excludes; do
        JOB_IDS+=("$id") JOB_NAMES+=("$name") JOB_SOURCES+=("$source") JOB_DESTINATIONS+=("$destination")
        JOB_MODES+=("$mode") JOB_ENABLED+=("$enabled") JOB_EXCLUDES_JSON+=("$excludes")
    done < <(jq -r '.jobs[] | [.id,.name,.source,.destination,.mode,(if .enabled then "1" else "0" end),(.exclude|tojson)] | @tsv' "$SYNC_CONFIG_FILE")
}

# Flags comuns a todos os modos.
COMMON_FLAGS=(
    --fast-list
    --transfers 4
    --checkers 8
    --retries 3
    --retries-sleep 30s
    --low-level-retries 10
    --timeout 300s
    --contimeout 120s
    --expect-continue-timeout 30s
    --modify-window 1s
    --log-level INFO
    --stats 1m
    --stats-one-line
)

# Flags so do bisync ("bisync seguro").
BISYNC_FLAGS=(
    --max-delete 50                       # aborta se >50 arquivos sumirem de um lado
    --check-access --check-filename "$CHECK_FILE"
    --conflict-resolve none               # conflito -> guarda as duas versoes
    --resilient --recover                 # tolera erro transiente sem exigir --resync
)

# ------------------------------------------------------------------ status ---
# "idade" legivel a partir de um epoch
_idade() {
    local s=$(( $(date +%s) - ${1:-0} ))
    (( s < 0 )) && s=0
    if   (( s < 3600 ));  then echo "há $(( s/60 ))min"
    elif (( s < 86400 )); then echo "há $(( s/3600 ))h"
    else                       echo "há $(( s/86400 ))d"
    fi
}

snapshot_info() {
    local current="$FAVORITES_BACKUP_DIR/favoritos-latest.tar.zst"
    FAVORITES_STATE="missing" FAVORITES_AGE=0 FAVORITES_CREATED="" FAVORITES_EPOCH=0
    CONFIG_STATE="missing"
    [[ "$SNAPSHOT_OMARCHY_ENABLED" == true ]] || CONFIG_STATE="disabled"
    [[ "$SNAPSHOT_OMARCHY_ENABLED" != true || ! -s "$CONFIG_BACKUP_DIR/config-latest.tar.zst" ]] || CONFIG_STATE="ok"
    [[ "$SNAPSHOT_FAVORITES_ENABLED" == true ]] || { FAVORITES_STATE="disabled"; return 0; }
    [[ -s "$current" ]] || return 0
    local epoch now
    epoch="$(stat -c %Y "$current" 2>/dev/null || echo 0)"
    FAVORITES_EPOCH="$epoch"
    now="$(date +%s)"
    FAVORITES_AGE=$(( now - epoch )); (( FAVORITES_AGE < 0 )) && FAVORITES_AGE=0
    FAVORITES_CREATED="$(date -d "@$epoch" '+%F %T' 2>/dev/null || true)"
    FAVORITES_STATE="ok"
    (( FAVORITES_AGE >= FAVORITES_STALE_HOURS * 3600 )) && FAVORITES_STATE="stale"
    return 0
}

emit_status_json() {
    local state="$1" age="$2" last_run="$3" failures="$4" jobs_count="$5"
    local favorites_state="$6" favorites_age="$7" config_state="$8" failure_code="$9"
    local jobs_json='[]' history_json='[]' timer_state="unknown"

    if [[ -s "$STATUS_FILE" ]]; then
        jobs_json="$(jq -Rn '[inputs | split("\t") | select(length >= 6 and (.[0] | test("^[0-9]+$"))) |
          if length >= 7 then {
            epoch:(.[0]|tonumber), time:.[1], id:.[2], destination:.[3], mode:.[4],
            result:.[5], durationSeconds:(.[6]|tonumber)
          }
          elif (.[4] == "bisync" or .[4] == "sync" or .[4] == "copy") then {
            epoch:(.[0]|tonumber), time:.[1], id:.[2], destination:.[3], mode:.[4],
            result:.[5], durationSeconds:null
          } elif (.[5] | test("^[0-9]+$")) then {
            epoch:(.[0]|tonumber), time:.[1], destination:.[2], mode:.[3],
            result:.[4], durationSeconds:(.[5]|tonumber)
          } else empty end]' < "$STATUS_FILE")"
    fi
    local syncs_json='[]' configured_syncs snapshot_target='null' snapshot_options='{"omarchy":true,"favorites":true}' baselines_json='[]' id source destination mode ready marker
    configured_syncs="$(jq -c '.jobs' "$SYNC_CONFIG_FILE" 2>/dev/null || echo '[]')"
    snapshot_target="$(jq -c '.snapshotTarget // null' "$SYNC_CONFIG_FILE" 2>/dev/null || echo 'null')"
    snapshot_options="$(jq -c '.snapshotOptions // {omarchy:true,favorites:true}' "$SYNC_CONFIG_FILE" 2>/dev/null || echo '{"omarchy":true,"favorites":true}')"
    while IFS=$'\t' read -r id source destination mode; do
        marker="$STATE_DIR/$(printf '%s' "$source|$destination" | md5sum | cut -c1-16).init"
        ready=false; [[ -f "$marker" ]] && ready=true
        baselines_json="$(jq -cn --argjson rows "$baselines_json" --arg id "$id" --argjson ready "$ready" '$rows + [{id:$id,ready:$ready}]')"
    done < <(jq -r '.[] | [.id,.source,.destination,.mode] | @tsv' <<< "$configured_syncs")
    syncs_json="$(jq -cn --argjson configured "$configured_syncs" --argjson results "$jobs_json" --argjson baselines "$baselines_json" --argjson target "$snapshot_target" '
      $configured | map(. as $job | . + {
        lastResult: ([$results[] | select(.id == $job.id or (.id == null and .destination == $job.destination))] | last // null),
        baselineReady: ([$baselines[] | select(.id == $job.id) | .ready] | last // ($job.mode != "bisync")),
        snapshotTarget: ($target != null and $target.syncId == $job.id),
        snapshotPath: (if $target != null and $target.syncId == $job.id then $target.path else null end)
      })
    ')"
    if [[ -s "$HISTORY_FILE" ]]; then
        history_json="$(jq -Rn '[inputs | split("\t") | select(length >= 6) | {
            epoch:(.[0]|tonumber), day:.[1], state:.[2], durationSeconds:(.[3]|tonumber),
            failures:(.[4]|tonumber), jobs:(.[5]|tonumber)
        }]' < "$HISTORY_FILE")"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        timer_state="$(systemctl --user is-active omarchy-backup.timer 2>/dev/null || true)"
        case "$timer_state" in
            active|inactive|failed|activating|deactivating|maintenance|reloading) ;;
            *) timer_state="unknown" ;;
        esac
    fi

    jq -cn \
        --arg state "$state" --arg lastRun "$last_run" \
        --arg favoritesState "$favorites_state" --arg configState "$config_state" \
        --arg failureCode "$failure_code" --arg timerState "$timer_state" \
        --argjson ageSeconds "$age" --argjson failures "$failures" \
        --argjson jobsCount "$jobs_count" --argjson favoritesAgeSeconds "$favorites_age" \
        --argjson jobs "$jobs_json" --argjson syncs "$syncs_json" --argjson history "$history_json" --argjson snapshotOptions "$snapshot_options" \
        '{state:$state,ageSeconds:$ageSeconds,lastRun:$lastRun,failures:$failures,
          jobsCount:$jobsCount,jobs:$jobs,syncs:$syncs,favoritesState:$favoritesState,
          favoritesAgeSeconds:$favoritesAgeSeconds,configState:$configState,
          failureCode:$failureCode,timerState:$timerState,history:$history,snapshotOptions:$snapshotOptions}'
}

record_history() {
    local state="$1" duration="$2" failures="$3" jobs="$4"
    local now day cutoff tmp
    now="$(date +%s)"; day="$(date '+%F')"; cutoff="$(date -d '30 days ago' +%s)"
    mkdir -p "$STATE_DIR"
    touch "$HISTORY_FILE"
    tmp="$(mktemp "$STATE_DIR/.history.XXXXXX")"
    awk -F '\t' -v cutoff="$cutoff" '$1 >= cutoff' "$HISTORY_FILE" | tail -n 99 > "$tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$day" "$state" "$duration" "$failures" "$jobs" >> "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$HISTORY_FILE"
}

# omarchy-backup status [--brief]
#   sem --brief: resumo completo da ultima rodada (offline, so le $STATE_DIR)
#   --brief    : 1 linha colorida p/ inicio de shell
cmd_status() {
    local brief=0 json=0
    [[ "${1:-}" == "--brief" || "${1:-}" == "-b" ]] && brief=1
    [[ "${1:-}" == "--json" ]] && json=1
    local c=1; [[ -t 1 ]] || c=0        # cor so em terminal
    local R='' G='' Y='' B='' N=''     # sem cor fora de tty (systemd, pipe, cron)
    if (( c )); then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[90m'; N=$'\e[0m'; fi

    if (( json )) && [[ -e "$LOCK_FILE" ]] && ! flock -n "$LOCK_FILE" -c true 2>/dev/null; then
        snapshot_info
        emit_status_json running 0 "" 0 0 "$FAVORITES_STATE" "$FAVORITES_AGE" "$CONFIG_STATE" ""
        return 0
    fi

    snapshot_info

    if [[ ! -s "$LASTRUN_FILE" ]]; then
        if (( json )); then
            emit_status_json never 0 "" 0 0 "$FAVORITES_STATE" "$FAVORITES_AGE" "$CONFIG_STATE" ""
            return 0
        fi
        if (( brief )); then echo "${Y}● backup: nunca rodou${N} ${B}— rode: omarchy-backup --resync${N}"
        else echo "omarchy-backup: nunca rodou. Rode: omarchy-backup --resync"; fi
        return 0
    fi

    local epoch iso overall nfail njobs failure_code
    IFS=$'\t' read -r epoch iso overall nfail njobs failure_code < "$LASTRUN_FILE"
    if [[ "$overall" == "fail" && -z "${failure_code:-}" && -s "$STATUS_FILE" ]]; then
        local failed_destination failed_id log_file
        IFS=$'\t' read -r failed_id failed_destination < <(awk -F '\t' 'NF >= 7 && $6 != "OK" {id=$3; destination=$4} NF < 7 && $5 != "OK" {destination=$3} END {print id "\t" destination}' "$STATUS_FILE")
        if [[ -n "$failed_id" ]]; then log_file="$LOG_DIR/${failed_id}_$(date -d "@$epoch" '+%F').log"
        else log_file="$LOG_DIR/${failed_destination%%:*}_$(date -d "@$epoch" '+%F').log"; fi
        if [[ -s "$log_file" ]] && awk -v since="$iso" '
            {
                stamp=""
                if ($0 ~ /^\[[0-9-]+ [0-9:]+\]/) stamp=substr($0, 2, 19)
                else if ($0 ~ /^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9:]+/) stamp=substr($0, 1, 19)
                gsub("/", "-", stamp)
                if (stamp >= since && /filters file (has changed|md5 hash not found)|must run --resync/) found=1
            }
            END { exit !found }
        ' "$log_file"; then
            failure_code="resync-required"
        fi
    fi
    [[ "$FAVORITES_STATE" == "ok" && "$FAVORITES_EPOCH" -gt "$epoch" ]] && FAVORITES_STATE="pending"
    local idade; idade="$(_idade "$epoch")"
    local age_seconds=$(( $(date +%s) - epoch )); (( age_seconds < 0 )) && age_seconds=0
    local horas=$(( ( $(date +%s) - epoch ) / 3600 ))
    local stale=0; (( horas >= STALE_HOURS )) && stale=1

    if (( json )); then
        local state="$overall"
        (( stale )) && [[ "$state" == "ok" ]] && state="stale"
        [[ "$state" == "ok" && ( ( "$FAVORITES_STATE" != "ok" && "$FAVORITES_STATE" != "disabled" ) || ( "$CONFIG_STATE" != "ok" && "$CONFIG_STATE" != "disabled" ) ) ]] && state="warning"
        if [[ -e "$LOCK_FILE" ]] && ! flock -n "$LOCK_FILE" -c true 2>/dev/null; then state="running"; fi
        emit_status_json "$state" "$age_seconds" "$iso" "$nfail" "$njobs" \
            "$FAVORITES_STATE" "$FAVORITES_AGE" "$CONFIG_STATE" "${failure_code:-}"
        return 0
    fi

    if (( brief )); then
        if [[ "$overall" == "ok" ]] && (( ! stale )); then
            echo "${G}● backup: ok${N} ${B}· $idade${N}"
        elif [[ "$overall" == "ok" ]] && (( stale )); then
            echo "${Y}● backup: ok mas $idade${N} ${B}· timer parado? systemctl --user status omarchy-backup.timer${N}"
        else
            echo "${R}● backup: FALHOU${N} ${B}· $idade · $nfail/$njobs job(s) · ~/logs/backup${N}"
        fi
        return 0
    fi

    # modo completo
    local head_c="$G"; [[ "$overall" != "ok" ]] && head_c="$R"
    (( stale )) && [[ "$overall" == "ok" ]] && head_c="$Y"
    echo "${head_c}omarchy-backup — ultima rodada $idade${N} (${iso})"
    (( stale )) && echo "${Y}  ! passou de ${STALE_HOURS}h desde a ultima rodada${N}"
    if [[ -f "$STATUS_FILE" ]]; then
        local jepoch jiso jid jdest jmode jres jdur mark
        while IFS=$'\t' read -r -a status_row; do
            (( ${#status_row[@]} >= 6 )) || continue
            if (( ${#status_row[@]} >= 7 )); then
                jepoch="${status_row[0]}"; jiso="${status_row[1]}"; jid="${status_row[2]}"
                jdest="${status_row[3]}"; jmode="${status_row[4]}"; jres="${status_row[5]}"; jdur="${status_row[6]}"
            elif [[ "${status_row[4]}" == "bisync" || "${status_row[4]}" == "sync" || "${status_row[4]}" == "copy" ]]; then
                jepoch="${status_row[0]}"; jiso="${status_row[1]}"; jid="${status_row[2]}"
                jdest="${status_row[3]}"; jmode="${status_row[4]}"; jres="${status_row[5]}"; jdur="?"
            else
                jepoch="${status_row[0]}"; jiso="${status_row[1]}"; jid=""
                jdest="${status_row[2]}"; jmode="${status_row[3]}"; jres="${status_row[4]}"; jdur="${status_row[5]}"
            fi
            if [[ "$jres" == "OK" ]]; then mark="${G}ok  ${N}"; else mark="${R}FALHOU${N}"; fi
            printf '  %b %-28s %-7s %5ss  %s\n' "$mark" "${jid:-$jdest}" "$jmode" "$jdur" "$(_idade "$jepoch")"
        done < "$STATUS_FILE"
    fi
    if [[ "$FAVORITES_STATE" == "ok" ]]; then
        echo "  favoritos: snapshot ok, $(_idade "$(( $(date +%s) - FAVORITES_AGE ))") ($FAVORITES_CREATED)"
    elif [[ "$FAVORITES_STATE" == "disabled" ]]; then
        echo "  favoritos: desativado"
    elif [[ "$FAVORITES_STATE" == "pending" ]]; then
        echo "  favoritos: snapshot local aguardando sincronizacao ($FAVORITES_CREATED)"
    elif [[ "$FAVORITES_STATE" == "stale" ]]; then
        echo "  favoritos: snapshot atrasado, $(_idade "$(( $(date +%s) - FAVORITES_AGE ))")"
    else
        echo "  favoritos: SEM SNAPSHOT"
    fi
    echo "  omarchy: $CONFIG_STATE"
    # estado do baseline bisync
    if compgen -G "$STATE_DIR/*.init" >/dev/null; then
        echo "${B}  baseline bisync: ok${N}"
    else
        echo "${Y}  baseline bisync: ausente — rode $0 --resync${N}"
    fi
    [[ "$overall" != "ok" ]] && echo "${B}  logs: $LOG_DIR${N}"
    return 0
}

syncs_command() {
    local action="${1:-}"
    shift || true
    case "$action" in
        list)
            [[ "${1:-}" == "--json" ]] || { echo 'uso: omarchy-backup syncs list --json' >&2; return 2; }
            sync_config_list_json
            ;;
        remotes)
            [[ "${1:-}" == "--json" ]] || { echo 'uso: omarchy-backup syncs remotes --json' >&2; return 2; }
            local remotes_json
            remotes_json="$(sync_remote_list_json)" || return $?
            jq -cn --argjson remotes "$remotes_json" '{remotes:$remotes}'
            ;;
        upsert)
            [[ "${1:-}" == "--json" && -n "${2:-}" ]] || { echo 'uso: omarchy-backup syncs upsert --json JOB' >&2; return 2; }
            sync_config_upsert "$2" && printf '{"ok":true}\n'
            ;;
        set-enabled)
            [[ -n "${1:-}" && -n "${2:-}" ]] || { echo 'uso: omarchy-backup syncs set-enabled ID 0|1' >&2; return 2; }
            sync_config_set_enabled "$1" "$2" && printf '{"ok":true}\n'
            ;;
        remove)
            [[ -n "${1:-}" ]] || { echo 'uso: omarchy-backup syncs remove ID' >&2; return 2; }
            sync_config_remove "$1" && printf '{"ok":true}\n'
            ;;
        snapshot-target)
            [[ "${1:-}" == "--json" && -n "${2:-}" ]] || { echo 'uso: omarchy-backup syncs snapshot-target --json {"syncId":"...","path":"..."}' >&2; return 2; }
            local target_id target_path
            target_id="$(jq -r '.syncId // empty' <<< "$2")"
            target_path="$(jq -r '.path // empty' <<< "$2")"
            sync_config_set_snapshot_target "$target_id" "$target_path" && printf '{"ok":true}\n'
            ;;
        snapshot-options)
            [[ "${1:-}" == "--json" && -n "${2:-}" ]] || { echo 'uso: omarchy-backup syncs snapshot-options --json {"omarchy":true,"favorites":true}' >&2; return 2; }
            sync_config_set_snapshot_options "$2" && printf '{"ok":true}\n'
            ;;
        *) echo 'uso: omarchy-backup syncs {list|remotes|upsert|set-enabled|remove|snapshot-target|snapshot-options|run}' >&2; return 2 ;;
    esac
}

if [[ "${1:-}" == "syncs" ]]; then
    shift
    if [[ "${1:-}" == "run" ]]; then
        shift
        MANUAL_JOB_ID="${1:-}"
        [[ "$MANUAL_JOB_ID" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || { echo 'syncs: id invalido' >&2; exit 2; }
        shift
        local_mode="newer" local_has_mode=0
        while (($#)); do
            case "$1" in
                --resync) RESYNC=1; MANUAL_RESYNC=1; shift ;;
                --mode)
                    [[ "${2:-}" == newer || "${2:-}" == path1 || "${2:-}" == path2 ]] || { echo 'syncs: --mode aceita newer, path1 ou path2' >&2; exit 2; }
                    local_mode="$2"; local_has_mode=1; shift 2 ;;
                *) echo "syncs: argumento invalido: $1" >&2; exit 2 ;;
            esac
        done
        (( local_has_mode == 0 || MANUAL_RESYNC == 1 )) || { echo 'syncs: --mode so pode ser usado com --resync' >&2; exit 2; }
        RESYNC_MODE="$local_mode"
        COMMAND="run"
    else
        syncs_command "$@"
        exit $?
    fi
fi

if [[ "${1:-}" == "status" ]]; then
    sync_config_ensure || exit $?
    snapshot_target_apply || exit $?
    snapshot_options_load
    shift; cmd_status "$@"; exit $?
fi

verify_config_archive() {
    local archive="$1" listing required entry item allowed ok
    [[ -s "$archive" ]] || return 1
    listing="$(tar --zstd -tf "$archive")" || return 1
    for required in config/omarchy config/hypr config/systemd; do
        grep -q "^${required}/" <<<"$listing" || {
            echo "omarchy: item obrigatorio ausente: $required" >&2
            return 1
        }
    done
    # Todo membro precisa pertencer a lista positiva, inclusive arquivos de uma
    # versao antiga do modulo que ainda estejam no disco.
    while IFS= read -r entry; do
        entry="${entry%/}"
        [[ "$entry" == config ]] && continue
        ok=0
        for item in "${SAFE_CONFIG_PATHS[@]}"; do
            allowed="config/$item"
            if [[ "$entry" == "$allowed" || "$entry" == "$allowed/"* \
               || "$allowed" == "$entry/"* ]]; then
                ok=1; break
            fi
        done
        (( ok )) || {
            echo "omarchy: item fora da lista segura: $entry" >&2
            return 1
        }
    done <<<"$listing"
}

snapshot_config() {
    [[ -d "$CONFIG_ROOT" ]] || { echo "omarchy: $CONFIG_ROOT nao existe" >&2; return 1; }
    [[ -f "$CONFIG_EXCLUDES" ]] || { echo "omarchy: filtro ausente: $CONFIG_EXCLUDES" >&2; return 1; }
    mkdir -p "$CONFIG_BACKUP_DIR"
    local current="$CONFIG_BACKUP_DIR/config-latest.tar.zst"
    local previous="$CONFIG_BACKUP_DIR/config-previous.tar.zst"
    local tmp="$CONFIG_BACKUP_DIR/.config-$(date +%s).partial.tar.zst"
    local stage
    stage="$(mktemp -d)"

    echo "omarchy: preparando somente configuracoes portateis da lista segura"
    mkdir -p "$stage/config"
    local item src dst
    for item in "${SAFE_CONFIG_PATHS[@]}"; do
        src="$CONFIG_ROOT/$item"
        [[ -e "$src" || -L "$src" ]] || continue
        dst="$stage/config/$item"
        mkdir -p "$(dirname -- "$dst")"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst"
            rsync -a --safe-links --exclude-from="$CONFIG_EXCLUDES" "$src/" "$dst/" || {
                rm -rf -- "$stage"; rm -f "$tmp"; return 1;
            }
        else
            rsync -a --safe-links "$src" "$dst" || {
                rm -rf -- "$stage"; rm -f "$tmp"; return 1;
            }
        fi
    done
    # Defesa adicional: um segredo escrito por engano numa configuracao segura
    # cancela a rodada antes que o arquivo seja empacotado ou enviado.
    local suspect
    suspect="$(grep -RIlEi \
        --exclude='*.py' --exclude='*.qml' --exclude='*.js' --exclude='*.ts' \
        --exclude='*.sh' --exclude='*.md' --exclude='*.css' \
        '(^|[^[:alnum:]_])(api[_-]?key|apikey|access[_-]?token|auth[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|secret([_-]?(key|access[_-]?key))?|password|passwd|private[_-]?key|credentials?|aws[_-]?secret[_-]?access[_-]?key)(["'"']?)[[:space:]]*[:=][[:space:]]*["'"']?[^[:space:]"'"']' \
        "$stage/config" 2>/dev/null || true)"
    if [[ -n "$suspect" ]]; then
        echo "omarchy: possivel segredo detectado; snapshot cancelado:" >&2
        sed "s|$stage/config/|  |" <<<"$suspect" >&2
        rm -rf -- "$stage"; rm -f "$tmp"
        return 1
    fi
    if ! tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        --zstd -cf "$tmp" -C "$stage" config; then
        rm -rf -- "$stage"; rm -f "$tmp"
        return 1
    fi
    rm -rf -- "$stage"
    verify_config_archive "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -s "$current" ]] && cmp -s "$tmp" "$current"; then
        rm -f "$tmp"
        echo "omarchy: configuracoes sem mudancas"
        return 0
    fi
    if [[ -f "$previous" ]] && ! verify_config_archive "$previous"; then
        rm -f "$previous"
    fi
    if [[ -f "$current" ]] && verify_config_archive "$current"; then
        mv -f "$current" "$previous"
    fi
    mv -f "$tmp" "$current"
    printf 'Criado em %s\nOrigem: %s\nFiltro: %s\n' \
        "$(date --iso-8601=seconds)" "$CONFIG_ROOT" "$CONFIG_EXCLUDES" \
        > "$CONFIG_BACKUP_DIR/LEIA-ME.txt"
    echo "omarchy: snapshot atualizado ($(du -h "$current" | cut -f1))"
}

# Exporta somente os registros que o usuario marcou como favoritos. Os arquivos
# de perfil originais nunca sao adicionados ao snapshot.
verify_favorites_archive() {
    local archive="$1" restore_dir json
    [[ -s "$archive" ]] || return 1
    restore_dir="$(mktemp -d)"
    if ! tar --zstd -xf "$archive" -C "$restore_dir"; then
        rm -rf -- "$restore_dir"
        return 1
    fi
    [[ -d "$restore_dir/favorites" ]] || { rm -rf -- "$restore_dir"; return 1; }
    if find "$restore_dir/favorites" -type f \
        \( -iname '*cookie*' -o -iname '*login*' -o -iname '*history*' \
           -o -iname '*session*' -o -iname '*password*' -o -name 'places.sqlite' \) \
        -print -quit | grep -q .; then
        echo "favoritos: conteudo proibido encontrado no snapshot" >&2
        rm -rf -- "$restore_dir"
        return 1
    fi
    while IFS= read -r -d '' json; do
        jq empty "$json" >/dev/null || { rm -rf -- "$restore_dir"; return 1; }
    done < <(find "$restore_dir/favorites" -type f -name '*.json' -print0)
    rm -rf -- "$restore_dir"
}

sanitize_favorites_json() {
    local file="$1" tmp="${1}.safe"
    jq '
      def safeurl:
        sub("^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/@]+@"; "\(.scheme)")
        | gsub("(?<sep>[?&#])(?<key>(?i:access_token|refresh_token|id_token|token|api[_-]?key|auth|signature|sig|password|passwd|client_secret|secret))=[^&#]*";
               "\(.sep)\(.key)=REDACTED");
      walk(if type == "object" and has("url") and (.url | type) == "string"
           then .url |= safeurl else . end)
    ' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

sanitize_favorites_url() {
    local url="$1"
    jq -nr --arg url "$url" '
      $url
      | sub("^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/@]+@"; "\\(.scheme)")
      | gsub("(?<sep>[?&#])(?<key>(?i:access_token|refresh_token|id_token|token|api[_-]?key|auth|signature|sig|password|passwd|client_secret|secret))=[^&#]*";
             "\\(.sep)\\(.key)=REDACTED")
    '
}

sanitize_gtk_bookmarks() {
    local source="$1" destination="$2" line uri label safe_uri
    : > "$destination"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || { printf '\n' >> "$destination"; continue; }
        uri="${line%%[[:space:]]*}"
        label="${line#"$uri"}"
        safe_uri="$(sanitize_favorites_url "$uri")" || return 1
        printf '%s%s\n' "$safe_uri" "$label" >> "$destination"
    done < "$source"
}

snapshot_favorites() {
    mkdir -p "$FAVORITES_BACKUP_DIR"
    local current="$FAVORITES_BACKUP_DIR/favoritos-latest.tar.zst"
    local previous="$FAVORITES_BACKUP_DIR/favoritos-previous.tar.zst"
    local tmp="$FAVORITES_BACKUP_DIR/.favoritos-$(date +%s).partial.tar.zst"
    local stage browser root bookmark profile safe_name out db query
    local exported=0 failed=0
    stage="$(mktemp -d)"
    mkdir -p "$stage/favorites"

    local -a chromium_browsers=(
        "chromium|$CONFIG_ROOT/chromium"
        "chrome|$CONFIG_ROOT/google-chrome"
        "chrome-beta|$CONFIG_ROOT/google-chrome-beta"
        "chrome-unstable|$CONFIG_ROOT/google-chrome-unstable"
        "brave|$CONFIG_ROOT/BraveSoftware/Brave-Browser"
        "brave-beta|$CONFIG_ROOT/BraveSoftware/Brave-Browser-Beta"
        "brave-nightly|$CONFIG_ROOT/BraveSoftware/Brave-Browser-Nightly"
        "vivaldi|$CONFIG_ROOT/vivaldi"
    )
    for browser in "${chromium_browsers[@]}"; do
        IFS='|' read -r browser root <<<"$browser"
        [[ -d "$root" ]] || continue
        local -a bookmark_files=()
        mapfile -d '' bookmark_files < <(find "$root" -mindepth 2 -maxdepth 2 \
            -type f -name Bookmarks -print0 2>/dev/null)
        for bookmark in "${bookmark_files[@]}"; do
            profile="$(basename -- "$(dirname -- "$bookmark")")"
            safe_name="${profile//[^a-zA-Z0-9._-]/_}"
            mkdir -p "$stage/favorites/$browser"
            out="$stage/favorites/$browser/$safe_name.json"
            if ! jq empty "$bookmark" >/dev/null; then
                rm -f "$out"
                echo "favoritos: JSON invalido em $browser/$profile" >&2
                failed=$(( failed + 1 ))
            elif ! jq -e '[.. | objects | select(.type? == "url")] | length > 0' \
                "$bookmark" >/dev/null; then
                rm -f "$out"
            elif jq '
                def clean:
                  if .type? == "url" then
                    {type:"url", name:(.name // ""), url:(.url // "")}
                  elif .type? == "folder" then
                    {type:"folder", name:(.name // ""),
                     children:[(.children // [])[] | clean]}
                  else empty end;
                {format:"browser-bookmarks-v1",
                 roots:(.roots | with_entries(.value |= clean))}
            ' "$bookmark" > "$out" && sanitize_favorites_json "$out"; then
                exported=$(( exported + 1 ))
            else
                rm -f "$out"
                echo "favoritos: JSON invalido em $browser/$profile" >&2
                failed=$(( failed + 1 ))
            fi
        done
    done

    # places.sqlite tambem contem historico. A consulta abaixo exporta apenas
    # moz_bookmarks e os URLs diretamente ligados a esses registros.
    query="SELECT b.id, b.parent, b.position, b.type, COALESCE(b.title, '') AS title, CASE WHEN b.type = 1 THEN p.url ELSE NULL END AS url FROM moz_bookmarks AS b LEFT JOIN moz_places AS p ON p.id = b.fk WHERE b.type IN (1,2,3) AND (b.type <> 1 OR p.url IS NOT NULL) ORDER BY b.parent, b.position;"
    local -a firefox_dbs=()
    mapfile -d '' firefox_dbs < <(find "$CONFIG_ROOT/mozilla/firefox" -mindepth 2 \
        -maxdepth 2 -type f -name places.sqlite -print0 2>/dev/null)
    for db in "${firefox_dbs[@]}"; do
        profile="$(basename -- "$(dirname -- "$db")")"
        safe_name="${profile//[^a-zA-Z0-9._-]/_}"
        mkdir -p "$stage/favorites/firefox"
        out="$stage/favorites/firefox/$safe_name.json"
        if sqlite3 -json "file:$db?immutable=1" "$query" \
                | jq '{format:"firefox-bookmarks-v1", items:.}' > "$out"; then
            if jq -e 'any(.items[]; .type == 1 and .url != null)' "$out" >/dev/null; then
                if sanitize_favorites_json "$out"; then
                    exported=$(( exported + 1 ))
                else
                    rm -f "$out"
                    echo "favoritos: nao foi possivel sanitizar Firefox/$profile" >&2
                    failed=$(( failed + 1 ))
                fi
            else
                rm -f "$out"
            fi
        else
            rm -f "$out"
            echo "favoritos: nao foi possivel exportar Firefox/$profile" >&2
            failed=$(( failed + 1 ))
        fi
    done

    if [[ -s "$CONFIG_ROOT/gtk-3.0/bookmarks" ]]; then
        mkdir -p "$stage/favorites/gtk"
        if sanitize_gtk_bookmarks "$CONFIG_ROOT/gtk-3.0/bookmarks" \
            "$stage/favorites/gtk/bookmarks.txt"; then
            exported=$(( exported + 1 ))
        else
            rm -rf -- "$stage"; rm -f "$tmp"
            echo "favoritos: nao foi possivel sanitizar os favoritos GTK" >&2
            return 1
        fi
    fi
    if (( failed > 0 )); then
        rm -rf -- "$stage"; rm -f "$tmp"
        echo "favoritos: exportacao incompleta; snapshot anterior preservado" >&2
        return 1
    fi
    if (( exported == 0 )); then
        rm -rf -- "$stage"; rm -f "$tmp"
        echo "favoritos: nenhum favorito atual; snapshot anterior preservado"
        return 0
    fi
    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        --zstd -cf "$tmp" -C "$stage" favorites
    rm -rf -- "$stage"
    verify_favorites_archive "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -s "$current" ]] && cmp -s "$tmp" "$current"; then
        rm -f "$tmp"
        echo "favoritos: sem mudancas"
        return 0
    fi
    [[ -f "$current" ]] && mv -f "$current" "$previous"
    mv -f "$tmp" "$current"
    printf 'Somente favoritos. Sem cookies, logins, historico ou sessoes.\nCriado em %s\n' \
        "$(date --iso-8601=seconds)" > "$FAVORITES_BACKUP_DIR/LEIA-ME.txt"
    echo "favoritos: snapshot atualizado ($(du -h "$current" | cut -f1))"
}

snapshot_all() {
    local result=0
    if [[ "$SNAPSHOT_OMARCHY_ENABLED" == true ]]; then snapshot_config || result=1; fi
    if [[ "$SNAPSHOT_FAVORITES_ENABLED" == true ]]; then snapshot_favorites || result=1; fi
    (( result == 0 ))
}

# ------------------------------------------------------------------ args -----
# RESYNC_MODE decide o VENCEDOR quando um arquivo existe nos dois lados e difere
# (arquivo que so existe de um lado e copiado pro outro de qualquer jeito):
#   newer  -> vence quem tem mtime mais recente  (padrao: nao perde edicao sua)
#   path1  -> o PC sempre vence
#   path2  -> o Filen sempre vence
DRY_RUN=(); VERIFY_DOWNLOAD=0
for a in "$@"; do
    case "$a" in
        --) ;;
        snapshot|snapshot-chromium) COMMAND="snapshot" ;;
        verify)                COMMAND="verify" ;;
        --download)            VERIFY_DOWNLOAD=1 ;;
        -n|--dry-run)          DRY_RUN=(--dry-run) ;;
        --resync)              RESYNC=1; RESYNC_MODE="newer" ;;
        --resync-from-pc)      RESYNC=1; RESYNC_MODE="path1" ;;
        --resync-from-filen|--resync-from-remote) RESYNC=1; RESYNC_MODE="path2" ;;
        -h|--help)             sed -n '3,48p' "$0"; exit 0 ;;
        *) echo "argumento desconhecido: $a" >&2; exit 2 ;;
    esac
done

RECORD=1
[[ -n "${DRY_RUN[*]}" || "$COMMAND" != "run" ]] && RECORD=0

sync_config_ensure || exit $?
load_sync_jobs || exit $?
MANUAL_INDEX=-1
if [[ -n "$MANUAL_JOB_ID" ]]; then
    for index in "${!JOB_IDS[@]}"; do [[ "${JOB_IDS[index]}" == "$MANUAL_JOB_ID" ]] && MANUAL_INDEX="$index"; done
    (( MANUAL_INDEX >= 0 )) || { echo 'syncs: job nao encontrado' >&2; exit 2; }
    (( JOB_ENABLED[MANUAL_INDEX] == 1 )) || { echo 'syncs: ative o job antes de executa-lo' >&2; exit 2; }
    if (( MANUAL_RESYNC == 1 )) && [[ "${JOB_MODES[MANUAL_INDEX]}" != bisync ]]; then
        echo 'syncs: baseline so existe para modo bidirecional' >&2
        exit 2
    fi
fi

# ------------------------------------------------------------ rclone nativo ---
strip() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

rclone_do() { command rclone "$@" </dev/null; }

# valida a stack de rclone ANTES de mexer em backup; fecha a porta (exit 3) em
# vez de rodar meio-configurado.
check_rclone_stack() {
    local active=0 j_enabled index
    for index in "${!JOB_IDS[@]}"; do
        [[ -z "$MANUAL_JOB_ID" || "$index" == "$MANUAL_INDEX" ]] || continue
        j_enabled="${JOB_ENABLED[index]}"
        (( j_enabled == 1 )) && active=$((active + 1))
    done
    (( active > 0 )) || return 0
    command -v rclone >/dev/null 2>&1 || {
        echo "ERRO: rclone nativo nao esta instalado. Rode: omarchy-pkg-add rclone" >&2
        exit 3
    }

    local have miss=() index remote
    have="$(sync_remote_list_json)" || exit 3
    for index in "${!JOB_IDS[@]}"; do
        [[ -z "$MANUAL_JOB_ID" || "$index" == "$MANUAL_INDEX" ]] || continue
        (( JOB_ENABLED[index] == 1 )) || continue
        remote="${JOB_DESTINATIONS[index]%%:*}"
        jq -e --arg remote "$remote" 'any(.[]; .name == $remote)' <<< "$have" >/dev/null || miss+=("$remote:")
    done
    if (( ${#miss[@]} )); then
        printf 'ERRO: remote(s) rclone nao configurado(s): %s\n' "${miss[*]}" >&2
        echo "  configure com: rclone config; depois atualize a lista no painel" >&2
        exit 3
    fi
}

notify_backup_failure() {
    local count="${1:-1}" total="${2:-1}"
    [[ "$NOTIFY_FAILURE" == "1" ]] || return 0
    command -v omarchy-notification-send >/dev/null 2>&1 || return 0
    omarchy-notification-send --app-name omarchy-backup -u critical -g $'\uf071' \
        "Falha no Omarchy Backup" \
        "$count de $total tarefa(s) falharam. Clique para diagnosticar." \
        --exec omarchy-agent --prompt \
        "Diagnostique a falha mais recente do Omarchy Backup. Consulte o estado com omarchy-backup status --json, os logs mais recentes em $LOG_DIR e o journal do serviço omarchy-backup.service. Leia o código em $SCRIPT_DIR para correlacionar o erro. Não mostre segredos nem logs completos. Não altere arquivos, não execute backup nem resync; apresente a causa provável, as evidências e a correção sugerida." \
        >/dev/null 2>&1 || true
}

RUN_COMPLETED=0 RUN_PHASE="pre-flight" RUN_FAILURE_CODE="preflight-failed"
RUN_START_EPOCH="$(date +%s)"
handle_unexpected_exit() {
    local ec="$1"
    (( ec != 0 && RECORD && ! RUN_COMPLETED )) || return 0
    mkdir -p "$STATE_DIR"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date +%s)" "$(date '+%F %T')" "sistema" "$RUN_PHASE" "FALHOU" "0" > "$STATUS_FILE"
    printf '%s\t%s\tfail\t1\t1\t%s\n' "$(date +%s)" "$(date '+%F %T')" "$RUN_FAILURE_CODE" > "$LASTRUN_FILE"
    record_history fail "$(( $(date +%s) - RUN_START_EPOCH ))" 1 1
    notify_backup_failure 1 1
}
trap 'handle_unexpected_exit $?' EXIT

# --------------------------------------------------------------- pre-flight ---
mkdir -p "$LOG_DIR" "$STATE_DIR" "$ARCHIVE_LOCAL" "$(dirname -- "$LOCK_FILE")"
unset RCLONE_VERBOSE RCLONE_LOG_LEVEL RCLONE_CONFIG_PASS 2>/dev/null || true

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date '+%F %T') outra execucao ja esta rodando (lock: $LOCK_FILE) - saindo." >&2
    exit 0
fi

if [[ "$COMMAND" == "snapshot" ]]; then
    sync_config_ensure || exit $?
    snapshot_target_apply || exit $?
    snapshot_options_load
    RUN_PHASE="configuracoes seguras e favoritos"
    snapshot_all
    RUN_COMPLETED=1
    exit 0
fi

check_rclone_stack
sync_config_ensure || exit $?
snapshot_target_apply || exit $?
snapshot_options_load
if [[ -n "$MANUAL_JOB_ID" ]] || printf '%s\n' "${JOB_ENABLED[@]}" | grep -qx '1'; then
    echo "rclone: nativo ($(command -v rclone))"
else
    echo "rclone: nenhum sync ativo"
fi

if [[ "$COMMAND" == "run" && -z "${DRY_RUN[*]}" ]]; then
    RUN_PHASE="configuracoes seguras e favoritos"
    snapshot_all || {
        echo "ERRO: um snapshot local falhou; backup remoto cancelado." >&2
        exit 5
    }
elif [[ "$COMMAND" == "run" ]]; then
    echo "snapshots: ignorados no modo dry-run"
fi

# --------------------------------------------------------------- runner ------
# roda um comando rclone com timeout + retry/backoff. $1 = log_file, resto = comando.
rodar_rclone() {
    local log_file="$1"; shift
    local inicio ec dur tentativa=1 espera="$RCLONE_BACKOFF" log_start=0
    while : ; do
        [[ -e "$log_file" ]] || : > "$log_file"
        log_start="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
        inicio=$SECONDS
        set +e
        timeout -k 60 -s INT "$RCLONE_MAX_SECONDS" \
            "$@" --log-file "$log_file" </dev/null
        ec=$?
        set -e
        dur=$(( SECONDS - inicio ))
        case "$ec" in
            0) return 0 ;;
            124|137)
                echo "[$(date '+%F %T')] TIMEOUT em ${RCLONE_MAX_SECONDS}s - INCOMPLETO" >>"$log_file"
                return "$ec" ;;
            *) echo "[$(date '+%F %T')] erro (codigo rclone: $ec, ${dur}s)" >>"$log_file" ;;
        esac
        if tail -n +"$(( log_start + 1 ))" "$log_file" 2>/dev/null \
            | grep -Eqi 'filters file (has changed|md5 hash not found)|must run --resync'; then
            RUN_FAILURE_CODE="resync-required"
            echo "[$(date '+%F %T')] filtro bisync alterado; escolha o lado vencedor antes do resync" >>"$log_file"
            return "$ec"
        fi
        (( tentativa >= RCLONE_TENTATIVAS )) && { echo "[$(date '+%F %T')] desisto apos $tentativa tentativas" >>"$log_file"; return "$ec"; }
        echo "[$(date '+%F %T')] nova tentativa em ${espera}s..." >>"$log_file"
        sleep "$espera"; tentativa=$(( tentativa + 1 )); espera=$(( espera * 2 ))
    done
}

verify_favorites_restore() {
    local archive="$FAVORITES_BACKUP_DIR/favoritos-latest.tar.zst"
    verify_favorites_archive "$archive" || return 1
    local restore_dir
    restore_dir="$(mktemp -d)"
    if ! tar --zstd -xf "$archive" -C "$restore_dir" favorites; then
        rm -rf -- "$restore_dir"
        return 1
    fi
    rm -rf -- "$restore_dir"
}

verify_other_snapshots() {
    local restore_dir
    verify_config_archive "$CONFIG_BACKUP_DIR/config-latest.tar.zst" || return 1
    restore_dir="$(mktemp -d)"
    if ! tar --zstd -xf "$CONFIG_BACKUP_DIR/config-latest.tar.zst" -C "$restore_dir" \
            config/omarchy config/hypr config/systemd; then
        rm -rf -- "$restore_dir"
        return 1
    fi
    rm -rf -- "$restore_dir"
}

verify_backup() {
    local log_file="$LOG_DIR/verificacao_$(date '+%Y-%m-%d_%H-%M-%S').log"
    local snapshots_checked=0 index id source destination excludes filter_path filter_tmp
    local combined failed=0 enabled=0 pattern
    local -a args=()
    if [[ "$SNAPSHOT_FAVORITES_ENABLED" == true ]]; then
        verify_favorites_restore || { echo "verificacao: snapshot de favoritos ausente ou invalido" >&2; return 1; }
        snapshots_checked=1
    fi
    if [[ "$SNAPSHOT_OMARCHY_ENABLED" == true ]]; then
        verify_other_snapshots || { echo "verificacao: snapshot Omarchy ausente ou invalido" >&2; return 1; }
        snapshots_checked=1
    fi
    if (( snapshots_checked )); then echo "verificacao: snapshots locais ativos estao integros"
    else echo "verificacao: snapshots locais desativados"; fi
    (( VERIFY_DOWNLOAD )) && echo "verificacao: comparando conteudo completo" \
        || echo "verificacao: comparando metadados"

    for index in "${!JOB_IDS[@]}"; do
        (( JOB_ENABLED[index] == 1 )) || continue
        enabled=$((enabled + 1))
        id="${JOB_IDS[index]}"; source="${JOB_SOURCES[index]}"
        destination="${JOB_DESTINATIONS[index]}"; excludes="${JOB_EXCLUDES_JSON[index]}"
        filter_path="$STATE_DIR/filters/$id.filters"
        install -d -m 700 -- "$(dirname -- "$filter_path")"
        filter_tmp="$(mktemp "$(dirname -- "$filter_path")/.${id}.XXXXXX")"
        cat -- "$SCRIPT_DIR/rclone-filter.txt" > "$filter_tmp" || {
            rm -f -- "$filter_tmp"; return 1;
        }
        while IFS= read -r pattern; do
            pattern="$(strip "$pattern")"
            [[ -n "$pattern" ]] && printf '\n- %s\n' "$pattern" >> "$filter_tmp"
        done < <(jq -r '.[]' <<< "$excludes")
        chmod 600 -- "$filter_tmp"
        mv -f -- "$filter_tmp" "$filter_path"
        combined="$STATE_DIR/verify-$id.txt"
        log_file="$LOG_DIR/verificacao_${id}_$(date '+%Y-%m-%d_%H-%M-%S').log"
        args=(rclone check "$source" "$destination"
            --filter-from "$filter_path" --checkers 8 --timeout 300s --contimeout 120s
            --combined "$combined")
        (( VERIFY_DOWNLOAD )) && args+=(--download)
        echo "verificacao: [$id] $source -> $destination"
        RCLONE_TENTATIVAS=1
        if ! rodar_rclone "$log_file" "${args[@]}"; then
            echo "verificacao: [$id] falhou; consulte $combined e $log_file" >&2
            failed=1
            continue
        fi
        if grep -Eq '^[+*?!-]' "$combined" 2>/dev/null; then
            echo "verificacao: [$id] relatorio contem diferencas: $combined" >&2
            failed=1
        else
            echo "verificacao: [$id] integro"
        fi
    done
    (( enabled > 0 )) || echo "verificacao: nenhum sync ativo configurado"
    (( failed == 0 )) || return 1
    echo "verificacao: jobs ativos e snapshots estao integros"
}

if [[ "$COMMAND" == "verify" ]]; then
    RUN_PHASE="verificacao"
    verify_backup
    RUN_COMPLETED=1
    exit 0
fi

fazer_backup() {
    local id="$1" origem="$2" destino="$3" modo="$4" excludes="$5"
    local log_file="$LOG_DIR/${id}_$(date '+%Y-%m-%d').log" filter_tmp filter_path filter_dir="$STATE_DIR/filters" rc pattern mark
    local remote="${destino%%:*}" archive_remote="$ARCHIVE_REMOTE" archive_local="$ARCHIVE_LOCAL"
    local -a args=()

    [[ -d "$origem" ]] || { echo "[$(date '+%F %T')] ERRO: origem nao existe: $origem" | tee -a "$log_file" >&2; return 2; }
    [[ -f "$SCRIPT_DIR/rclone-filter.txt" ]] || { echo "[$(date '+%F %T')] ERRO: filtro global ausente" | tee -a "$log_file" >&2; return 2; }
    install -d -m 700 -- "$filter_dir"
    filter_path="$filter_dir/$id.filters"
    filter_tmp="$(mktemp "$filter_dir/.${id}.XXXXXX")"
    cat -- "$SCRIPT_DIR/rclone-filter.txt" > "$filter_tmp" || { rm -f -- "$filter_tmp"; return 2; }
    while IFS= read -r pattern; do
        pattern="$(strip "$pattern")"
        [[ -n "$pattern" ]] && printf '\n- %s\n' "$pattern" >> "$filter_tmp"
    done < <(jq -r '.[]' <<< "$excludes")
    chmod 600 -- "$filter_tmp"
    mv -f -- "$filter_tmp" "$filter_path"
    if [[ "$id" != "personal-filen" ]]; then
        archive_local="$ARCHIVE_LOCAL/$id"
        archive_remote="$remote:backup/_archive-backup-multiplo/$id"
    fi
    mkdir -p -- "$archive_local"

    {
        echo "========================================"
        echo "[$(date '+%F %T')] JOB $id ($modo${DRY_RUN:+,dry-run})  $origem  ->  $destino"
    } >>"$log_file"

    case "$modo" in
        sync)
            args=(rclone sync "$origem" "$destino" "${COMMON_FLAGS[@]}"
                  --max-delete 50 --backup-dir "$archive_remote" --filter-from "$filter_path" "${DRY_RUN[@]}")
            rodar_rclone "$log_file" "${args[@]}"; rc=$?
            ;;
        copy)
            args=(rclone copy "$origem" "$destino" "${COMMON_FLAGS[@]}"
                  --filter-from "$filter_path" "${DRY_RUN[@]}")
            rodar_rclone "$log_file" "${args[@]}"; rc=$?
            ;;
        bisync)
            mark="$STATE_DIR/$(printf '%s' "$origem|$destino" | md5sum | cut -c1-16).init"
            args=(rclone bisync "$origem" "$destino" "${COMMON_FLAGS[@]}" "${BISYNC_FLAGS[@]}"
                  --backup-dir1 "$archive_local" --backup-dir2 "$archive_remote"
                  --filters-file "$filter_path" "${DRY_RUN[@]}")
            if (( RESYNC )); then
                echo "[$(date '+%F %T')] --resync (resync-mode $RESYNC_MODE)" >>"$log_file"
                if (( RECORD )); then
                    : > "$origem/$CHECK_FILE" 2>/dev/null || true
                    rclone_do touch "$destino/$CHECK_FILE" >>"$log_file" 2>&1 || true
                fi
                args+=(--resync --resync-mode "$RESYNC_MODE")
                rodar_rclone "$log_file" "${args[@]}"; rc=$?
                (( rc == 0 )) && touch "$mark"
            elif [[ ! -f "$mark" ]]; then
                echo "[$(date '+%F %T')] bisync ainda nao inicializado para este par; use o baseline pelo painel." >>"$log_file"
                rc=4
            else
                rodar_rclone "$log_file" "${args[@]}"; rc=$?
            fi
            ;;
        *) rc=2 ;;
    esac

    if (( rc == 0 )); then echo "[$(date '+%F %T')] OK  $destino" >>"$log_file"
    else echo "[$(date '+%F %T')] FALHOU  $destino (codigo $rc)" >>"$log_file"; fi
    echo "========================================" >>"$log_file"; echo "" >>"$log_file"
    return "$rc"
}

# --------------------------------------------------------------- main --------
echo "=== OMARCHY BACKUP ${DRY_RUN:+(DRY-RUN) }$( ((RESYNC)) && echo "(RESYNC $RESYNC_MODE) ")==="

# grava estado so em rodada real (nao em --dry-run/verify/snapshot)
(( RECORD )) && : > "$STATUS_FILE"

falhas=0; njobs=0
RUN_PHASE="sincronizacao rclone"
RUN_FAILURE_CODE="sync-failed"
for index in "${!JOB_IDS[@]}"; do
    (( JOB_ENABLED[index] == 1 )) || continue
    [[ -z "$MANUAL_JOB_ID" || "${JOB_IDS[index]}" == "$MANUAL_JOB_ID" ]] || continue
    j_id="${JOB_IDS[index]}"; j_name="${JOB_NAMES[index]}"; j_origem="${JOB_SOURCES[index]}"
    j_destino="${JOB_DESTINATIONS[index]}"; j_modo="${JOB_MODES[index]}"; j_excludes="${JOB_EXCLUDES_JSON[index]}"

    if (( RESYNC )) && [[ "$j_modo" != "bisync" ]]; then
        [[ -n "$MANUAL_JOB_ID" ]] && { echo "syncs: $j_id nao e bidirecional" >&2; exit 2; }
        echo "  -- pulando [$j_modo] $j_destino (--resync so vale p/ bisync)"
        continue
    fi

    echo "  -> [$j_modo] $j_name: $j_origem  =>  $j_destino"
    njobs=$(( njobs + 1 )); t0=$SECONDS
    if fazer_backup "$j_id" "$j_origem" "$j_destino" "$j_modo" "$j_excludes"; then
        res=OK; echo "     OK"
    else
        res=FALHOU; echo "     FALHOU (ver $LOG_DIR/${j_id}_$(date '+%Y-%m-%d').log)"
        falhas=$(( falhas + 1 ))
    fi
    (( RECORD )) && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date +%s)" "$(date '+%F %T')" "$j_id" "$j_destino" "$j_modo" "$res" "$(( SECONDS - t0 ))" >> "$STATUS_FILE"
done

if (( RECORD )); then
    local_state="$([[ $falhas -eq 0 ]] && echo ok || echo fail)"
    failure_code=""
    (( falhas == 0 )) || failure_code="$RUN_FAILURE_CODE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(date '+%F %T')" \
        "$local_state" "$falhas" "$njobs" "$failure_code" > "$LASTRUN_FILE"
    record_history "$local_state" "$(( $(date +%s) - RUN_START_EPOCH ))" "$falhas" "$njobs"
fi

if (( falhas > 0 )); then
    RUN_COMPLETED=1
    notify_backup_failure "$falhas" "$njobs"
    echo "=== TERMINOU COM $falhas FALHA(S) ==="
    exit 1
fi
RUN_COMPLETED=1
echo "=== TUDO OK ==="
