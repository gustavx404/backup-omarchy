from __future__ import annotations

import fcntl
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from .config import ConfigError, Paths, SyncStore, rclone_remotes
from .snapshots import SnapshotManager


COMMON_FLAGS = [
    "--fast-list", "--transfers", "4", "--checkers", "8", "--retries", "3",
    "--retries-sleep", "30s", "--low-level-retries", "10", "--timeout", "300s",
    "--contimeout", "120s", "--expect-continue-timeout", "30s", "--modify-window", "1s",
    "--log-level", "INFO", "--stats", "1m", "--stats-one-line",
]
BISYNC_FLAGS = [
    "--max-delete", "50", "--check-access", "--check-filename", ".backup_multiplo_ok",
    "--conflict-resolve", "none", "--resilient", "--recover",
]


class BackupRunner:
    def __init__(
        self,
        paths: Paths,
        store: SyncStore,
        snapshots: SnapshotManager,
        *,
        dry_run: bool = False,
        resync: bool = False,
        resync_mode: str = "newer",
        manual_job_id: str = "",
        verify_download: bool = False,
    ):
        self.paths = paths
        self.store = store
        self.snapshots = snapshots
        self.dry_run = dry_run
        self.resync = resync
        self.resync_mode = resync_mode
        self.manual_job_id = manual_job_id
        self.verify_download = verify_download
        self.failure_code = "preflight-failed"
        self.phase = "pre-flight"
        self.started = int(time.time())
        self._lock_stream = None

    def _prepare(self) -> dict[str, Any]:
        self.paths.log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.paths.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.paths.archive_local.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.paths.lock_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.paths.log_dir, 0o700)
        os.chmod(self.paths.state_dir, 0o700)
        self._lock_stream = self.paths.lock_file.open("a")
        try:
            fcntl.flock(self._lock_stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"{datetime.now():%F %T} outra execucao ja esta rodando (lock: {self.paths.lock_file}) - saindo.", file=sys.stderr)
            return {}
        os.environ.pop("RCLONE_VERBOSE", None)
        os.environ.pop("RCLONE_LOG_LEVEL", None)
        os.environ.pop("RCLONE_CONFIG_PASS", None)
        return self.store.ensure()

    def run(self) -> int:
        completed = False
        try:
            config = self._prepare()
            if not config:
                return 0
            self.snapshots.apply_target(config)
            self.snapshots.load_options(config)
            if not self._validate_selection(config):
                if not self.dry_run:
                    self._record_failure("preflight-failed", jobs_count=1)
                return 2
            if not self._check_rclone(config):
                if not self.dry_run:
                    self._record_failure("preflight-failed", jobs_count=1)
                return 3
            jobs = self._selected_jobs(config)
            if self.manual_job_id:
                print(f"rclone: nativo ({shutil_which('rclone')})")
            elif jobs:
                print(f"rclone: nativo ({shutil_which('rclone')})")
            else:
                print("rclone: nenhum sync ativo")

            if self.dry_run:
                print("snapshots: ignorados no modo dry-run")
            else:
                self.phase = "configuracoes seguras e favoritos"
                if not self.snapshots.snapshot_all():
                    print("ERRO: um snapshot local falhou; backup remoto cancelado.", file=sys.stderr)
                    self._record_failure("snapshot-failed", jobs_count=1)
                    completed = True
                    return 5

            self.phase = "sincronizacao rclone"
            self.failure_code = "sync-failed"
            record = not self.dry_run
            if record:
                self.paths.status_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                self.paths.status_file.write_text("", encoding="utf-8")
            print("=== OMARCHY BACKUP {}{}===".format(
                "(DRY-RUN) " if self.dry_run else "",
                f"(RESYNC {self.resync_mode}) " if self.resync else "",
            ))
            failures = 0
            job_count = 0
            for job in jobs:
                if self.resync and job["mode"] != "bisync":
                    if self.manual_job_id:
                        print(f"syncs: {job['id']} nao e bidirecional", file=sys.stderr)
                        return 2
                    print(f"  -- pulando [{job['mode']}] {job['destination']} (--resync so vale p/ bisync)")
                    continue
                print(f"  -> [{job['mode']}] {job['name']}: {job['source']}  =>  {job['destination']}")
                job_count += 1
                started = time.monotonic()
                code = self._run_job(job)
                duration = int(time.monotonic() - started)
                if code == 0:
                    result = "OK"
                    print("     OK")
                else:
                    result = "FALHOU"
                    print(f"     FALHOU (ver {self.paths.log_dir}/{job['id']}_{datetime.now():%Y-%m-%d}.log)")
                    failures += 1
                if record:
                    self._append_status(job, result, duration)
            if record:
                state = "ok" if failures == 0 else "fail"
                code = "" if failures == 0 else self.failure_code
                self._write_last_run(state, failures, job_count, code)
                self._record_history(state, int(time.time() - self.started), failures, job_count)
            if failures:
                completed = True
                self._notify_failure(failures, job_count)
                print(f"=== TERMINOU COM {failures} FALHA(S) ===")
                return 1
            completed = True
            print("=== TUDO OK ===")
            return 0
        except ConfigError as exc:
            print(str(exc), file=sys.stderr)
            if not completed and not self.dry_run:
                self._record_failure("preflight-failed", jobs_count=1)
            return 2
        except Exception as exc:
            print(f"ERRO: {exc}", file=sys.stderr)
            if not completed and not self.dry_run:
                self._record_failure(self.failure_code, jobs_count=1)
            return 1
        finally:
            if self._lock_stream:
                try:
                    fcntl.flock(self._lock_stream.fileno(), fcntl.LOCK_UN)
                    self._lock_stream.close()
                except OSError:
                    pass

    def snapshot_only(self) -> int:
        try:
            config = self._prepare()
            if not config:
                return 0
            self.snapshots.apply_target(config)
            self.snapshots.load_options(config)
            self.phase = "configuracoes seguras e favoritos"
            return 0 if self.snapshots.snapshot_all() else 1
        except ConfigError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        finally:
            self._unlock()

    def verify_only(self) -> int:
        try:
            config = self._prepare()
            if not config:
                return 0
            self.snapshots.apply_target(config)
            self.snapshots.load_options(config)
            if not self._check_rclone(config):
                return 3
            self.phase = "verificacao"
            return self.verify(config)
        except ConfigError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        finally:
            self._unlock()

    def _unlock(self) -> None:
        if self._lock_stream:
            try:
                fcntl.flock(self._lock_stream.fileno(), fcntl.LOCK_UN)
                self._lock_stream.close()
            except OSError:
                pass
            self._lock_stream = None

    def _selected_jobs(self, config: dict[str, Any]) -> list[dict[str, Any]]:
        jobs = [job for job in config["jobs"] if job["enabled"]]
        if self.manual_job_id:
            jobs = [job for job in jobs if job["id"] == self.manual_job_id]
        return jobs

    def _validate_selection(self, config: dict[str, Any]) -> bool:
        if not self.manual_job_id:
            return True
        job = next((item for item in config["jobs"] if item["id"] == self.manual_job_id), None)
        if job is None:
            print("syncs: job nao encontrado", file=sys.stderr)
            return False
        if not job["enabled"]:
            print("syncs: ative o job antes de executa-lo", file=sys.stderr)
            return False
        if self.resync and job["mode"] != "bisync":
            print("syncs: baseline so existe para modo bidirecional", file=sys.stderr)
            return False
        return True

    def _check_rclone(self, config: dict[str, Any]) -> bool:
        jobs = self._selected_jobs(config)
        if not jobs:
            return True
        if not shutil_which("rclone"):
            print("ERRO: rclone nativo nao esta instalado. Rode: omarchy-pkg-add rclone", file=sys.stderr)
            return False
        try:
            remotes = {item["name"] for item in rclone_remotes()}
        except ConfigError as exc:
            print(str(exc), file=sys.stderr)
            return False
        missing = sorted({job["destination"].split(":", 1)[0] for job in jobs} - remotes)
        if missing:
            print(f"ERRO: remote(s) rclone nao configurado(s): {' '.join(name + ':' for name in missing)}", file=sys.stderr)
            print("  configure com: rclone config; depois atualize a lista no painel", file=sys.stderr)
            return False
        return True

    def _write_filter(self, job: dict[str, Any]) -> Path:
        if not self.paths.filter_file.is_file():
            raise OSError(f"ERRO: filtro global ausente: {self.paths.filter_file}")
        filter_dir = self.paths.state_dir / "filters"
        filter_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(filter_dir, 0o700)
        target = filter_dir / f"{job['id']}.filters"
        fd, temp = tempfile.mkstemp(prefix=f".{job['id']}.", dir=filter_dir)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as output:
                output.write(self.paths.filter_file.read_bytes())
                for pattern in job["exclude"]:
                    pattern = pattern.strip()
                    if pattern:
                        output.write(f"\n- {pattern}\n".encode())
                output.flush()
                os.fsync(output.fileno())
            os.replace(temp, target)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        return target

    def _run_rclone(self, log_file: Path, args: list[str], *, attempts: int | None = None) -> int:
        attempts = attempts or self.paths.rclone_attempts
        delay = self.paths.rclone_backoff
        log_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        log_file.touch(mode=0o600, exist_ok=True)
        os.chmod(log_file, 0o600)
        for attempt in range(1, attempts + 1):
            with log_file.open("r", encoding="utf-8", errors="replace") as stream:
                start_line = sum(1 for _ in stream)
            command = [*args, "--log-file", str(log_file)]
            started = time.monotonic()
            try:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True)
                try:
                    code = process.wait(timeout=self.paths.rclone_max_seconds)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGINT)
                    try:
                        process.wait(timeout=60)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    with log_file.open("a", encoding="utf-8") as stream:
                        stream.write(f"[{datetime.now():%F %T}] TIMEOUT em {self.paths.rclone_max_seconds}s - INCOMPLETO\n")
                    return 124
            except OSError as exc:
                with log_file.open("a", encoding="utf-8") as stream:
                    stream.write(f"[{datetime.now():%F %T}] erro ao iniciar rclone: {exc}\n")
                return 127
            duration = int(time.monotonic() - started)
            if code == 0:
                return 0
            with log_file.open("a", encoding="utf-8") as stream:
                stream.write(f"[{datetime.now():%F %T}] erro (codigo rclone: {code}, {duration}s)\n")
            try:
                new_lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()[start_line:]
            except OSError:
                new_lines = []
            if any(re.search(r"filters file (?:has changed|md5 hash not found)|must run --resync", line, re.I) for line in new_lines):
                self.failure_code = "resync-required"
                with log_file.open("a", encoding="utf-8") as stream:
                    stream.write(f"[{datetime.now():%F %T}] filtro bisync alterado; escolha o lado vencedor antes do resync\n")
                return code
            if attempt >= attempts:
                with log_file.open("a", encoding="utf-8") as stream:
                    stream.write(f"[{datetime.now():%F %T}] desisto apos {attempt} tentativas\n")
                return code
            with log_file.open("a", encoding="utf-8") as stream:
                stream.write(f"[{datetime.now():%F %T}] nova tentativa em {delay}s...\n")
            time.sleep(delay)
            delay *= 2
        return 1

    def _run_job(self, job: dict[str, Any]) -> int:
        origin = job["source"]
        destination = job["destination"]
        mode = job["mode"]
        job_id = job["id"]
        log = self.paths.log_dir / f"{job_id}_{datetime.now():%Y-%m-%d}.log"
        if not Path(origin).is_dir():
            print(f"ERRO: origem nao existe: {origin}", file=sys.stderr)
            return 2
        try:
            filter_path = self._write_filter(job)
        except OSError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        remote = destination.split(":", 1)[0]
        archive_remote = self.paths.archive_remote
        archive_local = self.paths.archive_local
        if job_id != "personal-filen":
            archive_local = archive_local / job_id
            archive_remote = f"{remote}:backup/_archive-backup-multiplo/{job_id}"
        archive_local.mkdir(parents=True, exist_ok=True, mode=0o700)
        with log.open("a", encoding="utf-8") as stream:
            stream.write("========================================\n")
            stream.write(f"[{datetime.now():%F %T}] JOB {job_id} ({mode}{',dry-run' if self.dry_run else ''})  {origin}  ->  {destination}\n")
        dry_flags = ["--dry-run"] if self.dry_run else []
        if mode == "sync":
            args = ["rclone", "sync", origin, destination, *COMMON_FLAGS, "--max-delete", "50", "--backup-dir", archive_remote, "--filter-from", str(filter_path), *dry_flags]
            code = self._run_rclone(log, args)
        elif mode == "copy":
            args = ["rclone", "copy", origin, destination, *COMMON_FLAGS, "--filter-from", str(filter_path), *dry_flags]
            code = self._run_rclone(log, args)
        elif mode == "bisync":
            mark = self.paths.state_dir / "baselines" / f"{job_id}.init"
            legacy_mark = self._legacy_marker(origin, destination)
            legacy_ready = job_id == "personal-filen" and not mark.is_file() and legacy_mark.is_file()
            if legacy_ready and not self.dry_run:
                mark.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                mark.touch(mode=0o600)
            args = ["rclone", "bisync", origin, destination, *COMMON_FLAGS, *BISYNC_FLAGS,
                    "--backup-dir1", str(archive_local), "--backup-dir2", archive_remote,
                    "--filters-file", str(filter_path), *dry_flags]
            if self.resync:
                with log.open("a", encoding="utf-8") as stream:
                    stream.write(f"[{datetime.now():%F %T}] --resync (resync-mode {self.resync_mode})\n")
                if not self.dry_run:
                    try:
                        (Path(origin) / self.paths.check_file).touch()
                    except OSError:
                        pass
                    self._run_rclone(log, ["rclone", "touch", f"{destination}/{self.paths.check_file}"])
                code = self._run_rclone(log, [*args, "--resync", "--resync-mode", self.resync_mode])
                if code == 0 and not self.dry_run:
                    mark.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    mark.touch(mode=0o600)
            elif not mark.is_file() and not legacy_ready:
                with log.open("a", encoding="utf-8") as stream:
                    stream.write(f"[{datetime.now():%F %T}] bisync ainda nao inicializado para este par; use o baseline pelo painel.\n")
                code = 4
            else:
                code = self._run_rclone(log, args)
        else:
            code = 2
        with log.open("a", encoding="utf-8") as stream:
            stream.write(f"[{datetime.now():%F %T}] {'OK' if code == 0 else 'FALHOU'}  {destination} (codigo {code})\n")
            stream.write("========================================\n\n")
        return code

    def _legacy_marker(self, source: str, destination: str) -> Path:
        import hashlib

        digest = hashlib.md5(f"{source}|{destination}".encode(), usedforsecurity=False).hexdigest()[:16]
        return self.paths.state_dir / f"{digest}.init"

    def verify(self, config: dict[str, Any]) -> int:
        info_checked = False
        if self.snapshots.favorites_enabled:
            if not self.snapshots.verify_favorites_archive(self.snapshots.favorites_archive):
                print("verificacao: snapshot de favoritos ausente ou invalido", file=sys.stderr)
                return 1
            info_checked = True
        if self.snapshots.omarchy_enabled:
            if not self.snapshots.verify_config_archive(self.snapshots.config_archive):
                print("verificacao: snapshot Omarchy ausente ou invalido", file=sys.stderr)
                return 1
            info_checked = True
        print("verificacao: snapshots locais ativos estao integros" if info_checked else "verificacao: snapshots locais desativados")
        print("verificacao: comparando conteudo completo" if self.verify_download else "verificacao: comparando metadados")
        failed = 0
        enabled = 0
        for job in config["jobs"]:
            if not job["enabled"]:
                continue
            enabled += 1
            filter_path = self._write_filter(job)
            combined = self.paths.state_dir / f"verify-{job['id']}.txt"
            log = self.paths.log_dir / f"verificacao_{job['id']}_{datetime.now():%Y-%m-%d_%H-%M-%S}.log"
            args = ["rclone", "check", job["source"], job["destination"], "--filter-from", str(filter_path),
                    "--checkers", "8", "--disable-http2", "--timeout", "300s", "--contimeout", "120s",
                    "--combined", str(combined)]
            if self.verify_download:
                args.append("--download")
            print(f"verificacao: [{job['id']}] {job['source']} -> {job['destination']}")
            if self._run_rclone(log, args, attempts=1):
                print(f"verificacao: [{job['id']}] falhou; consulte {combined} e {log}", file=sys.stderr)
                failed += 1
            elif combined.is_file() and re.search(r"^[+*?!-]", combined.read_text(encoding="utf-8", errors="replace"), re.M):
                print(f"verificacao: [{job['id']}] relatorio contem diferencas: {combined}", file=sys.stderr)
                failed += 1
            else:
                print(f"verificacao: [{job['id']}] integro")
        if not enabled:
            print("verificacao: nenhum sync ativo configurado")
        if failed:
            return 1
        print("verificacao: jobs ativos e snapshots estao integros")
        return 0

    def _append_status(self, job: dict[str, Any], result: str, duration: int) -> None:
        self.paths.status_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.paths.status_file.open("a", encoding="utf-8") as stream:
            stream.write(f"{int(time.time())}\t{datetime.now():%F %T}\t{job['id']}\t{job['destination']}\t{job['mode']}\t{result}\t{duration}\n")
        os.chmod(self.paths.status_file, 0o600)

    def _write_last_run(self, state: str, failures: int, jobs: int, failure_code: str) -> None:
        self.paths.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.paths.last_run_file.write_text(
            f"{int(time.time())}\t{datetime.now():%F %T}\t{state}\t{failures}\t{jobs}\t{failure_code}\n",
            encoding="utf-8",
        )
        os.chmod(self.paths.last_run_file, 0o600)

    def _record_history(self, state: str, duration: int, failures: int, jobs: int) -> None:
        cutoff = int((datetime.now() - timedelta(days=30)).timestamp())
        rows = []
        try:
            rows = [line for line in self.paths.history_file.read_text(encoding="utf-8").splitlines() if line.split("\t", 1)[0].isdigit() and int(line.split("\t", 1)[0]) >= cutoff][-99:]
        except OSError:
            pass
        rows.append(f"{int(time.time())}\t{datetime.now():%F}\t{state}\t{duration}\t{failures}\t{jobs}")
        self._atomic_text(self.paths.history_file, "\n".join(rows) + "\n", 0o600)

    def _record_failure(self, failure_code: str, *, jobs_count: int) -> None:
        now = int(time.time())
        self.paths.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._atomic_text(self.paths.status_file, f"{now}\t{datetime.now():%F %T}\tsistema\t{self.phase}\tFALHOU\t0\n", 0o600)
        self._write_last_run("fail", 1, jobs_count, failure_code)
        self._record_history("fail", int(time.time() - self.started), 1, jobs_count)
        self._notify_failure(1, jobs_count)

    @staticmethod
    def _atomic_text(path: Path, content: str, mode: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            os.fchmod(fd, mode)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

    def _notify_failure(self, count: int, total: int) -> None:
        if not self.paths.notify_failure or not shutil_which("omarchy-notification-send"):
            return
        message = (
            "Diagnostique a falha mais recente do Omarchy Backup. Consulte status --json e os logs mais recentes; "
            "não mostre segredos nem logs completos. Não altere arquivos, não execute backup nem resync; "
            "apresente causa provável, evidências e correção sugerida."
        )
        subprocess.run([
            "omarchy-notification-send", "--app-name", "omarchy-backup", "-u", "critical", "-g", "⚠",
            "Falha no Omarchy Backup", f"{count} de {total} tarefa(s) falharam. Clique para diagnosticar.",
            "--exec", "omarchy-agent", "--prompt", message,
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def shutil_which(name: str) -> str | None:
    from shutil import which

    return which(name)
