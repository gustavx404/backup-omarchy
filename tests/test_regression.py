from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "src" / "omarchy-backup"


class BackupRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.source = self.home / "source"
        self.config = self.home / ".config" / "backup-multiplo" / "syncs.json"
        self.state = self.home / "state"
        self.config_root = self.home / ".config"
        self.favorites = self.home / "snapshots" / "favorites"
        self.config_snapshots = self.home / "snapshots" / "omarchy"
        self.rclone_calls = self.home / "rclone-calls.jsonl"
        self.rclone_args = self.home / "rclone-args.jsonl"
        for path in (self.home, self.bin, self.source, self.config_root):
            path.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home),
                "BACKUP_CONFIG_ROOT": str(self.config_root),
                "BACKUP_PERSONAL_DIR": str(self.home / "personal"),
                "BACKUP_CONFIG_DEST": str(self.config_snapshots),
                "BACKUP_FAVORITES_DEST": str(self.favorites),
                "BACKUP_LOG_DIR": str(self.home / "logs"),
                "BACKUP_LOCK": str(self.home / "lock"),
                "BACKUP_STATE_DIR": str(self.state),
                "BACKUP_SYNC_CONFIG": str(self.config),
                "BACKUP_NOTIFY_FAILURE": "0",
                "BACKUP_TEST_RCLONE_LOG": str(self.rclone_calls),
                "BACKUP_TEST_RCLONE_ARGS_LOG": str(self.rclone_args),
                "RCLONE_BACKOFF": "0",
                "RCLONE_TENTATIVAS": "1",
                "PATH": os.environ.get("PATH", ""),
            }
        )
        self._create_rclone_mock()
        self.env["PATH"] = f"{self.bin}:{os.environ.get('PATH', '')}"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _create_rclone_mock(self) -> None:
        mock = self.bin / "rclone"
        mock.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['BACKUP_TEST_RCLONE_LOG'], 'a') as f: f.write(json.dumps(args) + '\\n')\n"
            "with open(os.environ['BACKUP_TEST_RCLONE_ARGS_LOG'], 'a') as f: f.write(json.dumps(args, ensure_ascii=False) + '\\n')\n"
            "if args and args[0] == '--ask-password=false': args = args[1:]\n"
            "if args[0] == 'listremotes':\n"
            " print(json.dumps([{'name':'Mock','type':'local','description':'private fixture','token':'must-not-leak'}]) if '--json' in args else 'Mock:')\n"
            "elif args[0] == 'check':\n"
            " if '--combined' in args:\n"
            "  path = pathlib.Path(args[args.index('--combined') + 1]); path.parent.mkdir(parents=True, exist_ok=True); path.write_text('= fixture\\n')\n"
            "elif args[0] in ('copy','sync','bisync','touch'):\n pass\n"
            "else:\n print('unexpected mocked rclone command: ' + ' '.join(args), file=sys.stderr); sys.exit(90)\n",
            encoding="utf-8",
        )
        mock.chmod(0o755)

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(CLI), *args], env=self.env, text=True, capture_output=True, check=False
        )

    def write_config(self, mode: str = "copy", options: dict | None = None) -> None:
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(
            json.dumps(
                {
                    "version": 1,
                    "jobs": [
                        {
                            "id": "fixture-job",
                            "name": "Fixture",
                            "source": str(self.source),
                            "destination": "Mock:target",
                            "mode": mode,
                            "enabled": True,
                            "exclude": [],
                        }
                    ],
                    "snapshotOptions": options or {"omarchy": False, "favorites": False},
                }
            ),
            encoding="utf-8",
        )
        self.config.chmod(0o600)

    def rclone_calls_data(self) -> list[list[str]]:
        if not self.rclone_args.exists():
            return []
        return [json.loads(line) for line in self.rclone_args.read_text().splitlines()]

    def make_config_snapshot_inputs(self) -> None:
        (self.config_root / "omarchy").mkdir(parents=True, exist_ok=True)
        (self.config_root / "hypr").mkdir(parents=True, exist_ok=True)
        unit = self.config_root / "systemd" / "user" / "omarchy-backup.service"
        unit.parent.mkdir(parents=True, exist_ok=True)
        unit.write_text("[Unit]\n", encoding="utf-8")

    def test_01_status_json_retains_sync_and_result(self) -> None:
        self.write_config()
        self.state.mkdir(parents=True)
        (self.state / "status.tsv").write_text(
            "1700000000\t2023-11-14 22:13:20\tfixture-job\tMock:target\tcopy\tOK\t5\n"
        )
        result = self.run_cli("status", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["syncs"][0]["id"], "fixture-job")
        self.assertEqual(data["syncs"][0]["lastResult"]["result"], "OK")
        self.assertEqual(data["syncs"][0]["lastResult"]["durationSeconds"], 5)

    def test_02_pending_and_stale_states_have_precedence(self) -> None:
        self.write_config(options={"omarchy": False, "favorites": True})
        self.favorites.mkdir(parents=True)
        (self.favorites / "favoritos-latest.tar.zst").write_text("fixture")
        self.state.mkdir(parents=True)
        now = int(__import__("time").time())
        (self.state / "last-run").write_text(f"{now - 3600}\told\tok\t0\t0\t\n")
        result = self.run_cli("status", "--json")
        self.assertEqual(json.loads(result.stdout)["favoritesState"], "pending")
        self.assertEqual(json.loads(result.stdout)["state"], "warning")

        self.write_config(options={"omarchy": False, "favorites": False})
        self.env["BACKUP_STALE_HOURS"] = "0"
        now = int(__import__("time").time())
        (self.state / "last-run").write_text(f"{now}\ttoday\tok\t0\t0\t\n")
        result = self.run_cli("status", "--json")
        self.assertEqual(json.loads(result.stdout)["state"], "stale")

    def test_03_verify_checks_read_only_and_disables_http2(self) -> None:
        self.write_config()
        result = self.run_cli("verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.rclone_calls_data()
        self.assertTrue(any(call[0] == "check" for call in calls))
        check = next(call for call in calls if call[0] == "check")
        self.assertIn("--disable-http2", check)
        self.assertNotIn(check[0], ("sync", "bisync", "copy"))
        self.assertIn("fixture-job", result.stdout)

    def test_04_copy_omits_archive_flag(self) -> None:
        self.write_config("copy")
        result = self.run_cli("syncs", "run", "fixture-job")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(call for call in self.rclone_calls_data() if call[0] == "copy")
        self.assertNotIn("--backup-dir", call)

    def test_05_sync_keeps_delete_limit_and_archive(self) -> None:
        self.write_config("sync")
        result = self.run_cli("syncs", "run", "fixture-job")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(call for call in self.rclone_calls_data() if call[0] == "sync")
        self.assertEqual(call[call.index("--max-delete") + 1], "50")
        self.assertIn("--backup-dir", call)

    def test_06_disabled_sync_is_skipped(self) -> None:
        self.write_config()
        data = json.loads(self.config.read_text())
        data["jobs"][0]["enabled"] = False
        self.config.write_text(json.dumps(data))
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] in ("copy", "sync", "bisync") for call in self.rclone_calls_data()))

    def test_07_global_resync_mode_reaches_bisync(self) -> None:
        self.write_config("bisync")
        result = self.run_cli("--resync-from-pc")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(call for call in self.rclone_calls_data() if call[0] == "bisync")
        self.assertEqual(call[call.index("--resync-mode") + 1], "path1")

    def test_08_empty_favorites_preserve_previous_snapshot(self) -> None:
        self.write_config(options={"omarchy": False, "favorites": True})
        self.favorites.mkdir(parents=True)
        archive = self.favorites / "favoritos-latest.tar.zst"
        archive.write_text("previous archive marker")
        result = self.run_cli("snapshot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(archive.read_text(), "previous archive marker")

    def test_09_gtk_bookmarks_redact_credentials(self) -> None:
        self.write_config(options={"omarchy": False, "favorites": True})
        gtk = self.config_root / "gtk-3.0"
        gtk.mkdir(parents=True)
        (gtk / "bookmarks").write_text(
            "https://user:fixture@example.test/path?access_token=fixture#token=fixture Label\n"
        )
        result = self.run_cli("snapshot")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = subprocess.check_output(
            ["tar", "--zstd", "-xOf", str(self.favorites / "favoritos-latest.tar.zst"), "favorites/gtk/bookmarks.txt"],
            text=True,
        )
        self.assertIn("REDACTED", content)
        self.assertNotIn("fixture", content)
        self.assertNotIn("user:", content)

    def test_10_chromium_bookmarks_redact_credentials(self) -> None:
        self.write_config(options={"omarchy": False, "favorites": True})
        profile = self.config_root / "chromium" / "Default"
        profile.mkdir(parents=True)
        (profile / "Bookmarks").write_text(
            json.dumps(
                {
                    "roots": {
                        "bookmark_bar": {
                            "type": "folder",
                            "name": "Bar",
                            "children": [
                                {
                                    "type": "url",
                                    "name": "Fixture",
                                    "url": "https://user:password@example.test/?token=fixture-secret",
                                }
                            ],
                        }
                    }
                }
            )
        )
        result = self.run_cli("snapshot")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = subprocess.check_output(
            ["tar", "--zstd", "-xOf", str(self.favorites / "favoritos-latest.tar.zst"), "favorites/chromium/Default.json"],
            text=True,
        )
        self.assertIn("REDACTED", content)
        self.assertNotIn("fixture-secret", content)
        self.assertNotIn("user:password", content)

    def test_11_firefox_exports_bookmarks_read_only_and_sanitized(self) -> None:
        self.write_config(options={"omarchy": False, "favorites": True})
        profile = self.config_root / "mozilla" / "firefox" / "fixture.default"
        profile.mkdir(parents=True)
        connection = sqlite3.connect(profile / "places.sqlite")
        connection.executescript("""
            CREATE TABLE moz_bookmarks (id INTEGER, parent INTEGER, position INTEGER, type INTEGER, title TEXT, fk INTEGER);
            CREATE TABLE moz_places (id INTEGER, url TEXT);
            INSERT INTO moz_places VALUES (1, 'https://user:password@example.test/?token=fixture-secret');
            INSERT INTO moz_bookmarks VALUES (2, 1, 0, 1, 'Fixture', 1);
        """)
        connection.commit()
        connection.close()
        result = self.run_cli("snapshot")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = subprocess.check_output(
            ["tar", "--zstd", "-xOf", str(self.favorites / "favoritos-latest.tar.zst"), "favorites/firefox/fixture.default.json"],
            text=True,
        )
        self.assertIn("REDACTED", content)
        self.assertNotIn("fixture-secret", content)

    def test_12_secret_in_config_blocks_snapshot(self) -> None:
        self.write_config(options={"omarchy": True, "favorites": False})
        self.make_config_snapshot_inputs()
        (self.config_root / "hypr" / "hyprland.conf").write_text("AWS_SECRET_ACCESS_KEY=fixture-only-value\n")
        result = self.run_cli("snapshot")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("possivel segredo detectado", result.stdout + result.stderr)
        self.assertFalse((self.config_snapshots / "config-latest.tar.zst").exists())

    def test_13_source_code_credential_words_do_not_block_snapshot(self) -> None:
        self.write_config(options={"omarchy": True, "favorites": False})
        self.make_config_snapshot_inputs()
        plugin = self.config_root / "omarchy" / "plugins" / "yubikey"
        (plugin / "tests").mkdir(parents=True)
        (plugin / "bridge.py").write_text('password = ""\n')
        (plugin / "Panel.qml").write_text('readonly property string password: ""\n')
        (plugin / "tests" / "test_bridge.py").write_text('fixture = b"credential"\n')
        result = self.run_cli("snapshot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.config_snapshots / "config-latest.tar.zst").is_file())

    def test_14_snapshot_target_rejects_traversal_atomically(self) -> None:
        self.write_config()
        before = self.config.read_bytes()
        for path in ("../outside", None):
            result = self.run_cli("syncs", "snapshot-target", "--json", json.dumps({"syncId": "fixture-job", "path": path}))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.config.read_bytes(), before)

    def test_15_config_writes_are_private(self) -> None:
        self.write_config()
        result = self.run_cli("syncs", "set-enabled", "fixture-job", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertFalse(json.loads(self.config.read_text())["jobs"][0]["enabled"])

    def test_16_remote_listing_projects_safe_fields(self) -> None:
        result = self.run_cli("syncs", "remotes", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"remotes": [{"name": "Mock", "type": "local"}]})
        self.assertNotIn("must-not-leak", result.stdout)
        self.assertNotIn("private fixture", result.stdout)

    def test_17_invalid_sync_edit_preserves_existing_config(self) -> None:
        self.write_config()
        before = self.config.read_bytes()
        invalid = {"id": "fixture-job", "name": "Fixture", "source": "/tmp", "destination": "Mock:other", "mode": "unknown", "enabled": True, "exclude": []}
        result = self.run_cli("syncs", "upsert", "--json", json.dumps(invalid))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_18_boolean_version_is_rejected(self) -> None:
        self.write_config()
        data = json.loads(self.config.read_text())
        data["version"] = True
        self.config.write_text(json.dumps(data))
        result = self.run_cli("syncs", "list", "--json")
        self.assertNotEqual(result.returncode, 0)

    def test_19_verify_restores_config_snapshot(self) -> None:
        self.write_config(options={"omarchy": True, "favorites": False})
        self.make_config_snapshot_inputs()
        snapshot = self.run_cli("snapshot")
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        result = self.run_cli("verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("snapshots locais ativos estao integros", result.stdout)

    def test_20_bisync_baseline_is_job_scoped_and_dry_run_neutral(self) -> None:
        self.write_config("bisync")
        result = self.run_cli("syncs", "run", "fixture-job", "--resync", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.state / "baselines" / "fixture-job.init").exists())
        calls = self.rclone_calls_data()
        self.assertTrue(any("--dry-run" in call for call in calls))
        result = self.run_cli("syncs", "run", "fixture-job", "--resync")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state / "baselines" / "fixture-job.init").is_file())

    def test_21_unicode_source_path_stays_one_argument(self) -> None:
        self.write_config()
        unicode_source = self.home / "Área Pessoal" / "資料"
        unicode_source.mkdir(parents=True)
        data = json.loads(self.config.read_text())
        data["jobs"][0]["source"] = str(unicode_source)
        self.config.write_text(json.dumps(data, ensure_ascii=False))
        result = self.run_cli("syncs", "run", "fixture-job")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(call for call in self.rclone_calls_data() if call[0] == "copy")
        self.assertIn(str(unicode_source), call)

    def test_22_cli_has_no_shell_compatibility_entrypoint(self) -> None:
        shell_scripts = [path for path in ROOT.rglob("*.sh") if ".git" not in path.parts]
        self.assertEqual(shell_scripts, [])

    def test_23_first_use_migrates_legacy_job_without_sync(self) -> None:
        self.env["BACKUP_FILEN_REMOTE"] = "Mock"
        result = self.run_cli("syncs", "list", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        jobs = json.loads(result.stdout)
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]["id"], "personal-filen")
        self.assertEqual(jobs[0]["destination"], "Mock:personal")
        self.assertEqual(jobs[0]["mode"], "bisync")
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertFalse(any(call[0] in ("copy", "sync", "bisync") for call in self.rclone_calls_data()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
