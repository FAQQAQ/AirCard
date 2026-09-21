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
- 💾 **Current Card Face Export (experimental):** Use **Back Up Artwork → Export Current Card Face…** to extract the currently displayed Wallet card face as a PNG. No imported image is required, and exporting never automatically flashes a skin.
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

### Interrupted exports and recovery

If an export is interrupted, keep its entire `AirCard-ORIGINAL-…` folder, including the hidden `.recovery` directory. Do not flash a new skin or start another export before the pending operation has been checked. Reconnect the same iPhone and keep it unlocked. If you are unsure which folder belongs to the interrupted operation, ask for help rather than guessing.

To retry only that operation's pending file return and cleanup, run the following from the repository directory after building the native helpers with `make all`. Replace the placeholders with the same device's UDID and the full path to the existing export folder:

```sh
python3 aircard_backend.py --recover-move-backup 'YOUR_DEVICE_UDID' '/absolute/path/to/AirCard-ORIGINAL-…' --accept-move-risk
```

Recovery validates the recorded device and exact asset; it does not start another card export. A successful recovery means the pending return and cleanup completed, not that a PNG was extracted. Check the recovery result and verify the card's appearance in Wallet before making further changes. If recovery cannot establish where the original is, it stops and retains the recovery files. Never delete those files after a failed recovery or use the older `finish-write` cleanup command on this export folder.

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
