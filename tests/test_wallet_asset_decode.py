import plistlib
import tempfile
import unittest
from pathlib import Path
from wallet_asset_decode import extract_images, decode_asset

PNG = b"\x89PNG\r\n\x1a\nfixture"


class WalletAssetDecodeTests(unittest.TestCase):
    def test_keyed_archive_data_without_class_instantiation(self):
        data = plistlib.dumps({"$archiver": "NSKeyedArchiver", "$objects": [
            "$null", {"$class": plistlib.UID(2), "imageData": plistlib.UID(3)},
            {"$classname": "NeverInstantiateThis"}, PNG, PNG]}, fmt=plistlib.FMT_BINARY)
        images, urls = extract_images(data)
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]["bytes"], PNG)
        self.assertEqual(urls, [])

    def test_nested_plist_and_url_are_inert(self):
        inner = plistlib.dumps({"image": PNG, "url": "https://example.invalid/art.png"}, fmt=plistlib.FMT_BINARY)
        images, urls = extract_images(plistlib.dumps({"nested": inner}))
        self.assertEqual(images[0]["bytes"], PNG)
        self.assertEqual(urls, ["https://example.invalid/art.png"])

    def test_raw_and_unknown(self):
        self.assertEqual(extract_images(PNG)[0][0]["extension"], "png")
        self.assertEqual(extract_images(b"unknown"), ([], []))

    def test_wallet_header_before_binary_plist(self):
        framed = bytes(48) + plistlib.dumps({"imageData": PNG}, fmt=plistlib.FMT_BINARY)
        images, _ = extract_images(framed)
        self.assertEqual(images[0]["bytes"], PNG)
        self.assertIn("plist-at-48", images[0]["archive_path"])

    def test_face_and_shadow_roles_follow_only_inert_uid_links(self):
        archive = {"$top": {"root": plistlib.UID(1)}, "$objects": [
            "$null", {"faceImage": plistlib.UID(2), "faceShadowImage": plistlib.UID(4)},
            {"imageData": plistlib.UID(3)}, {"NS.data": PNG},
            {"imageData": plistlib.UID(5)}, {"NS.data": PNG + b"shadow"}]}
        images, _ = extract_images(bytes(48) + plistlib.dumps(archive, fmt=plistlib.FMT_BINARY))
        self.assertEqual(images[0]["roles"], ["faceImage"])
        self.assertEqual(images[1]["roles"], ["faceShadowImage"])

    def test_writes_exact_bytes_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / "FrontFace"
            source.write_bytes(plistlib.dumps({"image": PNG}))
            result = decode_asset(str(source), root)
            self.assertEqual(Path(result["images"][0]["path"]).read_bytes(), PNG)
            self.assertFalse(result["visually_verified"])
            with self.assertRaises(FileExistsError):
                decode_asset(str(source), root)

    def test_empty_and_excessive_nesting_fail(self):
        with self.assertRaises(ValueError):
            extract_images(b"")
        value = PNG
        for _ in range(40):
            value = [value]
        with self.assertRaises(ValueError):
            extract_images(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
