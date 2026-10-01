from __future__ import annotations

import fcntl
import hashlib
import json
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .config import Paths
from .snapshots import SnapshotManager


def _read_tsv(path: Path) -> list[list[str]]:
    try:
        return [line.rstrip("\n").split("\t") for line in path.read_text(encoding="utf-8").splitlines()]
    except OSError:
        return []


def _age(seconds: int) -> str:
    seconds = max(0, seconds)
    if seconds < 3600:
        return f"há {seconds // 60}min"
    if seconds < 86400:
        return f"há {seconds // 3600}h"
    return f"há {seconds // 86400}d"


def _timer_state() -> str:
    if not shutil_which("systemctl"):
        return "unknown"
    result = subprocess.run(
        ["systemctl", "--user", "is-active", "omarchy-backup.timer"],
        text=True,
        capture_output=True,
        check=False,
    )
    state = result.stdout.strip()
    return state if state in {
        "active", "inactive", "failed", "activating", "deactivating", "maintenance", "reloading"
    } else "unknown"


def shutil_which(name: str) -> str | None:
    from shutil import which

    return which(name)


def _locked(paths: Paths) -> bool:
    lock = paths.lock_file
    if not lock.exists():
        return False
    try:
        with lock.open("a") as stream:
            try:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
                return False
            except BlockingIOError:
                return True
    except OSError:
        return False


def _job_result(row: list[str]) -> dict[str, Any] | None:
    if len(row) < 6 or not row[0].isdigit():
        return None
    if len(row) >= 7:
        return {
            "epoch": int(row[0]), "time": row[1], "id": row[2], "destination": row[3],
            "mode": row[4], "result": row[5],
            "durationSeconds": int(row[6]) if row[6].isdigit() else None,
        }
    if row[4] in {"bisync", "sync", "copy"}:
        return {
            "epoch": int(row[0]), "time": row[1], "id": row[2], "destination": row[3],
            "mode": row[4], "result": row[5], "durationSeconds": None,
        }
    if row[5].isdigit():
        return {
            "epoch": int(row[0]), "time": row[1], "destination": row[2], "mode": row[3],
            "result": row[4], "durationSeconds": int(row[5]),
        }
    return None


def status_json(paths: Paths, config: dict[str, Any], snapshots: SnapshotManager) -> dict[str, Any]:
    snapshot = snapshots.info()
    rows = [_job_result(row) for row in _read_tsv(paths.status_file)]
    results = [row for row in rows if row is not None]
    history = []
    for row in _read_tsv(paths.history_file):
        if len(row) < 6:
            continue
        try:
            history.append({
                "epoch": int(row[0]), "day": row[1], "state": row[2],
                "durationSeconds": int(row[3]), "failures": int(row[4]), "jobs": int(row[5]),
            })
        except ValueError:
            continue
    syncs: list[dict[str, Any]] = []
    for job in config["jobs"]:
        marker = paths.state_dir / "baselines" / f"{job['id']}.init"
        ready = marker.is_file()
        digest = hashlib.md5(
            f"{job['source']}|{job['destination']}".encode(), usedforsecurity=False
        ).hexdigest()[:16]
        legacy_marker = paths.state_dir / f"{digest}.init"
        if job["id"] == "personal-filen" and not ready and legacy_marker.is_file():
            ready = True
        matching = [
            result for result in results
            if result.get("id") == job["id"]
            or (result.get("id") is None and result.get("destination") == job["destination"])
        ]
        target = config.get("snapshotTarget")
        syncs.append({
            **job,
            "lastResult": matching[-1] if matching else None,
            "baselineReady": ready if job["mode"] == "bisync" else True,
            "snapshotTarget": bool(target and target.get("syncId") == job["id"]),
            "snapshotPath": target.get("path") if target and target.get("syncId") == job["id"] else None,
        })
    timer_state = _timer_state()
    last_run = None
    state = "never"
    age = 0
    failures = jobs_count = 0
    failure_code = ""
    last_rows = _read_tsv(paths.last_run_file)
    if last_rows and len(last_rows[0]) >= 5:
        row = last_rows[0]
        try:
            epoch = int(row[0])
            iso = row[1]
            overall = row[2]
            failures = int(row[3])
            jobs_count = int(row[4])
            failure_code = row[5] if len(row) > 5 else ""
            current = int(time.time())
            age = max(0, current - epoch)
            last_run = iso
            state = overall
            if state == "fail" and not failure_code:
                failure_code = _detect_resync_failure(paths, iso, results)
            if state == "ok" and age >= paths.stale_hours * 3600:
                state = "stale"
            if snapshot["favorites"]["state"] == "ok" and snapshot["favorites"]["epoch"] > epoch:
                snapshot["favorites"]["state"] = "pending"
            fav_state = snapshot["favorites"]["state"]
            config_state = snapshot["config"]
            if state == "ok" and (
                fav_state not in {"ok", "disabled"} or config_state not in {"ok", "disabled"}
            ):
                state = "warning"
        except ValueError:
            pass
    if _locked(paths):
        state = "running"
        age = 0
        last_run = ""
        failures = 0
        jobs_count = 0
        failure_code = ""
    return {
        "state": state,
        "ageSeconds": age,
        "lastRun": last_run or "",
        "failures": failures,
        "jobsCount": jobs_count,
        "jobs": results,
        "syncs": syncs,
        "favoritesState": snapshot["favorites"]["state"],
        "favoritesAgeSeconds": snapshot["favorites"]["age"],
        "configState": snapshot["config"],
        "failureCode": failure_code,
        "timerState": timer_state,
        "history": history,
        "snapshotOptions": config.get("snapshotOptions", {"omarchy": True, "favorites": True}),
    }


def _detect_resync_failure(paths: Paths, iso: str, results: list[dict[str, Any]]) -> str:
    failed = next((item for item in reversed(results) if item["result"] != "OK"), None)
    if failed is None:
        return ""
    when = datetime.fromisoformat(iso).strftime("%Y-%m-%d") if iso else ""
    if failed.get("id"):
        log = paths.log_dir / f"{failed['id']}_{when}.log"
    else:
        log = paths.log_dir / f"{failed['destination'].split(':', 1)[0]}_{when}.log"
    try:
        lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    pattern = re.compile(r"filters file (?:has changed|md5 hash not found)|must run --resync", re.I)
    stamp_pattern = re.compile(r"^\[([0-9-]+ [0-9:]+)\]")
    for line in lines:
        match = stamp_pattern.match(line)
        stamp = match.group(1) if match else ""
        if not stamp:
            match = re.match(r"^([0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]+)", line)
            if match:
                stamp = match.group(1).replace("/", "-")
        if stamp and stamp >= iso[:19] and pattern.search(line):
            return "resync-required"
    return ""


def render_status(data: dict[str, Any], *, brief: bool = False) -> str:
    color = sys.stdout.isatty()
    red, green, yellow, gray, reset = ("\033[31m", "\033[32m", "\033[33m", "\033[90m", "\033[0m") if color else ("", "", "", "", "")
    state = data["state"]
    if state == "never":
        return f"{yellow}● backup: nunca rodou{reset} {gray}— rode: omarchy-backup --resync{reset}" if brief else "omarchy-backup: nunca rodou. Rode: omarchy-backup --resync"
    if brief:
        age = _age(data["ageSeconds"])
        if state in {"ok", "warning"}:
            return f"{green}● backup: ok{reset} {gray}· {age}{reset}"
        if state == "stale":
            return f"{yellow}● backup: ok mas {age}{reset} {gray}· timer parado? systemctl --user status omarchy-backup.timer{reset}"
        if state == "running":
            return f"{green}● backup: executando{reset}"
        return f"{red}● backup: FALHOU{reset} {gray}· {age} · {data['failures']}/{data['jobsCount']} job(s) · ~/logs/backup{reset}"
    age = _age(data["ageSeconds"])
    output = [f"omarchy-backup — ultima rodada {age} ({data['lastRun']})"]
    for row in data["jobs"]:
        mark = f"{green}ok  {reset}" if row["result"] == "OK" else f"{red}FALHOU{reset}"
        output.append(f"  {mark} {row.get('id', row.get('destination', '')):<28} {row['mode']:<7} {row.get('durationSeconds', '?')}s  {_age(int(time.time()) - row['epoch'])}")
    fav = data["favoritesState"]
    if fav == "disabled":
        output.append("  favoritos: desativado")
    elif fav in {"ok", "stale"}:
        output.append(f"  favoritos: snapshot {fav}, {_age(data['favoritesAgeSeconds'])}")
    elif fav == "pending":
        output.append("  favoritos: snapshot local aguardando sincronizacao")
    else:
        output.append("  favoritos: SEM SNAPSHOT")
    output.append(f"  omarchy: {data['configState']}")
    output.append("  baseline bisync: ok" if any(job.get("baselineReady") for job in data["syncs"]) else "  baseline bisync: ausente — rode omarchy-backup --resync")
    if state not in {"ok", "stale"}:
        output.append("  logs: ~/logs/backup")
    return "\n".join(output)
