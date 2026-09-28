#!/usr/bin/env bash
#
# install.sh - liga o backup_multiplo no sistema:
#   * painel do Omarchy: mostra estado, atividade e acoes sem terminal
#   * agendamento: systemd --user timer (padrao) ou crontab (--cron / fallback)
#   * symlink  ~/.local/bin/backup_multiplo  -> o script
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
SCRIPT="$DIR/backup_multiplo.sh"
BIN="$HOME/.local/bin/backup_multiplo"
FISH_CONF="$HOME/.config/fish/conf.d/99-backup-multiplo.fish"
PLUGIN_SRC="$DIR/omarchy-plugin"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/local.backup-status"
M_INI="# >>> backup_multiplo (nao editar a mao) >>>"
M_END="# <<< backup_multiplo <<<"

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

# ---- uninstall ---------------------------------------------------------
if (( UNINSTALL )); then
    echo "desinstalando..."
    rm -f "$FISH_CONF"
    strip_block "$HOME/.config/fish/config.fish"   # caso versao antiga tenha usado config.fish
    strip_block "$HOME/.bashrc"
    strip_block "$HOME/.zshrc"
    if have systemctl; then
        systemctl --user disable --now backup-multiplo.timer 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/backup-multiplo.service" \
              "$HOME/.config/systemd/user/backup-multiplo.timer"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    if have crontab; then
        crontab -l 2>/dev/null | grep -vF "backup_multiplo.sh" | crontab - || true
    fi
    [[ -L "$BIN" ]] && rm -f "$BIN"
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
    mkdir -p "$(dirname "$PLUGIN_DEST")"
    rm -rf "$PLUGIN_DEST"
    cp -a "$PLUGIN_SRC" "$PLUGIN_DEST"
    omarchy plugin validate "$PLUGIN_DEST"
    omarchy-shell shell rescanPlugins
    omarchy plugin enable local.backup-status --before omarchy.system-update
    echo "omarchy: painel local.backup-status instalado na barra"
fi

# ---- symlink no PATH -------------------------------------------------------
mkdir -p "$HOME/.local/bin"
ln -sfn "$SCRIPT" "$BIN"
echo "symlink:  $BIN -> $SCRIPT"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
    echo "  (obs: ~/.local/bin nao esta no PATH; adicione se quiser usar 'backup_multiplo' direto)" ;;
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
if (( ! USE_CRON )) && have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
        mkdir -p "$HOME/.config/systemd/user"
        sed "s|^ExecStart=.*|ExecStart=$SCRIPT|" \
            "$DIR/systemd/backup-multiplo.service" > "$HOME/.config/systemd/user/backup-multiplo.service"
        cp "$DIR/systemd/backup-multiplo.timer" "$HOME/.config/systemd/user/"
        systemctl --user daemon-reload
    if (( DO_TIMER )); then
        systemctl --user enable --now backup-multiplo.timer
        loginctl enable-linger "$USER" 2>/dev/null || true
        echo "systemd: timer backup-multiplo.timer ativo (a cada 2h)"
        systemctl --user list-timers backup-multiplo.timer --no-pager | sed -n '1,2p' || true
    else
        echo "systemd: servico instalado; timer nao alterado (--no-timer)"
    fi
elif (( DO_TIMER )) && have crontab; then
        ( crontab -l 2>/dev/null | grep -vF "backup_multiplo.sh"
          echo "0 */2 * * * $SCRIPT >/dev/null 2>&1   # backup_multiplo" ) | crontab -
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
