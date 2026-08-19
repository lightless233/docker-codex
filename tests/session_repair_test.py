#!/usr/bin/env python3
import json
import os
import re
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
REPAIR = ROOT / "container-codex-session-repair"
OLD_PREFIX = "/codex-home/sessions/"


class SessionRepairTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(prefix="docker-codex-repair.")
        self.addCleanup(self.tempdir.cleanup)
        self.base = Path(self.tempdir.name)
        self.home = self.base / "codex home"
        (self.home / "sessions").mkdir(parents=True)
        self.db = self.home / "state_5.sqlite"
        self.connection = sqlite3.connect(self.db)
        self.addCleanup(self.connection.close)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA wal_autocheckpoint=0")
        self.connection.execute(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT)"
        )
        self.connection.commit()

    def write_session(self, relative: str, session_id: str, *, valid_json=True):
        path = self.home / "sessions" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if valid_json:
            metadata = {
                "timestamp": "2026-08-19T00:00:00Z",
                "type": "session_meta",
                "payload": {"id": session_id, "cwd": "/tmp/project"},
            }
            path.write_text(
                json.dumps(metadata)
                + "\n"
                + json.dumps(
                    {
                        "type": "response_item",
                        "payload": {"content": "DO-NOT-PRINT-SESSION-CONTENT"},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
        else:
            path.write_text("not-json\n", encoding="utf-8")
        return path

    def add_row(self, session_id: str, rollout_path: str):
        self.connection.execute(
            "INSERT INTO threads(id, rollout_path, title) VALUES (?, ?, ?)",
            (session_id, rollout_path, "secret title"),
        )
        self.connection.commit()

    def run_repair(self, home=None, *, timeout_seconds=None):
        env = os.environ.copy()
        env["CODEX_HOME"] = str(home or self.home)
        if timeout_seconds is not None:
            env["DOCKER_AGENT_SESSION_REPAIR_TIMEOUT_SECONDS"] = str(
                timeout_seconds
            )
        return subprocess.run(
            [str(REPAIR)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )

    def backup_path(self, output: str):
        match = re.search(r"^backup: (.+)$", output, re.MULTILINE)
        self.assertIsNotNone(match, output)
        return Path(match.group(1))

    def rollout_path(self, session_id: str, db=None):
        connection = db or self.connection
        row = connection.execute(
            "SELECT rollout_path FROM threads WHERE id = ?", (session_id,)
        ).fetchone()
        return row[0]

    def test_valid_wal_record_is_backed_up_migrated_and_idempotent(self):
        session_id = "session-valid"
        relative = "2026/08/19/rollout-valid.jsonl"
        self.write_session(relative, session_id)
        old_path = OLD_PREFIX + relative
        self.add_row(session_id, old_path)

        result = self.run_repair()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated: 1", result.stdout)
        self.assertIn("skipped: 0", result.stdout)
        self.assertNotIn("DO-NOT-PRINT", result.stdout + result.stderr)
        self.assertEqual(
            self.rollout_path(session_id), str(self.home / "sessions" / relative)
        )
        backup_path = self.backup_path(result.stdout)
        self.assertTrue(backup_path.is_file())
        self.assertEqual(backup_path.stat().st_mode & 0o777, 0o600)
        with sqlite3.connect(backup_path) as backup:
            self.assertEqual(self.rollout_path(session_id, backup), old_path)
            self.assertEqual(
                backup.execute("PRAGMA integrity_check").fetchone()[0], "ok"
            )

        second = self.run_repair()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("updated: 0", second.stdout)
        self.assertIn("skipped: 0", second.stdout)

    def test_only_valid_legacy_records_are_updated(self):
        valid_relative = "2026/08/19/valid.jsonl"
        self.write_session(valid_relative, "valid")
        self.add_row("valid", OLD_PREFIX + valid_relative)

        self.add_row("missing", OLD_PREFIX + "2026/08/19/missing.jsonl")
        self.write_session("2026/08/19/bad-json.jsonl", "bad-json", valid_json=False)
        self.add_row("bad-json", OLD_PREFIX + "2026/08/19/bad-json.jsonl")
        self.write_session("2026/08/19/mismatch.jsonl", "different-id")
        self.add_row("mismatch", OLD_PREFIX + "2026/08/19/mismatch.jsonl")

        unreadable = self.write_session("2026/08/19/unreadable.jsonl", "unreadable")
        unreadable.chmod(0)
        self.add_row("unreadable", OLD_PREFIX + "2026/08/19/unreadable.jsonl")

        outside = self.base / "outside.jsonl"
        outside.write_text(
            json.dumps({"type": "session_meta", "payload": {"id": "traversal"}})
            + "\n",
            encoding="utf-8",
        )
        self.add_row("traversal", OLD_PREFIX + "../../outside.jsonl")

        symlink = self.home / "sessions" / "2026" / "08" / "19" / "outside.jsonl"
        symlink.parent.mkdir(parents=True, exist_ok=True)
        symlink.symlink_to(outside)
        self.add_row("symlink", OLD_PREFIX + "2026/08/19/outside.jsonl")
        self.add_row("other", "/other-root/sessions/rollout.jsonl")

        result = self.run_repair()

        self.assertEqual(result.returncode, 0, result.stderr)
        unreadable_is_readable = os.access(unreadable, os.R_OK)
        expected_updated = 2 if unreadable_is_readable else 1
        expected_skipped = 5 if unreadable_is_readable else 6
        self.assertIn(f"updated: {expected_updated}", result.stdout)
        self.assertIn(f"skipped: {expected_skipped}", result.stdout)
        self.assertEqual(
            self.rollout_path("valid"), str(self.home / "sessions" / valid_relative)
        )
        skipped_ids = [
            "missing",
            "bad-json",
            "mismatch",
            "traversal",
            "symlink",
        ]
        if unreadable_is_readable:
            self.assertEqual(
                self.rollout_path("unreadable"),
                str(self.home / "sessions/2026/08/19/unreadable.jsonl"),
            )
        else:
            skipped_ids.append("unreadable")
        for session_id in skipped_ids:
            self.assertTrue(self.rollout_path(session_id).startswith(OLD_PREFIX))
        self.assertEqual(
            self.rollout_path("other"), "/other-root/sessions/rollout.jsonl"
        )
        self.assertNotIn("secret title", result.stdout + result.stderr)

    def test_logical_symlink_is_preserved_in_updated_paths(self):
        physical_home = self.home
        logical_home = self.base / "logical codex home"
        logical_home.symlink_to(physical_home)
        relative = "2026/08/19/symlink-home.jsonl"
        self.write_session(relative, "logical")
        self.add_row("logical", OLD_PREFIX + relative)

        result = self.run_repair(logical_home)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.rollout_path("logical"), str(logical_home / "sessions" / relative)
        )
        self.assertTrue(str(self.backup_path(result.stdout)).startswith(str(logical_home)))

    def test_unknown_schema_fails_without_changing_rows(self):
        self.connection.close()
        self.connection = sqlite3.connect(self.db)
        self.connection.execute("DROP TABLE threads")
        self.connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY)")
        self.connection.commit()

        result = self.run_repair()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("schema", result.stderr.lower())

    def test_missing_and_corrupt_databases_fail_without_creating_backups(self):
        missing_home = self.base / "missing database home"
        missing_home.mkdir()
        missing = self.run_repair(missing_home)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("does not exist", missing.stderr)
        self.assertFalse((missing_home / "session-repair-backups").exists())

        self.connection.close()
        self.db.write_bytes(b"not a sqlite database")
        corrupt = self.run_repair()
        self.assertNotEqual(corrupt.returncode, 0)
        self.assertIn("database", corrupt.stderr.lower())
        self.assertFalse((self.home / "session-repair-backups").exists())

    def test_write_failure_rolls_back_every_update(self):
        for session_id in ("first", "second"):
            relative = f"2026/08/19/{session_id}.jsonl"
            self.write_session(relative, session_id)
            self.add_row(session_id, OLD_PREFIX + relative)
        self.connection.execute(
            """
            CREATE TRIGGER reject_second
            BEFORE UPDATE OF rollout_path ON threads
            WHEN NEW.id = 'second'
            BEGIN
              SELECT RAISE(ABORT, 'injected write failure');
            END
            """
        )
        self.connection.commit()

        result = self.run_repair()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update", result.stderr.lower())
        self.assertTrue(self.rollout_path("first").startswith(OLD_PREFIX))
        self.assertTrue(self.rollout_path("second").startswith(OLD_PREFIX))
        self.assertTrue(self.backup_path(result.stdout).is_file())

    def test_trigger_side_effect_is_detected_and_rolled_back(self):
        relative = "2026/08/19/side-effect.jsonl"
        self.write_session(relative, "side-effect")
        self.add_row("side-effect", OLD_PREFIX + relative)
        self.connection.execute("CREATE TABLE repair_audit (value TEXT)")
        self.connection.execute(
            """
            CREATE TRIGGER add_repair_audit
            AFTER UPDATE OF rollout_path ON threads
            BEGIN
              INSERT INTO repair_audit VALUES ('unexpected');
            END
            """
        )
        self.connection.commit()

        result = self.run_repair()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("side effects", result.stderr.lower())
        self.assertTrue(self.rollout_path("side-effect").startswith(OLD_PREFIX))
        count = self.connection.execute("SELECT count(*) FROM repair_audit").fetchone()[0]
        self.assertEqual(count, 0)
        self.assertTrue(self.backup_path(result.stdout).is_file())

    def test_persistent_write_lock_times_out_without_backup(self):
        relative = "2026/08/19/locked.jsonl"
        self.write_session(relative, "locked")
        self.add_row("locked", OLD_PREFIX + relative)
        self.connection.execute("BEGIN IMMEDIATE")

        result = self.run_repair(timeout_seconds=0.1)

        self.connection.rollback()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lock", result.stderr.lower())
        self.assertIn("exit", result.stderr.lower())
        backup_dir = self.home / "session-repair-backups"
        self.assertFalse(backup_dir.exists())
        self.assertTrue(self.rollout_path("locked").startswith(OLD_PREFIX))


if __name__ == "__main__":
    unittest.main(verbosity=2)
