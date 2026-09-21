"""Fault-injection coverage for the destructive read-and-return boundary."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import card_backup_move as backup

CARD = "a" * 27 + "="
UDID = f"test-device-{os.getpid()}"


def ok(**fields):
    return {"exitCode": 0, "targetGatePassed": True, "operation": {"ok": True, **fields}}


class FakeDevice:
    def __init__(self):
        self.originals = {leaf: (b"%PDF-1.4" if leaf.endswith(".pdf") else b"\x89PNG\r\n\x1a\n") + leaf.encode()
                          for leaf in backup.ARTWORK_FILES}
        self.initial = dict(self.originals)
        self.media = {}
        self.commands = []
        self.transfers = []
        self.return_failures = 0
        self.export_failures = 0
        self.stat_unknown = False
        self.fail_on_second_export = False
        self.export_count = 0
        self.cleanup_calls = 0
        self.mutate_readback = False
        self.disconnect_after_move = False
        self.consumed_ids = set()
        self.journal_seen = []

    def native(self, command, udid, *arguments):
        self.commands.append(command)
        if command in ("finish-write", "finish"):
            raise AssertionError("Destructive cleanup must never be called")
        if command == "snapshot-books":
            (Path(arguments[0]) / "manifest.plist").write_text("{}")
            return ok()
        if command == "stage":
            return ok(cleanupAuthorized=True)
        if command in ("refresh-move-books", "refresh-original-books"):
            self.consumed_ids.clear()
            return ok()
        if command == "recovered-status":
            if self.stat_unknown:
                return {"exitCode": 2, "targetGatePassed": True,
                        "operation": {"ok": False, "presence": "unknown", "exists": None}}
            present = arguments[0] in self.media
            return ok(presence="present" if present else "absent", exists=present)
        if command == "export-recovered-artwork":
            self.export_count += 1
            if self.export_failures or (self.fail_on_second_export and self.export_count == 2):
                if self.export_failures:
                    self.export_failures -= 1
                raise RuntimeError("simulated export failure")
            recovered, leaf, directory = arguments
            with (Path(directory) / leaf).open("xb") as stream:
                stream.write(self.media[recovered])
            return ok()
        if command == "finish-move-backup":
            self.cleanup_calls += 1
            if arguments[2] in self.media:
                raise AssertionError("Cleanup attempted with original still relocated")
            return ok(cleanupComplete=True)
        raise AssertionError(command)

    def transfer(self, command, timeout):
        _, udid, identifier, destination = command
        self.transfers.append((identifier, destination))
        if identifier in self.consumed_ids:
            raise RuntimeError("Books ID was consumed; refresh was missing")
        self.consumed_ids.add(identifier)
        if "/p0/p1/p2/link" in identifier:
            return {"exitCode": 0, "ok": True}
        if destination.startswith("airlift-recovered-"):
            leaf = identifier.rsplit("/", 1)[-1]
            self.media[destination] = self.originals.pop(leaf)
            if self.mutate_readback and self.export_count > 0:
                self.media[destination] += b" changed"
            if self.disconnect_after_move:
                self.stat_unknown = True
                raise subprocess.TimeoutExpired("airtraffic_host", timeout)
        else:
            if self.return_failures:
                self.return_failures -= 1
                raise subprocess.TimeoutExpired("airtraffic_host", timeout)
            recovered = identifier.removeprefix("../../")
            leaf = destination.rsplit("/", 1)[-1]
            self.originals[leaf] = self.media.pop(recovered)
        return {"exitCode": 0, "ok": True}


class MoveBackupTests(unittest.TestCase):
    def patch_device(self, device):
        for mock in (patch.object(backup, "native", side_effect=device.native),
                     patch.object(backup, "run_json", side_effect=device.transfer),
                     patch.object(backup.time, "sleep")):
            mock.start()
            self.addCleanup(mock.stop)

    def test_complete_backup_roundtrips_exact_bytes_and_records_limit(self):
        device = FakeDevice()
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_card_by_move(UDID, CARD, parent)
            self.assertTrue(result["ok"], result.get("error"))
            self.assertEqual(device.originals, device.initial)
            self.assertEqual(device.media, {})
            self.assertEqual(device.cleanup_calls, 3)
            self.assertEqual(device.export_count, 6)
            self.assertFalse(result["final_destination_directly_verified"])
            self.assertFalse(result["safe_for_automatic_flash"])
            for row in result["operations"]:
                self.assertTrue(row["readback_sha256_match"])
                self.assertEqual((Path(result["path"]) / row["leaf"]).read_bytes(), device.initial[row["leaf"]])
            self.assertEqual(json.loads((Path(result["path"]) / "manifest.json").read_text()), result)

    def test_journal_identifies_exact_pending_move_before_transfer(self):
        device = FakeDevice()
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            original_transfer = device.transfer
            def transfer(command, timeout):
                journals = list(Path(parent).glob("*/.recovery/state.json"))
                self.assertEqual(len(journals), 1)
                state = json.loads(journals[0].read_text())
                row = state["operations"][-1]
                self.assertTrue(row["phase"].endswith("_intent"))
                self.assertEqual(row["last_dispatch"]["identifier"], command[2])
                self.assertEqual(row["last_dispatch"]["destination"], command[3])
                self.assertEqual(state["device"], UDID)
                return original_transfer(command, timeout)
            with patch.object(backup, "run_json", side_effect=transfer):
                self.assertTrue(backup.backup_card_by_move(UDID, CARD, parent)["ok"])

    def test_export_failure_returns_original_stops_and_preserves_snapshot(self):
        device = FakeDevice()
        device.export_failures = 1
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_card_by_move(UDID, CARD, parent)
            self.assertFalse(result["ok"])
            self.assertEqual(device.originals, device.initial)
            self.assertEqual(len(result["operations"]), 1)
            self.assertEqual(device.cleanup_calls, 0)
            self.assertTrue(result["recovery_required"])
            self.assertTrue((Path(result["recovery_path"]) / "state.json").is_file())

    def test_failed_return_keeps_only_remote_copy_and_snapshot(self):
        device = FakeDevice()
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_card_by_move(UDID, CARD, parent)
            self.assertFalse(result["ok"])
            self.assertTrue(device.media)
            self.assertNotIn(backup.ARTWORK_FILES[0], device.originals)
            self.assertEqual(device.cleanup_calls, 0)
            self.assertEqual(len(result["operations"]), 1)
            self.assertTrue(Path(result["operations"][0]["snapshot"]).is_dir())

    def test_same_device_recovery_restores_pending_file_not_later_leaves(self):
        device = FakeDevice()
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_card_by_move(UDID, CARD, parent)
            device.return_failures = 0
            resumed = backup.recover_move_backup(UDID, failed["path"])
            self.assertTrue(resumed.get("recovery_completed"), resumed.get("error"))
            self.assertFalse(resumed["ok"], "Only one file is a partial backup")
            self.assertEqual(device.originals, device.initial)
            self.assertEqual(len(resumed["operations"]), 1)
            self.assertEqual(device.cleanup_calls, 1)

    def test_export_failure_rescue_baseline_can_be_recovered(self):
        device = FakeDevice()
        device.export_failures = 1
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_card_by_move(UDID, CARD, parent)
            resumed = backup.recover_move_backup(UDID, failed["path"])
            self.assertTrue(resumed.get("recovery_completed"), resumed.get("error"))
            self.assertFalse(resumed["ok"])
            self.assertEqual(device.originals, device.initial)
            self.assertEqual(len(resumed["files"]), 1)
            self.assertTrue(Path(resumed["files"][0]["path"]).is_file())
            self.assertEqual(device.cleanup_calls, 1)

    def test_all_exports_failed_but_returned_can_establish_recovery_baseline(self):
        device = FakeDevice()
        device.export_failures = 2
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_card_by_move(UDID, CARD, parent)
            self.assertNotIn("file", failed["operations"][0])
            self.assertEqual(device.originals, device.initial)
            resumed = backup.recover_move_backup(UDID, failed["path"])
            self.assertTrue(resumed.get("recovery_completed"), resumed.get("error"))
            self.assertFalse(resumed["ok"])
            self.assertTrue(resumed["operations"][0]["readback_sha256_match"])
            self.assertEqual(device.originals, device.initial)
            self.assertTrue(Path(resumed["files"][0]["path"]).is_file())

    def test_same_device_lock_spans_different_output_directories(self):
        with tempfile.TemporaryDirectory() as parent:
            with backup.move_device_lock(UDID), patch.object(backup, "native") as native:
                result = backup.backup_card_by_move(UDID, CARD, parent)
                self.assertFalse(result["ok"])
                self.assertIn("already using this device", result["error"])
                native.assert_not_called()
            self.assertEqual(list(Path(parent).iterdir()), [])

    def test_rescue_keeps_device_lock_until_finished(self):
        device = FakeDevice()
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_card_by_move(UDID, CARD, parent)
            original_rescue = backup._rescue
            def rescue(state, row):
                with self.assertRaises(backup.MoveBackupError):
                    with backup.move_device_lock(UDID):
                        pass
                return original_rescue(state, row)
            with patch.object(backup, "_rescue", side_effect=rescue):
                self.assertFalse(backup.recover_move_backup(UDID, failed["path"])["ok"])

    def test_wrong_device_recovery_never_touches_device(self):
        device = FakeDevice()
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_card_by_move(UDID, CARD, parent)
            count = len(device.commands)
            resumed = backup.recover_move_backup("different-device", failed["path"])
            self.assertFalse(resumed["ok"])
            self.assertEqual(len(device.commands), count)

    def test_unknown_status_never_means_success_or_cleanup(self):
        device = FakeDevice()
        device.disconnect_after_move = True
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_card_by_move(UDID, CARD, parent)
            self.assertFalse(result["ok"])
            self.assertTrue(device.media)
            self.assertEqual(device.cleanup_calls, 0)
            self.assertTrue(result["recovery_required"])

    def test_absent_copy_after_timeout_is_not_proof_of_return(self):
        device = FakeDevice()
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_card_by_move(UDID, CARD, parent)
            device.media.clear()  # disconnect/reboot/external action: no positive return evidence
            resumed = backup.recover_move_backup(UDID, failed["path"])
            self.assertFalse(resumed["ok"])
            self.assertIn("location remains uncertain", resumed["error"])
            self.assertEqual(device.cleanup_calls, 0)

    def test_readback_mismatch_is_returned_but_prevents_later_artwork(self):
        device = FakeDevice()
        device.mutate_readback = True
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_card_by_move(UDID, CARD, parent)
            self.assertFalse(result["ok"])
            self.assertFalse(result["operations"][0]["readback_sha256_match"])
            self.assertEqual(device.media, {})
            self.assertEqual(device.cleanup_calls, 0)
            self.assertEqual(len(result["operations"]), 1)
            self.assertEqual(device.originals[backup.ARTWORK_FILES[1]], device.initial[backup.ARTWORK_FILES[1]])

    def test_invalid_hash_and_missing_output_do_not_call_native(self):
        with tempfile.TemporaryDirectory() as parent:
            with patch.object(backup, "native") as native:
                for value in ("../" + CARD, CARD + "\n", "a" * 100):
                    self.assertFalse(backup.backup_card_by_move(UDID, value, parent)["ok"])
                self.assertFalse(backup.backup_card_by_move(UDID, CARD, parent + "/missing")["ok"])
                native.assert_not_called()
            self.assertEqual(list(Path(parent).iterdir()), [])

    def test_repeat_backup_uses_unique_directories(self):
        device = FakeDevice()
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            first = backup.backup_card_by_move(UDID, CARD, parent)
            second = backup.backup_card_by_move(UDID, CARD, parent)
            self.assertTrue(first["ok"])
            self.assertTrue(second["ok"])
            self.assertNotEqual(first["path"], second["path"])

    def test_tampered_recovery_paths_never_touch_device(self):
        device = FakeDevice()
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_card_by_move(UDID, CARD, parent)
            path = Path(failed["recovery_path"]) / "state.json"
            state = json.loads(path.read_text())
            state["operations"][0]["target_identifier"] = "../../../Library/other"
            path.write_text(json.dumps(state))
            count = len(device.commands)
            self.assertFalse(backup.recover_move_backup(UDID, failed["path"])["ok"])
            self.assertEqual(len(device.commands), count)

    def test_original_cache_exports_exact_raw_bytes_and_discloses_undecoded(self):
        device = FakeDevice()
        data = b"bplist00" + bytes(range(32))
        device.originals = {"FrontFace": data}
        device.initial = dict(device.originals)
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_original_asset(UDID, CARD, "cache", "FrontFace", parent)
            self.assertTrue(result["ok"], result.get("error"))
            self.assertTrue(result["raw_asset_exported"])
            self.assertFalse(result["decoded_card_image"])
            self.assertFalse(result["complete_card_artwork_backup"])
            self.assertEqual(result["mode"], "original_asset")
            self.assertEqual(len(result["operations"]), 1)
            self.assertEqual(device.originals, device.initial)
            self.assertEqual((Path(result["path"]) / "FrontFace").read_bytes(), data)
            self.assertIn("refresh-original-books", device.commands)
            self.assertNotIn("refresh-move-books", device.commands)
            self.assertEqual(result["source"], f"/var/mobile/Library/Passes/Cards/{CARD}.cache")

    def test_original_png_keeps_format_check_and_single_asset_scope(self):
        device = FakeDevice()
        data = b"\x89PNG\r\n\x1a\noriginal strip"
        device.originals = {"strip@3x.png": data}
        device.initial = dict(device.originals)
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_original_asset(UDID, CARD, "pkpass", "strip@3x.png", parent)
            self.assertTrue(result["ok"], result.get("error"))
            self.assertFalse(result["raw_asset_exported"])
            self.assertEqual(result["artifact_type"], "source_visual_asset")
            self.assertEqual(device.originals, device.initial)
            self.assertEqual(device.export_count, 2)

    def test_original_mode_rejects_metadata_and_container_traversal(self):
        with tempfile.TemporaryDirectory() as parent, patch.object(backup, "native") as native:
            for container, leaf in (("pkpass", "pass.json"), ("pkpass", "FrontFace"),
                                    ("cache", "logo.png"), ("../cache", "FrontFace"),
                                    ("cache", "../FrontFace"), ("pkcache", "Preview\n"),
                                    ("pkpass", "private.urls"), ("cache", "cardBackgroundCombined.urls")):
                self.assertFalse(backup.backup_original_asset(UDID, CARD, container, leaf, parent)["ok"])
            native.assert_not_called()
            self.assertEqual(list(Path(parent).iterdir()), [])

    def test_fixed_original_sidecar_exports_raw_without_claiming_image(self):
        device = FakeDevice()
        leaf = "cardBackgroundCombined@3x.png.urls"
        data = b"opaque sidecar bytes, not a PNG"
        device.originals = {leaf: data}
        device.initial = dict(device.originals)
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_original_asset(UDID, CARD, "pkpass", leaf, parent)
            self.assertTrue(result["ok"], result.get("error"))
            self.assertTrue(result["raw_asset_exported"])
            self.assertFalse(result["decoded_card_image"])
            self.assertEqual(result["artifact_type"], "raw_visual_asset_sidecar")
            self.assertEqual((Path(result["path"]) / leaf).read_bytes(), data)
            self.assertEqual(device.originals, device.initial)

    def test_original_cache_return_failure_recovery_keeps_exact_source(self):
        device = FakeDevice()
        device.originals = {"Preview": b"bplist00opaque preview"}
        device.initial = dict(device.originals)
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_original_asset(UDID, CARD, "pkcache", "Preview", parent)
            self.assertFalse(failed["ok"])
            self.assertTrue(device.media)
            self.assertEqual(device.cleanup_calls, 0)
            device.return_failures = 0
            recovered = backup.recover_move_backup(UDID, failed["path"])
            self.assertTrue(recovered.get("recovery_completed"), recovered.get("error"))
            self.assertTrue(recovered["ok"])
            self.assertTrue(recovered["raw_asset_exported"])
            self.assertEqual(device.originals, device.initial)
            self.assertTrue(all(f"{CARD}.pkcache/Preview" in identifier for identifier, destination in device.transfers
                                if destination.startswith("airlift-recovered-")))

    def test_missing_original_asset_stops_without_trying_other_names(self):
        device = FakeDevice()
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            result = backup.backup_original_asset(UDID, CARD, "cache", "FrontFace", parent)
            self.assertFalse(result["ok"])
            self.assertTrue(result["recovery_required"])
            self.assertEqual(device.cleanup_calls, 0)
            self.assertEqual(device.originals, device.initial)
            self.assertEqual(len(result["operations"]), 1)
            self.assertEqual(len(device.transfers), 2)

    def test_original_recovery_rejects_changed_container_or_asset_set(self):
        device = FakeDevice()
        device.originals = {"FrontFace": b"bplist00original"}
        device.return_failures = 10
        self.patch_device(device)
        with tempfile.TemporaryDirectory() as parent:
            failed = backup.backup_original_asset(UDID, CARD, "cache", "FrontFace", parent)
            path = Path(failed["recovery_path"]) / "state.json"
            original_state = json.loads(path.read_text())
            count = len(device.commands)
            for key, value in (("container", "pkcache"), ("asset_names", ["FrontFace", "Preview"]),
                               ("asset_names", ["pass.json"]), ("mode", "experimental_move")):
                state = dict(original_state)
                state[key] = value
                path.write_text(json.dumps(state))
                self.assertFalse(backup.recover_move_backup(UDID, failed["path"])["ok"])
                self.assertEqual(len(device.commands), count)


if __name__ == "__main__":
    unittest.main()
