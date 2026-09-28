#!/usr/bin/env bash
#
# install.sh - instala Omarchy Backup:
#   * painel do Omarchy: mostra estado, atividade e acoes sem terminal
#   * agendamento: systemd --user timer (padrao) ou crontab (--cron / fallback)
#   * comando  ~/.local/bin/omarchy-backup -> o backend
#
# Uso:
#   ./install.sh                 # widget Omarchy + service/timer (2h)
#   ./install.sh --cron          # usa crontab em vez do systemd
#   ./install.sh --shell-status  # opcional: tambem mostra status no terminal
#   ./install.sh --no-omarchy    # nao instala o widget da barra
#   ./install.sh --no-timer      # nao agenda nada
#   ./install.sh --uninstall     # desfaz tudo (nao apaga logs/estado)
#
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/src/omarchy-backup.sh"
BIN="$HOME/.local/bin/omarchy-backup"
FISH_CONF="$HOME/.config/fish/conf.d/omarchy-backup.fish"
PLUGIN_SRC="$DIR/omarchy-plugin"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/local.backup-status"
M_INI="# >>> omarchy-backup (nao editar a mao) >>>"
M_END="# <<< omarchy-backup <<<"

DO_SHELL=0 DO_OMARCHY=1 DO_TIMER=1 USE_CRON=0 UNINSTALL=0
for a in "$@"; do case "$a" in
    --shell-status) DO_SHELL=1 ;;
    --no-shell) DO_SHELL=0 ;;
    --no-omarchy) DO_OMARCHY=0 ;;
    --no-timer) DO_TIMER=0 ;;
    --cron)     USE_CRON=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "arg desconhecido: $a" >&2; exit 2 ;;
esac; done

[[ -f "$SCRIPT" ]] || { echo "nao achei $SCRIPT" >&2; exit 1; }
chmod +x "$SCRIPT"

# ---- helpers -------------------------------------------------------------
# remove o bloco entre os marcadores de um arquivo (se existir)
strip_block() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    [[ "$(grep -cF "$M_INI" "$f")" -gt 0 ]] || return 0
    local tmp; tmp="$(mktemp)"
    awk -v i="$M_INI" -v e="$M_END" '
        $0==i {skip=1} !skip {print} $0==e {skip=0}' "$f" > "$tmp"
    # tira linha em branco sobrando no fim
    sed -e :a -e '/^\n*$/{$d;N;ba}' "$tmp" > "$f"
    rm -f "$tmp"
}

add_block() {   # $1=arquivo  $2=conteudo do meio
    local f="$1" body="$2"
    mkdir -p "$(dirname "$f")"; touch "$f"
    strip_block "$f"
    { echo ""; echo "$M_INI"; printf '%s\n' "$body"; echo "$M_END"; } >> "$f"
}

have() { command -v "$1" >/dev/null 2>&1; }

unit_enabled() {
    systemctl --user is-enabled --quiet "$1" 2>/dev/null
}

unit_active() {
    systemctl --user is-active --quiet "$1" 2>/dev/null
}

install_plugin_transactionally() {
    local parent base staging backup had_previous=0
    parent="$(dirname "$PLUGIN_DEST")"
    base="$(basename "$PLUGIN_DEST")"
    mkdir -p "$parent"
    staging="$(mktemp -d "$parent/.${base}.staging.XXXXXX")"
    backup="$(mktemp -d "$parent/.${base}.backup.XXXXXX")"

    if ! cp -a "$PLUGIN_SRC/." "$staging/"; then
        rm -rf "$staging" "$backup"
        echo "omarchy: copia do painel falhou; instalacao atual preservada" >&2
        return 1
    fi
    if ! omarchy plugin validate "$staging"; then
        rm -rf "$staging" "$backup"
        echo "omarchy: validacao do painel falhou; instalacao atual preservada" >&2
        return 1
    fi

    if [[ -e "$PLUGIN_DEST" || -L "$PLUGIN_DEST" ]]; then
        mv -- "$PLUGIN_DEST" "$backup/original"
        had_previous=1
    fi

    if ! mv -- "$staging" "$PLUGIN_DEST"; then
        if (( had_previous )); then
            if ! mv -- "$backup/original" "$PLUGIN_DEST"; then
                echo "omarchy: troca falhou; instalacao anterior preservada em $backup/original" >&2
                rm -rf "$staging"
                return 1
            fi
        fi
        rm -rf "$staging" "$backup"
        echo "omarchy: troca do painel falhou; instalacao anterior restaurada" >&2
        return 1
    fi

    if ! omarchy plugin validate "$PLUGIN_DEST"; then
        rm -rf "$PLUGIN_DEST"
        if (( had_previous )) && ! mv -- "$backup/original" "$PLUGIN_DEST"; then
            echo "omarchy: validacao falhou; instalacao anterior preservada em $backup/original" >&2
            return 1
        fi
        rm -rf "$backup"
        echo "omarchy: validacao apos a troca falhou; instalacao anterior restaurada" >&2
        return 1
    fi

    rm -rf "$backup"
}

# ---- uninstall ---------------------------------------------------------
if (( UNINSTALL )); then
    echo "desinstalando..."
    rm -f "$FISH_CONF"
    rm -f "$HOME/.config/fish/conf.d/99-backup-multiplo.fish"
    strip_block "$HOME/.config/fish/config.fish"   # caso versao antiga tenha usado config.fish
    strip_block "$HOME/.bashrc"
    strip_block "$HOME/.zshrc"
    if have systemctl; then
        systemctl --user disable --now omarchy-backup.timer backup-multiplo.timer 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/omarchy-backup.service" \
              "$HOME/.config/systemd/user/omarchy-backup.timer" \
              "$HOME/.config/systemd/user/backup-multiplo.service" \
              "$HOME/.config/systemd/user/backup-multiplo.timer"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    if have crontab; then
        crontab -l 2>/dev/null | grep -vE 'omarchy-backup\.sh|backup_multiplo\.sh' | crontab - || true
    fi
    [[ -L "$BIN" ]] && rm -f "$BIN"
    [[ -L "$HOME/.local/bin/backup_multiplo" ]] && rm -f "$HOME/.local/bin/backup_multiplo"
    if have omarchy; then omarchy plugin disable local.backup-status 2>/dev/null || true; fi
    if [[ -d "$PLUGIN_DEST" ]]; then rm -rf "$PLUGIN_DEST"; fi
    echo "pronto. Logs/estado/arquivo-morto foram mantidos."
    exit 0
fi

# ---- dependencias e credenciais -------------------------------------------
for dep in bash flock timeout tar zstd pgrep md5sum jq readlink rsync sqlite3; do
    have "$dep" || { echo "dependencia ausente: $dep" >&2; exit 3; }
done

if ! have rclone; then
    if have omarchy; then
        echo "instalando dependencia: rclone"
        omarchy pkg add rclone
    else
        echo "rclone nao encontrado; instale-o antes de continuar" >&2
        exit 3
    fi
fi

# ---- Omarchy --------------------------------------------------------------
if (( DO_OMARCHY )) && have omarchy && [[ -d "$PLUGIN_SRC" ]]; then
    install_plugin_transactionally
    omarchy-shell shell rescanPlugins
    omarchy plugin enable local.backup-status --before omarchy.system-update
    echo "omarchy: painel local.backup-status instalado na barra"
fi

# ---- symlink no PATH -------------------------------------------------------
mkdir -p "$HOME/.local/bin"
[[ -L "$HOME/.local/bin/backup_multiplo" ]] && rm -f "$HOME/.local/bin/backup_multiplo"
ln -sfn "$SCRIPT" "$BIN"
echo "comando: $BIN -> $SCRIPT"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
    echo "  (obs: ~/.local/bin nao esta no PATH; adicione se quiser usar 'omarchy-backup' direto)" ;;
esac

# ---- hook no shell ------------------------------------------------------
if (( DO_SHELL )); then
    mkdir -p "$(dirname "$FISH_CONF")"
    cat > "$FISH_CONF" <<EOF
$M_INI
# fish sourceia este arquivo em toda sessao. Mostra o estado do ultimo backup.
if status is-interactive
    test -x '$SCRIPT'; and '$SCRIPT' status --brief 2>/dev/null
end
$M_END
EOF
    echo "fish:  $FISH_CONF"
    strip_block "$HOME/.config/fish/config.fish"   # limpa bloco de versao anterior

    if [[ -f "$HOME/.bashrc" ]]; then
        add_block "$HOME/.bashrc" \
"case \$- in *i*) [ -x '$SCRIPT' ] && '$SCRIPT' status --brief 2>/dev/null ;; esac"
        echo "bash:  hook adicionado em ~/.bashrc"
    fi
    if [[ -f "$HOME/.zshrc" ]]; then
        add_block "$HOME/.zshrc" \
"[[ -o interactive && -x '$SCRIPT' ]] && '$SCRIPT' status --brief 2>/dev/null"
        echo "zsh:   hook adicionado em ~/.zshrc"
    fi
fi

# ---- servico e agendamento -------------------------------------------------
SYSTEMD_USER=0
if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    SYSTEMD_USER=1
fi

if (( ! USE_CRON && SYSTEMD_USER )); then
    UNIT_DIR="$HOME/.config/systemd/user"
    LEGACY_ENABLED=0 LEGACY_ACTIVE=0 NEW_ENABLED=0 NEW_ACTIVE=0
    unit_enabled backup-multiplo.timer && LEGACY_ENABLED=1 || true
    unit_active backup-multiplo.timer && LEGACY_ACTIVE=1 || true
    unit_enabled omarchy-backup.timer && NEW_ENABLED=1 || true
    unit_active omarchy-backup.timer && NEW_ACTIVE=1 || true

    mkdir -p "$UNIT_DIR"
    cp "$DIR/systemd/omarchy-backup.service" "$UNIT_DIR/"
    if (( DO_TIMER || ! NEW_ACTIVE )); then
        cp "$DIR/systemd/omarchy-backup.timer" "$UNIT_DIR/"
    fi
    systemctl --user daemon-reload
    if (( DO_TIMER )); then
        if (( LEGACY_ENABLED || LEGACY_ACTIVE )); then
            (( LEGACY_ENABLED )) && systemctl --user enable omarchy-backup.timer
            (( LEGACY_ACTIVE )) && systemctl --user start omarchy-backup.timer
            systemctl --user disable --now backup-multiplo.timer 2>/dev/null || true
            rm -f "$UNIT_DIR/backup-multiplo.service" "$UNIT_DIR/backup-multiplo.timer"
            systemctl --user daemon-reload
        elif (( NEW_ENABLED || NEW_ACTIVE )); then
            (( NEW_ENABLED )) || systemctl --user disable omarchy-backup.timer
            (( NEW_ACTIVE )) || systemctl --user stop omarchy-backup.timer
        else
            systemctl --user enable --now omarchy-backup.timer
        fi
        rm -f "$UNIT_DIR/backup-multiplo.service" "$UNIT_DIR/backup-multiplo.timer"
        systemctl --user daemon-reload
        loginctl enable-linger "$USER" 2>/dev/null || true
        echo "systemd: timer omarchy-backup.timer ativo (a cada 2h)"
        systemctl --user list-timers omarchy-backup.timer --no-pager | sed -n '1,2p' || true
    else
        if (( LEGACY_ENABLED || LEGACY_ACTIVE )); then
            (( LEGACY_ENABLED )) && systemctl --user enable omarchy-backup.timer
            (( LEGACY_ACTIVE )) && systemctl --user start omarchy-backup.timer
            systemctl --user disable --now backup-multiplo.timer 2>/dev/null || true
            rm -f "$UNIT_DIR/backup-multiplo.service" "$UNIT_DIR/backup-multiplo.timer"
            systemctl --user daemon-reload
            echo "systemd: timer legado migrado; estado preservado sem iniciar o servico"
        fi
        echo "systemd: unidades instaladas; agendamento preservado (--no-timer)"
    fi
elif (( DO_TIMER )) && have crontab; then
        CRON_TMP="$(mktemp)"
        crontab -l 2>/dev/null | grep -vE 'omarchy-backup\.sh|backup_multiplo\.sh' > "$CRON_TMP" || true
        echo "0 */2 * * * $SCRIPT >/dev/null 2>&1   # omarchy-backup" >> "$CRON_TMP"
        crontab "$CRON_TMP"
        rm -f "$CRON_TMP"
        if (( USE_CRON && SYSTEMD_USER )); then
            systemctl --user disable --now omarchy-backup.timer backup-multiplo.timer 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/omarchy-backup.service" \
                  "$HOME/.config/systemd/user/omarchy-backup.timer" \
                  "$HOME/.config/systemd/user/backup-multiplo.service" \
                  "$HOME/.config/systemd/user/backup-multiplo.timer"
            systemctl --user daemon-reload
        fi
        echo "cron:  '0 */2 * * *  $SCRIPT'  adicionado ao crontab"
elif (( DO_TIMER )); then
        echo "!! nem systemd --user nem crontab disponiveis - agende manualmente." >&2
fi

# ---- estado atual ---------------------------------------------------------
echo
"$SCRIPT" status || true
if ! compgen -G "$HOME/.cache/backup_multiplo/"'*.init' >/dev/null 2>&1; then
    echo
    echo ">> baseline do bisync ainda nao existe. Rode UMA vez:"
    echo "     $SCRIPT --resync"
fi
