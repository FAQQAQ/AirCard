"""Extract intact image bytes from a Wallet cache without executing archives.

Only plistlib containers/data are interpreted. Never instantiate archived
Objective-C classes, deserialize pickle, or follow embedded network URLs.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

MAX_BYTES = 16 * 1024 * 1024


def image_extension(data: bytes) -> str | None:
    for magic, extension in ((b"\x89PNG\r\n\x1a\n", "png"), (b"\xff\xd8\xff", "jpg"),
                             (b"%PDF-", "pdf"), (b"II*\0", "tiff"), (b"MM\0*", "tiff"),
                             (b"GIF87a", "gif"), (b"GIF89a", "gif")):
        if data.startswith(magic):
            return extension
    if len(data) >= 12 and data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"mif1", b"avif"):
        return "avif" if data[8:12] == b"avif" else "heic"
    return None


def extract_images(data: bytes) -> tuple[list[dict], list[str]]:
    if not 0 < len(data) <= MAX_BYTES:
        raise ValueError("Asset is empty or larger than 16 MiB")
    images, urls, seen, roles = [], set(), set(), {}
    count = 0
    def visit(value, trail: str, depth: int = 0):
        nonlocal count
        count += 1
        if count > 50000 or depth > 32:
            raise ValueError("Asset container exceeds safe traversal limits")
        if isinstance(value, bytes):
            if len(value) > MAX_BYTES:
                raise ValueError("Embedded asset is too large")
            digest = hashlib.sha256(value).hexdigest()
            if digest in seen:
                return
            seen.add(digest)
            extension = image_extension(value)
            if extension:
                if len(images) >= 32:
                    raise ValueError("More than 32 embedded images")
                images.append({"bytes": value, "extension": extension, "sha256": digest, "archive_path": trail,
                               "roles": sorted(roles.get(digest, set()))})
            elif value.startswith((b"bplist00", b"<?xml", b"<plist")):
                visit(plistlib.loads(value), trail + "/plist", depth + 1)
            elif 0 < value[:4096].find(b"bplist00") < 4096:
                # Observed iOS 27 FrontFace: a 48-byte Wallet cache header
                # precedes the intact NSKeyedArchiver binary plist. Keep the
                # original cache, parse only the bounded embedded plist slice.
                offset = value[:4096].find(b"bplist00")
                visit(plistlib.loads(value[offset:]), trail + f"/plist-at-{offset}", depth + 1)
            elif len(value) < 1024 * 1024:
                for url in re.findall(rb"https://[^\s\x00<>\"']+", value):
                    urls.add(url.decode("utf-8", errors="replace"))
        elif isinstance(value, dict):
            objects = value.get("$objects")
            top = value.get("$top")
            if isinstance(objects, list) and isinstance(top, dict):
                def resolve(item):
                    visited = set()
                    while isinstance(item, plistlib.UID) and item.data not in visited:
                        visited.add(item.data)
                        if len(visited) > 32 or not 0 <= item.data < len(objects):
                            return None
                        item = objects[item.data]
                    return item
                root = resolve(top.get("root"))
                if isinstance(root, dict):
                    for role in ("faceImage", "faceShadowImage", "placeHolderImage", "iconImage", "notificationIconImage"):
                        obj = resolve(root.get(role))
                        if isinstance(obj, dict):
                            obj = resolve(obj.get("imageData"))
                        if isinstance(obj, dict):
                            obj = resolve(obj.get("NS.data"))
                        if isinstance(obj, bytes):
                            roles.setdefault(hashlib.sha256(obj).hexdigest(), set()).add(role)
            for key, item in value.items():
                visit(item, trail + "/" + str(key)[:80], depth + 1)
        elif isinstance(value, (tuple, list)):
            for index, item in enumerate(value):
                visit(item, trail + f"/{index}", depth + 1)
        elif isinstance(value, str):
            for url in re.findall(r"https://[^\s<>\"']+", value):
                urls.add(url)
        # plistlib.UID remains inert. Every $objects item is visited once as
        # stored data, so cycles/references cannot invoke code or recurse.
    visit(data, "$asset")
    return images, sorted(urls)


def decode_asset(source: str, output_dir: str) -> dict:
    source_path = Path(source).expanduser().resolve(strict=True)
    if not source_path.is_file() or source_path.stat().st_size > MAX_BYTES:
        raise ValueError("Expected a regular asset file no larger than 16 MiB")
    data = source_path.read_bytes()
    images, urls = extract_images(data)
    directory = Path(output_dir).expanduser().resolve(strict=True)
    if not directory.is_dir():
        raise ValueError("Output directory must exist")
    result = {"source": str(source_path), "source_sha256": hashlib.sha256(data).hexdigest(),
              "images": [], "asset_urls": urls, "network_accessed": False}
    for index, image in enumerate(images, 1):
        path = directory / f"wallet-image-{index}-{image['sha256'][:12]}.{image['extension']}"
        with path.open("xb") as stream:
            stream.write(image["bytes"])
        path.chmod(0o600)
        info = {key: value for key, value in image.items() if key != "bytes"} | {
            "path": str(path), "size": len(image["bytes"]), "image_decoder_verified": False}
        try:
            checked = subprocess.run(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                                     capture_output=True, text=True, timeout=10)
            width = re.search(r"pixelWidth:\s*(\d+)", checked.stdout)
            height = re.search(r"pixelHeight:\s*(\d+)", checked.stdout)
            if checked.returncode == 0 and width and height and int(width[1]) > 0 and int(height[1]) > 0:
                info.update(image_decoder_verified=True, pixel_width=int(width[1]), pixel_height=int(height[1]))
        except (OSError, subprocess.SubprocessError):
            pass
        result["images"].append(info)
    result["image_bytes_extracted"] = bool(result["images"])
    faces = [image for image in result["images"] if "faceImage" in image["roles"] and image["image_decoder_verified"]]
    if faces:
        result["primary_image_path"] = faces[0]["path"]
    result["card_face_decoded"] = bool(faces)
    result["visually_verified"] = False
    with (directory / "extraction.json").open("x") as stream:
        json.dump(result, stream, indent=2)
    return result


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("output_dir")
    args = parser.parse_args()
    print(json.dumps(decode_asset(args.source, args.output_dir)))
