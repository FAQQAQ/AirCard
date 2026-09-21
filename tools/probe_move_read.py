#!/usr/bin/env python3
"""Opt-in synthetic move/read probe. Never names an existing artwork file.

Writes a fresh canary to one explicitly selected card directory, moves it to
Media, reads it, then removes only this attempt's canary and staging objects.
Retains the Books snapshot and durable operation log even after success.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import posixpath
import re
import secrets
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apply_card_skin import (AIRLOCK_ROOT, AIRTRAFFIC_HOST, build_archive,
                             build_books, native, operation_ok, run_json)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid")
    parser.add_argument("card_hash")
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--allow-test-card-write", action="store_true", required=True)
    parser.add_argument("--roundtrip", action="store_true", help="Also return and re-read the synthetic canary")
    args = parser.parse_args()
    if not re.fullmatch(r"[-A-Za-z0-9_+=]{20,44}", args.card_hash):
        parser.error("Invalid card hash")
    parent = args.output_dir.resolve(strict=True)
    token = secrets.token_hex(10)
    folder = parent / f"canary-{token}"
    folder.mkdir(mode=0o700)
    snapshot = folder / "books-snapshot"
    snapshot.mkdir(mode=0o700)
    exported = folder / "exported"
    exported.mkdir(mode=0o700)
    source, link, recovered = (prefix + token for prefix in
        ("airlift-src-", "airlift-link-", "airlift-recovered-"))
    leaf = f"airlift-canary-{secrets.token_hex(16)}.bin"
    target = f"/var/mobile/Library/Passes/Cards/{args.card_hash}.pkpass"
    data = b"AirCard synthetic move/read probe\n" + secrets.token_bytes(64)
    expected = folder / "expected.bin"
    expected.write_bytes(data)
    archive, books = folder / "payload.zip", folder / "Books.plist"
    identifiers = [f"../../{source}/p0/p1/p2/link", f"../../{source}/payload",
                   posixpath.relpath(target + "/" + leaf, AIRLOCK_ROOT)]
    destinations = [link, link + "/" + leaf, recovered]
    archive.write_bytes(build_archive(target, data))
    books.write_bytes(build_books(identifiers))
    cleanup = ["finish", args.udid, source, link, recovered, str(expected),
               target.lstrip("/"), leaf, "1", str(snapshot)]
    report = {"ok": False, "card": args.card_hash, "device": args.udid,
              "path": str(folder), "canary_leaf": leaf, "target": target,
              "source": source, "link": link, "recovered": recovered,
              "expected_sha256": hashlib.sha256(data).hexdigest(),
              "cleanup_arguments": cleanup, "events": []}

    def save():
        temporary = folder / "report.json.tmp"
        with temporary.open("w") as stream:
            json.dump(report, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, folder / "report.json")
        directory_fd = os.open(folder, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    def step(name, call):
        report["phase"] = name
        save()
        value = call()
        report["events"].append({"phase": name, "result": value})
        save()
        print(json.dumps({"phase": name, "result": value}), flush=True)
        return value

    staged = False
    try:
        if not operation_ok(step("snapshot", lambda: native("snapshot-books", args.udid, str(snapshot)))):
            raise RuntimeError("Snapshot failed; nothing staged")
        staged = True
        result = step("stage", lambda: native("stage", args.udid, source, link,
                      recovered, str(archive), str(books), str(snapshot)))
        if result.get("operation", {}).get("cleanupAuthorized") is False:
            staged = False
        if not operation_ok(result):
            raise RuntimeError("Canary staging failed")
        command = [str(AIRTRAFFIC_HOST), args.udid]
        for identifier, destination in zip(identifiers, destinations):
            command.extend((identifier, destination))
        atc = step("canary_write_then_move_out", lambda: run_json(command, timeout=120))
        if not atc.get("ok") or atc.get("exitCode") != 0:
            raise RuntimeError("Canary transfer did not complete")
        readback = step("export", lambda: native("export-recovered-artwork", args.udid,
                       recovered, leaf, str(exported)))
        if not operation_ok(readback):
            raise RuntimeError("Could not read moved canary")
        report["bytes_match"] = (exported / leaf).read_bytes() == data
        if not report["bytes_match"]:
            raise RuntimeError("Canary bytes differ")
        if args.roundtrip:
            for name, identifier, destination, presence in (
                ("return_canary", "../../" + recovered, link + "/" + leaf, "absent"),
                ("reread_canary", identifiers[2], recovered, "present"),
            ):
                refreshed = step(name + "_refresh", lambda: native("refresh-move-books", args.udid,
                    source, link, recovered, args.card_hash, str(snapshot), leaf))
                if not operation_ok(refreshed):
                    raise RuntimeError("Could not prepare canary roundtrip")
                moved = step(name, lambda: run_json([str(AIRTRAFFIC_HOST), args.udid,
                                                    identifier, destination], timeout=120))
                if not moved.get("ok") or moved.get("exitCode") != 0:
                    raise RuntimeError("Canary roundtrip dispatch failed")
                status = step(name + "_status", lambda: native("recovered-status", args.udid, recovered))
                if not operation_ok(status) or status["operation"].get("presence") != presence:
                    raise RuntimeError("Canary roundtrip location was not confirmed")
            verification = folder / "verification"
            verification.mkdir(mode=0o700)
            reread = step("verify_returned_canary", lambda: native("export-recovered-artwork", args.udid,
                         recovered, leaf, str(verification)))
            report["roundtrip_match"] = operation_ok(reread) and (verification / leaf).read_bytes() == data
            if not report["roundtrip_match"]:
                raise RuntimeError("Returned canary does not match")
    except Exception as error:
        report["error"] = str(error)
        report["failure_phase"] = report["phase"]
    finally:
        if staged:
            try:
                result = step("cleanup", lambda: native(*cleanup))
                report["cleanup_complete"] = result.get("operation", {}).get("cleanupComplete", False)
            except Exception as error:
                report["cleanup_error"] = str(error)
        report["ok"] = bool(not report.get("error") and report.get("bytes_match") and report.get("cleanup_complete"))
        save()
        print(json.dumps(report), flush=True)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
