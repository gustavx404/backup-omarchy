from __future__ import annotations

import json
import filecmp
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any

from .config import ConfigError, Paths, SAFE_CONFIG_PATHS, SyncStore


SECRET_ASSIGNMENT = re.compile(
    r"(?i)(?<![A-Za-z0-9_])(?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|"
    r"refresh[_-]?token|id[_-]?token|client[_-]?secret|secret(?:[_-]?(?:key|access[_-]?key))?|"
    r"password|passwd|private[_-]?key|credentials?|aws[_-]?secret[_-]?access[_-]?key)"
    r"[\"']?\s*[:=]\s*[\"']?[^\s\"']+"
)
SAFE_SCAN_SUFFIXES = {".py", ".qml", ".js", ".ts", ".sh", ".md", ".css"}
URL_SECRET = re.compile(
    r"(?i)([?&#])(access_token|refresh_token|id_token|token|api[_-]?key|auth|"
    r"signature|sig|password|passwd|client_secret|secret)=([^&#]*)"
)
URL_CREDENTIALS = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]+@")


class SnapshotManager:
    def __init__(self, paths: Paths, store: SyncStore):
        self.paths = paths
        self.store = store
        self.config_dir = paths.config_backup
        self.favorites_dir = paths.favorites_backup
        self.omarchy_enabled = True
        self.favorites_enabled = True

    def load_options(self, config: dict[str, Any]) -> None:
        options = config.get("snapshotOptions", {})
        self.omarchy_enabled = options.get("omarchy", True)
        self.favorites_enabled = options.get("favorites", True)

    def apply_target(self, config: dict[str, Any]) -> None:
        target = config.get("snapshotTarget")
        if not target:
            return
        job = next((item for item in config["jobs"] if item["id"] == target["syncId"]), None)
        if job is None:
            raise ConfigError("snapshots: sync de destino nao existe; configure o destino no painel")
        source = Path(self.store.validate_source(job["source"]))
        resolved = (source / target["path"]).resolve(strict=False)
        if source not in resolved.parents:
            raise ConfigError("snapshots: o destino configurado sai da origem do sync; ajuste-o no painel")
        self.config_dir = resolved / "Omarchy"
        self.favorites_dir = resolved / "Favoritos"

    @property
    def config_archive(self) -> Path:
        return self.config_dir / "config-latest.tar.zst"

    @property
    def favorites_archive(self) -> Path:
        return self.favorites_dir / "favoritos-latest.tar.zst"

    def info(self) -> dict[str, Any]:
        favorites = {
            "state": "disabled" if not self.favorites_enabled else "missing",
            "age": 0,
            "created": "",
            "epoch": 0,
        }
        config_state = "disabled" if not self.omarchy_enabled else "missing"
        if self.omarchy_enabled and self.config_archive.is_file() and self.config_archive.stat().st_size:
            config_state = "ok"
        if not self.favorites_enabled or not self.favorites_archive.is_file():
            return {"favorites": favorites, "config": config_state}
        stat = self.favorites_archive.stat()
        now = int(datetime.now().timestamp())
        age = max(0, now - int(stat.st_mtime))
        favorites.update(
            state="stale" if age >= self.paths.favorites_stale_hours * 3600 else "ok",
            age=age,
            created=datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
            epoch=int(stat.st_mtime),
        )
        return {"favorites": favorites, "config": config_state}

    def snapshot_all(self) -> bool:
        success = True
        if self.omarchy_enabled and not self.snapshot_config():
            success = False
        if self.favorites_enabled and not self.snapshot_favorites():
            success = False
        return success

    @staticmethod
    def _run(args: list[str], *, stdout=None, stderr=None) -> subprocess.CompletedProcess[Any]:
        return subprocess.run(args, stdout=stdout, stderr=stderr, check=False)

    def _scan_secrets(self, root: Path) -> list[Path]:
        suspects: list[Path] = []
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix in SAFE_SCAN_SUFFIXES:
                continue
            try:
                content = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if SECRET_ASSIGNMENT.search(content):
                suspects.append(path)
        return suspects

    def verify_config_archive(self, archive: Path) -> bool:
        if not archive.is_file() or not archive.stat().st_size:
            return False
        result = subprocess.run(["tar", "--zstd", "-tf", str(archive)], text=True, capture_output=True)
        if result.returncode:
            return False
        entries = result.stdout.splitlines()
        for required in ("config/omarchy", "config/hypr", "config/systemd"):
            if not any(entry.startswith(required + "/") for entry in entries):
                print(f"omarchy: item obrigatorio ausente: {required}", file=sys.stderr)
                return False
        for raw_entry in entries:
            entry = raw_entry.rstrip("/")
            if entry == "config":
                continue
            parts = PurePosixPath(entry).parts
            if entry.startswith("/") or any(part in {".", ".."} for part in parts):
                print(f"omarchy: caminho inseguro no snapshot: {entry}", file=sys.stderr)
                return False
            if not any(
                entry == f"config/{item}"
                or entry.startswith(f"config/{item}/")
                or f"config/{item}".startswith(entry + "/")
                for item in SAFE_CONFIG_PATHS
            ):
                print(f"omarchy: item fora da lista segura: {entry}", file=sys.stderr)
                return False
        with tempfile.TemporaryDirectory(prefix="config-verify-") as restore_dir:
            restored = subprocess.run(
                [
                    "tar", "--zstd", "-xf", str(archive), "-C", restore_dir,
                    "config/omarchy", "config/hypr", "config/systemd",
                ],
                text=True,
                capture_output=True,
            )
            if restored.returncode:
                print("omarchy: nao foi possivel restaurar os itens obrigatorios do snapshot", file=sys.stderr)
                return False
        return True

    def snapshot_config(self) -> bool:
        if not self.paths.config_root.is_dir():
            print(f"omarchy: {self.paths.config_root} nao existe", file=sys.stderr)
            return False
        if not self.paths.config_excludes.is_file():
            print(f"omarchy: filtro ausente: {self.paths.config_excludes}", file=sys.stderr)
            return False
        self.config_dir.mkdir(parents=True, exist_ok=True)
        current = self.config_archive
        previous = self.config_dir / "config-previous.tar.zst"
        try:
            with tempfile.TemporaryDirectory(prefix="omarchy-backup-") as temp_dir:
                stage = Path(temp_dir)
                config_root = stage / "config"
                config_root.mkdir()
                print("omarchy: preparando somente configuracoes portateis da lista segura")
                for relative in SAFE_CONFIG_PATHS:
                    source = self.paths.config_root / relative
                    if not source.exists() and not source.is_symlink():
                        continue
                    destination = config_root / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.mkdir(exist_ok=True) if source.is_dir() else None
                    args = ["rsync", "-a", "--safe-links"]
                    if source.is_dir():
                        args.extend([f"--exclude-from={self.paths.config_excludes}", f"{source}/", f"{destination}/"])
                    else:
                        args.extend([str(source), str(destination)])
                    result = self._run(args)
                    if result.returncode:
                        return False
                suspects = self._scan_secrets(config_root)
                if suspects:
                    print("omarchy: possivel segredo detectado; snapshot cancelado:", file=sys.stderr)
                    for suspect in suspects:
                        print(f"  {suspect.relative_to(config_root)}", file=sys.stderr)
                    return False
                temp_archive = self.config_dir / f".config-{int(datetime.now().timestamp())}.partial.tar.zst"
                args = [
                    "tar", "--sort=name", "--mtime=UTC 1970-01-01", "--owner=0", "--group=0",
                    "--numeric-owner", "--zstd", "-cf", str(temp_archive), "-C", str(stage), "config",
                ]
                if self._run(args).returncode:
                    temp_archive.unlink(missing_ok=True)
                    return False
                if not self.verify_config_archive(temp_archive):
                    temp_archive.unlink(missing_ok=True)
                    return False
                if current.is_file() and filecmp.cmp(current, temp_archive, shallow=False):
                    temp_archive.unlink()
                    print("omarchy: configuracoes sem mudancas")
                    return True
                if previous.exists() and not self.verify_config_archive(previous):
                    previous.unlink()
                if current.is_file() and self.verify_config_archive(current):
                    os.replace(current, previous)
                os.replace(temp_archive, current)
                (self.config_dir / "LEIA-ME.txt").write_text(
                    f"Criado em {datetime.now().astimezone().isoformat()}\n"
                    f"Origem: {self.paths.config_root}\nFiltro: {self.paths.config_excludes}\n",
                    encoding="utf-8",
                )
                size = subprocess.run(["du", "-h", str(current)], text=True, capture_output=True)
                print(f"omarchy: snapshot atualizado ({size.stdout.split()[0] if size.stdout else 'ok'})")
                return True
        except OSError as exc:
            print(f"omarchy: falha ao criar snapshot: {exc}", file=sys.stderr)
            return False

    @staticmethod
    def _sanitize_url(value: str) -> str:
        value = URL_CREDENTIALS.sub(r"\1", value)
        return URL_SECRET.sub(lambda match: f"{match.group(1)}{match.group(2)}=REDACTED", value)

    @classmethod
    def _sanitize_json(cls, value: Any) -> Any:
        if isinstance(value, dict):
            result = {key: cls._sanitize_json(item) for key, item in value.items()}
            if isinstance(result.get("url"), str):
                result["url"] = cls._sanitize_url(result["url"])
            return result
        if isinstance(value, list):
            return [cls._sanitize_json(item) for item in value]
        return value

    @classmethod
    def _clean_chromium_node(cls, node: Any) -> dict[str, Any] | None:
        if not isinstance(node, dict):
            return None
        if node.get("type") == "url":
            return {
                "type": "url",
                "name": node.get("name", ""),
                "url": cls._sanitize_url(node.get("url", "")),
            }
        if node.get("type") == "folder":
            children = [
                clean for child in node.get("children", [])
                if (clean := cls._clean_chromium_node(child)) is not None
            ]
            return {"type": "folder", "name": node.get("name", ""), "children": children}
        return None

    def verify_favorites_archive(self, archive: Path) -> bool:
        if not archive.is_file() or not archive.stat().st_size:
            return False
        with tempfile.TemporaryDirectory(prefix="favorites-verify-") as temp:
            result = self._run(["tar", "--zstd", "-xf", str(archive), "-C", temp])
            root = Path(temp) / "favorites"
            if result.returncode or not root.is_dir():
                return False
            for path in root.rglob("*"):
                if path.is_file() and (any(
                    token in path.name.lower()
                    for token in ("cookie", "login", "history", "session", "password")
                ) or path.name == "places.sqlite"):
                    print("favoritos: conteudo proibido encontrado no snapshot", file=sys.stderr)
                    return False
                if path.is_file() and path.suffix == ".json":
                    try:
                        json.loads(path.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError):
                        return False
        return True

    def snapshot_favorites(self) -> bool:
        self.favorites_dir.mkdir(parents=True, exist_ok=True)
        current = self.favorites_archive
        previous = self.favorites_dir / "favoritos-previous.tar.zst"
        try:
            with tempfile.TemporaryDirectory(prefix="favorites-stage-") as temp:
                stage = Path(temp)
                root = stage / "favorites"
                root.mkdir()
                exported = 0
                failed = 0
                chromium_browsers = (
                    ("chromium", self.paths.config_root / "chromium"),
                    ("chrome", self.paths.config_root / "google-chrome"),
                    ("chrome-beta", self.paths.config_root / "google-chrome-beta"),
                    ("chrome-unstable", self.paths.config_root / "google-chrome-unstable"),
                    ("brave", self.paths.config_root / "BraveSoftware/Brave-Browser"),
                    ("brave-beta", self.paths.config_root / "BraveSoftware/Brave-Browser-Beta"),
                    ("brave-nightly", self.paths.config_root / "BraveSoftware/Brave-Browser-Nightly"),
                    ("vivaldi", self.paths.config_root / "vivaldi"),
                )
                for browser, browser_root in chromium_browsers:
                    if not browser_root.is_dir():
                        continue
                    for bookmark in browser_root.glob("*/Bookmarks"):
                        profile = re.sub(r"[^a-zA-Z0-9._-]", "_", bookmark.parent.name)
                        output_dir = root / browser
                        output_dir.mkdir(exist_ok=True)
                        output = output_dir / f"{profile}.json"
                        try:
                            raw = json.loads(bookmark.read_text(encoding="utf-8"))
                        except (OSError, json.JSONDecodeError):
                            output.unlink(missing_ok=True)
                            print(f"favoritos: JSON invalido em {browser}/{bookmark.parent.name}", file=sys.stderr)
                            failed += 1
                            continue
                        urls = self._iter_chromium_urls(raw)
                        if not urls:
                            output.unlink(missing_ok=True)
                            continue
                        roots: dict[str, Any] = {}
                        for key, value in raw.get("roots", {}).items():
                            clean = self._clean_chromium_node(value)
                            if clean is not None:
                                roots[key] = clean
                        output.write_text(
                            json.dumps({"format": "browser-bookmarks-v1", "roots": roots}, ensure_ascii=False),
                            encoding="utf-8",
                        )
                        exported += 1

                query = (
                    "SELECT b.id, b.parent, b.position, b.type, COALESCE(b.title, '') AS title, "
                    "CASE WHEN b.type = 1 THEN p.url ELSE NULL END AS url "
                    "FROM moz_bookmarks AS b LEFT JOIN moz_places AS p ON p.id = b.fk "
                    "WHERE b.type IN (1,2,3) AND (b.type <> 1 OR p.url IS NOT NULL) "
                    "ORDER BY b.parent, b.position"
                )
                firefox_root = self.paths.config_root / "mozilla/firefox"
                if firefox_root.is_dir():
                    for db in firefox_root.glob("*/places.sqlite"):
                        profile = re.sub(r"[^a-zA-Z0-9._-]", "_", db.parent.name)
                        output_dir = root / "firefox"
                        output_dir.mkdir(exist_ok=True)
                        output = output_dir / f"{profile}.json"
                        try:
                            uri = f"file:{db}?mode=ro&immutable=1"
                            with sqlite3.connect(uri, uri=True) as connection:
                                connection.row_factory = sqlite3.Row
                                rows = [dict(row) for row in connection.execute(query)]
                            if not any(row["type"] == 1 and row["url"] for row in rows):
                                continue
                            output.write_text(
                                json.dumps(
                                    self._sanitize_json({"format": "firefox-bookmarks-v1", "items": rows}),
                                    ensure_ascii=False,
                                ),
                                encoding="utf-8",
                            )
                            exported += 1
                        except (OSError, sqlite3.Error) as exc:
                            output.unlink(missing_ok=True)
                            print(f"favoritos: nao foi possivel exportar Firefox/{db.parent.name}: {exc}", file=sys.stderr)
                            failed += 1

                gtk_bookmarks = self.paths.config_root / "gtk-3.0/bookmarks"
                if gtk_bookmarks.is_file() and gtk_bookmarks.stat().st_size:
                    gtk = root / "gtk"
                    gtk.mkdir(exist_ok=True)
                    sanitized_lines = []
                    for line in gtk_bookmarks.read_text(encoding="utf-8", errors="replace").splitlines():
                        if not line:
                            sanitized_lines.append("")
                            continue
                        fields = line.split(None, 1)
                        sanitized_lines.append(self._sanitize_url(fields[0]) + (" " + fields[1] if len(fields) > 1 else ""))
                    (gtk / "bookmarks.txt").write_text("\n".join(sanitized_lines) + "\n", encoding="utf-8")
                    exported += 1
                if failed:
                    print("favoritos: exportacao incompleta; snapshot anterior preservado", file=sys.stderr)
                    return False
                if exported == 0:
                    print("favoritos: nenhum favorito atual; snapshot anterior preservado")
                    return True
                temp_archive = self.favorites_dir / f".favoritos-{int(datetime.now().timestamp())}.partial.tar.zst"
                result = self._run([
                    "tar", "--sort=name", "--mtime=UTC 1970-01-01", "--owner=0", "--group=0",
                    "--numeric-owner", "--zstd", "-cf", str(temp_archive), "-C", str(stage), "favorites",
                ])
                if result.returncode or not self.verify_favorites_archive(temp_archive):
                    temp_archive.unlink(missing_ok=True)
                    return False
                if current.is_file() and filecmp.cmp(current, temp_archive, shallow=False):
                    temp_archive.unlink()
                    print("favoritos: sem mudancas")
                    return True
                if current.exists():
                    os.replace(current, previous)
                os.replace(temp_archive, current)
                (self.favorites_dir / "LEIA-ME.txt").write_text(
                    "Somente favoritos. Sem cookies, logins, historico ou sessoes.\n"
                    f"Criado em {datetime.now().astimezone().isoformat()}\n",
                    encoding="utf-8",
                )
                print(f"favoritos: snapshot atualizado ({current.stat().st_size} bytes)")
                return True
        except OSError as exc:
            print(f"favoritos: falha ao criar snapshot: {exc}", file=sys.stderr)
            return False

    @classmethod
    def _iter_chromium_urls(cls, value: Any):
        if isinstance(value, dict):
            if value.get("type") == "url" and isinstance(value.get("url"), str):
                yield value["url"]
            for item in value.values():
                yield from cls._iter_chromium_urls(item)
        elif isinstance(value, list):
            for item in value:
                yield from cls._iter_chromium_urls(item)
