import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import aircard_backend as backend


CARD = "a" * 27 + "="


def ok(**fields):
    return {"exitCode": 0, "targetGatePassed": True, "operation": {"ok": True, **fields}}


class CardBackupTests(unittest.TestCase):
    def run_backup(self, root, fail=None, card=CARD):
        def native(command, *args):
            if command == fail:
                if command == "stage":
                    raise subprocess.TimeoutExpired("device_helper", 60)
                return {"exitCode": 2, "targetGatePassed": True,
                        "operation": {"ok": False, "error": "artwork_read_unavailable",
                                      "message": "AFC denied access"}}
            if command == "export-card-artwork":
                for leaf in backend.ARTWORK_FILES:
                    signature = b"%PDF-1.4" if leaf.endswith(".pdf") else b"\x89PNG\r\n\x1a\n"
                    (Path(args[-1]) / leaf).write_bytes(signature + b"original bytes")
            return ok()

        output = io.StringIO()
        with (patch.object(backend, "native", side_effect=native) as helper,
              patch.object(backend, "run_json", return_value={"ok": True, "exitCode": 0}) as atc,
              patch.object(backend, "write_file") as write,
              patch.object(backend, "write_files_batch") as batch,
              redirect_stdout(output)):
            success = backend.cmd_backup_card("device", card, str(root))
        write.assert_not_called()
        batch.assert_not_called()
        return success, json.loads(output.getvalue()), helper, atc

    def test_complete_backup_preserves_exact_bytes_and_records_hashes(self):
        with tempfile.TemporaryDirectory() as root:
            success, result, helper, atc = self.run_backup(root)
            self.assertTrue(success)
            backup = Path(result["path"])
            self.assertEqual({p.name for p in backup.iterdir()}, set(backend.ARTWORK_FILES) | {"manifest.json"})
            self.assertTrue(result["cleanup_complete"])
            self.assertEqual(len(result["files"]), 3)
            self.assertTrue(all(len(row["sha256"]) == 64 for row in result["files"]))
            self.assertEqual(json.loads((backup / "manifest.json").read_text()), result)
            self.assertEqual([c.args[0] for c in helper.call_args_list],
                             ["snapshot-books", "stage", "export-card-artwork", "finish-write"])
            # Exactly one AirTraffic operation: move only the generated link.
            command = atc.call_args.args[0]
            self.assertEqual(len(command), 4)
            self.assertTrue(command[2].endswith("/p0/p1/p2/link"))
            self.assertTrue(command[3].startswith("airlift-link-"))

    def test_repeat_backup_never_overwrites_previous_files(self):
        with tempfile.TemporaryDirectory() as root:
            _, first, _, _ = self.run_backup(root)
            _, second, _, _ = self.run_backup(root)
            self.assertNotEqual(first["path"], second["path"])
            self.assertTrue(Path(first["path"]).is_dir())

    def test_afc_denial_fails_closed_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as root:
            success, result, helper, _ = self.run_backup(root, "export-card-artwork")
            self.assertFalse(success)
            self.assertEqual(result["error_code"], "artwork_read_unavailable")
            self.assertEqual(helper.call_args.args[0], "finish-write")
            self.assertFalse(json.loads((Path(result["path"]) / "manifest.json").read_text())["ok"])

    def test_stage_timeout_still_attempts_cleanup(self):
        with tempfile.TemporaryDirectory() as root:
            success, _, helper, atc = self.run_backup(root, "stage")
            self.assertFalse(success)
            self.assertEqual(helper.call_args.args[0], "finish-write")
            atc.assert_not_called()

    def test_native_read_diagnostics_survive_manifest_and_cleanup(self):
        diagnostics = {
            "link": {"fileInfoStatus": 0, "metadata": {"st_ifmt": "S_IFLNK"}},
            "artwork": {"phase": "stat", "fileInfoStatus": 8, "bytesRead": 0},
        }
        def native(command, *args):
            if command == "export-card-artwork":
                return {
                    "exitCode": 2, "targetGatePassed": True,
                    "operation": {
                        "ok": False, "error": "artwork_read_unavailable",
                        "leaf": backend.ARTWORK_FILES[0],
                        "message": "Artwork stat failed (AFC status 8).",
                        "diagnostics": diagnostics,
                    },
                }
            return ok()

        output = io.StringIO()
        with tempfile.TemporaryDirectory() as root:
            with (patch.object(backend, "native", side_effect=native) as helper,
                  patch.object(backend, "run_json", return_value={"ok": True, "exitCode": 0}),
                  redirect_stdout(output)):
                self.assertFalse(backend.cmd_backup_card("device", CARD, root))
            result = json.loads(output.getvalue())
            saved = json.loads((Path(result["path"]) / "manifest.json").read_text())
            self.assertEqual(result["diagnostics"], diagnostics)
            self.assertEqual(saved["diagnostics"], diagnostics)
            self.assertEqual(result["failure_phase"], "export_artwork")
            self.assertTrue(result["cleanup_complete"])
            self.assertEqual(helper.call_args.args[0], "finish-write")

    def test_failed_snapshot_does_not_stage_or_cleanup(self):
        with tempfile.TemporaryDirectory() as root:
            success, _, helper, atc = self.run_backup(root, "snapshot-books")
            self.assertFalse(success)
            self.assertEqual(helper.call_count, 1)
            atc.assert_not_called()

    def test_failed_cleanup_keeps_recovery_inputs_and_is_not_success(self):
        with tempfile.TemporaryDirectory() as root:
            success, result, _, _ = self.run_backup(root, "finish-write")
            self.assertFalse(success)
            self.assertEqual(result["error_code"], "cleanup_failed")
            self.assertTrue((Path(result["recovery_path"]) / "cleanup.json").is_file())

    def test_invalid_hashes_never_touch_device_or_create_directories(self):
        with tempfile.TemporaryDirectory() as root:
            for card in ("../" + "a" * 25, "/" + "a" * 27, "a" * 20 + "/b", "a" * 20 + "\n", "a" * 100):
                success, _, helper, atc = self.run_backup(root, card=card)
                self.assertFalse(success)
                helper.assert_not_called()
                atc.assert_not_called()
            self.assertEqual(list(Path(root).iterdir()), [])

    def test_output_must_exist(self):
        with tempfile.TemporaryDirectory() as root:
            success, _, helper, _ = self.run_backup(Path(root) / "missing")
            self.assertFalse(success)
            helper.assert_not_called()

    def test_output_with_spaces_and_shell_characters_is_literal(self):
        with tempfile.TemporaryDirectory() as root:
            parent = Path(root) / "my backup $(not-a-command)"
            parent.mkdir()
            success, result, _, _ = self.run_backup(parent)
            self.assertTrue(success)
            self.assertEqual(Path(result["path"]).parent, parent.resolve())

    def test_airtraffic_error_always_cleans_up(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as root:
            with (patch.object(backend, "native", return_value=ok()) as helper,
                  patch.object(backend, "run_json", side_effect=RuntimeError("sync failed")),
                  redirect_stdout(output)):
                self.assertFalse(backend.cmd_backup_card("device", CARD, root))
            self.assertEqual(helper.call_args.args[0], "finish-write")

    def test_helper_success_without_files_is_not_a_backup(self):
        with tempfile.TemporaryDirectory() as root:
            with (patch.object(backend, "native", return_value=ok()),
                  patch.object(backend, "run_json", return_value={"ok": True, "exitCode": 0}),
                  redirect_stdout(io.StringIO())):
                self.assertFalse(backend.cmd_backup_card("device", CARD, root))

    def test_rejected_stage_does_not_clean_up_unauthorized_paths(self):
        with tempfile.TemporaryDirectory() as root:
            rejected = {"exitCode": 2, "targetGatePassed": True,
                        "operation": {"ok": False, "cleanupAuthorized": False}}
            with (patch.object(backend, "native", side_effect=[ok(), rejected]) as helper,
                  patch.object(backend, "run_json") as atc,
                  redirect_stdout(io.StringIO())):
                self.assertFalse(backend.cmd_backup_card("device", CARD, root))
            self.assertEqual(helper.call_count, 2)
            atc.assert_not_called()

    def test_partial_files_are_retained_but_marked_incomplete(self):
        def native(command, *args):
            if command == "export-card-artwork":
                (Path(args[-1]) / backend.ARTWORK_FILES[0]).write_bytes(b"\x89PNG\r\n\x1a\npartial")
                return {"exitCode": 2, "targetGatePassed": True,
                        "operation": {"ok": False, "error": "artwork_read_unavailable"}}
            return ok()
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as root:
            with (patch.object(backend, "native", side_effect=native),
                  patch.object(backend, "run_json", return_value={"ok": True, "exitCode": 0}),
                  redirect_stdout(output)):
                self.assertFalse(backend.cmd_backup_card("device", CARD, root))
            result = json.loads(output.getvalue())
            backup = Path(result["path"])
            self.assertTrue((backup / backend.ARTWORK_FILES[0]).is_file())
            self.assertFalse(json.loads((backup / "manifest.json").read_text())["ok"])

    def test_invalid_artwork_signature_fails_validation(self):
        def native(command, *args):
            if command == "export-card-artwork":
                for leaf in backend.ARTWORK_FILES:
                    (Path(args[-1]) / leaf).write_bytes(b"not artwork")
            return ok()
        with tempfile.TemporaryDirectory() as root:
            with (patch.object(backend, "native", side_effect=native) as helper,
                  patch.object(backend, "run_json", return_value={"ok": True, "exitCode": 0}),
                  redirect_stdout(io.StringIO())):
                self.assertFalse(backend.cmd_backup_card("device", CARD, root))
            self.assertEqual(helper.call_args.args[0], "finish-write")


if __name__ == "__main__":
    unittest.main()
