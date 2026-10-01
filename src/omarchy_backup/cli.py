from __future__ import annotations

import json
import os
import re
import sys
from typing import Any

from .config import ConfigError, Paths, SyncStore, rclone_remotes
from .runner import BackupRunner
from .snapshots import SnapshotManager
from .status import render_status, status_json


def _json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def _usage() -> str:
    return """Uso:
  omarchy-backup                         executa os syncs ativos
  omarchy-backup status [--brief|--json]
  omarchy-backup snapshot
  omarchy-backup verify [--download]
  omarchy-backup --dry-run
  omarchy-backup --resync [--resync-from-pc|--resync-from-remote]
  omarchy-backup syncs list --json
  omarchy-backup syncs remotes --json
  omarchy-backup syncs upsert --json JOB
  omarchy-backup syncs set-enabled ID 0|1
  omarchy-backup syncs remove ID
  omarchy-backup syncs run ID [--resync --mode newer|path1|path2]
"""


def _ok() -> None:
    _json({"ok": True})


def _syncs(args: list[str], store: SyncStore) -> int:
    if not args:
        raise ConfigError("uso: omarchy-backup syncs {list|remotes|upsert|set-enabled|remove|snapshot-target|snapshot-options|run}")
    action, *rest = args
    if action == "list":
        if rest != ["--json"]:
            raise ConfigError("uso: omarchy-backup syncs list --json")
        _json(store.list_jobs())
        return 0
    if action == "remotes":
        if rest != ["--json"]:
            raise ConfigError("uso: omarchy-backup syncs remotes --json")
        _json({"remotes": rclone_remotes()})
        return 0
    if action == "upsert":
        if len(rest) != 2 or rest[0] != "--json":
            raise ConfigError("uso: omarchy-backup syncs upsert --json JOB")
        try:
            job = json.loads(rest[1])
        except json.JSONDecodeError as exc:
            raise ConfigError("syncs: objeto de job invalido") from exc
        store.upsert(job)
        _ok()
        return 0
    if action == "set-enabled":
        if len(rest) != 2:
            raise ConfigError("uso: omarchy-backup syncs set-enabled ID 0|1")
        store.set_enabled(*rest)
        _ok()
        return 0
    if action == "remove":
        if len(rest) != 1:
            raise ConfigError("uso: omarchy-backup syncs remove ID")
        store.remove(rest[0])
        _ok()
        return 0
    if action in {"snapshot-target", "snapshot-options"}:
        if len(rest) != 2 or rest[0] != "--json":
            raise ConfigError(f"uso: omarchy-backup syncs {action} --json JSON")
        try:
            value = json.loads(rest[1])
        except json.JSONDecodeError as exc:
            raise ConfigError(f"{action}: JSON invalido") from exc
        if action == "snapshot-target":
            store.set_snapshot_target(value)
        else:
            store.set_snapshot_options(value)
        _ok()
        return 0
    if action == "run":
        if not rest or not rest[0] or not re.fullmatch(r"[A-Za-z0-9_-]{1,48}", rest[0]):
            raise ConfigError("syncs: id invalido")
        job_id, *options = rest
        resync = False
        mode = "newer"
        has_mode = False
        dry_run = False
        while options:
            option, *options = options
            if option == "--resync":
                resync = True
            elif option == "--mode" and options and options[0] in {"newer", "path1", "path2"}:
                mode = options.pop(0)
                has_mode = True
            elif option in {"--dry-run", "-n"}:
                dry_run = True
            else:
                raise ConfigError(f"syncs: argumento invalido: {option}")
        if has_mode and not resync:
            raise ConfigError("syncs: --mode so pode ser usado com --resync")
        paths = store.paths
        snapshots = SnapshotManager(paths, store)
        return BackupRunner(
            paths, store, snapshots, dry_run=dry_run, resync=resync,
            resync_mode=mode, manual_job_id=job_id,
        ).run()
    raise ConfigError("uso: omarchy-backup syncs {list|remotes|upsert|set-enabled|remove|snapshot-target|snapshot-options|run}")


def main(argv: list[str] | None = None) -> int:
    os.umask(0o077)
    argv = list(sys.argv[1:] if argv is None else argv)
    paths = Paths()
    store = SyncStore(paths)
    snapshots = SnapshotManager(paths, store)
    try:
        if argv and argv[0] == "syncs":
            return _syncs(argv[1:], store)
        if argv and argv[0] == "status":
            config = store.ensure()
            snapshots.apply_target(config)
            snapshots.load_options(config)
            options = argv[1:]
            data = status_json(paths, config, snapshots)
            if "--json" in options:
                _json(data)
            else:
                print(render_status(data, brief=bool(set(options) & {"--brief", "-b"})))
            return 0

        dry_run = False
        resync = False
        resync_mode = "newer"
        verify_download = False
        command = "run"
        for arg in argv:
            if arg in {"--help", "-h"}:
                print(_usage(), end="")
                return 0
            if arg in {"-n", "--dry-run"}:
                dry_run = True
            elif arg in {"snapshot", "snapshot-chromium"}:
                command = "snapshot"
            elif arg == "verify":
                command = "verify"
            elif arg == "--download":
                verify_download = True
            elif arg == "--resync":
                resync, resync_mode = True, "newer"
            elif arg == "--resync-from-pc":
                resync, resync_mode = True, "path1"
            elif arg in {"--resync-from-filen", "--resync-from-remote"}:
                resync, resync_mode = True, "path2"
            else:
                raise ConfigError(f"argumento desconhecido: {arg}")
        runner = BackupRunner(
            paths,
            store,
            snapshots,
            dry_run=dry_run,
            resync=resync,
            resync_mode=resync_mode,
            verify_download=verify_download,
        )
        if command == "snapshot":
            return runner.snapshot_only()
        if command == "verify":
            return runner.verify_only()
        return runner.run()
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError) as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
