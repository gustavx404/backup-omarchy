#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/src/omarchy-backup.sh"
ORIGINAL_PATH="$PATH"
SANDBOX=""
TESTS=0

cleanup() {
    [[ -z "$SANDBOX" ]] || rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    TESTS=$((TESTS + 1))
    printf 'ok %d - %s\n' "$TESTS" "$1"
}

new_sandbox() {
    [[ -z "$SANDBOX" ]] || rm -rf -- "$SANDBOX"
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX/home"
    export BACKUP_CONFIG_ROOT="$HOME/.config"
    export BACKUP_PERSONAL_DIR="$HOME/personal"
    export BACKUP_CONFIG_DEST="$HOME/snapshots/omarchy"
    export BACKUP_FAVORITES_DEST="$HOME/snapshots/favorites"
    export BACKUP_LOG_DIR="$HOME/logs"
    export BACKUP_LOCK="$HOME/lock"
    export BACKUP_STATE_DIR="$HOME/state"
    export BACKUP_SYNC_CONFIG="$HOME/.config/backup-multiplo/syncs.json"
    export BACKUP_NOTIFY_FAILURE=0
    export BACKUP_TEST_RCLONE_LOG="$HOME/rclone-calls.log"
    export PATH="$SANDBOX/bin:$ORIGINAL_PATH"
    mkdir -p "$HOME" "$SANDBOX/bin" "$BACKUP_CONFIG_ROOT" "$BACKUP_PERSONAL_DIR" "$HOME/source"

    cat > "$SANDBOX/bin/rclone" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$BACKUP_TEST_RCLONE_LOG"
if [[ "${1:-}" == --ask-password=false ]]; then shift; fi
original=("$@")
while (($#)); do
    if [[ "$1" == --log-file ]]; then
        mkdir -p "$(dirname -- "$2")"
        : > "$2"
        break
    fi
    shift
done
set -- "${original[@]}"
case "${1:-}" in
    listremotes)
        if [[ " $* " == *" --json "* ]]; then
            printf '[{"name":"Mock","type":"local"}]\n'
        else
            printf 'Mock:\n'
        fi
        ;;
    check)
        combined=""
        while (($#)); do
            if [[ "$1" == --combined ]]; then
                combined="${2:?missing --combined path}"
                shift 2
            else
                shift
            fi
        done
        [[ -z "$combined" ]] || printf '= fixture\n' > "$combined"
        ;;
    copy|sync|bisync)
        ;;
    *)
        printf 'unexpected mocked rclone command: %s\n' "$*" >&2
        exit 90
        ;;
esac
MOCK
    chmod +x "$SANDBOX/bin/rclone"
}

write_config() {
    local mode="${1:-copy}" snapshot_options="${2:-}"
    [[ -n "$snapshot_options" ]] || snapshot_options='{"omarchy":false,"favorites":false}'
    mkdir -p "$(dirname -- "$BACKUP_SYNC_CONFIG")"
    jq -n --arg source "$HOME/source" --arg mode "$mode" \
        --argjson options "$snapshot_options" \
        '{version:1,jobs:[{id:"fixture-job",name:"Fixture",source:$source,
          destination:"Mock:target",mode:$mode,enabled:true,exclude:[]}],
          snapshotOptions:$options}' > "$BACKUP_SYNC_CONFIG"
    chmod 600 "$BACKUP_SYNC_CONFIG"
}

test_status_parser_keeps_configured_sync() {
    new_sandbox
    write_config
    mkdir -p "$BACKUP_STATE_DIR"
    printf '1700000000\t2023-11-14 22:13:20\tfixture-job\tMock:target\tcopy\tOK\t5\n' \
        > "$BACKUP_STATE_DIR/status.tsv"

    result="$("$SCRIPT" status --json)" || fail 'status --json failed'
    jq -e '.syncs[0].id == "fixture-job" and
        .syncs[0].lastResult.result == "OK" and
        .syncs[0].lastResult.durationSeconds == 5' <<< "$result" >/dev/null \
        || fail 'status JSON lost the sync or its latest result'
    pass 'status JSON retains configured syncs and recent results'
}

test_verify_checks_jobs_without_syncing() {
    new_sandbox
    write_config

    output="$("$SCRIPT" verify)" || fail 'verify failed with a mocked healthy remote'
    grep -q 'fixture-job.*integro' <<< "$output" || fail 'verify did not report the configured job'
    if grep -q 'No such file or directory' <<< "$output"; then
        fail 'verify emitted a missing-log warning on a clean run'
    fi
    grep -q '^check ' "$BACKUP_TEST_RCLONE_LOG" || fail 'verify did not use rclone check'
    if grep -Eq '^(sync|bisync|copy) ' "$BACKUP_TEST_RCLONE_LOG"; then
        fail 'verify invoked a write-capable rclone operation'
    fi
    pass 'verify checks configured jobs without starting a sync'
}

test_copy_does_not_receive_backup_dir() {
    new_sandbox
    write_config copy

    "$SCRIPT" syncs run fixture-job >/dev/null || fail 'mocked copy job failed'
    grep -q '^copy ' "$BACKUP_TEST_RCLONE_LOG" || fail 'copy mode was not invoked'
    if grep '^copy ' "$BACKUP_TEST_RCLONE_LOG" | grep -q -- '--backup-dir'; then
        fail 'copy mode received unsupported --backup-dir'
    fi
    pass 'copy mode omits the unsupported archive flag'
}

test_empty_favorites_preserve_previous_snapshot() {
    new_sandbox
    write_config copy '{"omarchy":false,"favorites":true}'
    mkdir -p "$BACKUP_FAVORITES_DEST"
    printf 'previous archive marker\n' > "$BACKUP_FAVORITES_DEST/favoritos-latest.tar.zst"

    "$SCRIPT" snapshot >/dev/null || fail 'snapshot failed when no browser favorites existed'
    grep -q '^previous archive marker$' "$BACKUP_FAVORITES_DEST/favoritos-latest.tar.zst" \
        || fail 'empty favorites replaced the previous snapshot'
    pass 'empty favorites preserve the previous snapshot without failing'
}

test_gtk_bookmarks_are_sanitized() {
    new_sandbox
    write_config copy '{"omarchy":false,"favorites":true}'
    mkdir -p "$BACKUP_CONFIG_ROOT/gtk-3.0"
    printf 'https://user:%s@example.test/path?access_%s=%s#token=%s Label\n' \
        'fixture' 'token' 'fixture' 'fixture' > "$BACKUP_CONFIG_ROOT/gtk-3.0/bookmarks"

    "$SCRIPT" snapshot >/dev/null || fail 'GTK favorites snapshot failed'
    mkdir -p "$SANDBOX/unpacked"
    tar --zstd -xf "$BACKUP_FAVORITES_DEST/favoritos-latest.tar.zst" \
        -C "$SANDBOX/unpacked"
    bookmark="$SANDBOX/unpacked/favorites/gtk/bookmarks.txt"
    grep -q 'REDACTED' "$bookmark" || fail 'sensitive GTK URL values were not redacted'
    if grep -Eq 'fixture|user:' "$bookmark"; then
        fail 'GTK snapshot retained URL credentials or token values'
    fi
    pass 'GTK bookmark snapshots redact URL credentials and tokens'
}

test_uppercase_secret_blocks_config_snapshot() {
    new_sandbox
    write_config copy '{"omarchy":true,"favorites":false}'
    mkdir -p "$BACKUP_CONFIG_ROOT/omarchy" "$BACKUP_CONFIG_ROOT/hypr" \
        "$BACKUP_CONFIG_ROOT/systemd/user"
    printf '[Unit]\n' > "$BACKUP_CONFIG_ROOT/systemd/user/omarchy-backup.service"
    printf '%s=%s\n' 'AWS_SECRET_ACCESS_KEY' 'fixture-only-value' \
        > "$BACKUP_CONFIG_ROOT/hypr/hyprland.conf"

    if "$SCRIPT" snapshot > "$SANDBOX/snapshot.log" 2>&1; then
        fail 'uppercase AWS secret field did not block the snapshot'
    fi
    grep -q 'possivel segredo detectado' "$SANDBOX/snapshot.log" || {
        cat "$SANDBOX/snapshot.log" >&2
        fail 'secret rejection did not explain why the snapshot stopped'
    }
    [[ ! -e "$BACKUP_CONFIG_DEST/config-latest.tar.zst" ]] \
        || fail 'secret-containing configuration archive was created'
    pass 'case-insensitive secret scanning blocks configuration snapshots'
}

test_plugin_source_fields_do_not_block_config_snapshot() {
    new_sandbox
    write_config copy '{"omarchy":true,"favorites":false}'
    mkdir -p "$BACKUP_CONFIG_ROOT/hypr" "$BACKUP_CONFIG_ROOT/systemd/user"
    printf '[Unit]\n' > "$BACKUP_CONFIG_ROOT/systemd/user/omarchy-backup.service"
    plugin="$BACKUP_CONFIG_ROOT/omarchy/plugins/yubikey"
    mkdir -p "$plugin/tests"
    cat > "$plugin/bridge.py" <<'PY'
def validate_password(raw_password: str) -> bool:
    password = ""
    return bool(raw_password)
PY
    cat > "$plugin/Panel.qml" <<'QML'
readonly property string password: String(passwords[keyId] || "")
QML
    cat > "$plugin/tests/test_bridge.py" <<'PY'
fixture = b'{"password":"","credential":"test"}'
PY

    "$SCRIPT" snapshot >/dev/null || fail 'source code mentioning credential fields blocked the snapshot'
    [[ -s "$BACKUP_CONFIG_DEST/config-latest.tar.zst" ]] \
        || fail 'safe configuration snapshot was not created'
    pass 'source code mentioning credential fields does not block snapshots'
}

test_snapshot_target_rejects_traversal() {
    new_sandbox
    write_config
    before="$(cat "$BACKUP_SYNC_CONFIG")"

    if "$SCRIPT" syncs snapshot-target --json '{"syncId":"fixture-job","path":"../outside"}' \
        >/dev/null 2>&1; then
        fail 'snapshot target accepted a parent-directory traversal'
    fi
    [[ "$(cat "$BACKUP_SYNC_CONFIG")" == "$before" ]] \
        || fail 'invalid snapshot target changed the sync configuration'
    pass 'snapshot target rejects path traversal without changing configuration'
}

test_sync_configuration_is_private() {
    new_sandbox
    write_config

    "$SCRIPT" syncs set-enabled fixture-job 0 >/dev/null || fail 'could not pause fixture job'
    mode="$(stat -c '%a' "$BACKUP_SYNC_CONFIG")"
    [[ "$mode" == 600 ]] || fail "sync configuration permissions are $mode instead of 600"
    jq -e '.jobs[0].enabled == false' "$BACKUP_SYNC_CONFIG" >/dev/null \
        || fail 'pausing a job did not update its enabled state'
    pass 'sync configuration writes stay private and preserve job edits'
}

test_status_parser_keeps_configured_sync
test_verify_checks_jobs_without_syncing
test_copy_does_not_receive_backup_dir
test_empty_favorites_preserve_previous_snapshot
test_gtk_bookmarks_are_sanitized
test_uppercase_secret_blocks_config_snapshot
test_plugin_source_fields_do_not_block_config_snapshot
test_snapshot_target_rejects_traversal
test_sync_configuration_is_private
printf 'All %d regression checks passed.\n' "$TESTS"
