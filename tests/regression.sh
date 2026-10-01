#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/src/omarchy-backup"
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
    export BACKUP_TEST_RCLONE_ARGS_LOG="$HOME/rclone-args.log"
    export RCLONE_BACKOFF=0
    export RCLONE_TENTATIVAS=1
    export PATH="$SANDBOX/bin:$ORIGINAL_PATH"
    mkdir -p "$HOME" "$SANDBOX/bin" "$BACKUP_CONFIG_ROOT" "$BACKUP_PERSONAL_DIR" "$HOME/source"

    cat > "$SANDBOX/bin/rclone" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$BACKUP_TEST_RCLONE_LOG"
    printf '<%q> ' "$@" >> "$BACKUP_TEST_RCLONE_ARGS_LOG"
    printf '\n' >> "$BACKUP_TEST_RCLONE_ARGS_LOG"
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
            printf '[{"name":"Mock","type":"local","description":"private fixture","token":"must-not-leak"}]\n'
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
    copy|sync|bisync|touch)
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

test_status_orders_pending_and_stale_states_consistently() {
    new_sandbox
    write_config copy '{"omarchy":false,"favorites":true}'
    mkdir -p "$BACKUP_FAVORITES_DEST"
    mkdir -p "$BACKUP_STATE_DIR"
    printf 'fixture archive marker\n' > "$BACKUP_FAVORITES_DEST/favoritos-latest.tar.zst"
    now="$(date +%s)"
    run_epoch=$((now - 3600))
    printf '%s\t%s\tok\t0\t0\t\n' "$run_epoch" "$(date -d "@$run_epoch" '+%F %T')" \
        > "$BACKUP_STATE_DIR/last-run"
    result="$("$SCRIPT" status --json)" || fail 'status calculation failed'
    jq -e '.favoritesState == "pending" and .state == "warning"' <<< "$result" >/dev/null \
        || fail 'a newer local snapshot was not reported as pending'

    new_sandbox
    write_config copy '{"omarchy":false,"favorites":false}'
    export BACKUP_STALE_HOURS=0
    mkdir -p "$BACKUP_STATE_DIR"
    run_epoch="$(date +%s)"
    printf '%s\t%s\tok\t0\t0\t\n' "$run_epoch" "$(date -d "@$run_epoch" '+%F %T')" \
        > "$BACKUP_STATE_DIR/last-run"
    result="$("$SCRIPT" status --json)" || fail 'stale status calculation failed'
    jq -e '.state == "stale"' <<< "$result" >/dev/null \
        || fail 'a stale backup state was overwritten by snapshot warnings'
    pass 'status preserves pending-snapshot and stale-state precedence'
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
    grep '^check ' "$BACKUP_TEST_RCLONE_LOG" | grep -q -- '--disable-http2' \
        || fail 'verify did not disable HTTP/2 for stable remote metadata checks'
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

test_sync_mode_keeps_delete_limit_and_archive() {
    new_sandbox
    write_config sync

    "$SCRIPT" syncs run fixture-job >/dev/null || fail 'mocked sync job failed'
    grep -q '^sync ' "$BACKUP_TEST_RCLONE_LOG" || fail 'sync mode was not invoked'
    grep '<sync>' "$BACKUP_TEST_RCLONE_ARGS_LOG" | grep -q '<--max-delete> <50>' \
        || fail 'sync mode lost its deletion limit'
    grep '<sync>' "$BACKUP_TEST_RCLONE_ARGS_LOG" | grep -q '<--backup-dir>' \
        || fail 'sync mode lost its archive directory'
    pass 'sync mode keeps the deletion limit and archive directory'
}

test_disabled_sync_is_not_executed() {
    new_sandbox
    write_config copy
    jq '.jobs[0].enabled = false' "$BACKUP_SYNC_CONFIG" > "$BACKUP_SYNC_CONFIG.tmp"
    mv "$BACKUP_SYNC_CONFIG.tmp" "$BACKUP_SYNC_CONFIG"

    "$SCRIPT" >/dev/null || fail 'run failed with all syncs disabled'
    if [[ -f "$BACKUP_TEST_RCLONE_LOG" ]] \
        && grep -Eq '^(copy|sync|bisync) ' "$BACKUP_TEST_RCLONE_LOG"; then
        fail 'a disabled sync was executed'
    fi
    pass 'disabled syncs are skipped by the scheduled runner'
}

test_global_resync_mode_reaches_bisync() {
    new_sandbox
    write_config bisync

    "$SCRIPT" --resync-from-pc >/dev/null || fail 'mocked global resync failed'
    grep '<bisync>' "$BACKUP_TEST_RCLONE_ARGS_LOG" \
        | grep -q '<--resync-mode> <path1>' \
        || fail 'global PC-wins resync mode was not passed to rclone'
    pass 'global resync mode preserves the selected conflict winner'
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

test_chromium_bookmarks_are_sanitized() {
    new_sandbox
    write_config copy '{"omarchy":false,"favorites":true}'
    mkdir -p "$BACKUP_CONFIG_ROOT/chromium/Default"
    cat > "$BACKUP_CONFIG_ROOT/chromium/Default/Bookmarks" <<'JSON'
{"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[{"type":"url","name":"Fixture","url":"https://user:password@example.test/?token=fixture-secret"}]}}}
JSON

    "$SCRIPT" snapshot >/dev/null || fail 'Chromium bookmarks snapshot failed'
    mkdir -p "$SANDBOX/unpacked"
    tar --zstd -xOf "$BACKUP_FAVORITES_DEST/favoritos-latest.tar.zst" \
        favorites/chromium/Default.json > "$SANDBOX/bookmarks.json" \
        || fail 'Chromium bookmarks were not included in the snapshot'
    jq -e '.. | objects | select(.type? == "url") | .url | contains("REDACTED")' \
        "$SANDBOX/bookmarks.json" >/dev/null || fail 'Chromium URL secrets were not redacted'
    if grep -q 'fixture-secret\|user:password' "$SANDBOX/bookmarks.json"; then
        fail 'Chromium snapshot retained URL credentials or token values'
    fi
    pass 'Chromium bookmark snapshots redact URL credentials and tokens'
}

test_firefox_bookmarks_use_read_only_sqlite_export() {
    new_sandbox
    write_config copy '{"omarchy":false,"favorites":true}'
    mkdir -p "$BACKUP_CONFIG_ROOT/mozilla/firefox/fixture.default"
    python3 - "$BACKUP_CONFIG_ROOT/mozilla/firefox/fixture.default/places.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.executescript("""
CREATE TABLE moz_bookmarks (id INTEGER, parent INTEGER, position INTEGER, type INTEGER, title TEXT, fk INTEGER);
CREATE TABLE moz_places (id INTEGER, url TEXT);
INSERT INTO moz_places VALUES (1, 'https://user:password@example.test/?token=fixture-secret');
INSERT INTO moz_bookmarks VALUES (2, 1, 0, 1, 'Fixture', 1);
""")
connection.commit()
connection.close()
PY

    "$SCRIPT" snapshot >/dev/null || fail 'Firefox bookmarks snapshot failed'
    tar --zstd -xOf "$BACKUP_FAVORITES_DEST/favoritos-latest.tar.zst" \
        favorites/firefox/fixture.default.json > "$SANDBOX/firefox.json" \
        || fail 'Firefox bookmarks were not included in the snapshot'
    jq -e '.items[0].url | contains("REDACTED")' "$SANDBOX/firefox.json" >/dev/null \
        || fail 'Firefox URL secrets were not redacted'
    if grep -q 'fixture-secret\|user:password' "$SANDBOX/firefox.json"; then
        fail 'Firefox snapshot retained URL credentials or token values'
    fi
    pass 'Firefox favorites use a read-only SQLite export with URL sanitizing'
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
    if "$SCRIPT" syncs snapshot-target --json '{"syncId":"fixture-job","path":null}' \
        >/dev/null 2>&1; then
        fail 'snapshot target accepted a non-string path'
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

test_remote_listing_projects_only_safe_fields() {
    new_sandbox
    result="$("$SCRIPT" syncs remotes --json)" || fail 'remote listing failed'
    jq -e '.remotes == [{"name":"Mock","type":"local"}]' <<< "$result" >/dev/null \
        || fail 'remote listing exposed unexpected attributes'
    if grep -q 'must-not-leak\|private fixture' <<< "$result"; then
        fail 'remote listing exposed private provider fields'
    fi
    pass 'remote listing exposes only provider name and type'
}

test_invalid_sync_edit_preserves_existing_config() {
    new_sandbox
    write_config
    before="$(cat "$BACKUP_SYNC_CONFIG")"
    invalid='{"id":"fixture-job","name":"Fixture","source":"/tmp","destination":"Mock:other","mode":"unknown","enabled":true,"exclude":[]}'
    if "$SCRIPT" syncs upsert --json "$invalid" >/dev/null 2>&1; then
        fail 'invalid sync edit was accepted'
    fi
    [[ "$(cat "$BACKUP_SYNC_CONFIG")" == "$before" ]] \
        || fail 'invalid sync edit changed the persisted configuration'
    pass 'invalid sync edits leave the previous configuration unchanged'
}

test_boolean_schema_version_is_rejected() {
    new_sandbox
    write_config
    jq '.version = true' "$BACKUP_SYNC_CONFIG" > "$BACKUP_SYNC_CONFIG.invalid"
    mv "$BACKUP_SYNC_CONFIG.invalid" "$BACKUP_SYNC_CONFIG"
    if "$SCRIPT" syncs list --json >/dev/null 2>&1; then
        fail 'boolean true was accepted as configuration version 1'
    fi
    pass 'configuration schema requires numeric version 1'
}

test_config_snapshot_can_be_restored_by_verify() {
    new_sandbox
    write_config copy '{"omarchy":true,"favorites":false}'
    mkdir -p "$BACKUP_CONFIG_ROOT/omarchy" "$BACKUP_CONFIG_ROOT/hypr" \
        "$BACKUP_CONFIG_ROOT/systemd/user"
    printf '[Unit]\n' > "$BACKUP_CONFIG_ROOT/systemd/user/omarchy-backup.service"
    "$SCRIPT" snapshot >/dev/null || fail 'config snapshot generation failed'
    output="$("$SCRIPT" verify)" || fail 'verify could not restore the generated config snapshot'
    grep -q 'snapshots locais ativos estao integros' <<< "$output" \
        || fail 'verify did not confirm the extracted snapshot'
    pass 'verify extracts and checks active configuration snapshots'
}

test_bisync_baseline_is_per_job_and_dry_run_is_state_neutral() {
    new_sandbox
    write_config bisync
    "$SCRIPT" syncs run fixture-job --resync --dry-run >/dev/null \
        || fail 'mocked dry-run baseline failed'
    [[ ! -e "$BACKUP_STATE_DIR/baselines/fixture-job.init" ]] \
        || fail 'dry-run created a persistent baseline marker'
    grep -q -- '<--dry-run>' "$BACKUP_TEST_RCLONE_ARGS_LOG" \
        || fail 'dry-run flag was not passed to rclone'
    "$SCRIPT" syncs run fixture-job --resync >/dev/null \
        || fail 'mocked baseline run failed'
    [[ -f "$BACKUP_STATE_DIR/baselines/fixture-job.init" ]] \
        || fail 'baseline marker was not stored under the job ID'
    pass 'bisync baselines are job-scoped and dry-runs do not create them'
}

test_python_cli_preserves_unicode_paths_as_one_argument() {
    new_sandbox
    source="$HOME/Área Pessoal/資料"
    mkdir -p "$source"
    mkdir -p "$(dirname "$BACKUP_SYNC_CONFIG")"
    jq -n --arg source "$source" \
        '{version:1,jobs:[{id:"fixture-job",name:"Unicode",source:$source,
          destination:"Mock:target",mode:"copy",enabled:true,exclude:[]}],
          snapshotOptions:{omarchy:false,favorites:false}}' > "$BACKUP_SYNC_CONFIG"
    chmod 600 "$BACKUP_SYNC_CONFIG"

    "$SCRIPT" syncs run fixture-job >/dev/null || fail 'Unicode source path did not run'
    escaped_source="$(printf '%q' "$source")"
    grep -Fq "<$escaped_source>" "$BACKUP_TEST_RCLONE_ARGS_LOG" \
        || fail 'Unicode source path was split or changed before reaching rclone'
    pass 'Unicode source paths reach rclone as one argument'
}

test_legacy_shell_path_delegates_to_python_backend() {
    new_sandbox
    write_config
    result="$("$ROOT/src/omarchy-backup.sh" status --json)" \
        || fail 'legacy shell entry point failed'
    jq -e '.syncs[0].id == "fixture-job"' <<< "$result" >/dev/null \
        || fail 'legacy shell entry point did not reach the Python backend'
    pass 'legacy shell entry point delegates to Python'
}

test_first_use_migrates_legacy_job_without_running_rclone_sync() {
    new_sandbox
    export BACKUP_FILEN_REMOTE=Mock
    result="$("$SCRIPT" syncs list --json)" || fail 'first-use job listing failed'
    jq -e 'length == 1 and .[0].id == "personal-filen" and
        .[0].destination == "Mock:personal" and .[0].mode == "bisync"' \
        <<< "$result" >/dev/null || fail 'legacy job was not initialized correctly'
    mode="$(stat -c '%a' "$BACKUP_SYNC_CONFIG")"
    [[ "$mode" == 600 ]] || fail "initial sync configuration mode is $mode instead of 600"
    if grep -Eq '^(copy|sync|bisync) ' "$BACKUP_TEST_RCLONE_LOG"; then
        fail 'first-use initialization ran a sync'
    fi
    pass 'first use initializes the legacy job privately without syncing'
}

test_status_parser_keeps_configured_sync
test_status_orders_pending_and_stale_states_consistently
test_verify_checks_jobs_without_syncing
test_copy_does_not_receive_backup_dir
test_sync_mode_keeps_delete_limit_and_archive
test_disabled_sync_is_not_executed
test_global_resync_mode_reaches_bisync
test_empty_favorites_preserve_previous_snapshot
test_gtk_bookmarks_are_sanitized
test_chromium_bookmarks_are_sanitized
test_firefox_bookmarks_use_read_only_sqlite_export
test_uppercase_secret_blocks_config_snapshot
test_plugin_source_fields_do_not_block_config_snapshot
test_snapshot_target_rejects_traversal
test_sync_configuration_is_private
test_remote_listing_projects_only_safe_fields
test_invalid_sync_edit_preserves_existing_config
test_boolean_schema_version_is_rejected
test_config_snapshot_can_be_restored_by_verify
test_bisync_baseline_is_per_job_and_dry_run_is_state_neutral
test_python_cli_preserves_unicode_paths_as_one_argument
test_legacy_shell_path_delegates_to_python_backend
test_first_use_migrates_legacy_job_without_running_rclone_sync
printf 'All %d regression checks passed.\n' "$TESTS"
