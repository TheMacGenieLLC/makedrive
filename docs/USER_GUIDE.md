# makedrive User Guide

**Version:** Build 201  
**Updated:** 2026-06-30  
**Author:** Ian Williams  
**Contact:** [ian@themacgenie.com](mailto:ian@themacgenie.com)  
**Project:** [https://makedrive.com](https://makedrive.com)

---

## Contents

- [Introduction](#introduction)
- [Hardware & Software Requirements](#hardware--software-requirements)
- [Quick Start](#quick-start)
- [The Main Menu](#the-main-menu)
- [makedrive.conf](#makedriveconf)
- [Adding Images to restorekit](#adding-images-to-restorekit)
- [Mac App Store Installers](#mac-app-store-installers)
- [Downloading Installers from Apple](#downloading-installers-from-apple)
- [Volume Icons](#volume-icons)
- [Building Install Drives](#building-install-drives)
- [Restoring to USB or SD Card](#restoring-to-usb-or-sd-card)
- [Lion, Mountain Lion, and Mavericks Pre-flight](#lion-mountain-lion-and-mavericks-pre-flight)
- [Pushover Notifications](#pushover-notifications)
- [Uninstalling makedrive](#uninstalling-makedrive)
- [Security Considerations](#security-considerations)
- [Changelog](#changelog)
- [Acknowledgements](#acknowledgements)

---

## Introduction

makedrive builds ready-to-use macOS install drives from a human-navigable
folder of DMG files called **restorekit**. Instead of manually partitioning
disks, mounting images, and running `asr` by hand, makedrive automates the
whole process. It verifies each installer, processes it into a restorable
image, and deploys your chosen set of installers onto a target disk in a
single pass.

A single makedrive disk can store multiple macOS installers side by side, from
the oldest retail DVDs through the current release, so a technician can boot
or re-install almost any Mac from one drive. Building these drives by hand
is tedious and error-prone. makedrive makes it consistent and repeatable,
and lets you re-purpose a drive quickly when a new macOS version ships.

> **Note for users of older makedrive releases:** makedrive was historically
> a diagnostic and triage tool tied to service provider workflows. Those
> diagnostic features have been removed, and the current tool is focused on
> building macOS install drives.

---

## Hardware & Software Requirements

**Imaging host (the Mac that runs makedrive):**

- A reasonably current version of macOS. makedrive is maintained against the
  latest macOS releases (currently macOS 26 and 27) and runs on both Apple
  Silicon and Intel Macs.
- The **Xcode Command Line Tools.** makedrive uses `setfile` (to apply
  volume icons) and `python3` (to check installer versions against Apple's
  catalog). If the tools aren't present, makedrive offers to install them at
  launch and then exits so installation can complete.
- **Pillow (PIL), a Python imaging library.** Used to build the legacy
  `it32`/`t8mk` icon format that pre-2013 EFI boot pickers need. Pillow
  isn't part of macOS or the Xcode Command Line Tools, so makedrive
  installs it automatically via `pip` the first time it's needed. If that
  installation fails (for example, on a host with no network access),
  makedrive continues normally. Icons are still applied to volumes, but
  they may not appear in the boot picker on older Macs.
- A **local administrator account.** makedrive uses
  command-line tools that require root access by way of `sudo`, so full
  administrator rights on the host are required.
- High-speed ports (Thunderbolt, USB-C, or USB 3) for the fastest deployment
  across the widest range of target disks.

**Target disk (the drive being built):**

- Size the target to the installers you intend to bundle plus optional
  DataDrive space. A drive that holds many installers needs to be
  correspondingly large, so acquiring the largest practical disks keeps it
  useful as new macOS versions come out.
- A disk offering both modern (USB 3 / USB-C) and legacy (FireWire)
  connectivity gives the widest hardware compatibility if you support
  vintage Macs.

---

## Quick Start

makedrive relies on the **restorekit** folder as its source for the DMG
files it deploys. restorekit must sit in the **same directory as the
makedrive script**. The simplest setup is to keep `makedrive.command` and
`restorekit` together in the Desktop folder of a dedicated imaging account.
Double-clicking `makedrive.command` then launches it in Terminal.

At the start of a session you're prompted for the administrator password.
Once authenticated, the password isn't requested again for the rest of the
session, no matter how many drives you image.

If a DMG that one of your configurations expects is missing from
restorekit, a notice listing the missing files appears above the Main Menu.
Add the missing installers (Main Menu option 1) and the notice clears.

If restorekit isn't found next to the script, makedrive offers to create an
empty one so you can start from scratch and add images from within the
script.

---

## The Main Menu

```
Welcome to makedrive's Main Menu.

1. Add installer from local file
2. Download installer from Apple
3. Compress and scan DMGs for restore
4. Build your install drive
5. Restore image to USB or SD card
6. Configure Pushover notifications
7. Uninstall makedrive from this Mac
X. Exit makedrive
```

- **1. Add installer from local file.** Verifies an installer (by volume
  name and macOS build number) and copies it into the correct place in
  restorekit, then compresses and scans it for restore. Use this for 10.9
  Mavericks (which has no Apple-hosted download source) or for any
  installer you already have.
- **2. Download installer from Apple.** Fetches the Apple software-update
  catalog, lists all available macOS installers (10.7 through current,
  except 10.9), and downloads the one you choose directly from Apple. The
  installer is processed through the same pipeline as option 1, and the
  temporary download is cleaned up automatically. 10.9 Mavericks isn't
  available from Apple and must be added through option 1.
- **3. Compress and scan DMGs for restore.** Explicitly checks the DMGs in
  restorekit, compressing any that aren't already compressed and adding
  `asr` scan data where it's missing. Images added through options 1 or 2
  are already processed, so this option is mainly for images placed into
  restorekit by hand.
- **4. Build your install drive.** Erases a chosen target disk and deploys
  the installers for the build type you select. This is where most time is
  spent.
- **5. Restore image to USB or SD card.** Restores a single installer image
  to a USB flash drive, SD card, or other small media in one step. See
  [Restoring to USB or SD Card](#restoring-to-usb-or-sd-card).
- **6. Configure Pushover notifications.** Optional push notifications when
  a build finishes. See [Pushover Notifications](#pushover-notifications).
- **7. Uninstall makedrive.** Removes makedrive from the host. See
  [Uninstalling makedrive](#uninstalling-makedrive).

If you add DMGs to restorekit with the Finder rather than through options 1
or 2, they're neither verified nor compressed and scanned. Use option 3 (or,
preferably, always use options 1 or 2 in the first place) to be sure they're
ready for restore.

---

## makedrive.conf

Everything makedrive deploys is described in an external configuration
file, **makedrive.conf**. Keeping this in a separate file means new macOS
versions and build configurations can be added by editing one place,
without touching the script.

makedrive.conf defines:

- **Image definitions:** one block of variables per installer, keyed by a
  unique prefix (for example `inst2600u`). Each block sets the DMG path,
  the deploy type, display name, final volume name, partition size and
  filesystem, the macOS build number to verify against, and the label shown
  in the add-image menu.
- **Build types:** the groupings offered when you build a drive (see
  [Building Install Drives](#building-install-drives)).
- **Catalog URLs:** the Apple software-update catalog index URLs makedrive
  consults to keep installer build numbers current.

**Where it lives.** makedrive.conf is stored at:

```
/Library/Application Support/makedrive/makedrive.conf
```

On launch, makedrive loads the configuration from next to the script if one
is present there, and otherwise loads it from Application Support. A
makedrive.conf found next to the script is migrated into Application
Support (replacing any existing copy) once makedrive has root. This makes
updating simple: **ship a new makedrive.conf alongside a new script, run it
once, and the new configuration is installed.**

When makedrive.conf is migrated, the previous copy is archived with a
timestamp in a **conf archive** subfolder of Application Support. makedrive
keeps the 10 most recent archived copies, which gives you a safety net if a
conf migration produces unexpected results.

**Automatic version checking.** At launch, makedrive fetches a lightweight
copy of Apple's software-update catalog and compares it against
makedrive.conf. When Apple publishes a newer minor release for a macOS
version you track, makedrive updates the build number (and the version
shown in menus and volume names) in makedrive.conf automatically, and notes
the change above the Main Menu.

---

## Adding Images to restorekit

makedrive adds images into restorekit from within the script, which is
strongly preferred over arranging the folder by hand. From the Main Menu
choose option 1 to see the list of installers makedrive knows how to add:

```
Choose the software you'd like to add to the restorekit folder:

 1. 10.3.7 PPC Install                   12. 26.x App Store Install
 2. 10.4.7 PPC Install                   13. 27.x App Store Install
 ...
 X. Exit Image Installer
```

(The exact list is defined in makedrive.conf and reflects the macOS
versions you support.)

Depending on the image, makedrive either processes an App Store installer
already in `/Applications` (see
[Mac App Store Installers](#mac-app-store-installers)) or prompts you to
drag a pre-built DMG into the Terminal window. A progress indicator is
shown during the copy, and afterward makedrive makes sure the DMG is
compressed and scanned for restore.

Before copying, makedrive verifies the source against the expected volume
name and macOS build number so the wrong image can't be added by mistake.
If a build number is left empty in makedrive.conf, the check is skipped for
that entry.

---

## Mac App Store Installers

Beginning with OS X 10.7, Apple distributes macOS exclusively as an
installer application. From 10.9 onward the downloaded installer requires
additional processing to create a restorable image. makedrive handles this
for you:

1. Download or place the macOS installer app into `/Applications`. If it
   launches automatically, quit it.
2. In makedrive (option 1), choose the matching installer entry.
3. makedrive runs `createinstallmedia`, builds the final DMG, applies the
   volume icon, and copies the result into restorekit.

makedrive removes the Mac App Store receipt from the processed installer so
no personally identifiable information ends up on deployed disks.

### Sourcing 10.7 through 10.12 from an Apple installer package

OS X/macOS 10.7 Lion through 10.12 Sierra are no longer offered through the
Mac App Store and can only be obtained as a direct-download installer
package from Apple, typically delivered as a `.pkg` file on a `.dmg` disk
image. For these versions, if the installer app isn't already in
`/Applications`, makedrive prompts you to drag in either the
Apple-provided `.pkg` file or the `.dmg` containing it. If a `.dmg` is
provided, makedrive mounts it, locates the package automatically, and
unmounts it when finished. makedrive assembles the installer app from the
package and continues as normal. The package's obsolete installation
scripts, which fail on current systems, are bypassed entirely.

Supply only the genuine Apple-provided package. makedrive checks the
package's macOS version before assembling it and verifies the exact build
afterward, but it runs as the administrator and builds an installer from
whatever package you provide, so the package's authenticity is your
responsibility.

Two deploy types are supported, both handled automatically based on the
entry's configuration:

- **GENERIC:** a Mac App Store installer processed with
  `createinstallmedia`. Mojave and later use one flag set, Mavericks
  through High Sierra use another, and makedrive selects the correct path
  for you.
- **INST-A:** a pre-built or legacy DMG (for example, an older retail
  install image) copied directly into restorekit.

---

## Downloading Installers from Apple

Main Menu option 2 fetches a macOS installer directly from Apple, so you
don't need to visit the App Store first or already have anything sitting
in `/Applications`. It's the fastest way to add an installer to restorekit
if you don't already have one on hand.

When you choose option 2, makedrive fetches Apple's software-update
catalog and lists every macOS installer it found, from 10.7 Lion through
the current release, along with its download size:

```
Choose a macOS installer to download from Apple:

  10.9 Mavericks is not available from Apple - add it manually via option 1.

  1. 10.15.7 App Store Install                    9.8 GB
  2. 26.x App Store Install                        14.2 GB
  ...

  X. Return to Main Menu

Enter a number to download, or X to return:
```

(The exact list, order, and sizes reflect what's currently available from
Apple and the macOS versions defined in makedrive.conf.)

Pick the installer you want and hit return. makedrive downloads it
straight from Apple's servers with a progress bar, then processes it
through the same pipeline as option 1: the result is verified, compressed,
and scanned for restore before it lands in restorekit. Temporary download
files are cleaned up automatically once the process finishes.

10.9 Mavericks is the one exception. Apple no longer hosts it anywhere, so
it isn't available through option 2 at all. If you need 10.9, add it
through option 1 instead, using an installer you already have.

---

## Volume Icons

makedrive applies a custom volume icon to deployed install volumes so
they're easy to identify in the Startup Manager and boot picker. The icon
is extracted automatically from the macOS installer's application bundle
when an image is added. Modern installers store it as
`ProductPageIcon.icns` or `InstallAssistant.icns`, while older installers
(10.3 Panther through 10.6 Snow Leopard) keep a differently named icon
inside the bundle, and makedrive locates that one too. No separate icon
download is required.

When an icon is applied, makedrive copies it to the volume as
`.VolumeIcon.icns` and sets the Finder custom-icon flag so the icon
displays both in the boot picker and when the volume is mounted.

---

## Building Install Drives

Main Menu option 4 builds a drive. First choose a build type:

```
 10. Apple Silicon & Intel Installers
 11. Older PPC & Intel 10.3-10.11 Installers
 12. DataDrive Only
  X. Return to the main menu
```

Build types and the volumes they contain are defined in makedrive.conf, so
the exact list reflects your configuration.

After choosing a build type you're asked whether the contents of restorekit
should also be copied to a **DataDrive** volume on the target. A populated
DataDrive doubles as a portable backup of restorekit. If the imaging host
is ever lost, restorekit can be rebuilt by copying the DataDrive folder
structure into an empty folder named `restorekit`.

makedrive then lists the disks attached to the Mac (`diskutil list`) and
asks which disk number to erase and restore onto:

```
Enter the disk number you would like to erase & restore. For example,
if the disk you want to erase is disk2, enter "2" and hit return.
```

makedrive won't let you select the disk you're currently booted from. On
Intel Macs the boot disk is identified with `bless`; on Apple Silicon the
boot volume is protected at the system level and makedrive recognizes it as
well.

Once a valid disk number is entered, no further input is needed until
imaging finishes. `asr` decompresses and restores the images, and this is
CPU-intensive and I/O-intensive, so the host may be sluggish for other work
in the meantime. When the build completes, makedrive asks whether you'd
like to image another disk.

---

## Restoring to USB or SD Card

Main Menu option 5 restores a single installer image to a USB flash drive,
SD card, or other small media in one step. Unlike option 4 (which builds a
full multi-installer drive with an optional DataDrive), this path formats
the entire target disk as a single volume and restores exactly one image
onto it. DataDrive isn't copied.

This is the fastest way to hand someone a bootable installer for a specific
macOS version, or to quickly re-purpose a small drive without going through
a full build.

All configured image types appear in the chooser: both **GENERIC**
(createinstallmedia-based) and **INST-A** (pre-built or legacy) images. The
same boot-disk protection applies, so makedrive won't let you erase the
disk you're currently running from.

When imaging is complete, makedrive ejects the disk and asks whether you'd
like to restore another.

---

## Lion, Mountain Lion, and Mavericks Pre-flight

When installing macOS 10.7 Lion, 10.8 Mountain Lion, or 10.9 Mavericks from
a makedrive install volume, the installer may refuse to proceed with a
certificate validation error. The signing certificates embedded in these
installers have expired and Apple hasn't re-issued them, so any Mac whose
clock is past the certificate expiry date will be blocked regardless of
hardware condition.

makedrive automatically places a small shell script, `datefix`, at the root
of every 10.7, 10.8, and 10.9 install volume it deploys. Running it from
the installer's Terminal disables Wi-Fi (so the clock can't be corrected by
a time server) and sets the clock back to a date within the certificate
validity window, allowing the installer to proceed.

**To use datefix:**

1. Boot the Mac from the makedrive install volume.
2. Once the installer environment loads, open **Terminal** from the
   Utilities menu in the menu bar.
3. Run:

```
sh /Volumes/*/datefix
```

4. The script prints confirmation that Wi-Fi was disabled and the clock was
   set. Close Terminal and proceed with the installer normally.

The script detects the OS version of the installer volume automatically. If
it's run on a 10.10 or later volume by mistake, it prints a notice and
exits without changing the clock.

---

## Pushover Notifications

makedrive can send a push notification (via [Pushover](https://pushover.net))
when a build finishes or fails, so you don't have to watch the screen. This
replaces the long-retired Boxcar notification support from older versions.

Configure it from Main Menu option 6:

- **Configure or update credentials:** enter your Pushover user key and
  application (API) token. They're stored in the macOS **System Keychain**,
  not in any plain-text file.
- **Send a test notification:** confirms your credentials work.
- **Remove credentials:** deletes the stored keys from the keychain, and
  makedrive stops sending notifications.

Pushover is entirely optional. If no credentials are configured, makedrive
simply doesn't send notifications.

---

## Uninstalling makedrive

Main Menu option 7 removes makedrive from the host. To prevent accidents it
requires you to type `UNINSTALL` to confirm. When confirmed it removes:

- the `/Library/Application Support/makedrive` folder (including
  makedrive.conf and all conf archives),
- Pushover credentials from the System Keychain (if any are present), and
- the makedrive script itself.

restorekit and any drives you've already built are not touched.

---

## Security Considerations

makedrive's tools require root on the host, but because makedrive is an
open shell script, its behavior can be readily audited against your
security policy.

makedrive makes network connections in four situations, all of which can be
avoided if you prefer an offline workflow:

1. **Version checking.** At launch makedrive fetches Apple's software-update
   catalog to compare installer build numbers. The catalog URLs are defined
   in makedrive.conf. A network failure here isn't fatal: makedrive simply
   leaves the configuration unchanged and continues.
2. **PIL (Pillow) installation.** On first launch makedrive checks whether
   the Pillow Python imaging library is installed. If it isn't, makedrive
   installs it automatically via `pip` from the Python Package Index
   (PyPI). Pillow is used to normalize volume icon formats for
   compatibility with pre-2013 EFI boot pickers. After the initial
   installation it isn't re-downloaded. If installation fails, for example
   in an offline or pip-restricted environment, makedrive continues
   normally. Icons are still applied to volumes, but they may not appear in
   the boot picker on older hardware.
3. **Xcode Command Line Tools installation.** If the Xcode Command Line
   Tools aren't present, makedrive offers to install them. Typing `I` to
   confirm hands off to Apple's own installer dialog
   (`xcode-select --install`), which downloads the tools from Apple's
   servers. makedrive then exits so installation can complete before the
   next run.
4. **Pushover notifications.** Only if you configure them (Main Menu
   option 6), and only to send the notification you requested.

makedrive.conf is the configuration that drives partitioning and
deployment. It's controlled by the administrator who runs makedrive, and
it's the intended trust boundary. Pushover credentials are stored in the
System Keychain rather than in any file on disk.

### Installer binary re-signing (10.10 through 10.15)

Apple's kernel maintains a trust cache, a per-release list of known
Apple-shipped binaries. When a binary carries Apple's "platform"
code-signing marker, the kernel validates its cryptographic hash against
this list before allowing it to run. Installer binaries from 10.10 through
10.15 carry that marker, but their hashes are absent from the trust caches
of current host systems, which only include binaries shipped with recent
OS releases. The result is that the kernel terminates them immediately on
launch, preventing `createinstallmedia` and its helpers from running at
all.

This enforcement has been present on all Apple Silicon Macs since Big Sur
(macOS 11), when Apple extended the same strict trust cache model used on
iOS to the Mac. Intel Macs are subject to it as well, though enforcement
has tightened gradually and failures on Intel have been less consistent
depending on the specific macOS version the host is running.

To work around this, makedrive replaces the platform signature on those
binaries with an ad-hoc signature, a locally computed hash with no
developer identity attached. An ad-hoc signature bypasses the trust cache
check while still satisfying the kernel's requirement that every
executable be signed. makedrive signs each executable file inside the
installer bundle individually before re-signing the bundle as a whole.

A few important boundaries on what this process does and doesn't affect:

- **Only the installer application itself is re-signed.** The macOS
  content that `createinstallmedia` copies onto the bootable installer
  volume (the operating system files, frameworks, and kernel) comes
  directly from Apple's original sources and is never modified.
- **Re-signing is limited to 10.10 through 10.15.** Installers for macOS 11
  and later are currently present in the trust caches of modern host
  systems and run without re-signing. Re-signing them would additionally
  risk breaking the resulting bootable installer on Apple Silicon
  hardware, where security requirements mean ad-hoc signatures may not be
  accepted during OS installation.
- **This is a host-compatibility measure, not a security bypass.** The
  installer content you're working with is still genuine Apple software.
  The ad-hoc signature replaces only the metadata that the trust cache
  mechanism reads, and it doesn't alter any executable code.

### Rosetta 2 discontinuation (10.9 through 10.15, beginning with macOS 28)

Apple announced at WWDC 2025 that Rosetta 2, the translation layer that
lets Apple Silicon Macs run Intel software, is being phased out on a fixed
schedule:

- **macOS 26 (Tahoe)** is the last release that runs on Intel Mac hardware
  at all, and still ships the full Rosetta 2 translation layer.
- **macOS 27** runs on Apple Silicon only but still ships the full Rosetta
  2 translation layer.
- **macOS 28** (expected fall 2027) removes Rosetta 2 entirely, with no
  partial or reduced mode to fall back on.

This matters to makedrive because Apple's own tool for building macOS
10.9 Mavericks through 10.15 Catalina installers only exists as Intel
software. Those versions all predate Apple Silicon, so on an Apple Silicon
host that tool currently runs only because Rosetta 2 translates it. Once
Rosetta 2 is gone in macOS 28, it will simply stop running, and makedrive
won't be able to build fresh installers for those versions on that host.

macOS 11 (Big Sur) and later aren't affected, since Apple's installer
tooling for those versions runs natively on Apple Silicon already. macOS
10.3 Panther through 10.8 Mountain Lion aren't affected either, since
makedrive doesn't rely on that tool for versions that old in the first
place.

This is a build-host limitation only. It has no bearing on install drives
you've already built, and no bearing on the old Intel Macs those drives
are meant to install onto. An old Intel Mac being installed from 10.9
through 10.15 media is native Intel hardware and was never involved with
Rosetta at all. The constraint is entirely about which Mac you use to
*create* new installers, not anything that happens afterward.

If you expect to keep building 10.9 through 10.15 install media after this
change lands, the practical mitigation is to keep one imaging host pinned
to macOS 26 or 27 rather than upgrading every host to the latest release.
Both still carry the full Rosetta 2 layer needed to run these older
installer tools on Apple Silicon. Once a host moves to macOS 28, it can no
longer build those images at all.

---

## Changelog

Full release history is in [RELEASE_HISTORY.md](RELEASE_HISTORY.md).

### Build 201 - 2026-06-30

- **EFI volume icons now present correctly in old and new style EFI.**
- **Disk labels now present consistently across all OS versions.**
- **datefix pre-flight script:** makedrive now places a `datefix` shell
  script at the root of every deployed 10.7, 10.8, and 10.9 install
  volume. Running it from the installer's Terminal disables Wi-Fi (so the
  clock can't be corrected by a time server) and sets the clock back to a
  date within the validity window of the installer's signing certificates,
  which have expired and won't be re-issued by Apple.
- **Legacy installer re-signing (10.10 through 10.15):**
  createinstallmedia was being killed on launch (or aborting during
  framework load) on macOS 26 Golden Gate and later. Newer systems
  validate Apple "platform" binaries against a per-OS trust cache that old
  installers aren't in. makedrive now ad-hoc re-signs every executable in
  the installer bundle before running createinstallmedia, replacing the
  platform claim with a locally trusted signature. Catalina additionally
  required clearing Finder-info metadata that blocked signing. Confirmed
  building on Golden Gate for 10.13 through 11.
- **Source 10.7 through current installers from Apple directly**
- **Sierra version-mismatch fix:** Apple shipped a Sierra installer whose
  recorded version disagrees with what its createinstallmedia expects,
  which caused it to spawn endlessly. makedrive now corrects the version
  before running so creation completes.
- **Progress messaging for silent steps:** steps that hand off to a long
  external process with no output (installer verification, re-signing,
  and icon merging) now print a status line so the terminal no longer
  appears to hang.
- **Quieter keychain migration:** Pushover credential migration and
  removal no longer leak raw `security` command dumps into the terminal.
- **conf archive:** makedrive.conf migrations now archive the previous
  conf with a timestamp in a "conf archive" subfolder of Application
  Support, keeping the 10 most recent copies as a safety net against
  unintended changes.
- **Restore to USB or SD card:** new Main Menu option 4 restores a single
  installer image to a USB drive, SD card, or other small media. The full
  disk is used for the install volume, and DataDrive isn't copied.

### Build 200 - 2026-06-27 (first public release)

- Refocused makedrive as a macOS install and restore drive builder. The
  legacy diagnostic and triage subsystem (ASD/AXD downloads, diagnostic
  and triage build menus, icon-zip import) has been removed.
- Configuration externalized to **makedrive.conf**, stored in
  `/Library/Application Support/makedrive/`, with automatic migration of a
  conf placed next to the script.
- Added **Pushover** notifications (replacing the retired Boxcar service),
  with credentials stored in the System Keychain.
- Added **automatic version checking** against Apple's software-update
  catalog, keeping installer build numbers current in makedrive.conf.
- Added an **Uninstall** option to the Main Menu.
- Added installer **build-number verification** before adding to
  restorekit.
- Volume icons are now extracted automatically from the installer app
  bundle, including the differently located icon used by 10.3 through
  10.6 installers.
- Boot-disk protection now covers **Apple Silicon** in addition to Intel.
- Installer coverage spans **10.3 Panther through the current macOS
  release.**

*For the complete release history going back to 2011, see [RELEASE_HISTORY.md](RELEASE_HISTORY.md).*

---

## Acknowledgements

Starting in 2026, makedrive was developed with assistance from
[Claude](https://claude.ai) (Anthropic), which contributed to design,
implementation, debugging, and documentation throughout the project.

The fix for the macOS 10.12 Sierra `createinstallmedia` fork bomb (a
`CFBundleShortVersionString` mismatch that causes the binary to spawn
itself indefinitely) was originally documented by Nick Sherlock:
[createinstallmedia for macOS Sierra is a fork bomb](https://www.nicksherlock.com/2020/02/createinstallmedia-for-macos-sierra-is-a-fork-bomb/).
makedrive's implementation patches the version string in `Info.plist`
before invoking `createinstallmedia`, resolving the issue without
modifying any executable code.

The version checking and installer download functionality is based on
Mist:

MIT License

Copyright (c) 2021-2026 Nindi Gill

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
