from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any


class ConfigError(Exception):
    """A configuration or validation error suitable for the CLI."""


def _run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, check=check)


class Paths:
    def __init__(self) -> None:
        self.home = Path.home()
        self.script_dir = Path(__file__).resolve().parent.parent
        self.personal = Path(os.getenv("BACKUP_PERSONAL_DIR", self.home / "personal"))
        self.config_root = Path(os.getenv("BACKUP_CONFIG_ROOT", self.home / ".config"))
        self.config_backup = Path(
            os.getenv("BACKUP_CONFIG_DEST", self.personal / "Backups/Omarchy")
        )
        self.config_excludes = Path(
            os.getenv("BACKUP_CONFIG_EXCLUDES", self.script_dir / "config-excludes.txt")
        )
        self.favorites_backup = Path(
            os.getenv("BACKUP_FAVORITES_DEST", self.personal / "Backups/Favoritos")
        )
        self.log_dir = Path(os.getenv("BACKUP_LOG_DIR", self.home / "logs/backup"))
        self.lock_file = Path(
            os.getenv("BACKUP_LOCK", self.home / ".cache/backup_multiplo.lock")
        )
        self.state_dir = Path(
            os.getenv("BACKUP_STATE_DIR", self.home / ".cache/backup_multiplo")
        )
        self.sync_config = Path(
            os.getenv("BACKUP_SYNC_CONFIG", self.home / ".config/backup-multiplo/syncs.json")
        )
        self.archive_local = Path(
            os.getenv(
                "BACKUP_ARCHIVE_LOCAL",
                self.home / ".local/share/backup-multiplo/archive",
            )
        )
        self.remote_name = os.getenv("BACKUP_FILEN_REMOTE", "Filen")
        self.archive_remote = os.getenv(
            "BACKUP_ARCHIVE_REMOTE", f"{self.remote_name}:backup/_archive-personal"
        )
        self.check_file = ".backup_multiplo_ok"
        self.filter_file = self.script_dir / "rclone-filter.txt"
        self.stale_hours = int(os.getenv("BACKUP_STALE_HOURS", "24"))
        self.favorites_stale_hours = int(
            os.getenv("BACKUP_FAVORITES_STALE_HOURS", "24")
        )
        self.notify_failure = os.getenv("BACKUP_NOTIFY_FAILURE", "1") == "1"
        self.rclone_max_seconds = int(os.getenv("RCLONE_MAX_SECONDS", "3600"))
        self.rclone_attempts = int(os.getenv("RCLONE_TENTATIVAS", "4"))
        self.rclone_backoff = int(os.getenv("RCLONE_BACKOFF", "20"))

        self.status_file = self.state_dir / "status.tsv"
        self.last_run_file = self.state_dir / "last-run"
        self.history_file = self.state_dir / "history.tsv"


SAFE_CONFIG_PATHS = (
    "omarchy",
    "hypr",
    "kitty",
    "alacritty",
    "foot",
    "ghostty",
    "waybar",
    "walker",
    "mako",
    "swaync",
    "fontconfig",
    "imv",
    "btop",
    "fastfetch",
    "nvim",
    "tmux",
    "starship.toml",
    "mimeapps.list",
    "user-dirs.dirs",
    "user-dirs.locale",
    "gtk-3.0/settings.ini",
    "gtk-4.0/settings.ini",
    "systemd/user/omarchy-backup.service",
    "systemd/user/omarchy-backup.timer",
)

JOB_KEYS = {"id", "name", "source", "destination", "mode", "enabled", "exclude"}
ROOT_KEYS = {"version", "jobs", "snapshotTarget", "snapshotOptions"}
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,48}$")
CONTROL_RE = re.compile(r"[\x00-\x1f]")
MODES = {"bisync", "sync", "copy"}


def rclone_remotes() -> list[dict[str, str]]:
    if not shutil_which("rclone"):
        raise ConfigError("syncs: rclone nao esta instalado")
    try:
        result = _run(["rclone", "--ask-password=false", "listremotes", "--json"])
        raw = json.loads(result.stdout)
        if not isinstance(raw, list):
            raise ValueError("expected list")
        remotes = [
            {"name": entry["name"], "type": entry["type"]}
            for entry in raw
            if isinstance(entry, dict)
            and isinstance(entry.get("name"), str)
            and isinstance(entry.get("type"), str)
        ]
        return sorted(remotes, key=lambda item: item["name"])
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, KeyError, ValueError) as exc:
        raise ConfigError(
            "syncs: nao foi possivel ler os remotes do rclone; confira a configuracao com rclone config"
        ) from exc


def shutil_which(name: str) -> str | None:
    from shutil import which

    return which(name)


def validate_file(data: Any) -> None:
    if (
        not isinstance(data, dict)
        or set(data) - ROOT_KEYS
        or type(data.get("version")) is not int
        or data.get("version") != 1
    ):
        raise ConfigError("syncs: configuracao invalida: schema ou versao desconhecida")
    jobs = data.get("jobs")
    if not isinstance(jobs, list) or len(jobs) > 64:
        raise ConfigError("syncs: configuracao invalida: lista de jobs")
    ids: list[str] = []
    for job in jobs:
        if not isinstance(job, dict) or set(job) != JOB_KEYS:
            raise ConfigError("syncs: configuracao invalida: campos do job")
        job_id = job["id"]
        if not isinstance(job_id, str) or not ID_RE.fullmatch(job_id):
            raise ConfigError("syncs: id invalido")
        ids.append(job_id)
        name = job["name"]
        if (
            not isinstance(name, str)
            or not name.strip()
            or len(name) > 80
            or CONTROL_RE.search(name)
        ):
            raise ConfigError("syncs: nome invalido")
        source = job["source"]
        if not isinstance(source, str) or not source.startswith("/") or len(source) <= 1 or CONTROL_RE.search(source):
            raise ConfigError("syncs: origem invalida")
        destination = job["destination"]
        if not isinstance(destination, str) or len(destination) <= 2 or ":" not in destination or CONTROL_RE.search(destination):
            raise ConfigError("syncs: destino invalido")
        if not isinstance(job["mode"], str) or job["mode"] not in MODES:
            raise ConfigError("syncs: modo invalido")
        if not isinstance(job["enabled"], bool):
            raise ConfigError("syncs: enabled precisa ser booleano")
        excludes = job["exclude"]
        if not isinstance(excludes, list) or len(excludes) > 64:
            raise ConfigError("syncs: exclusoes invalidas")
        for pattern in excludes:
            if (
                not isinstance(pattern, str)
                or not pattern
                or len(pattern) > 256
                or CONTROL_RE.search(pattern)
                or pattern.lstrip().startswith(("+", "!"))
            ):
                raise ConfigError("syncs: exclusoes invalidas; use padroes negativos")
    if len(set(ids)) != len(ids):
        raise ConfigError("syncs: IDs duplicados")
    target = data.get("snapshotTarget")
    if target is not None:
        if (
            not isinstance(target, dict)
            or set(target) != {"syncId", "path"}
            or not isinstance(target.get("syncId"), str)
            or not ID_RE.fullmatch(target["syncId"])
            or not isinstance(target.get("path"), str)
            or not re.fullmatch(r"[A-Za-z0-9._/-]{1,240}", target["path"])
            or target["path"].startswith("/")
            or "//" in target["path"]
            or any(part in {".", ".."} for part in target["path"].split("/"))
        ):
            raise ConfigError("snapshots: destino configurado invalido")
    options = data.get("snapshotOptions", {})
    if (
        not isinstance(options, dict)
        or set(options) - {"omarchy", "favorites"}
        or any(not isinstance(value, bool) for value in options.values())
    ):
        raise ConfigError("snapshots: opcoes invalidas")


def validate_destinations(data: dict[str, Any]) -> None:
    destinations: list[tuple[str, str]] = []
    for job in data["jobs"]:
        remote, path = job["destination"].split(":", 1)
        path = path.rstrip("/")
        if not remote or not path or path.startswith("/") or any(p in {".", ".."} for p in path.split("/")):
            raise ConfigError("syncs: caminho remoto invalido")
        for reserved in ("backup/_archive-personal", "backup/_archive-backup-multiplo"):
            if path == reserved or path.startswith(reserved + "/") or reserved.startswith(path + "/"):
                raise ConfigError("syncs: destino sobrepoe uma pasta reservada para arquivo-morto")
        for other_remote, other_path in destinations:
            if remote == other_remote and (
                path == other_path
                or path.startswith(other_path + "/")
                or other_path.startswith(path + "/")
            ):
                raise ConfigError("syncs: destinos sobrepostos entre jobs")
        destinations.append((remote, path))


class SyncStore:
    def __init__(self, paths: Paths):
        self.paths = paths

    def _locked(self):
        class Lock:
            def __init__(inner, store: SyncStore):
                inner.path = store.paths.sync_config
                inner.file = None

            def __enter__(inner):
                inner.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                os.chmod(inner.path.parent, 0o700)
                inner.file = inner.path.with_suffix(inner.path.suffix + ".lock").open("a")
                fcntl.flock(inner.file.fileno(), fcntl.LOCK_EX)
                return inner

            def __exit__(inner, *_exc):
                if inner.file:
                    fcntl.flock(inner.file.fileno(), fcntl.LOCK_UN)
                    inner.file.close()

        return Lock(self)

    def ensure(self) -> dict[str, Any]:
        path = self.paths.sync_config
        with self._locked():
            if path.is_symlink():
                raise ConfigError("syncs: o arquivo de configuracao nao pode ser um link simbolico")
            if path.exists():
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                    validate_file(data)
                    validate_destinations(data)
                except (OSError, json.JSONDecodeError, ConfigError) as exc:
                    raise ConfigError(
                        f"syncs: configuracao invalida em {path}; nenhuma sincronizacao foi iniciada"
                    ) from exc
                os.chmod(path, 0o600)
                return data
            remotes: set[str] = set()
            try:
                remotes = {remote["name"] for remote in rclone_remotes()}
            except ConfigError:
                pass
            jobs = []
            if self.paths.remote_name in remotes:
                jobs.append(
                    {
                        "id": "personal-filen",
                        "name": "Pessoal · Filen",
                        "source": str(self.paths.personal),
                        "destination": f"{self.paths.remote_name}:personal",
                        "mode": "bisync",
                        "enabled": True,
                        "exclude": [],
                    }
                )
            data = {"version": 1, "jobs": jobs}
            self._atomic_write(data)
            return data

    def list_jobs(self) -> list[dict[str, Any]]:
        return self.ensure()["jobs"]

    def _atomic_write(self, data: dict[str, Any]) -> None:
        path = self.paths.sync_config
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(path.parent, 0o700)
        validate_file(data)
        validate_destinations(data)
        fd, temp_name = tempfile.mkstemp(prefix=".syncs.", dir=path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(data, stream, ensure_ascii=False, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_name, path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)

    def write(self, updated: dict[str, Any], expected: dict[str, Any]) -> None:
        with self._locked():
            path = self.paths.sync_config
            if path.is_symlink() or not path.exists():
                raise ConfigError("syncs: arquivo de configuracao mudou; atualize o painel")
            current = json.loads(path.read_text(encoding="utf-8"))
            if current != expected:
                raise ConfigError("syncs: configuracao mudou durante a edicao; atualize o painel e tente novamente")
            self._atomic_write(updated)

    def validate_source(self, raw: str) -> str:
        source = Path(raw).expanduser()
        if not source.is_absolute():
            raise ConfigError("syncs: origem precisa ser uma pasta absoluta existente")
        try:
            resolved = source.resolve(strict=True)
        except OSError as exc:
            raise ConfigError("syncs: origem precisa ser uma pasta absoluta existente") from exc
        if not resolved.is_dir():
            raise ConfigError("syncs: origem precisa ser uma pasta absoluta existente")
        home = self.paths.home.resolve()
        if resolved == Path("/") or resolved == home:
            raise ConfigError("syncs: nao use / ou sua pasta pessoal inteira como origem")
        protected = [
            home / ".config", home / ".ssh", home / ".gnupg", home / ".aws",
            home / ".azure", home / ".mozilla", home / ".config/chromium",
            home / ".config/google-chrome", home / ".config/BraveSoftware",
            self.paths.personal / "Vault", self.paths.personal / "Firefox",
            self.paths.personal / "Backups/Chromium", self.paths.personal / "Backups/Firefox",
            self.paths.archive_local,
        ]
        for root in protected:
            candidate = root.resolve() if root.exists() else root.resolve(strict=False)
            if resolved == candidate or resolved in candidate.parents or candidate in resolved.parents:
                raise ConfigError(f"syncs: pasta protegida nao pode ser origem: {candidate}")
        return str(resolved)

    def validate_job(self, job: Any) -> dict[str, Any]:
        if not isinstance(job, dict) or set(job) != JOB_KEYS:
            raise ConfigError("syncs: objeto de job invalido")
        validate_file({"version": 1, "jobs": [job]})
        job = dict(job)
        job["source"] = self.validate_source(job["source"])
        remote, path = job["destination"].split(":", 1)
        if not remote or not path or path.startswith("/"):
            raise ConfigError("syncs: destino precisa ser remote:pasta")
        configured = {item["name"] for item in rclone_remotes()}
        if remote not in configured:
            raise ConfigError(f"syncs: remote nao configurado no rclone: {remote}")
        return job

    def upsert(self, job: Any) -> None:
        job = self.validate_job(job)
        current = self.ensure()
        updated = dict(current)
        updated["jobs"] = [item for item in current["jobs"] if item["id"] != job["id"]] + [job]
        self.write(updated, current)

    def set_enabled(self, job_id: str, enabled: str) -> None:
        if enabled not in {"0", "1"}:
            raise ConfigError("syncs: enabled deve ser 0 ou 1")
        current = self.ensure()
        if not any(job["id"] == job_id for job in current["jobs"]):
            raise ConfigError("syncs: job nao encontrado")
        updated = dict(current)
        updated["jobs"] = [
            {**job, "enabled": enabled == "1"} if job["id"] == job_id else job
            for job in current["jobs"]
        ]
        self.write(updated, current)

    def remove(self, job_id: str) -> None:
        current = self.ensure()
        if not any(job["id"] == job_id for job in current["jobs"]):
            raise ConfigError("syncs: job nao encontrado")
        updated = dict(current)
        updated["jobs"] = [job for job in current["jobs"] if job["id"] != job_id]
        if (updated.get("snapshotTarget") or {}).get("syncId") == job_id:
            updated["snapshotTarget"] = None
        self.write(updated, current)

    def set_snapshot_target(self, target: Any) -> None:
        if not isinstance(target, dict) or set(target) != {"syncId", "path"}:
            raise ConfigError("snapshots: destino configurado invalido")
        current = self.ensure()
        job = next((item for item in current["jobs"] if item["id"] == target["syncId"]), None)
        if not job:
            raise ConfigError("snapshots: selecione um sync existente")
        source = Path(self.validate_source(job["source"]))
        if not isinstance(target["path"], str):
            raise ConfigError("snapshots: informe uma subpasta relativa, sem segmentos . ou ..")
        target_path = target["path"]
        if not re.fullmatch(r"[A-Za-z0-9._/-]{1,240}", target_path) or target_path.startswith("/") or "//" in target_path or any(part in {".", ".."} for part in target_path.split("/")):
            raise ConfigError("snapshots: informe uma subpasta relativa, sem segmentos . ou ..")
        resolved = (source / target_path).resolve(strict=False)
        if source not in resolved.parents:
            raise ConfigError("snapshots: a pasta escolhida precisa permanecer dentro da origem do sync")
        updated = dict(current)
        updated["snapshotTarget"] = {"syncId": job["id"], "path": target_path}
        self.write(updated, current)

    def set_snapshot_options(self, options: Any) -> None:
        if (
            not isinstance(options, dict)
            or set(options) != {"omarchy", "favorites"}
            or any(not isinstance(value, bool) for value in options.values())
        ):
            raise ConfigError("snapshots: opções inválidas")
        current = self.ensure()
        updated = dict(current)
        updated["snapshotOptions"] = options
        self.write(updated, current)
