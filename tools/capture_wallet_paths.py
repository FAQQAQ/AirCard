#!/usr/bin/env python3
"""Read-only bounded capture of Wallet file-path evidence, not general syslog."""
import argparse
import json
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apply_card_skin import DEVICE_HELPER


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid")
    parser.add_argument("output", type=Path)
    parser.add_argument("--seconds", type=int, default=45)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60:
        parser.error("Capture must last 1–60 seconds")
    if args.output.exists():
        parser.error("Output already exists; refusing to replace")
    paths, clues = set(), set()
    # Persist only Wallet paths and selected asset-loading statements. Never
    # store the unfiltered device log, payment events, amounts, or credentials.
    wallet = re.compile(r"passd|passbook|passkit|wallet|/passes/", re.I)
    asset = re.compile(r"frontface|placeholder|pkcache|cardbackground|\.pkpass|image.*cache|render.*cache|[-A-Za-z0-9_+]{27}=", re.I)
    path_re = re.compile(r"/(?:private/)?var/mobile/[^\s\x00\"'<>]+")
    process = subprocess.Popen([str(DEVICE_HELPER), "syslog", args.udid], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + args.seconds
    buffer = b""
    received_bytes = 0
    received_lines = 0
    try:
        while time.monotonic() < deadline and len(clues) < 200:
            for key, _ in selector.select(timeout=min(0.5, max(0, deadline-time.monotonic()))):
                import os
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    deadline = 0
                    break
                buffer += chunk
                received_bytes += len(chunk)
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    text = line.decode("utf-8", errors="replace").replace("\x00", "")
                    received_lines += 1
                    if not wallet.search(text) or not asset.search(text):
                        continue
                    for path in path_re.findall(text):
                        if "/Passes/" in path:
                            paths.add(path.rstrip(").,;"))
                    if text[:2000] not in clues:
                        clues.add(text[:2000])
                        print(json.dumps({"asset_clue": text[:2000]}), flush=True)
                if len(buffer) > 65536:
                    buffer = b""
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        selector.close()
    result = {"read_only": True, "paths": sorted(paths), "asset_clues": sorted(clues),
              "capture_seconds": args.seconds, "received_bytes": received_bytes,
              "received_lines": received_lines, "process_returncode": process.returncode}
    with args.output.open("x") as stream:
        import os
        os.chmod(args.output, 0o600)
        json.dump(result, stream, indent=2)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
