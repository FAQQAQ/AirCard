import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import aircard_backend
import card_backup_move
import wallet_asset_decode


class MoveCLITests(unittest.TestCase):
    def invoke(self, arguments):
        stream = io.StringIO()
        code = 0
        with patch("sys.argv", ["aircard_backend.py", *arguments]), redirect_stdout(stream):
            try:
                aircard_backend.main()
            except SystemExit as error:
                code = error.code
        return code, json.loads(stream.getvalue())

    def test_missing_risk_acknowledgment_never_calls_move(self):
        with patch.object(card_backup_move, "backup_card_by_move") as run:
            code, result = self.invoke(["--backup-card-move", "device", "a" * 28, "/tmp"])
        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        run.assert_not_called()

    def test_explicit_move_has_no_flash_side_effect(self):
        with patch.object(card_backup_move, "backup_card_by_move", return_value={"ok": True}) as run, \
             patch.object(aircard_backend, "cmd_flash") as flash:
            code, result = self.invoke(["--backup-card-move", "device", "a" * 28, "/tmp", "--accept-move-risk"])
        self.assertEqual(code, 0)
        run.assert_called_once_with("device", "a" * 28, "/tmp")
        flash.assert_not_called()

    def test_recovery_exit_status_is_distinct_from_complete_backup(self):
        with patch.object(card_backup_move, "recover_move_backup", return_value={"ok": False, "recovery_completed": True}):
            code, result = self.invoke(["--recover-move-backup", "device", "/tmp/backup", "--accept-move-risk"])
        self.assertEqual(code, 0)
        self.assertFalse(result["ok"])

    def test_failed_recovery_exits_nonzero(self):
        with patch.object(card_backup_move, "recover_move_backup", return_value={"ok": False, "recovery_completed": False}):
            code, _ = self.invoke(["--recover-move-backup", "device", "/tmp/backup", "--accept-move-risk"])
        self.assertEqual(code, 1)

    def test_legacy_flash_obeys_experimental_device_lock(self):
        device = f"cli-lock-test-{os.getpid()}"
        with card_backup_move.move_device_lock(device), \
             patch.object(aircard_backend, "cmd_flash") as flash:
            code, result = self.invoke(["--flash", device, "a" * 28, "/tmp/image.png"])
        self.assertEqual(code, 1)
        self.assertIn("already using", result["error"])
        flash.assert_not_called()

    def original_export_result(self, directory):
        source = Path(directory) / "FrontFace"
        source.write_bytes(b"local raw cache fixture")
        return {"ok": True, "mode": "original_asset", "path": directory,
                "raw_asset_exported": True, "decoded_card_image": False,
                "complete_card_artwork_backup": False, "cleanup_complete": True,
                "files": [{"name": "FrontFace", "path": str(source)}]}

    def test_original_cache_requires_explicit_risk_acknowledgment(self):
        with patch.object(card_backup_move, "backup_original_asset") as export, \
             patch.object(wallet_asset_decode, "decode_asset") as decode:
            code, result = self.invoke(["--backup-original-asset", "device", "a" * 28,
                                        "cache", "FrontFace", "/tmp"])
        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        export.assert_not_called()
        decode.assert_not_called()

    def test_original_cache_export_runs_decoder_and_saves_extraction_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            exported = self.original_export_result(directory)
            decoded = {"image_bytes_extracted": True, "visually_verified": False,
                       "card_face_decoded": True,
                       "primary_image_path": str(Path(directory) / "extracted-images" / "test.png"),
                       "network_accessed": False,
                       "images": [{"path": str(Path(directory) / "extracted-images" / "test.png")}]}
            with patch.object(card_backup_move, "backup_original_asset", return_value=exported) as export, \
                 patch.object(wallet_asset_decode, "decode_asset", return_value=decoded) as decode, \
                 patch.object(aircard_backend, "cmd_flash") as flash:
                code, result = self.invoke(["--backup-original-asset", "device", "a" * 28,
                                            "cache", "FrontFace", directory, "--accept-move-risk"])
            self.assertEqual(code, 0)
            export.assert_called_once_with("device", "a" * 28, "cache", "FrontFace", directory)
            decode.assert_called_once_with(str(Path(directory) / "FrontFace"),
                                           str(Path(directory) / "extracted-images"))
            flash.assert_not_called()
            self.assertTrue(result["ok"])
            self.assertTrue(result["raw_asset_exported"])
            self.assertTrue(result["decoded_card_image"])
            self.assertFalse(result["visually_verified"])
            self.assertFalse(result["complete_card_artwork_backup"])
            self.assertEqual(result["extraction"], decoded)
            self.assertEqual(json.loads((Path(directory) / "manifest.json").read_text()), result)

    def test_failed_cache_decode_preserves_raw_success_without_image_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            exported = self.original_export_result(directory)
            with patch.object(card_backup_move, "backup_original_asset", return_value=exported), \
                 patch.object(wallet_asset_decode, "decode_asset", side_effect=ValueError("unsupported cache format")):
                code, result = self.invoke(["--backup-original-asset", "device", "a" * 28,
                                            "cache", "FrontFace", directory, "--accept-move-risk"])
            self.assertEqual(code, 0, "The raw asset was still exported successfully")
            self.assertTrue(result["ok"])
            self.assertTrue(result["raw_asset_exported"])
            self.assertFalse(result["decoded_card_image"])
            self.assertEqual(result["decode_error"], "unsupported cache format")
            self.assertNotIn("extraction", result)
            self.assertEqual(json.loads((Path(directory) / "manifest.json").read_text()), result)
            self.assertTrue((Path(directory) / "FrontFace").is_file())

    def test_valid_cache_without_embedded_images_does_not_claim_image(self):
        with tempfile.TemporaryDirectory() as directory:
            exported = self.original_export_result(directory)
            decoded = {"image_bytes_extracted": False, "visually_verified": False,
                       "card_face_decoded": False,
                       "images": [], "network_accessed": False}
            with patch.object(card_backup_move, "backup_original_asset", return_value=exported), \
                 patch.object(wallet_asset_decode, "decode_asset", return_value=decoded):
                code, result = self.invoke(["--backup-original-asset", "device", "a" * 28,
                                            "cache", "FrontFace", directory, "--accept-move-risk"])
            self.assertEqual(code, 0)
            self.assertTrue(result["raw_asset_exported"])
            self.assertFalse(result["decoded_card_image"])
            self.assertFalse(result["visually_verified"])
            self.assertEqual(result["extraction"]["images"], [])

    def test_other_embedded_image_is_not_claimed_as_the_card_face(self):
        with tempfile.TemporaryDirectory() as directory:
            exported = self.original_export_result(directory)
            decoded = {"image_bytes_extracted": True, "card_face_decoded": False,
                       "visually_verified": False, "network_accessed": False,
                       "images": [{"path": str(Path(directory) / "extracted-images" / "shadow.png"),
                                   "role": "faceShadowImage"}]}
            with patch.object(card_backup_move, "backup_original_asset", return_value=exported), \
                 patch.object(wallet_asset_decode, "decode_asset", return_value=decoded):
                code, result = self.invoke(["--backup-original-asset", "device", "a" * 28,
                                            "cache", "FrontFace", directory, "--accept-move-risk"])
            self.assertEqual(code, 0)
            self.assertTrue(result["raw_asset_exported"])
            self.assertFalse(result["decoded_card_image"])
            self.assertFalse(result["visually_verified"])

    def test_failed_original_export_never_runs_decoder(self):
        with patch.object(card_backup_move, "backup_original_asset", return_value={"ok": False, "recovery_required": True}), \
             patch.object(wallet_asset_decode, "decode_asset") as decode:
            code, result = self.invoke(["--backup-original-asset", "device", "a" * 28,
                                        "cache", "FrontFace", "/tmp", "--accept-move-risk"])
        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        decode.assert_not_called()
