"""Explicit experimental artwork export by moving one original at a time.

This must never be a fallback for the read-only backup command. AirTraffic
acknowledges dispatch, not the final private-directory contents. The manifest
therefore distinguishes a successful content readback from the final return,
which is inferred from a previously observed Media file becoming absent.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import posixpath
import re
import secrets
import stat
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from apply_card_skin import (
    AIRLOCK_ROOT, AIRTRAFFIC_HOST, build_archive, build_books, native,
    operation_ok, run_json,
)

ARTWORK_FILES = (
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
    "cardBackgroundCombined.pdf",
)
ORIGINAL_PKPASS_ASSETS = tuple(
    f"{base}{scale}.png"
    for base in ("cardBackground", "strip", "background", "logo")
    for scale in ("", "@2x", "@3x")
) + ("cardBackground.pdf",)
ORIGINAL_CACHE_ASSETS = ("FrontFace", "PlaceHolder", "Preview")
ORIGINAL_PKPASS_SIDECARS = (
    "cardBackgroundCombined.urls",
    "cardBackgroundCombined@2x.urls",
    "cardBackgroundCombined@3x.urls",
    "cardBackgroundCombined.pdf.urls",
    "cardBackgroundCombined@2x.png.urls",
    "cardBackgroundCombined@3x.png.urls",
)
MAX_ARTWORK_BYTES = 16 * 1024 * 1024
STATE_VERSION = 1


class MoveBackupError(RuntimeError):
    pass


def _sync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _validate(udid: str, card_hash: str) -> None:
    if not isinstance(udid, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", udid):
        raise ValueError("Invalid device identifier")
    if not isinstance(card_hash, str) or not re.fullmatch(r"[-A-Za-z0-9_+=]{20,44}", card_hash):
        raise ValueError("Invalid card hash")


def _validate_original_asset(container: str, leaf: str) -> None:
    allowed = ORIGINAL_PKPASS_ASSETS + ORIGINAL_PKPASS_SIDECARS if container == "pkpass" else ORIGINAL_CACHE_ASSETS if container in ("cache", "pkcache") else ()
    if leaf not in allowed:
        raise ValueError("Unsupported original visual asset or container")


def _asset_context(state: dict) -> tuple[str, tuple[str, ...], bool]:
    if state.get("mode") == "experimental_move":
        if state.get("container", "pkpass") != "pkpass" or state.get("asset_names", list(ARTWORK_FILES)) != list(ARTWORK_FILES):
            raise ValueError("Invalid combined-artwork backup scope")
        return "pkpass", ARTWORK_FILES, False
    if state.get("mode") != "original_asset":
        raise ValueError("Unknown backup mode")
    container = state.get("container")
    names = state.get("asset_names")
    if not isinstance(names, list) or len(names) != 1 or not isinstance(names[0], str):
        raise ValueError("Original-asset recovery requires exactly one fixed asset")
    _validate_original_asset(container, names[0])
    return container, tuple(names), container in ("cache", "pkcache") or names[0] in ORIGINAL_PKPASS_SIDECARS


def _atomic_json(path: Path, data: dict) -> None:
    """A replaced and fsynced journal always precedes a device mutation."""
    temporary = path.with_name(path.name + "." + secrets.token_hex(8) + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.chmod(temporary, 0o600)
            json.dump(data, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def _save(state: dict, row: dict | None = None, phase: str | None = None) -> None:
    if phase:
        state["phase"] = phase
        if row is not None:
            row["phase"] = phase
    _atomic_json(Path(state["path"]) / ".recovery" / "state.json", state)


@contextmanager
def _lock(backup: Path):
    # Keep the lock inode for subsequent recovery attempts; never unlink it.
    with (backup / ".recovery" / "operation.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise MoveBackupError("This backup already has an operation running") from error
        yield


@contextmanager
def move_device_lock(udid: str):
    """Serialize this Mac's operations on one device, across output folders.

    Exposed so legacy flash/read-only backup entry points can opt into the same
    lock. The native helpers cannot protect against another sync application.
    """
    if not isinstance(udid, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", udid):
        raise ValueError("Invalid device identifier")
    directory = Path(tempfile.gettempdir()).resolve() / f"aircard-device-locks-{os.getuid()}"
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise MoveBackupError("Device lock directory is not private and owned by this user")
    path = directory / (hashlib.sha256(udid.encode()).hexdigest() + ".lock")
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise MoveBackupError("Invalid device lock file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise MoveBackupError("Another AirCard operation is already using this device") from error
        yield
    finally:
        os.close(descriptor)


def _sync_snapshot(snapshot: Path) -> None:
    """Persist the actual Books bytes, not only the JSON recovery journal."""
    entries = list(snapshot.rglob("*"))
    for path in entries:
        if path.is_symlink():
            raise MoveBackupError("Books snapshot contains an unexpected symbolic link")
        if path.is_file():
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
        elif not path.is_dir():
            raise MoveBackupError("Books snapshot contains a non-regular object")
    for directory in sorted([snapshot, snapshot.parent] + [path for path in entries if path.is_dir()],
                            key=lambda path: len(path.parts), reverse=True):
        _sync_directory(directory)


def _status(state: dict, row: dict) -> str:
    result = native("recovered-status", state["device"], row["recovered"])
    row["last_recovered_status"] = result
    operation = result.get("operation", {})
    presence = operation.get("presence")
    if not operation_ok(result) or presence not in ("present", "absent"):
        raise MoveBackupError("Cannot establish whether the relocated original is present; recovery files were retained")
    return presence


def _wait_presence(state: dict, row: dict, expected: str) -> None:
    # AFC's known absent is distinct from transport/access errors. Unknown
    # results stop immediately, rather than being interpreted as absence.
    for attempt in range(9):
        if _status(state, row) == expected:
            _save(state)
            return
        if attempt < 8:
            time.sleep(0.25)
    _save(state)
    raise MoveBackupError(f"Relocated artwork did not become {expected}; keep the recovery directory")


def _refresh_books(state: dict, row: dict) -> None:
    _save(state, row, "refresh_books")
    if state["mode"] == "original_asset":
        result = native("refresh-original-books", state["device"], row["source"],
                        row["link"], row["recovered"], state["card"], state["container"],
                        row["leaf"], row["snapshot"])
    else:
        result = native("refresh-move-books", state["device"], row["source"],
                        row["link"], row["recovered"], state["card"], row["snapshot"])
    row["last_books_refresh"] = result
    _save(state)
    if not operation_ok(result):
        raise MoveBackupError("Could not prepare the next Books transfer; any relocated original was retained")


def _dispatch(state: dict, row: dict, identifier: str, destination: str, phase: str) -> dict:
    _refresh_books(state, row)
    row["last_dispatch"] = {"identifier": identifier, "destination": destination,
                            "result": None, "phase": phase}
    _save(state, row, phase + "_intent")
    result = run_json([str(AIRTRAFFIC_HOST), state["device"], identifier, destination], timeout=120)
    row["last_dispatch"]["result"] = result
    _save(state, row, phase + "_dispatched")
    if result.get("exitCode") != 0 or result.get("ok") is not True:
        raise MoveBackupError(f"AirTraffic did not confirm {phase} dispatch")
    return result


def _file_record(path: Path, leaf: str, *, raw_asset: bool = False) -> dict:
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_ARTWORK_BYTES:
        raise MoveBackupError(f"Invalid or missing local artwork: {leaf}")
    data = path.read_bytes()
    if raw_asset:
        if leaf not in ORIGINAL_CACHE_ASSETS + ORIGINAL_PKPASS_SIDECARS:
            raise MoveBackupError("Only known Wallet visual cache and sidecar leaves may be exported as raw bytes")
    else:
        signature = b"%PDF-" if leaf.endswith(".pdf") else b"\x89PNG\r\n\x1a\n"
        if not data.startswith(signature):
            raise MoveBackupError(f"Recovered file is not the expected artwork format: {leaf}")
    return {"name": leaf, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def _export(state: dict, row: dict, directory: Path) -> dict:
    path = directory / row["leaf"]
    if path.exists() or path.is_symlink():
        raise MoveBackupError("Refusing to overwrite an existing exported file")
    _save(state, row, "export_relocated_artwork")
    result = native("export-recovered-artwork", state["device"], row["recovered"],
                    row["leaf"], str(directory))
    row["last_export"] = result
    _save(state)
    if not operation_ok(result):
        raise MoveBackupError(result.get("operation", {}).get("message") or "Could not export the relocated original")
    record = _file_record(path, row["leaf"], raw_asset=_asset_context(state)[2])
    # Persist file content before a subsequent return can remove the Media copy.
    with path.open("rb") as stream:
        os.fsync(stream.fileno())
    _sync_directory(directory)
    _sync_directory(directory.parent)
    return record


def _move_out(state: dict, row: dict, verification: bool = False) -> None:
    if _status(state, row) != "absent":
        raise MoveBackupError("The recovery destination is not empty; refusing another move")
    row["location"] = "unknown"
    row["move_attempted"] = True
    phase = "verification_move_out" if verification else "move_out"
    _dispatch(state, row, row["target_identifier"], row["recovered"], phase)
    _wait_presence(state, row, "present")
    row["location"] = "media"
    row["recovered_observed"] = True
    _save(state, row, phase + "_observed")


def _return_original(state: dict, row: dict) -> None:
    if _status(state, row) != "present":
        raise MoveBackupError("Original was not observed in Media before return; no return will be assumed")
    row["return_preimage_observed"] = True
    row["location"] = "unknown"
    _dispatch(state, row, "../../" + row["recovered"],
              row["link"] + "/" + row["leaf"], "return_original")
    _wait_presence(state, row, "absent")
    row["location"] = "return_observed"
    row["final_destination_directly_verified"] = False
    row["return_evidence"] = "recovered_present_before_dispatch_and_known_absent_after_successful_dispatch"
    _save(state, row, "return_observed")


def _verify_roundtrip(state: dict, row: dict) -> None:
    _move_out(state, row, verification=True)
    directory = Path(row["recovery_dir"]) / ("verify-" + secrets.token_hex(6))
    directory.mkdir(mode=0o700)
    record = _export(state, row, directory)
    row["verification_file"] = str(directory / row["leaf"])
    if not row.get("file"):
        # A previous attempt may have returned successfully after both exports
        # failed. Establish a durable baseline now, then perform a separate
        # return/readback comparison; one read alone is not verification.
        row["file"] = record
        row["recovered_copy_path"] = row["verification_file"]
        _save(state, row, "recovery_baseline_saved")
        _return_original(state, row)
        _verify_roundtrip(state, row)
        return
    row["readback_sha256_match"] = record == row["file"]
    _save(state, row, "readback_verified")
    # Even a mismatched readback must be returned before reporting the error.
    _return_original(state, row)
    if not row["readback_sha256_match"]:
        raise MoveBackupError("Returned artwork changed during readback verification; later files were not touched")


def _finish(state: dict, row: dict) -> None:
    if row.get("move_attempted") and not (
        row.get("location") == "return_observed" and row.get("readback_sha256_match")
    ):
        raise MoveBackupError("Restoration evidence is incomplete; cleanup is deliberately deferred")
    if _status(state, row) != "absent":
        raise MoveBackupError("Relocated original remains in Media; cleanup is forbidden")
    _save(state, row, "cleanup_intent")
    result = native("finish-move-backup", state["device"], row["source"],
                    row["link"], row["recovered"], row["snapshot"])
    row["cleanup_result"] = result
    row["cleanup_complete"] = operation_ok(result)
    _save(state, row, "complete" if row["cleanup_complete"] else "cleanup_failed")
    if not row["cleanup_complete"]:
        raise MoveBackupError("Books/temporary-state cleanup could not be verified; keep recovery files")


def _rescue(state: dict, row: dict) -> None:
    """After failure, return an observed original without deleting recovery data."""
    if not row.get("move_attempted"):
        return
    try:
        if _status(state, row) == "present":
            # Retain an additional copy even when the primary export failed or
            # verification differed. No existing backup file is ever replaced.
            directory = Path(row["recovery_dir"]) / ("rescue-" + secrets.token_hex(6))
            directory.mkdir(mode=0o700)
            try:
                row["rescue_file"] = _export(state, row, directory)
                row["rescue_path"] = str(directory / row["leaf"])
                if not row.get("file"):
                    row["file"] = row["rescue_file"]
                    row["recovered_copy_path"] = row["rescue_path"]
                    _save(state, row, "rescue_baseline_saved")
            except Exception as error:
                row["rescue_export_error"] = str(error)
            _return_original(state, row)
    except Exception as error:
        row["recovery_error"] = str(error)
    _save(state)


def _new_row(state: dict, index: int, leaf: str) -> dict:
    token = secrets.token_hex(10)
    directory = Path(state["path"]) / ".recovery" / f"{index}-{token}"
    directory.mkdir(mode=0o700)
    snapshot = directory / "books-snapshot"
    snapshot.mkdir(mode=0o700)
    row = {"leaf": leaf, "token": token, "source": "airlift-src-" + token,
           "link": "airlift-link-" + token, "recovered": "airlift-recovered-" + token,
           "snapshot": str(snapshot), "recovery_dir": str(directory),
           "location": "untouched", "cleanup_complete": False}
    row["target_identifier"] = posixpath.relpath(state["source"] + "/" + leaf, AIRLOCK_ROOT)
    row["link_identifier"] = "../../" + row["source"] + "/p0/p1/p2/link"
    (directory / "link.zip").write_bytes(build_archive(state["source"], b"move-backup-link-only"))
    identifiers = [row["link_identifier"], "../../" + row["recovered"]]
    identifiers += [posixpath.relpath(state["source"] + "/" + item, AIRLOCK_ROOT) for item in _asset_context(state)[1]]
    (directory / "Books.plist").write_bytes(build_books(identifiers))
    state["operations"].append(row)
    _save(state, row, "prepared")
    return row


def _run_row(state: dict, row: dict) -> None:
    _save(state, row, "snapshot_books")
    result = native("snapshot-books", state["device"], row["snapshot"])
    if not operation_ok(result):
        raise MoveBackupError("Could not preserve Books state; no artwork was moved")
    _sync_snapshot(Path(row["snapshot"]))
    row["snapshot_complete"] = True
    directory = Path(row["recovery_dir"])
    _save(state, row, "stage_intent")
    row["stage_attempted"] = True
    _save(state)
    result = native("stage", state["device"], row["source"], row["link"], row["recovered"],
                    str(directory / "link.zip"), str(directory / "Books.plist"), row["snapshot"])
    row["stage_result"] = result
    _save(state)
    if not operation_ok(result):
        raise MoveBackupError("Could not stage the experimental artwork export")
    _dispatch(state, row, row["link_identifier"], row["link"], "activate_link")
    _move_out(state, row)
    row["file"] = _export(state, row, Path(state["path"]))
    _save(state, row, "local_original_saved")
    _return_original(state, row)
    _verify_roundtrip(state, row)
    _finish(state, row)


def _result(state: dict, error: str | None = None) -> dict:
    operations = state["operations"]
    container, expected_assets, raw_asset = _asset_context(state)
    local_complete = True
    files = []
    for row in operations:
        valid_primary = False
        try:
            valid_primary = _file_record(Path(state["path"]) / row["leaf"], row["leaf"], raw_asset=raw_asset) == row.get("file")
        except (OSError, MoveBackupError):
            pass
        local_complete = local_complete and valid_primary
        if row.get("file"):
            local_path = str(Path(state["path"]) / row["leaf"]) if valid_primary else row.get("recovered_copy_path")
            files.append({**row["file"], "path": local_path})
    complete = (len(operations) == len(expected_assets) and
                local_complete and all(row.get("cleanup_complete") and row.get("readback_sha256_match") for row in operations))
    result = {"ok": bool(complete and error is None), "type": "success" if complete and error is None else "error",
              "mode": state["mode"], "card": state["card"], "device": state["device"],
              "path": state["path"], "source": state["source"],
              "files": files,
              "cleanup_complete": bool(operations and all(row.get("cleanup_complete") for row in operations)),
              "recovery_path": str(Path(state["path"]) / ".recovery"),
              "recovery_required": any(row.get("stage_attempted") and not row.get("cleanup_complete") for row in operations),
              "final_destination_directly_verified": False,
              "safe_for_automatic_flash": False,
              "operations": operations}
    if state["mode"] == "original_asset":
        raw_cache = container in ("cache", "pkcache")
        result.update(container=container, asset_names=list(expected_assets),
                      raw_asset_exported=bool(complete and error is None and raw_asset),
                      decoded_card_image=False,
                      artifact_type="raw_wallet_visual_cache" if raw_cache else "raw_visual_asset_sidecar" if raw_asset else "source_visual_asset",
                      complete_card_artwork_backup=False)
    if error:
        result.update(error=error, message=error)
    else:
        result["message"] = ("Artwork exported and a return/readback cycle matched its SHA-256. "
                             "The final return was observed indirectly; inspect Wallet before further changes.")
        if state["mode"] == "original_asset":
            result["message"] = ("One original visual asset exported and its return/readback SHA-256 matched. "
                                 "The final return is indirect evidence. This is not a complete card-artwork backup.")
            if raw_asset:
                label = "Wallet cache" if container in ("cache", "pkcache") else "visual asset sidecar"
                result["message"] += f" Saved bytes are an undecoded {label}, not a decoded card image."
    return result


def _backup_card_by_move(udid: str, card_hash: str, output_dir: str, *, original_asset: tuple[str, str] | None = None) -> dict:
    """Explicit opt-in API: operates only on this device and this exact card."""
    state = None
    try:
        _validate(udid, card_hash)
        if original_asset is not None:
            _validate_original_asset(*original_asset)
        parent = Path(output_dir).expanduser().resolve(strict=True)
        if not parent.is_dir():
            raise ValueError("Output directory must already exist")
        label = "ORIGINAL" if original_asset else "MOVE"
        backup = parent / f"AirCard-{label}-{card_hash}-{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(10)}"
        backup.mkdir(mode=0o700)
        (backup / ".recovery").mkdir(mode=0o700)
        for directory in (backup / ".recovery", backup, parent):
            _sync_directory(directory)
        state = {"version": STATE_VERSION, "mode": "experimental_move", "device": udid,
                 "card": card_hash, "path": str(backup), "operations": [],
                 "source": f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"}
        if original_asset:
            container, leaf = original_asset
            state.update(mode="original_asset", container=container, asset_names=[leaf],
                         source=f"/var/mobile/Library/Passes/Cards/{card_hash}.{container}")
        _save(state, phase="created")
        with _lock(backup):
            for index, leaf in enumerate(_asset_context(state)[1]):
                row = _new_row(state, index, leaf)
                try:
                    _run_row(state, row)
                except Exception:
                    _rescue(state, row)
                    raise
            result = _result(state)
    except Exception as error:
        result = _result(state, str(error)) if state else {"ok": False, "type": "error", "mode": "original_asset" if original_asset else "experimental_move", "error": str(error), "message": str(error)}
    if state:
        _atomic_json(Path(state["path"]) / "manifest.json", result)
    return result


def _load_state(udid: str, backup: Path) -> dict:
    state_path = backup / ".recovery" / "state.json"
    if state_path.is_symlink():
        raise ValueError("Recovery journal must not be a symbolic link")
    state = json.loads(state_path.read_text())
    _validate(udid, state.get("card"))
    if (state.get("version") != STATE_VERSION or state.get("mode") not in ("experimental_move", "original_asset")
            or state.get("device") != udid or state.get("path") != str(backup)):
        raise ValueError("Recovery requires the original backup directory and the same device")
    container, expected_assets, _ = _asset_context(state)
    if state.get("source") != f"/var/mobile/Library/Passes/Cards/{state['card']}.{container}":
        raise ValueError("Invalid recovery card target")
    rows = state.get("operations")
    if not isinstance(rows, list) or not 1 <= len(rows) <= len(expected_assets):
        raise ValueError("Invalid recovery operations")
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError("Invalid recovery operation")
        token = row.get("token", "")
        if not re.fullmatch(r"[0-9a-f]{20}", token) or row.get("leaf") != expected_assets[index]:
            raise ValueError("Invalid recovery artifact or ordering")
        expected_dir = backup / ".recovery" / f"{index}-{token}"
        expected = {"source": "airlift-src-" + token, "link": "airlift-link-" + token,
                    "recovered": "airlift-recovered-" + token, "recovery_dir": str(expected_dir),
                    "snapshot": str(expected_dir / "books-snapshot"),
                    "link_identifier": "../../airlift-src-" + token + "/p0/p1/p2/link",
                    "target_identifier": posixpath.relpath(state["source"] + "/" + row["leaf"], AIRLOCK_ROOT)}
        if any(row.get(key) != value for key, value in expected.items()):
            raise ValueError("Recovery journal contains an unexpected path")
        if expected_dir.is_symlink() or expected_dir.resolve() != expected_dir or Path(row["snapshot"]).is_symlink():
            raise ValueError("Recovery paths must stay inside the original backup")
    return state


def _recover_move_backup(udid: str, backup_dir: str) -> dict:
    """Return only an already pending original; never start another card/leaf."""
    state = None
    try:
        backup = Path(backup_dir).expanduser().resolve(strict=True)
        with _lock(backup):
            state = _load_state(udid, backup)
            pending = [row for row in state["operations"] if not row.get("cleanup_complete")]
            if len(pending) > 1:
                raise MoveBackupError("Multiple pending originals require manual review")
            if pending:
                row = pending[0]
                if not row.get("snapshot_complete"):
                    raise MoveBackupError("Books snapshot is incomplete; no cleanup was attempted")
                stage = row.get("stage_result", {}).get("operation", {})
                if stage.get("cleanupAuthorized") is False:
                    raise MoveBackupError("Staging was rejected; no ownership of remote paths was established")
                presence = _status(state, row)
                if row.get("move_attempted"):
                    if presence == "present":
                        directory = Path(row["recovery_dir"]) / ("resume-" + secrets.token_hex(6))
                        directory.mkdir(mode=0o700)
                        record = _export(state, row, directory)
                        if row.get("file") and record != row["file"]:
                            _return_original(state, row)
                            raise MoveBackupError("Recovery content differs from the saved original; restored observed bytes and stopped")
                        if not row.get("file"):
                            row["file"] = record
                            row["recovered_copy_path"] = str(directory / row["leaf"])
                        _return_original(state, row)
                    elif row.get("location") != "return_observed":
                        raise MoveBackupError("Recovery copy is absent but its return was not observed; original location remains uncertain")
                    if not row.get("readback_sha256_match"):
                        _verify_roundtrip(state, row)
                _finish(state, row)
            result = _result(state)
            result["recovery_completed"] = not result["recovery_required"]
            result["message"] = "Pending original return and Books cleanup completed; a partial backup is not a complete backup."
    except Exception as error:
        if state and state["operations"]:
            _rescue(state, state["operations"][-1])
        result = _result(state, str(error)) if state else {"ok": False, "type": "error", "error": str(error), "message": str(error)}
    if state:
        _atomic_json(Path(state["path"]) / "manifest.json", result)
    return result


def backup_card_by_move(udid: str, card_hash: str, output_dir: str) -> dict:
    try:
        _validate(udid, card_hash)
        with move_device_lock(udid):
            return _backup_card_by_move(udid, card_hash, output_dir)
    except Exception as error:
        return {"ok": False, "type": "error", "mode": "experimental_move", "error": str(error), "message": str(error)}


def backup_original_asset(udid: str, card_hash: str, container: str, leaf: str, output_dir: str) -> dict:
    """Export exactly one whitelisted source visual or raw cache, explicitly."""
    try:
        _validate(udid, card_hash)
        _validate_original_asset(container, leaf)
        with move_device_lock(udid):
            return _backup_card_by_move(udid, card_hash, output_dir, original_asset=(container, leaf))
    except Exception as error:
        return {"ok": False, "type": "error", "mode": "original_asset", "error": str(error), "message": str(error)}


def recover_move_backup(udid: str, backup_dir: str) -> dict:
    try:
        # Covers exception rescue and manifest writes as well as the happy path.
        with move_device_lock(udid):
            return _recover_move_backup(udid, backup_dir)
    except Exception as error:
        return {"ok": False, "type": "error", "mode": "experimental_move", "error": str(error), "message": str(error)}
