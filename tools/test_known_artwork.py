#!/usr/bin/env python3
"""DESTRUCTIVE TEST: replace a disposable card's three artwork files, then export.

Does not touch Wallet cache directories. This tests the same artwork writer as
Flash Skins, not whether Wallet refreshes its visible preview. Never use for an
irreplaceable card. All expected bytes are saved before any phone write.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apply_card_skin import native, operation_ok, write_files_batch
from card_assets import build_card_assets
from card_backup_move import backup_card_by_move, move_device_lock, _atomic_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid")
    parser.add_argument("card_hash")
    parser.add_argument("png", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--previous-unobserved-attempt", type=Path)
    parser.add_argument("--allow-test-card-overwrite", action="store_true", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[-A-Za-z0-9_+=]{20,44}", args.card_hash):
        parser.error("Invalid card hash")
    parent = args.output_dir.resolve(strict=True)
    folder = parent / ("known-artwork-test-" + secrets.token_hex(10))
    folder.mkdir(mode=0o700)
    payloads = build_card_assets(args.png.read_bytes())
    expected = []
    for leaf, payload in payloads:
        path = folder / leaf
        with path.open("xb") as stream:
            stream.write(payload)
            stream.flush()
            import os
            os.fsync(stream.fileno())
        expected.append({"name": leaf, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
    report = {"ok": False, "card": args.card_hash, "device": args.udid, "path": str(folder),
              "expected": expected, "replaces_previous_artwork": True, "events": []}
    def save():
        _atomic_json(folder / "test-report.json", report)
    def record(phase, value):
        report["events"].append({"phase": phase, "result": value})
        save()
        print(json.dumps({"phase": phase, "result": value}), flush=True)
    save()
    try:
        with move_device_lock(args.udid):
            if args.previous_unobserved_attempt:
                # Restore only Books. Keep all original recovery artifacts and
                # generated links: absence never proves the original returned.
                previous = args.previous_unobserved_attempt.resolve(strict=True)
                from card_backup_move import _load_state
                state = _load_state(args.udid, previous)
                if state["card"] != args.card_hash or len(state["operations"]) != 1:
                    raise RuntimeError("Previous attempt does not match the exact test card")
                row = state["operations"][0]
                if row.get("recovered_observed") or row.get("file") or not row.get("snapshot_complete"):
                    raise RuntimeError("Previous attempt requires original-return recovery, not this test")
                status = native("recovered-status", args.udid, row["recovered"])
                record("previous_recovered_status", status)
                if not operation_ok(status) or status["operation"].get("presence") != "absent":
                    raise RuntimeError("Previous recovered copy is present or unknown; stop")
                restored = native("restore-books", args.udid, row["snapshot"])
                record("previous_books_restore", restored)
                _atomic_json(previous / "manual-books-restore.json", {
                    "result": restored, "original_location_verified": False,
                    "note": "Books restored only; generated source/link and all recovery files retained. No original was observed."})
                if not operation_ok(restored):
                    raise RuntimeError("Previous Books snapshot could not be restored")
            report["write_intent"] = True
            save()
            target = f"/var/mobile/Library/Passes/Cards/{args.card_hash}.pkpass"
            written = write_files_batch(args.udid, target, list(payloads), retries=1)
            record("write_known_artwork", {"dispatch_and_cleanup_ok": written})
            if not written:
                raise RuntimeError("Known-artwork writer failed; no backup was started")
        result = backup_card_by_move(args.udid, args.card_hash, str(parent))
        record("export_known_artwork", result)
        observed = [{key: row[key] for key in ("name", "bytes", "sha256")} for row in result.get("files", [])]
        report["ok"] = result.get("ok") is True and observed == expected
        report["byte_for_byte_match"] = observed == expected
        if not report["ok"]:
            report["error"] = "Known-artwork export did not completely match; retain recovery files"
    except Exception as error:
        report["error"] = str(error)
    save()
    print(json.dumps({key: value for key, value in report.items() if key != "events"}), flush=True)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
