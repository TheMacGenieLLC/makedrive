# makedrive

**Build ready-to-use macOS install and restore drives from a folder of DMGs.**

makedrive is a single Bash script that automates the tedious parts of making
macOS installation media: it verifies installers, processes them into restorable
images, and deploys your chosen set onto a target disk in one pass. A single
makedrive disk can carry many macOS installers side by side — from the oldest
retail DVDs (10.3 Panther) through the current release — so you can boot or
re-install almost any Mac from one drive.

> **Note:** makedrive was historically a service provider diagnostic/triage tool.
> Those diagnostic features have been removed; it is now focused on building
> macOS install drives.

<a href="https://www.buymeacoffee.com/themacgenie"><img width="214" height="60" src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy me a coffee"></a>
---
## Features

- **One-pass drive builds** — erase a target disk and deploy a whole set of
  macOS installers, with optional shared DataDrive space.
- **Guided image management** — add installers from within the script, verified
  by volume name and macOS build number, then automatically compressed and
  scanned for `asr` restore.
- **App Store installer processing** — runs `createinstallmedia` for you
  (Mojave+ and the El Capitan–High Sierra path) and strips the App Store receipt.
- **Automatic version tracking** — checks Apple's software-update catalog at
  launch and keeps installer build numbers current.
- **Volume icons** — extracted automatically from each installer's app bundle.
- **Optional Pushover notifications** when a build finishes.
- **Apple Silicon & Intel** hosts, with boot-disk protection on both.

## Requirements

- A reasonably current version of macOS (maintained against the latest releases),
  on Apple Silicon or Intel.
- **Xcode Command Line Tools** (for `setfile` and `python3`). makedrive offers to
  install them at first launch if they're missing.
- A local **administrator** account — makedrive uses tools that require root via
  `sudo`.

## Getting Started

1. Place `makedrive.command` and your `restorekit` folder together (the Desktop
   of a dedicated imaging account works well). `restorekit` must sit in the same
   directory as the script.
2. Double-click `makedrive.command` to launch it in Terminal.
3. Enter your administrator password when prompted.
4. Use the Main Menu to add installers, then build your drive:

```
Welcome to makedrive's Main Menu.

1. Add installers to the restorekit folder
2. Compress and scan DMGs for restore
3. Build your install drive
4. Configure Pushover notifications
5. Uninstall makedrive from this Mac
X. Exit makedrive
```

If `restorekit` isn't found next to the script, makedrive offers to create an
empty one so you can start from scratch.

## Configuration

makedrive reads everything it deploys — image definitions, build types, and the
Apple catalog URLs — from **`makedrive.conf`**, stored at
`/Library/Application Support/makedrive/makedrive.conf`. To update a deployment,
ship a new `makedrive.conf` next to the script and run it once; makedrive
migrates it into place after it has root.

## Documentation

The full manual, including configuration details and the complete changelog, is
in **[docs/USER_GUIDE.md](docs/USER_GUIDE.md)**.

## Uninstalling

Main Menu option 5 removes makedrive from the host (the Application Support
folder and its config, any Pushover credentials in the System Keychain, and the
script itself). It requires typing `UNINSTALL` to confirm. Your `restorekit` and
any drives you've already built are left untouched.

## License

Released under the [MIT License](LICENSE). © 2010–2026 The Mac Genie LLC.

## Author

Created by Ian Williams — ian@themacgenie.com
