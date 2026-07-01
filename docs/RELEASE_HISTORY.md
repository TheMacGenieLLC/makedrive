# makedrive Release History

Full release history from initial development through the current build.
For context on current features, see [USER_GUIDE.md](USER_GUIDE.md).

---

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

### 2018-05-15 - build 153

- Added support for 10.13.4 and 10.11.6
- Pared support to the latest OS for each supported hardware group
- Fixed an issue with the deployment of, and added support for, the latest
  version of the Blank Board Serializer tool
- Cleaned up a decent amount of code, but there's still a lot left to do
- Happy birthday to me

### 2015-02-27 - build 152

- Changed the structure of the restorekit folder to be a little cleaner. This
  change may require re-building restorekit manually from within the script. Sorry
- Removed some narrative from the source code as well as the documentation
- Removed support for Boxcar push notifications due to changes in their API. Be
  sure to delete the `~/Library/Preferences/makedrivenotificationmail.txt` file
  to ensure security of the email address previously used for Boxcar
- Added support for the latest versions of ASD
- Added support for OS X 10.9.5
- Added support for OS X 10.10.2
- Did I not warn you about 151? Can't believe it's been a year…

### 2014-02-27 - build 151

- Implemented support for OS X 10.9.2 (vital for fix of SSL/TLS bug)
- Cleaned up some menu logic for fewer parsing errors and ease of code reading
- Structured disk deployment configuration menu for better hierarchy. Note that
  some of your favorite menu item numbers may have changed!
- Custom makedrive deployment configurations now have their own sub-menu, and
  much more headroom in terms of function numbering. Customize away
- Fixed a bug that prevented the user from exiting the push notification
  configuration menu
- Should not be consumed on its own. For your safety, use only for mixing

### 2014-01-24 - build 150

- Created an AXD-only configuration option
- Due to a bug with APM disks having a large number of volumes, removed AXD from
  the main ASD configuration. ASD disks now format and build correctly
- Releasing this build to the public. Sorry for the extraordinary delay

### 2014-01-09 - build 149

- Added support for ASD 3S159
- Released in parallel with this build are new gray-coded and color-coded icon
  sets for those interested in improved volume type differentiation

### 2013-12-21 - build 148

- Added support for 10.9.1 Install and Triage

### 2013-11-02 - build 147

- Added a simple function to install icons into restorekit from a .zip download.
  This function is now option #3 in the Main Menu. "Build Drives" is now option #4
- The postflight cleanup now fixes permissions of the restorekit folder so that
  restorekit can be manipulated in the Finder without a password prompt
- Fixed an issue where the user would be returned to the Main Menu rather than
  the "Install DMG" function menu as intended

### 2013-10-30 - build 146

- Added functionality to warn if volume icon files are missing. The message will
  appear along with missing DMGs, if any
- Fixed an issue where OS X 10.9 Mavericks install DMGs would not always be
  created or restored correctly

### 2013-10-22 - build 145

- Added full support for OS X 10.9 Install and Triage
- Added support for ASD 3S158

### 2013-10-17 - build 144

- A major internal overhaul of the script. Removed a lot of redundancies,
  consolidated functionality, and reduced script size by more than 10%
- Initial support for OS X 10.9 Boot volumes
- Mac App Store OS installers must now be added from an App Store download
- Fixed OS installer version checking, prevents accidentally adding the wrong
  installer to restorekit

### 2013-10-03 - build 143

- Updated 10.8.5 Install version check for today's re-release

### 2013-10-02 - build 142

- Re-implemented verification of installer certificates. 3X109 has been
  re-released with a new security certificate, and certificates are now required
  to be valid
- Cleaned up the interface and changed wording in a bunch of places to be more
  clear and concise, less ambiguous

### 2013-09-25 - build 141

- Removed support for ASD 3S152
- Implemented support for ASD 3S157
- Corrected a no-longer-accurate text string in the "Add new DMG" function

### 2013-09-18 - build 140

- Implemented support for OS X 10.8.5 Triage

### 2013-09-12 - build 139

- Implemented support for OS X 10.8.5 Install (no triage yet)
- makedrive now prompts the user to create an empty restorekit folder upon
  launch, should one not be present (rather than presenting an error)
- All images can now be added to an empty restorekit folder. Previously, most
  images would not copy if intermediate directories were missing from the target
- After choosing a target configuration, one can now exit to the main menu from
  the target device selection screen rather than having to kill the script to go back

### 2013-08-22 - build 138

- Implemented workaround for a Terminal.app bug where root-owned processes are
  not terminated when quitting the application (rdar://problem/6259606), which
  caused a launch failure due to the unexpected persistence of the script instance
- Removed separate build functions for each configuration and consolidated build
  calls to the `build_run_build_task` routing function. Custom configuration
  syntax has not changed since version 137, it just has a new home
- Removed "Triage Tools" flash configuration (seems rarely used)

### 2013-08-19 - build 137

- Removed Mac OS X 10.5 boot and install from all configs except "Universal"
- Completely overhauled formatting and deployment functions to be much more
  simple when creating custom configurations
- Added two empty "Custom Configuration" functions and spots in config menu
- Fixed the bless command for AXD volumes. Volume names should now display
  correctly in Startup Manager

### 2013-08-13 - build 136

- Various minor UI spacing cleanups
- Implemented script lockfile, prevents running multiple makedrive instances
  (this avoids bad things)
- Implemented initial support for OS X 10.9 Mavericks installation testing
  (10.9 Mavericks support is only implemented in a single USB flash configuration)
- Changed the "DataDrive only, for testing use" configuration to state it should
  be used to build a disk for sharing makedrive and restorekit with another team
- Removed support for closing automatically-opened Finder windows. Older OS
  installation images cause this behavior, and research is ongoing for a reliable fix

### 2013-06-12 - build 135

- Implemented support for ASD 3S156

### 2013-06-09 - build 134

- Implemented support for 10.8.4
- Implemented support for custom volume icon sets
- Created a default custom volume icon set, distributed separately
- Minor internal code cleanups

### 2013-03-31 - build 133

- Implemented support for ASD 3S155
- Removed support for ASD 3S150 (redundant)
- Implemented support for Boxcar push notifications (optional)
- Removed support for Speech Services verbal notification

### 2013-03-15 - build 132

- Re-implemented support for AXD 106
- Implemented support for 10.8.3
- Cleanups and removal of some redundant code
- New USB flash configuration for 64GB drives. Builds 10.8/10.6 triage as well as
  10.8/10.7/10.6 installers on one flash drive

### 2012-11-30 - build 131

- Removed the PowerPC-only configuration (use the Universal config for PPC)
- Removed 10.4 installer from the Intel-only configuration (still in Universal)
- Added support for ASD 3S152, removed 3S151 support per GSX guidance
- Corrected menu choice bug where each ASD 3S150 volume was listed twice
- Cleaned up some leftovers in the code and added more documentation in various places

### 2012-10-31 - build 130

- Added support for ASD 3S151 and AXD 3X111
- Removed 10.7 triage boot from Intel diagnostic configuration. If it doesn't
  boot to 10.8, it will boot to 10.6. Needed fewer volumes on disk
- Converted all `cp` functions to `rsync` for better progress visibility
- Fixed an issue where adding ASD images to a symlinked restorekit folder would fail
- Removed all version numbers from hard-coded triage disk image names
- Updated the version comparison references for the latest 10.7 and 10.8 Mac App
  Store installer bundles

### 2012-09-19 - build 129

- Support for 10.7.5 and 10.8.2 installation DMGs
- Improved verification of MAS bundles prevents installation of the wrong minor
  version of OS X (couldn't differentiate 10.7.4 & 10.7.5, for example)
- Triage image version support is 10.7.4 and 10.8
- makedrive "1" is now in support-only mode. makedrive "2" will be an ongoing
  personal development and release details will be forthcoming

### 2012-07-17 - build 128

- Script functions renamed and made more hierarchical (easier to read & follow)
- Fully implemented directly adding images into makedrive/restorekit
- Compress/scan images are now one option, and it does it all in one go
- Scanning for restore now only scans images without scan data (much faster)
- MAS 10.7 and 10.8 system installers can be added from the app download itself
- Added 10.8 install and triage images to all relevant disk build configurations
- Added USB flash configurations for home or lab use

### 2012-06-25 - build 127

- Cleaned up a lot of the imaging routines, eliminating nearly 700 lines of
  redundant code
- Fixed an issue where ASD EFI images were not fully restoring with proper blessing

### 2012-06-24 - build 126

- Interface tidying and cleanup; makedrive now shows version info with date & time
  at the top of the window; more consistent text input
- makedrive now compresses disk images and suggests checking all images for
  restore afterward
- Minor logic cleanups, plus support added for ASD 150 to work with the mid-2012
  computers launched at WWDC. Several older ASD versions were updated with 'A'
  versions available only through GSX (not on service source). Please ensure
  you're using updated ASD 132, 142, and 145 image sets and folder names

### 2012-05-28 - build 125

- Updated disk image information to store partition size and other information in
  a single global location rather than individually coded values in each
  configuration, making partition sizes easier to change
- The DataDrive partition name can now be changed in the script (one global near
  the top) without causing problems

### 2012-05-23 - build 124

- Added functionality to close Finder windows opened by installation images that
  are restored to disk
- Added a 3-second sleep after each volume is restored before Spotlight is
  disabled, to prevent Spotlight from randomly spawning during imaging

### 2012-05-23 - build 123

- Fixed a bug where AXD volumes weren't properly created in the EFI flash drive
  configuration; fixed an issue where two OS148 volumes were created, causing
  OS149 to not image; tidied up the rsync copy
- AXD 109's install package certificate is expired; using the `allowUntrusted`
  flag for its installation until Apple resolves it

### 2012-05-21 - build 122

- Fixed a bug that prevented the text file from being created on DataDrive
- Renamed a few functions for consistency and moved some tasks to more
  appropriate functions

### 2012-05-20 - build 121

- Textual interface cleanups; updated image titles to newest available
- Made specific Intel and PPC triage configs in addition to the universal one
- Switched the DataDrive partition copy to `rsync` for per-file progress

### 2012-05-07 - build 120

- Integrated ASD 149 (released via a GSX article) and removed ASD 143, which it
  replaced
- Reordered the disk-image titling to roughly reverse-chronological order
- Updated the voice announcement and triage image names

### 2012-03-24 - build 119

- Updated image names for newer triage packages and OS installers
- Spotlight handling in makedrive no longer deletes indices; it only stops the
  index process while the script runs
- Updated ASD OS 138 sizing

### 2012-01-17 - build 118

- Increased the sizes on most ASD OS volumes to prevent "out of memory" errors
- By request, makedrive now offers a spoken voice notification when imaging
  completes - handy when working away from the imaging station
- Small code cleanups and interface tidying

### 2011-12-14 - build 117

- makedrive now works properly in both OS X 10.6 and 10.7
- More state moved into single-location variables; beginning to migrate toward a
  more object-oriented style as far as a bash script allows
- AXD (a DMG containing pkg installers) is now installed for you onto ASD hard
  disks and flash drives
- The inability to partition the ASD drives as GPT remains unresolved through
  engineering and developer channels; the open bug is rdar://problem/9720530

### 2011-11-12 - build 116

- Disk-image paths for each file are now loaded into a global variable once at
  the start of the script, so names can be changed in one place
- Image structure changed from a custom-named image in a sub-folder to pulling
  directly from plain-English named folders; update your folders or the script
  paths accordingly
- Added ASD 148 to the respective drive types

### 2011-08-12 - build 115

- Updated ASD configurations for 3S147 on both hard disk and flash drive

### 2011-07-28 - build 114

- Updated ASD configuration for 3S146 on flash drive

### 2011-07-27 - build 113

- Updated ASD disk configuration for 3S146 EFI and OS (flash not yet updated)

### 2011-07-21 - build 112

- Updated triage disk config for Lion Install. Note that both Lion triage and
  Lion installers are incompatible with the mid-2011 MacBook Air and Mac mini

### 2011-07-20 - build 111

- Updated the triage disk build for Mac OS X 10.7 Lion triage functionality

### 2011-07-12 - build 110

- Updated the flash drive partition function to name it 'DataDrive' to avoid a
  rename error in cleanup
- Note: a bug in 10.6.8's `diskutil` prevents proper GPT partitioning, so all
  partitioning is APM until addressed

### 2011-07-01 - build 109

- Worked around the `/Volumes` folder issue when a disk is disconnected
  mid-imaging by partitioning as "DataDriveTempFolder" and renaming to "DataDrive"
  after the copy completes

### 2011-06-28 - build 108

- Added config information for 10.6.8 Boot partitions on both ASD and triage
  drives, plus miscellaneous cleanups

### 2011-06-13 - build 107

- Removed the cooling-system diagnostic from the ASD disk setup (the test was
  integrated into AST/MRI for network diagnostic use and the standalone image is
  deprecated)
- Added 1 GB to the ASD OS 145 partition to address "startup disk full" errors

### 2011-05-25 - build 106

- Added the 10.6 boot partition to the ASD configuration by request; it can be
  removed easily but has been a useful addition in day-to-day use

### 2011-05-23 - build 105

- Added ASD 145 to the diagnostic and USB flash configurations. The file naming
  convention is unchanged, but you may need to add the disk images manually

### 2011-05-08 - build 104

- Reverted to APM for all disk types, as the syntax correction did not
  consistently resolve a re-mounting failure. All disks build correctly, though
  APM-partitioned

### 2011-05-08 - build 103

- Removed the message from the data-partition copy that stated the data partition
  was not copied and required a return. Disks now eject immediately upon restore
  completion and prompt for the next disk

### 2011-05-08 - build 102

- Reverted to proper partition-scheme syntax, which may have been related to
  partitioning issues on some test machines

### 2011-05-07 - build 101

- After re-imaging test machines, the script would fail when `asr` restored to
  ASD disks. Isolated to `asr` unmounting all partitions on a GPT disk but not
  re-mounting them; distributing with APM as the default for now

### 2011-04-18 - build 100

- Created the USB flash drive configuration for use outside service environments. The
  flash configuration does not allow the data partition to be copied to remaining
  space; it should fit most 2 GB flash drives and all larger ones

### Earlier (2011, pre-build-numbering)

- Updated ASD OS 138 partition size to eliminate "startup disk almost full"
- Updated naming and bless commands for the 10.6.7 boot drive
- Updated the script for ASD 3S144 and the new Cooling System Diagnostic
- Reorganized the restorekit ASD folder structure for easier updates
- Re-configured triage drive bless commands for PowerPC booting (verified on
  iMac G5); fixed older Intel machines showing boot partitions as 'EFI Boot'
- Nearly rewrote the script using proper functions and more useful input checks;
  compensates for the boot disk not being set in NVRAM
- Added input checking for the drive-number prompt (checks the disk ID exists in
  `/dev`)
- Fixed a bug where imaging another drive reused the previously chosen disk type
- Initial version-tracking commentary and documentation; added detection of the
  boot disk to prevent its erasure
