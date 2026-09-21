"""Static Swift source regression checks, not device or interactive UI tests.

These checks protect the separation between export and explicit Flash actions.
They do not establish that an iPhone export succeeds or validate rendered UI.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_SOURCE = ROOT / "AirCardApp.swift"
HAN_CHARACTER = re.compile(
    "[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff"
    "\U00020000-\U0002ee5f\U0002f800-\U0002fa1f\U00030000-\U000323af]"
)


def swift_method(source: str, name: str) -> tuple[str, str]:
    """Extract a model method using the file's stable four-space indentation.

    This is intentionally a source-layout check, not a general Swift parser.
    A method-layout refactor should update this helper alongside the tests.
    """
    method = re.search(
        rf"^    func {re.escape(name)}\b(?P<signature>[^{{]*)\{{"
        rf"(?P<body>.*?)^    \}}[ \t]*$",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if method is None:
        raise AssertionError(f"Could not locate the Swift method {name}")
    return method.group("signature"), method.group("body")


def alert_case_body(method_body: str, case: str) -> str:
    branch = re.search(
        rf"case\s+\.{re.escape(case)}\s*:\s*(?P<body>.*?)"
        r"(?=\s*case\s+|\s*default\s*:)",
        method_body,
        re.DOTALL,
    )
    if branch is None:
        raise AssertionError(f"Could not locate alert branch {case}")
    return branch.group("body").strip()


class BackupUIFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SWIFT_SOURCE.read_text(encoding="utf-8")

    def test_back_up_first_opens_export_method_picker(self):
        _, body = swift_method(self.source, "requestApplySkin")
        labels = re.findall(r'alert\.addButton\(withTitle:\s*"([^"\n]*)"\)', body)
        self.assertGreaterEqual(len(labels), 3)
        self.assertEqual(labels[0], "Back Up First…")
        self.assertEqual(
            alert_case_body(body, "alertFirstButtonReturn"),
            "requestBackupArtwork()",
        )
        self.assertNotIn("backupSelectedCards(", body)
        self.assertNotIn("Back Up, Then Flash", self.source)

    def test_flashing_remains_an_explicit_separate_choice(self):
        _, confirmation = swift_method(self.source, "requestApplySkin")
        labels = re.findall(r'alert\.addButton\(withTitle:\s*"([^"\n]*)"\)', confirmation)
        self.assertEqual(labels[2], "Flash Without Backup")
        self.assertEqual(
            alert_case_body(confirmation, "alertThirdButtonReturn"),
            "applySkin()",
        )
        _, flash = swift_method(self.source, "applySkin")
        self.assertIn("isFlashing = true", flash)
        self.assertNotIn("requestBackupArtwork(", flash)
        self.assertNotIn("backupSelectedCards(", flash)

    def test_backup_never_chains_into_flash(self):
        signature, backup = swift_method(self.source, "backupSelectedCards")
        self.assertNotIn("thenFlash", signature + backup)
        self.assertNotRegex(backup, r"\bapplySkin\s*\(")
        self.assertNotRegex(backup, r"\brequestApplySkin\s*\(")
        self.assertNotRegex(backup, r"\bisFlashing\s*=\s*true")
        self.assertNotIn("thenFlash", self.source)
        self.assertNotIn("backedUpCards", self.source)

    def test_current_face_is_available_in_english_export_picker(self):
        _, picker = swift_method(self.source, "requestBackupArtwork")
        self.assertIn('alert.messageText = "Export Current Card Face"', picker)
        self.assertIn('alert.addButton(withTitle: "Export Current Card Face…")', picker)
        self.assertRegex(
            picker,
            r"case\s+\.alertFirstButtonReturn\s*:\s*backupSelectedCards\(currentFace:\s*true\)",
        )
        self.assertNotRegex(picker, r"\bapplySkin\s*\(")

    def test_export_picker_reminds_users_about_express_mode(self):
        _, picker = swift_method(self.source, "requestBackupArtwork")
        self.assertIn("turn off Express Mode for this card in Wallet", picker)
        self.assertIn("turn Express Mode back on after export", picker)

    def test_swift_ui_source_contains_no_han_characters(self):
        offending_lines = [
            number
            for number, line in enumerate(self.source.splitlines(), start=1)
            if HAN_CHARACTER.search(line)
        ]
        self.assertEqual(
            offending_lines,
            [],
            f"English-only Swift UI source contains Han characters on lines {offending_lines}",
        )


if __name__ == "__main__":
    unittest.main()
