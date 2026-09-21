# AirCard 🎴

> **Apple Wallet Card Skinner & Lockscreen Passcode Themer for iOS 18+ (No Jailbreak Required)**  
> **Tested on iOS 27 release.**
> Powered by the `airlift` AirTraffic sync exploit.

<p align="left">
  <a href="https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y"><img src="https://img.shields.io/badge/Donate-PayPal-00457C?style=flat-square&logo=paypal" alt="Donate with PayPal" /></a>
</p>

---

## Features
- 🎨 **Custom Card Skins:** Assign custom artwork, textures, or bank logos to Apple Pay and Wallet cards.
- 🔢 **Lock Screen Passcode Themes (.passthm):** Apply custom keypad button artwork from popular `.passthm` themes directly to iOS 18+ lockscreen.
- 🧩 **Passcode Theme Creator:** Create custom themes from a single wallpaper (Seamless Poster Slicing) or build key-by-key (Individual Keys).
- 🔍 **Interactive Photo Framing:** Pan and zoom artwork directly inside keypad buttons with real-time iPhone preview.
- ✏️ **Edit Existing .passthm Themes:** Open any Cowabunga or Nugget theme package directly in the creator, tweak button artwork, reposition photos, and re-export or flash.
- ⚡ **Per-Card & Bulk Customization:** Set unique artwork for each card or apply one design across all cards with a single click.
- 💾 **Current Card Face Export (experimental):** Use **Back Up Artwork → Export Current Card Face…** to extract the currently displayed Wallet card face as a PNG. No imported image is required, and exporting never automatically flashes a skin. The app presents only this export method; the older combined-file experiments remain available in the backend for developers.
- 📱 **Zero-Hassle Card Detection:** Tap any card in your iPhone's Wallet app to detect its hash in real-time.
- 🚀 **100% Standalone (Universal):** Native support for both **Apple Silicon** and **Intel (x86)** Macs. All required device-communication utilities and image engines are pre-bundled inside the app.
- 📦 **Zero Prerequisites:** No Homebrew, Python packages, or terminal setup required for macOS users.

---

## Installation

### macOS (Universal DMG)
1. Download **`AirCard.dmg`** from [Releases](https://github.com/mak5er/AirCard/releases).
2. Open `AirCard.dmg` and drag **`AirCard.app`** into your **Applications** folder.
3. Fully compatible with both **Apple Silicon** and **Intel (x86)** Macs.

> [!NOTE]
> **First Launch on macOS (Gatekeeper):**
> If macOS displays an unidentified developer prompt on first launch:
> - **Method 1 (UI):** Right-click (or Control-click) `AirCard.app` in Applications ➔ click **Open** ➔ click **Open**.
> - **Method 2 (Terminal):**
>   ```sh
>   sudo xattr -cr /Applications/AirCard.app
>   ```

---

## How to Customize Apple Wallet Cards
1. Connect your iPhone to your Mac via USB cable and ensure it is unlocked and trusted.
2. In AirCard, stay on the **Wallet Cards** tab and click **Scan Cards**.
3. On your iPhone:
   - **Double-click the Side (Power) button** to open Apple Pay.
   - Authenticate with **Face ID**.
   - **Tap your card** (or tap it once more) to trigger instant detection!
4. Click on any card mockup or drag & drop an image directly onto the card.
5. To export the current card face first, click **Back Up Artwork → Export Current Card Face…**, or click **Flash Skins → Back Up First…** to open the same export confirmation. Backup never automatically flashes a skin. Check the exported files, then start **Flash Skins** separately when ready. **Flash Without Backup** retains the previous flash workflow.
6. Force-close the **Wallet** app on your iPhone from the App Switcher (or reboot) to see your new custom card design!

---

## Back Up Current Wallet Artwork (experimental)

Connect the same unlocked, trusted iPhone used to detect the card hash. **Back Up Artwork** opens the **Export Current Card Face** confirmation, with **Export Current Card Face…** and **Cancel** as its only buttons. No imported image is required. This saves the current display image from Wallet's cache, not a complete Wallet pass or payment credentials. The export additions described here require this modified build; an upstream release may not include them.

Every attempt creates a new private folder. Its manifest records device/card identifiers, the exact source path, file sizes, SHA-256 checksums and recovery evidence. Backups and extracted images can contain personal card artwork or other identifying details. Keep them private, and never include real device IDs, card hashes, manifests, Books snapshots, raw caches, extracted artwork or diagnostic logs in a public source-code contribution. Use placeholders in examples and inspect screenshots before sharing them.

Before exporting, turn off Express Mode for the selected card in Wallet, then open the card and scan it again. You can turn Express Mode back on after the export finishes. This resolved the reported export failure for one user; it is not a guarantee for every card or device. Keep the selected output folder in place until the operation finishes.

### Export the current displayed card face

Select exactly one disposable test card, click **Back Up Artwork**, and click **Export Current Card Face…**. If the app reports that no full card path was observed, choose **Cancel and Scan** unless you have independently confirmed that the identifier belongs to the intended test card. **Use This Unverified Identifier** continues without verifying the path; it is not an extra verification step.

Review the temporary-file-move warning and the named card before choosing **Test This Disposable Card**, then select a destination folder. Keep the iPhone connected, unlocked, and awake until the operation and cleanup finish. Do not operate Wallet, Books, or another Airlift tool during the export. On success, inspect the extracted PNG and compare it with the intended card face; retain the export folder and its recovery files.

This exports the existing `/var/mobile/Library/Passes/Cards/<card_hash>.cache/FrontFace`, then extracts the archived `faceImage` bytes. It does not flash a replacement picture or invalidate Wallet caches, and it never proceeds to automatic flashing.

For terminal use, build the native helpers with `make all`, then run from the repository directory. The destination parent folder must already exist:

```sh
python3 aircard_backend.py --backup-original-asset 'YOUR_DEVICE_UDID' 'YOUR_CARD_HASH' cache FrontFace '/absolute/output/folder' --accept-move-risk
```

The new `AirCard-ORIGINAL-…` folder contains the unchanged raw `FrontFace`, `manifest.json`, and a hidden `.recovery` directory. When decoding succeeds, `extracted-images/` contains extracted image files and `extraction.json`; `extraction.primary_image_path` points to the verified card-face image. Other entries, such as a shadow image, are not treated as the card face. The decoder parses bounded plist data and inert archive references; it does not instantiate archived Objective-C classes or fetch embedded URLs. Image decoding and pixel dimensions are checked locally.

Exit status 0 and `ok: true` indicate successful raw export, return/readback verification and cleanup. They do **not** by themselves establish that a card image was extracted: also inspect `decoded_card_image` and `extraction.card_face_decoded`. An unknown cache format or a cache containing no verified `faceImage` retains the raw file without claiming a decoded card face. A decode exception is recorded in `decode_error`. The tool leaves `visually_verified` false; a person must check that the pictured card is the one intended.

Physical-device validation on 2026-09-21 exported an existing 198,749-byte `FrontFace` cache, completed an exact-byte return/readback cycle and restored Books state. The cache's archived `faceImage` produced a 1272 × 780 PNG, which its owner confirmed matched the preexisting displayed design. This establishes export of that rendered Wallet card face on one iOS 27.0 device. It does **not** establish retrieval of an issuer's 1536-pixel source PNG, vector artwork or original PDF, and output dimensions may differ by card/device. The manifest therefore retains `complete_card_artwork_backup: false` and `safe_for_automatic_flash: false`.

This method temporarily moves the real cache into Media, exports it, returns it, and repeats a move/read to compare SHA-256. Final return evidence is indirect: an observed Media file becomes explicitly absent after successful transfer dispatch. Keep the iPhone unlocked and connected, and do not operate Wallet, Books or another Airlift tool until completion. Disconnecting or stopping the app can leave the asset displaced. Preserve `.recovery`; use the recovery command below with the original `AirCard-ORIGINAL-…` folder if an operation is interrupted. Successful extraction of a cached display image is an artwork export, not a payment credential backup or an automatic restore feature.

### Developer reference: combined-file exports (command line only)

The former **Read-Only Files** and **Combined Files (Experimental)…** buttons have been removed from the app. Their backend implementations are retained for development and controlled testing, not as additional choices in the current interface. The command-line methods below target `cardBackgroundCombined@3x.png`, `cardBackgroundCombined@2x.png`, and `cardBackgroundCombined.pdf`. A complete three-file backup requires all three files and verified cleanup.

This exports the bytes currently stored in `/var/mobile/Library/Passes/Cards/<card_hash>.pkpass/`. If a skin was already flashed, those bytes may already be custom artwork; this cannot recreate the bank's factory artwork. It is an artwork backup, not a full Wallet pass, payment credential backup, or an automatic restore feature.

The read-only command (`--backup-card`) stages and relocates only a generated symlink, then attempts AFC access to those three fixed filenames. This method never moves, replaces, or deletes original artwork. Standard AFC may reject access outside its Media scope. On the tested iOS 27.0 device, this method returned AFC status 8 before reading the first file, despite the generated link existing. That establishes an unavailable path through AFC, not proof that the actual artwork is absent. A folder containing only `manifest.json` with `ok: false` is a failed attempt, not a backup. Missing/empty files, files over 16 MiB, invalid image signatures, and cleanup failures also return errors. This method never silently switches to a move-based method.

For terminal use, build the native helpers with `make all`, then run from the repository directory (the destination parent folder must already exist):

```sh
python3 aircard_backend.py --backup-card 'YOUR_DEVICE_UDID' 'YOUR_CARD_HASH' '/absolute/path/to/backup folder'
```

The command prints JSON, including the new folder's `path`, and returns exit status 0 only for a complete export with successful cleanup. Card hashes must be 20–44 characters from `A–Z`, `a–z`, `0–9`, `_`, `-`, `+`, `=`; paths and shell syntax are not accepted as hashes. Arguments are passed to helpers without a shell. Existing backup directories are never reused or overwritten. The existing `--flash UDID HASH IMAGE` API is unchanged and does not automatically back up.

Keep the iPhone connected until cleanup finishes. Do not run backup and another Airlift operation concurrently, and do not force-quit the app during backup. The operation temporarily stages Books sync state, snapshots it first, and restores it in the cleanup path. If read-only cleanup cannot be verified (for example, after a disconnect), the command fails and preserves `.recovery/` beside any exported files. Only this **read-only** method's `cleanup.json` contains the exact helper path and argument array for retrying `finish-write` with the same device, plus the Books snapshot. Never use that older cleanup command for a current-card-face or combined-files **move** export. Keep recovery files until cleanup succeeds; a failed or partial export must not be treated as a verified backup. Process termination or power loss can interrupt cleanup.

Failed exports retain `failure_phase` and native `diagnostics` in `manifest.json`: link and file metadata, the exact failed call, raw AFC return codes, size limits, and bytes read where available. Raw private-framework status codes are not treated as POSIX errors. The [upstream Airlift verified scope](https://github.com/0xjohnnydev/airlift#verified-scope) describes indirect reads by moving a target file into Media, reading it, and moving it back. The opt-in method below follows that approach; it is not a non-destructive backup guarantee.

### Developer reference: combined-file move export (command line only)

The retained `--backup-card-move` command is an explicit experimental operation for one disposable test card. It is not offered by **Back Up Artwork**. Independently confirm the device and card identifier before supplying `--accept-move-risk`; the command line does not show the app's confirmation dialogs. This method does not need an imported image, does not invalidate Wallet caches, and never proceeds to automatic flashing. Do not use it on irreplaceable artwork. Keep the phone unlocked and connected, and do not use Wallet, Books, another Airlift tool, or a second AirCard operation while it runs.

Each artwork file is temporarily moved into Media, exported to a new local folder, and returned. A second move/read compares SHA-256 against the export, then returns the file again. The final destination cannot be read directly through AFC: final return evidence is a previously present Media file becoming explicitly absent after successful transfer dispatch. A successful readback is stronger evidence than dispatch alone, but is **not a guarantee against disconnection, service bugs, or final-return failure**. Inspect Wallet before making any further changes.

```sh
python3 aircard_backend.py --backup-card-move 'YOUR_DEVICE_UDID' 'YOUR_CARD_HASH' '/absolute/output/folder' --accept-move-risk
```

The new folder retains a hidden `.recovery` directory containing an atomic operation journal, Books snapshots, and verification copies. Never delete it after an interrupted operation. If an original is still in Media, cleanup refuses to delete it. A metadata access/transport error is not treated as absence. To recover only the pending operation on the **same phone**, without starting another card or later artwork file:

```sh
python3 aircard_backend.py --recover-move-backup 'YOUR_DEVICE_UDID' '/absolute/path/to/AirCard-MOVE-…' --accept-move-risk
```

For a current-card-face or other single-asset export, pass its `AirCard-ORIGINAL-…` directory to the same recovery command. Recovery validates the recorded device, container and exact asset; it does not start another card or search other filenames. Recovery exit status 0 means pending return/cleanup completed, not that all three combined artwork files were backed up or a PNG was decoded. Inspect `recovery_completed`, `ok`, and `files` separately. If recovery cannot establish where the original is, it stops and retains evidence rather than guessing or deleting it. The older `finish-write` cleanup must **never** be used on a move-export recovery directory.

`tools/probe_move_read.py` provides a separate opt-in synthetic test: it writes only a fresh random canary filename to the selected card directory, moves and reads it, and cleans its own canary/staging objects. `--roundtrip` also returns and re-reads that canary. It never names or overwrites the three real artwork files. This synthetic roundtrip has succeeded on one iPhone18,2 running iOS 27.0; that alone does not prove real artwork export or general device compatibility.

Physical-device validation on 2026-09-21 then used the explicitly authorized disposable card and `tools/test_known_artwork.py`: the same artwork writer as Flash Skins wrote a known PNG into the two combined PNG filenames and a generated PDF into the combined PDF filename. All three exported files matched their expected SHA-256 (509,737 bytes per PNG; 54,217 bytes for PDF), all three return/readback cycles matched, and temporary cleanup/Books restoration completed. Wallet caches were not invalidated, so this test does not establish a visible Wallet refresh. The attempt **before** writing these fixtures did not observe the expected first original filename in Media. Therefore this proves backup of known newly written artwork, **not extraction or restoration of the earlier original design**. The combined filenames may not exist on every unmodified card. Never publish personal card hashes, device IDs, Books snapshots, or artwork with a source-code contribution.

Run the portable test suite with `python3 -m unittest discover -s tests -v`. Backup tests mock device communication and verify export validation, failure cleanup, unique destinations, path rejection, and that backup never calls the artwork write functions. CLI adapter tests use temporary local fixtures and mocked export/decoder results to verify the risk gate, manifest output and separation between raw-export success and a decoded card face; they never contact a phone. These tests do not establish on-device AFC access. `tests/test_backend_passthm.py` is a separate legacy integration script requiring external `.passthm` fixture files at the example paths in that script; those fixtures are not included.

On macOS, `make test-artwork-diagnostics test-move-backup` runs native mocked scenarios for read failures, metadata parsing, size limits, partial reads, close errors, refusal to delete relocated originals, scoped Books refresh, and strict snapshot/restore checks. These harnesses do not open a device session.

---

## How to Apply Lockscreen Passcode Themes (.passthm)
1. Switch to the **Passcode Themes** tab at the top of AirCard.
2. Drag & drop any `.passthm` file into the app (or click **Choose .passthm File**).
3. AirCard will inspect the theme and display an interactive preview on the numeric keypad (0–9, *, #).
4. Click **Apply Passcode Theme**.
5. Restart your iPhone to reload the lock screen cache and see your custom passcode buttons!

> [!TIP]
> **Universal Language & Bold Text Support:**  
> AirCard automatically expands and flashes custom keypad assets for all system locales (English, Ukrainian, Russian, Spanish, German, French, etc.) and generates both standard and **Bold Text** cache bitmaps (`--white` and `--white-bold`), ensuring your theme works regardless of your iOS language or accessibility display settings!

---

## Building from Source

```sh
git clone https://github.com/mak5er/AirCard.git
cd AirCard
chmod +x build.sh
./build.sh
```
This builds universal binaries (`arm64` + `x86_64`), bundles dependencies into `build/AirCard.app`, and outputs `build/AirCard.dmg`.

Open `build/AirCard.app` for normal use. The `AirCard_arm64` and `AirCard_x86_64` files are intermediate executables; if launched inside the intact checkout, they resolve the backend and scanner helper relative to that checkout. Device detection and card scanning use the same helper location. The activity log records the application path and the scanner helper path for troubleshooting.

---

## Contributors
- **[@mak5er](https://github.com/mak5er)** (Developer) — [GitHub](https://github.com/mak5er) · [Twitter / X](https://x.com/mak5er)
- **[@Lumid-Off](https://github.com/Lumid-Off)** (Contributor & Developer) — [GitHub](https://github.com/Lumid-Off) · [Twitter / X](https://x.com/LumidOff)
- **[AirLift](https://github.com/0xjohnnydev/airlift)** by **[0xjohnny (@0xjohnnydev)](https://github.com/0xjohnnydev)**: Original AirTraffic/ATAirlock sandbox escape and proof of concept underlying `AirliftFFI`.

## Credits
- Core exploit based on `airlift` (AirTraffic sync escape).

---

## Support

If you find AirCard useful, you can support future development:

- **PayPal**: [Donate via PayPal](https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y)
- **TON**: `UQBm9KPhtMw-XVVjirUoa09wzrlyWsbeZhKfefl1Uw-qNZ-r`
- **USDT (TRC20)**: `TDkDMCyjYxgvkWUnQiF5Erk2RyPQMT6G1n`
- **USDT / BNB (BEP20)**: `0x0954dc491c502849d04956ef74634aa5931a08e8`
