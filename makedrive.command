#!/bin/bash

# shellcheck disable=SC2154  # config vars (catalogURLs, imageFilePaths, etc.) are set in makedrive.conf, sourced at runtime

# makedrive.command
#
# Created by:
# Ian Williams, The Mac Genie LLC
# ian@themacgenie.com
#
# https://makedrive.com
#
# Current script version:
currentVersion="2026-11-03 - Build 203"

# Global Variable Declarations
bootDiskID=""
diskNum=""
diskType=""
doDrive=""
executionPath=""
imagePathToAdd=""
imageToAdd=""
lastBuildError=""
okToCopyData=""
okToErase=""
stayInMainMenuLoop=""
timeMachineDiskID=""
timeMachineUnreadable=""
trackToTake=""

# Script-internal temporary file paths. The lockfile must live at a fixed,
# predictable path so a second instance can find it. Everything else lives in
# a root-owned scratch directory created with an unpredictable name once root
# is established (see the mktemp -d in the startup flow) - fixed scratch
# paths in world-writable /var/tmp would be symlink-plant targets for a
# process running as root.
makedriveLockFile="/var/tmp/makedrivelockfile"
makedriveScratchDir=""
makedriveInstTmpImageFile=""

# Configuration and credentials are stored in the invoking user's home directory.
# Before sudo elevation $SUDO_USER is empty and $USER is the real user; after
# elevation $SUDO_USER is the real user. Both cases resolve to the same home.
_makedrive_userhome=$(eval echo "~${SUDO_USER:-$USER}")
makedriveSupportDir="${_makedrive_userhome}/Library/Application Support/makedrive"
makedriveSupportConf="${makedriveSupportDir}/makedrive.conf"
makedrivePushoverKeychain="${_makedrive_userhome}/Library/Keychains/login.keychain-db"
unset _makedrive_userhome

# Image definitions, imageFilePaths, and build type configurations are
# loaded from makedrive.conf at startup.

declare -a imagesThatFailedCompression
declare -a imagesThatFailedScan

# Main Functions

# ------------------------------------------------------------------------------
# normalize_icon_for_efi
# Normalizes a .icns file to include it32 + t8mk legacy chunks alongside the
# existing PNG slices (ic08 / ic09 / ic10). Pre-2013 EFI firmware cannot decode
# the PNG-only format used in 10.7-10.14 installer icons and reads only the
# legacy it32 (128×128 raw RGB, PackBits) + t8mk (128×128 alpha mask) format.
# Newer EFI and macOS continue to use the existing PNG slices.
#
# If PIL is unavailable or normalization fails, returns silently without error -
# the icon still works, just may not appear in older EFI boot pickers.
#
# To disable: comment out the call in dmg_apply_volume_icon (search for ICON_NORM)
#
# $1 - Path to the .icns file to normalize (modified in-place)
# ------------------------------------------------------------------------------
normalize_icon_for_efi () {

	local iconPath="$1"
	[ -z "$iconPath" ] || [ ! -f "$iconPath" ] && return 0

	MAKEDRIVE_ICON_NORM_PATH="$iconPath" python3 << 'MAKEDRIVE_ICON_NORM_PYEOF'
import os, io, struct, sys

iconPath = os.environ.get("MAKEDRIVE_ICON_NORM_PATH", "")
if not iconPath or not os.path.isfile(iconPath):
    sys.exit(0)

try:
    from PIL import Image
except ImportError:
    sys.exit(0)

ICNS_MAGIC = b'icns'
PNG_SIG    = b'\x89PNG\r\n\x1a\n'

def parse_icns(data):
    if data[:4] != ICNS_MAGIC:
        return []
    chunks, off = [], 8
    while off + 8 <= len(data):
        typ  = data[off:off+4]
        size = struct.unpack_from('>I', data, off+4)[0]
        if size < 8 or off + size > len(data):
            break
        chunks.append((typ, data[off+8:off+size]))
        off += size
    return chunks

def build_icns(chunks):
    body = bytearray()
    for typ, payload in chunks:
        body += typ + struct.pack('>I', 8 + len(payload)) + payload
    return ICNS_MAGIC + struct.pack('>I', 8 + len(body)) + bytes(body)

def packbits_encode(data):
    # icns-specific RLE variant (it32/il32/ih32/is32), NOT classic PackBits:
    # literal header 0x00-0x7F -> next (N+1) bytes; repeat header 0x80-0xFF ->
    # next byte repeated (N-0x80+3) times, so a repeat run needs >=3 identical
    # bytes (max 130), not 2 as in classic PackBits.
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        run_len = 1
        while i + run_len < n and run_len < 130 and data[i + run_len] == data[i]:
            run_len += 1
        if run_len >= 3:
            out.append(0x80 + (run_len - 3))
            out.append(data[i])
            i += run_len
            continue
        start = i
        i += 1
        while i < n and (i - start) < 128:
            k = 1
            while i + k < n and k < 130 and data[i + k] == data[i]:
                k += 1
            if k >= 3:
                break
            i += 1
        out.append(i - start - 1)
        out.extend(data[start:i])
    return bytes(out)

try:
    with open(iconPath, 'rb') as f:
        icns_data = f.read()

    chunks = parse_icns(icns_data)
    if not chunks:
        sys.exit(0)

    # Already has legacy chunks - nothing to do
    if any(t == b'it32' for t, _ in chunks):
        sys.exit(0)

    # Find a PNG source chunk; prefer largest (ic10 > ic09 > ic08)
    src_png = None
    for preferred in (b'ic10', b'ic09', b'ic08'):
        for typ, payload in chunks:
            if typ == preferred and payload[:8] == PNG_SIG:
                src_png = payload
                break
        if src_png:
            break

    if not src_png:
        sys.exit(0)

    img = Image.open(io.BytesIO(src_png)).convert("RGBA").resize((128, 128), Image.LANCZOS)
    r, g, b, a = img.split()

    it32_payload = (b'\x00\x00\x00\x00' +
                    packbits_encode(r.tobytes()) +
                    packbits_encode(g.tobytes()) +
                    packbits_encode(b.tobytes()))
    t8mk_payload = a.tobytes()

    # Prepend legacy chunks so they appear first (some EFI parsers scan forward)
    new_chunks = [(b'it32', it32_payload), (b't8mk', t8mk_payload)] + chunks
    with open(iconPath, 'wb') as f:
        f.write(build_icns(new_chunks))

except Exception:
    pass

MAKEDRIVE_ICON_NORM_PYEOF
}


# ------------------------------------------------------------------------------
# dmg_apply_volume_icon
# Copies the installer's custom icon onto an already-mounted volume and sets
# the custom-icon flag. Tries ProductPageIcon.icns first (Tahoe and later),
# then InstallAssistant.icns. Older installer apps (10.3 through 10.6) use
# neither name, so it falls back to the icon CFBundleIconFile names, then to
# the largest .icns in the bundle. Does nothing if none is found.
#
# $1 - Path to the installer application bundle (icon source)
# $2 - Path to the mounted volume (e.g. /Volumes/MyVolume)
# ------------------------------------------------------------------------------
dmg_apply_volume_icon () {

	local icnsPath=""

	if [ -e "$1/Contents/Resources/ProductPageIcon.icns" ]; then
		icnsPath="$1/Contents/Resources/ProductPageIcon.icns"
	elif [ -e "$1/Contents/Resources/InstallAssistant.icns" ]; then
		icnsPath="$1/Contents/Resources/InstallAssistant.icns"
	else
		# Older installer apps (10.3 Panther through 10.6 Snow Leopard) use a
		# different icns name and don't always keep it at the top level of
		# Contents/Resources. Read CFBundleIconFile from the app's Info.plist
		# first; if that key is absent or its file isn't where it points, fall
		# back to the largest .icns found anywhere in the bundle.
		local iconFile=""
		iconFile=$(plutil -extract CFBundleIconFile raw \
		    "$1/Contents/Info.plist" 2>/dev/null)
		if [ -n "$iconFile" ]; then
			[[ "$iconFile" != *.icns ]] && iconFile="${iconFile}.icns"
			[ -e "$1/Contents/Resources/$iconFile" ] && \
			    icnsPath="$1/Contents/Resources/$iconFile"
		fi
		if [ -z "$icnsPath" ]; then
			icnsPath=$(find "$1" \
			    -name "*.icns" ! -name "*.licns" 2>/dev/null \
			    | while IFS= read -r f; do
			        printf '%d\t%s\n' "$(stat -f%z "$f")" "$f"
			      done | sort -t$'\t' -k1 -rn | head -1 | cut -f2)
		fi
	fi

	if [ -n "$icnsPath" ]; then
		# ICON_NORM: Normalize icon for EFI compatibility (pre-2013 firmware support)
		# To disable: comment out the next line
		normalize_icon_for_efi "$icnsPath"

		cp "$icnsPath" "$2/.VolumeIcon.icns"
		setfile -a C "$2"
	fi

}


# ------------------------------------------------------------------------------
# add_offer_app_removal
# Shows where an installer app makedrive placed in /Applications is and asks
# whether to delete it. The app runs several gigabytes and the finished image
# never reads it again, but it is also the quickest way to retry an add that
# failed, so removal is offered rather than assumed, and each outcome says
# what keeping the app is good for. Anything typed during the long build is
# discarded first so it can't answer the question unseen. Does nothing if the
# app is not there.
#
# $1 - Path to the installer app
# $2 - Result of the add that used it (0 = the image was added)
# $3 - Where the app came from: "download" (Main Menu option 2) or "package"
#      (assembled from a package supplied through option 1)
# ------------------------------------------------------------------------------
add_offer_app_removal () {

	local appPath="$1" addResult="$2" appSource="$3"
	local appOrigin="downloaded for this image" deleteApp

	[ -n "$appPath" ] && [ -d "$appPath" ] || return 0

	[ "$appSource" = "package" ] && appOrigin="assembled from your package"

	disp_print_header

	if [ "$addResult" = "0" ]; then
		echo "The installer app $appOrigin is still in /Applications:"
		echo "  $appPath"
		echo ""
		echo "The image in restorekit doesn't need it. Keep it only if you want the"
		echo "installer app itself."
	else
		echo "The add did not finish, but the installer app $appOrigin"
		echo "is still in /Applications:"
		echo "  $appPath"
		echo ""
		if [ "$appSource" = "package" ]; then
			echo "Keep it to try again without supplying the package a second time. Delete"
			echo "it if the package was the wrong one, so makedrive asks for it again."
		else
			echo "Keeping it lets you try again through Main Menu option 1 without"
			echo "downloading it a second time."
		fi
	fi

	echo ""
	disp_discard_typeahead
	printf "Delete it to free up disk space? Y/N: "
	read -r deleteApp

	if [ "$deleteApp" = "Y" ] || [ "$deleteApp" = "y" ]; then
		if ! rm -rf "$appPath"; then
			echo ""
			echo "The installer app could not be removed. Delete it from /Applications"
			echo "yourself to reclaim the space."
			echo ""
			disp_pause_for_input
		fi
	fi

	return 0

}


# ------------------------------------------------------------------------------
# add_copy_single_dmg
# Processes a given single disk image and copies it into its proper location
# inside of the restorekit folder.
#
# $1 - Display name string for chosen disk image
# $2 - Path to designated target image location in restorekit
# $3 - Correct mounted image name (for comparison to user-provided image)
# $4 - Build number to search for in the SystemInformation.plist file
#      (Only needed when copying an OS installer)
# $5 - Path to source DMG, if already known (leave empty to prompt the user)
# $6 - Path to installer application bundle for volume icon (leave empty to skip)
#
# Returns 0 once the image is in restorekit, compressed, and scanned; 1 otherwise.
# ------------------------------------------------------------------------------
add_copy_single_dmg () {

	local testDevice testMountPoint mpBase grepReturn dmgBaseDir _pkgExtractedApp=""
	local copyResult=1

	disp_print_header

	# If $5 is empty, we don't have a source DMG yet; prompt the user to find
	# one. If $5 points to an existing file, use it directly.
	if [ "$5" = "" ]; then

		echo "Drag the DMG for $1 into "
		echo "the terminal window and hit return to add the image into restorekit."
		echo ""
		read -r imagePathToAdd

		# Dragging a file into Terminal backslash-escapes spaces (and other
		# special characters) in the path. read -r keeps those backslashes
		# verbatim, so the quoted path handed to hdiutil below would name a
		# file that doesn't exist.
		imagePathToAdd="${imagePathToAdd//\\/}"

	elif [ -f "$5" ]; then

		imagePathToAdd="$5"

	else

		# $5 is set but the ESD doesn't exist. Derive the installer app path
		# by stripping the SharedSupport suffix and offer pkg extraction.
		local _derivedApp="${5%/Contents/SharedSupport/InstallESD.dmg}"
		if [ "$_derivedApp" = "$5" ] || [ -d "$_derivedApp" ]; then
			imagePathToAdd="$5"
		else
			add_installer_from_pkg "$_derivedApp" "$1" || return 1
			_pkgExtractedApp="$_derivedApp"
			imagePathToAdd="$5"
		fi

	fi

	echo "Verifying disk image source and destination..."
	echo ""
	
	# Since we need to mount the image with its own name to verify if it is
	# correct, we need the device ID to properly unmount.
	IFS=$'\t' read -r testDevice testMountPoint < <(dmgtool_attach_parse "$imagePathToAdd" -readonly)

	if [ -z "$testDevice" ]; then
		disp_print_header
		echo "The disk image could not be mounted. Verify the file and try again."
		echo ""
		disp_pause_for_input
		imagePathToAdd=""
		add_offer_app_removal "$_pkgExtractedApp" 1 package
		return 1
	fi

	# Validate against the image's own mount point rather than the expected
	# /Volumes path, so a name collision with an already-mounted volume
	# (which shifts our mount to "<name> 2") can neither fail the right
	# image nor let the pre-existing volume vouch for a wrong one. The
	# mount-point suffix macOS adds on collision is tolerated because the
	# volume name inside the image is unchanged by it. Ambiguous volume
	# names (shared by every retail DVD and install ESD of the era) get a
	# build number check on top of the name.
	mpBase="${testMountPoint##*/}"
	grepReturn=1
	case "$mpBase" in
	"$3"|"$3 "[0-9]* )
		if [ "$3" = "Mac OS X Install DVD" ] || [ "$3" = "Mac OS X Install ESD" ]; then
			grep -qF "$4" "$testMountPoint/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null
			grepReturn=$?
		else
			grepReturn=0
		fi
		;;
	esac
	
	hdiutil detach -quiet "$testDevice"
		
	# A match means the source image is what we want to add into restorekit.
	if [ "$grepReturn" = "0" ]; then
		
		disp_print_header
		
		echo "$1 appears valid and is"
		echo "copying to restorekit now."
		echo ""
		
		# Get the base directory path to ensure no rsync errors if the full
		# directory hierarchy is not present
		dmgBaseDir=$(dirname "$2")
	
		if [ ! -d "$dmgBaseDir" ]; then
		
			mkdir -p "$dmgBaseDir"
	
		fi

		if rsync -Wh --progress "$imagePathToAdd" "$2"; then

			# Determine icon source. Use $6 (external app path) when provided,
			# or an app just extracted from a pkg. Otherwise the image itself is
			# searched for an embedded installer bundle while it is attached for
			# icon work below (e.g. a pre-built installer volume like Mavericks,
			# or a retail DVD). Modern installers are named "Install*.app"; classic
			# retail DVDs (10.3 Panther / 10.4 Tiger) ship an extensionless
			# "Install Mac OS X" bundle under "Welcome to Mac OS X". DVDs with no
			# installer bundle skip the icon step.
			local iconSource="$6"
			[ -z "$iconSource" ] && [ -n "$_pkgExtractedApp" ] && iconSource="$_pkgExtractedApp"

			# The image is never attached writable: a shadow file catches the icon
			# writes (also the only attach mode DVD-style Apple_Driver_ATAPI images
			# allow on Apple Silicon), and a single convert then merges base plus
			# shadow into the UDRW image that is byte-patched below and compressed
			# after. Compress and scan run exactly once, after any icon work is
			# done.
			local iconShadow="$makedriveScratchDir/makedrive-icon.shadow"
			local iconMergedDmg="$makedriveScratchDir/makedrive-icon-merged.dmg"
			local iconMount="" iconApplied="N"
			rm -f "$iconShadow"
			IFS=$'\t' read -r _ iconMount < <(dmgtool_attach_parse "$2" -shadow "$iconShadow")
			if [ -n "$iconMount" ]; then
				local applySrc="$iconSource"
				[ -z "$applySrc" ] && applySrc=$(find "$iconMount" -type d -maxdepth 2 \
				    \( -name "Install Mac OS X" \
				       -o -name "Install Mac OS X*.app" \
				       -o -name "Install OS X*.app" \
				       -o -name "Install macOS*.app" \) \
				    -print -quit 2>/dev/null)
				if [ -n "$applySrc" ]; then
					dmg_apply_volume_icon "$applySrc" "$iconMount"
					iconApplied="Y"
				fi
				hdiutil detach -quiet "$iconMount" 2>/dev/null
			fi

			# Merge only when an icon was actually written; if the merge fails the
			# original image is left untouched and simply goes uniconed.
			if [ "$iconApplied" = "Y" ]; then
				echo "Merging icon changes..."
				if hdiutil convert "$2" -shadow "$iconShadow" \
				    -format UDRW -o "$iconMergedDmg" 2>/dev/null; then
					# Zero finderInfo[0..5] in the merged image. Running post-merge
					# ensures the shadow write-back (macOS updates the volume header
					# on mount/unmount) cannot override the patch. finderInfo[6,7]
					# (UUID) are preserved. finderInfo[1]=0 means no open-folder CNID
					# so Finder does not auto-open on a fresh hardware connect.
					# 10.7+ images use GUID and have no APM DDM; they exit early.
					python3 -c "
import sys, struct
with open(sys.argv[1], 'r+b') as f:
    ddm = f.read(4)
    if len(ddm) < 4:
        sys.exit(0)
    hfs_off = None
    if struct.unpack_from('>H', ddm)[0] == 0x4552:
        # APM: locate HFS+ partition via partition map
        blk_size = struct.unpack_from('>H', ddm, 2)[0] or 512
        i = 1
        while True:
            f.seek(blk_size * i)
            blk = f.read(512)
            if len(blk) < 512 or struct.unpack_from('>H', blk)[0] != 0x504D:
                break
            if b'HFS' in blk[48:80] and hfs_off is None:
                hfs_off = struct.unpack_from('>I', blk, 8)[0] * blk_size
            i += 1
    else:
        # No APM: bare HFS+ image - volume header at offset 1024
        f.seek(1024)
        if struct.unpack_from('>H', f.read(2))[0] in (0x482B, 0x4244):
            hfs_off = 0
    if hfs_off is not None:
        base = hfs_off + 1024 + 80
        for idx in range(6):
            f.seek(base + idx * 4)
            if struct.unpack('>I', f.read(4))[0]:
                f.seek(base + idx * 4)
                f.write(b'\\x00\\x00\\x00\\x00')
" "$iconMergedDmg" 2>/dev/null
					rm -f "$2"
					mv "$iconMergedDmg" "$2"
				fi
			fi
			rm -f "$iconShadow" "$iconMergedDmg"

			if dmgtool_prepare_dmg "$2" "$1"; then
				disp_print_header
				echo "$1 was successfully copied into restorekit."
				copyResult=0
			fi

		else
			
			echo ""
			echo "$1 was NOT successfully copied into restorekit."
			echo "Check the image source and destination, then try again."
		
		fi
	
	# No match means the image did not mount or, more likely, is the wrong DMG.
	else
	
		disp_print_header
		
		echo "The image does not appear to match $1."
		echo "It may be the wrong image, it may have been modified since it was downloaded,"
		echo "or it may not be titled the way makedrive expects. Verify your image and try"
		echo "adding it again."
	
	fi
	
	echo ""
	disp_pause_for_input

	imagePathToAdd=""
	add_offer_app_removal "$_pkgExtractedApp" "$copyResult" package

	return "$copyResult"

}


# ------------------------------------------------------------------------------
# add_create_install_dmg
# Creates the DMG file for installers that use createinstallmedia
#
# $1 - Destination DMG name with full path
# $2 - Size of DMG volume to be created
# $3 - Temporary name of the image volume used while creating the installer
# ------------------------------------------------------------------------------
add_create_install_dmg () {

	# hdiutil create is formally deprecated as of macOS 26 in favor of
	# "diskutil image create blank"; it still works everywhere makedrive
	# runs, but expect this call to need migrating in a future release.
	if ! hdiutil create -o "$1" -size "$2" -layout SPUD -fs JHFS+ -volname "$3"; then
		return 1
	fi

	hdiutil mount -nobrowse "$1"

}


# ------------------------------------------------------------------------------
# read_installer_build
# Returns the macOS build string actually present in the installer at $1, or
# nothing if it cannot be determined. This is the single source of truth for
# both verification and error reporting; it never fails the caller.
#
# Four ways to find the build, tried in this order:
#
#   Explicit key: ProductBuildVersion in InstallInfo.plist, which makedrive
#     writes when it assembles a 10.13 through 10.15 installer from the catalog.
#
#   New-format (Big Sur 11+): build metadata is inside SharedSupport.dmg, read
#     from Assets.0.Build in the MobileAsset XML.
#
#   InstallESD generation (10.7 Lion through 10.15 Catalina): InstallInfo.plist
#     records only the version, not the build. The build lives in BaseSystem.dmg
#     at System/Library/CoreServices/SystemVersion.plist (ProductBuildVersion).
#     BaseSystem.dmg sits either directly in SharedSupport (Mojave/Catalina) or
#     nested inside InstallESD.dmg (older), so we mount whatever is needed and
#     always detach both, in reverse order.
#
#   Fallback: a build-number-shaped token scanned out of InstallInfo.plist.
#
# $1 - Path to the installer application bundle
# ------------------------------------------------------------------------------
read_installer_build () {

	local installInfo="${1}/Contents/SharedSupport/InstallInfo.plist"
	local ssDmg="${1}/Contents/SharedSupport/SharedSupport.dmg"
	local esdDmg="${1}/Contents/SharedSupport/InstallESD.dmg"
	local directBase="${1}/Contents/SharedSupport/BaseSystem.dmg"
	local build=""

	# Explicit key written by catalog_hfs assembly: ProductBuildVersion in
	# InstallInfo.plist is the authoritative build from the catalog dist file.
	# Check this before mounting BaseSystem.dmg, whose recovery build may differ.
	if [ -f "$installInfo" ]; then
		build=$(plutil -extract "ProductBuildVersion" raw -o - "$installInfo" 2>/dev/null)
		if [ -n "$build" ]; then
			printf '%s' "$build"
			return 0
		fi
	fi

	# New-format (11+): build is inside SharedSupport.dmg.
	if [ -f "$ssDmg" ]; then
		local ssDevice ssMountPoint
		IFS=$'\t' read -r ssDevice ssMountPoint < <(dmgtool_attach_parse "$ssDmg" -readonly)
		if [ -n "$ssDevice" ]; then
			build=$(plutil -extract "Assets.0.Build" raw -o - \
			    "${ssMountPoint}/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml" \
			    2>/dev/null)
			hdiutil detach -quiet "$ssDevice" 2>/dev/null
		fi
		printf '%s' "$build"
		return 0
	fi

	# InstallESD generation (10.7 through 10.15): build is in BaseSystem.dmg.
	if [ -f "$esdDmg" ] || [ -f "$directBase" ]; then
		local esdDevice="" baseDmg=""

		if [ -f "$directBase" ]; then
			baseDmg="$directBase"
		else
			local esdMountPoint
			IFS=$'\t' read -r esdDevice esdMountPoint < <(dmgtool_attach_parse "$esdDmg" -readonly)
			[ -n "$esdMountPoint" ] && baseDmg="${esdMountPoint}/BaseSystem.dmg"
		fi

		if [ -n "$baseDmg" ] && [ -f "$baseDmg" ]; then
			local baseDevice baseMountPoint
			IFS=$'\t' read -r baseDevice baseMountPoint < <(dmgtool_attach_parse "$baseDmg" -readonly)
			if [ -n "$baseDevice" ]; then
				build=$(plutil -extract "ProductBuildVersion" raw -o - \
				    "${baseMountPoint}/System/Library/CoreServices/SystemVersion.plist" \
				    2>/dev/null)
				hdiutil detach -quiet "$baseDevice" 2>/dev/null
			fi
		fi

		[ -n "$esdDevice" ] && hdiutil detach -quiet "$esdDevice" 2>/dev/null
		if [ -n "$build" ]; then
			printf '%s' "$build"
			return 0
		fi
		# build is empty: BaseSystem.dmg not found inside InstallESD.dmg (10.15+
		# moved it out of InstallESD). Fall through to InstallInfo.plist below.
	fi

	# Fallback: read ProductBuildVersion from InstallInfo.plist.
	# Failing that, scan it for a build-shaped token.
	if [ -f "$installInfo" ]; then
		build=$(plutil -extract "ProductBuildVersion" raw -o - "$installInfo" 2>/dev/null)
		[ -z "$build" ] && \
			build=$(grep -Eo '[0-9]{2}[A-Z][0-9a-z]+' "$installInfo" 2>/dev/null | head -1)
		printf '%s' "$build"
		return 0
	fi

	return 0

}


# ------------------------------------------------------------------------------
# verify_installer_build
# Confirms that the installer application at $1 reports the expected macOS build
# string $2. Delegates extraction to read_installer_build, which handles every
# installer layout.
#
# Returns 0 if the builds match (or $2 is empty), non-zero otherwise.
#
# $1 - Path to the installer application bundle
# $2 - macOS build string to verify (e.g. "16G29"); empty string skips check
# ------------------------------------------------------------------------------
verify_installer_build () {

	[ -z "$2" ] && return 0

	[ "$(read_installer_build "$1")" = "$2" ]

}


# ------------------------------------------------------------------------------
# add_mas_build_mismatch
# Displays the standard build-mismatch error when verify_installer_build returns
# non-zero. Called from add_mas_createinstallmedia_impl, which both
# createinstallmedia wrappers use.
#
# $1 - Expected build string from the conf (optional)
# $2 - Build string actually found in the installer (optional)
# ------------------------------------------------------------------------------
add_mas_build_mismatch () {

	disp_print_header

	echo "The installer in /Applications does not match the expected macOS build for"
	echo "the version chosen. Verify the installer and try again."
	echo ""

	if [ -n "$1" ]; then
		echo "Expected build:  $1"
		if [ -n "$2" ]; then
			echo "Installer build: $2"
		else
			echo "Installer build: (could not be determined)"
		fi
		echo ""
	fi

}


# ------------------------------------------------------------------------------
# add_resign_installer_bundle
# Ad-hoc re-signs every executable file inside an installer bundle, then the
# bundle itself. On Golden Gate and later, AMFI validates any binary marked
# as a platform binary via trust cache - a per-OS-build whitelist of
# Apple-shipped hashes. Old installer bundles contain many such binaries
# (createinstallmedia, framework dylibs, nested helper daemons) that are
# absent from newer trust caches. codesign --deep recurses only into bundle
# containers, silently skipping standalone Mach-O executables in any
# Resources directory. Signing by file path strips the platform claim from
# each binary directly, replacing it with a locally trusted ad-hoc signature
# that bypasses the trust cache check. All exec-bit files are signed first so
# the outer bundle seal reflects their updated hashes.
#
# $1 - Path to the installer application bundle
# ------------------------------------------------------------------------------
add_resign_installer_bundle () {

	local _rsBin

	echo "Re-signing installer binaries..."
	while IFS= read -r -d '' _rsBin; do
		codesign -f -s - "$_rsBin" 2>/dev/null
	done < <(find "$1" -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \) -print0)

	echo "Re-signing installer bundle..."
	codesign -f -s - "$1" 2>/dev/null
	echo ""

}


# ------------------------------------------------------------------------------
# add_mas_createinstallmedia_impl
# Shared implementation for both createinstallmedia wrapper functions below.
# $7 = "mav" selects the --applicationpath path with codesign workarounds
# (Mavericks through High Sierra); any other value uses --downloadassets
# (Mojave and later).
#
# $1 - Path to MAS install application given by user
# $2 - macOS build string to verify (e.g. "24G85"); empty string skips check
# $3 - Size of created DMG volume
# $4 - Final name of installation DMG volume
# $5 - Path to final destination of install DMG within restorekit
# $6 - Display name of MAS install application
# $7 - "mav" for --applicationpath style; omit or empty for --downloadassets
# ------------------------------------------------------------------------------
add_mas_createinstallmedia_impl () {

	disp_print_header

	echo "Verifying installer build..."
	echo ""

	if ! verify_installer_build "$1" "$2"; then
		add_mas_build_mismatch "$2" "$(read_installer_build "$1")"
		disp_pause_for_input
		return 1
	fi

	disp_print_header

	echo "Creating $6 installation master DMG file..."
	echo ""

	# Temp volume name is always FinalName + " temp"; the name createinstallmedia
	# sets on the volume is always the app bundle name without the .app extension.
	local newImageVolName="${4} temp"
	local endName="${1##*/}"; endName="${endName%.app}"

	if ! add_create_install_dmg "$makedriveInstTmpImageFile" "$3" "$newImageVolName"; then
		echo ""
		echo "Could not create the temporary installer DMG. Check available disk space."
		rm -f "$makedriveInstTmpImageFile"
		echo ""
		disp_pause_for_input
		return 1
	fi

	echo ""
	echo "Creating $6 bootable DMG..."
	echo ""

	# Clear the quarantine flag so macOS skips the one-time Gatekeeper
	# assessment of the multi-GB installer bundle, which otherwise stalls
	# createinstallmedia for minutes on older hosts with slow disks.
	xattr -dr com.apple.quarantine "$1" 2>/dev/null
	# FinderInfo xattrs on any resource inside the bundle (e.g. SharedSupport
	# DMGs) cause codesign to refuse signing with "detritus not allowed".
	xattr -dr com.apple.FinderInfo "$1" 2>/dev/null

	if [ "$7" = "mav" ]; then

		# Old installer bundles carry platform binaries missing from newer
		# trust caches; see add_resign_installer_bundle for the mechanics.
		add_resign_installer_bundle "$1"

		# Apple shipped a Sierra installer where CFBundleShortVersionString in
		# Info.plist does not match the version createinstallmedia was built to
		# expect. The binary checks this and forkbombs when they differ.
		# Patching Info.plist only breaks the bundle seal (CodeResources hash),
		# not the Mach-O signatures; AMFI checks the latter, so this is safe.
		local cimPlistVer cimBinVer cimMajor
		cimPlistVer=$(plutil -extract CFBundleShortVersionString raw \
		    "$1/Contents/Info.plist" 2>/dev/null)
		cimMajor="${cimPlistVer%%.*}"
		cimBinVer=$(strings "$1/Contents/Resources/createinstallmedia" 2>/dev/null \
		    | grep -E "^${cimMajor}\.[0-9]+\.[0-9]+$" | head -1)
		if [ -n "$cimBinVer" ] && [ "$cimPlistVer" != "$cimBinVer" ]; then
			echo "Correcting installer version mismatch ($cimPlistVer → $cimBinVer)..."
			echo ""
			plutil -replace CFBundleShortVersionString -string "$cimBinVer" \
			    "$1/Contents/Info.plist" 2>/dev/null
		fi

		echo "macOS may run a security scan on the installer before proceeding."
		echo "This is normal and can take a few minutes."
		echo ""
		"$1/Contents/Resources/createinstallmedia" --volume "/Volumes/$newImageVolName" --applicationpath "$1" --nointeraction
		local cimResult=$?

		if [ "$cimResult" != "0" ]; then
			echo ""
			echo "createinstallmedia failed. Check the installer and available disk space,"
			echo "then try again."
			hdiutil detach -force "/Volumes/$newImageVolName" 2>/dev/null
			hdiutil detach -force "/Volumes/$endName" 2>/dev/null
			rm -f "$makedriveInstTmpImageFile"
			echo ""
			disp_pause_for_input
			return 1
		fi

	else

		# Re-sign only 10.14 (Darwin 18) and 10.15 (Darwin 19). These carry
		# platform-identifier binaries absent from newer trust caches, causing
		# AMFI to SIGKILL createinstallmedia and framework dylibs on Golden Gate
		# and later. 11+ binaries are still in current trust caches and run
		# without re-signing; ad-hoc re-signing those on Apple Silicon carries
		# real risk since Reduced Security still enforces identity requirements
		# that ad-hoc signatures do not satisfy.
		case "$2" in 18*|19*)
			add_resign_installer_bundle "$1"
			;;
		esac

		echo "macOS may run a security scan on the installer before proceeding."
		echo "This is normal and can take a few minutes."
		echo ""
		if ! "$1/Contents/Resources/createinstallmedia" --volume "/Volumes/$newImageVolName" --nointeraction --downloadassets; then
			echo ""
			echo "createinstallmedia failed. Check the installer and available disk space,"
			echo "then try again."
			hdiutil detach -force "/Volumes/$newImageVolName" 2>/dev/null
			hdiutil detach -force "/Volumes/$endName" 2>/dev/null
			hdiutil detach -force "/Volumes/Shared Support" 2>/dev/null
			rm -f "$makedriveInstTmpImageFile"
			echo ""
			disp_pause_for_input
			return 1
		fi

	fi

	dmg_apply_volume_icon "$1" "/Volumes/$endName"

	# Everything from here on targets the renamed volume, so a failed rename
	# has to stop the process rather than cascade into misdirected paths.
	if ! diskutil rename "/Volumes/$endName" "$4"; then
		echo ""
		echo "Could not rename the completed installer volume /Volumes/$endName."
		echo "It may not have mounted under the expected name. The DMG was not"
		echo "moved into restorekit."
		hdiutil detach -force "/Volumes/$endName" 2>/dev/null
		[ "$7" != "mav" ] && hdiutil detach -force "/Volumes/Shared Support" 2>/dev/null
		rm -f "$makedriveInstTmpImageFile"
		echo ""
		disp_pause_for_input
		return 1
	fi

	local appPathForReceiptWipe="${1#/Applications/}"

	rm -rf "/Volumes/$4/$appPathForReceiptWipe/Contents/_MASReceipt/"

	touch "/Volumes/$4/.metadata_never_index"

	# checking workaround for new (2025 era) behavior for macOS Big Sur installer
	# not properly unmounting causing creation process to fail compress and scan
	# and using force after waiting for disk activity to wind down
	[ "$7" != "mav" ] && sleep 3

	hdiutil detach -force "/Volumes/$4"

	sleep 1

	if ! mv "$makedriveInstTmpImageFile" "$5"; then
		echo ""
		echo "Could not move the completed DMG to restorekit. Check permissions and disk space."
		[ "$7" != "mav" ] && hdiutil detach -force "/Volumes/Shared Support" 2>/dev/null
		echo ""
		disp_pause_for_input
		return 1
	fi

	# Detach the Shared Support volume left mounted by createinstallmedia (Mojave+ only).
	[ "$7" != "mav" ] && hdiutil detach -force "/Volumes/Shared Support"

	if ! dmgtool_prepare_dmg "$5" "$6"; then
		echo ""
		disp_pause_for_input
		return 1
	fi

	echo ""
	echo "$6 is ready for use."
	echo ""
	disp_pause_for_input

	return 0

}


# ------------------------------------------------------------------------------
# add_mas_createinstallmedia
# Processes a newer Mac App Store system installer into an install DMG that can
# be restored to disk. Required on 10.14 Mojave and later because createinstallmedia
# blesses the DMG root rather than a full OS volume, and must download assets
# during creation.
#
# $1 - Path to MAS install application given by user
# $2 - macOS build string to verify (e.g. "24G85"); empty string skips check
# $3 - Size of created DMG volume
# $4 - Final name of installation DMG volume
# $5 - Path to final destination of install DMG within restorekit
# $6 - Display name of MAS install application
# ------------------------------------------------------------------------------
add_mas_createinstallmedia () {

	add_mas_createinstallmedia_impl "$1" "$2" "$3" "$4" "$5" "$6" ""

}


# ------------------------------------------------------------------------------
# host_macos_version
# Echoes the host's full macOS version string (e.g. 10.15.7, 13.6.1, 26.1), or
# nothing if it cannot be determined. Compare it with conf_version_newer rather
# than extracting a single field: before macOS 11 the release number is the
# second component (10.14, 10.15) and from 11 on it is the first (11, 12, … 26),
# and component-wise comparison orders both schemes correctly (10.15 < 11).
# ------------------------------------------------------------------------------
host_macos_version () {

	sw_vers -productVersion 2>/dev/null

}


# ------------------------------------------------------------------------------
# add_installer_from_pkg
# Assembles a legacy OS installer application in /Applications from an
# Apple-provided flat package (.pkg). Used for OS X/macOS 10.7-10.12, where
# the installer is no longer available through the Mac App Store and must be
# sourced from Apple's direct-download flat package. The flat package contains
# a thin installer app shell (Payload, ~10 MB) and the multi-GB OS content
# (InstallESD.dmg) as a sibling file inside the same component package
# directory; the postinstall script that normally wires them together is
# bypassed (it uses JavaScript distribution scripts incompatible with modern
# pkg engines). This function replicates that wiring manually.
#
# Members are pulled individually with xar rather than expanding the whole
# package, so a wrong package is caught from the thin Payload before the
# multi-GB InstallESD.dmg is extracted. The Payload's InstallInfo.plist records
# the macOS version (e.g. 10.12.6) but not the build, which lives only inside
# InstallESD.dmg, so the authoritative build check (verify_installer_build) runs
# later against the assembled app. The pre-check compares at major.minor so a
# point-release difference is left to the build check.
#
# The InstallESD.dmg is moved (not copied) into the assembled app - a move on
# the same volume is instant and uses no additional disk space.
#
# The caller offers removal of $1 (add_offer_app_removal) once it is no
# longer needed.
#
# $1 - Expected path of the assembled installer app (e.g.
#      /Applications/Install macOS Sierra.app)
# $2 - Display name containing the expected macOS version (e.g.
#      "macOS 10.12.6 App Store Installer"); empty skips the version pre-check
# Returns 0 on success with the app at $1 and InstallESD.dmg in SharedSupport,
#         non-zero on failure (app is not present at $1).
# ------------------------------------------------------------------------------
add_installer_from_pkg () {

	local appPath="$1"
	local expandDir="$makedriveScratchDir/pkgexpand"
	local pkgPath esdMember compDir payloadPath stageApp stagedAppDir
	local expectedVer pkgVer instInfo
	local _dmgDevice=""
	local suppliedPath="${3:-}"

	# Pull the dotted version (e.g. 10.12.6) out of the display name for the
	# pre-extraction check; empty if the name carries no version-shaped token.
	expectedVer=$(printf '%s' "$2" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

	# Shared failure exit: print the message lines, clean up, and pause. Callers
	# still return 1 themselves so control flow stays visible at each site.
	_pkg_fail () {
		local _failLine
		for _failLine in "$@"; do
			echo "$_failLine"
		done
		echo ""
		rm -rf "$expandDir"
		[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
		disp_pause_for_input
	}

	if [ -n "$suppliedPath" ]; then

		pkgPath="$suppliedPath"

	else

		disp_print_header

		echo "The installer application is not in /Applications."
		echo ""
		echo "Drag the Apple-provided installer .pkg or .dmg into this Terminal"
		echo "window and press Return to continue, or press Return alone to cancel:"
		echo ""
		read -r pkgPath

		# Terminal drag-in backslash-escapes spaces and other special characters.
		pkgPath="${pkgPath//\\/}"

		if [ -z "$pkgPath" ]; then
			return 1
		fi

		if [ ! -f "$pkgPath" ]; then
			_pkg_fail "" "File not found. Verify the path and try again."
			return 1
		fi

	fi

	# If a DMG was provided, mount it and locate the single installer package
	# at its root; subsequent xar calls read from pkgPath on the mounted volume.
	case "$pkgPath" in *.dmg|*.DMG)
		disp_print_header
		echo "Mounting installer disk image..."
		echo ""
		local _dmgMount
		IFS=$'\t' read -r _dmgDevice _dmgMount < <(dmgtool_attach_parse "$pkgPath" -readonly)
		if [ -z "$_dmgDevice" ] || [ -z "$_dmgMount" ]; then
			_pkg_fail "Could not mount the disk image. Verify the file and try again."
			return 1
		fi
		pkgPath=$(find "$_dmgMount" -maxdepth 1 -name "*.pkg" -type f | head -1)
		if [ -z "$pkgPath" ]; then
			_pkg_fail "No installer package found on the disk image."
			return 1
		fi
		;;
	esac

	disp_print_header

	# Locate the InstallESD.dmg member and its component directory, which also
	# holds the thin Payload.
	esdMember=$(xar -tf "$pkgPath" 2>/dev/null | grep -m1 '/InstallESD.dmg$')
	if [ -z "$esdMember" ]; then
		_pkg_fail "This does not look like a macOS installer package (no InstallESD.dmg)."
		return 1
	fi
	compDir="${esdMember%/InstallESD.dmg}"

	echo "Reading installer package..."
	echo ""
	rm -rf "$expandDir"
	mkdir -p "$expandDir"

	# Extract only the thin Payload first (a few MB) so the package version can
	# be checked before committing to the multi-GB InstallESD.dmg extraction.
	if ! xar -x -C "$expandDir" -f "$pkgPath" "$compDir/Payload" 2>/dev/null; then
		_pkg_fail "Could not read the package. Verify the file and try again."
		return 1
	fi
	payloadPath="$expandDir/$compDir/Payload"
	if [ ! -f "$payloadPath" ]; then
		_pkg_fail "Unexpected package structure: Payload not found."
		return 1
	fi

	stageApp="$expandDir/stage"
	mkdir -p "$stageApp"
	bsdtar -C "$stageApp" -xf "$payloadPath" 2>/dev/null
	stagedAppDir=$(find "$stageApp" -maxdepth 1 -name "*.app" | head -1)
	if [ -z "$stagedAppDir" ]; then
		_pkg_fail "Could not extract the installer application from the package."
		return 1
	fi

	# Pre-extraction version check: the thin app's InstallInfo.plist names the
	# macOS version the bundled ESD provides; compare it (major.minor) to what
	# the chosen installer expects.
	instInfo="$stagedAppDir/Contents/SharedSupport/InstallInfo.plist"
	pkgVer=$(plutil -extract "System Image Info.version" raw -o - "$instInfo" 2>/dev/null)
	if [ -n "$expectedVer" ] && [ -n "$pkgVer" ] && \
	   [ "$(printf '%s' "$expectedVer" | cut -d. -f1-2)" != "$(printf '%s' "$pkgVer" | cut -d. -f1-2)" ]; then
		_pkg_fail "This package is for macOS $pkgVer, but the chosen installer expects" \
		          "macOS $expectedVer. Verify you supplied the correct package and try again."
		return 1
	fi

	# Version matches - extract the multi-GB ESD and assemble the installer.
	echo "Extracting installer content..."
	echo ""
	if ! xar -x -C "$expandDir" -f "$pkgPath" "$esdMember" 2>/dev/null; then
		_pkg_fail "Could not extract the installer content. Check available disk space."
		return 1
	fi

	# PKG reads are complete; detach the source DMG before local moves.
	[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null

	# Place the staged app at the expected path (renaming so it lands correctly
	# regardless of the bundle name inside the package) and move the ESD into it.
	rm -rf "$appPath"
	mv "$stagedAppDir" "$appPath"
	mkdir -p "$appPath/Contents/SharedSupport"
	mv "$expandDir/$esdMember" "$appPath/Contents/SharedSupport/InstallESD.dmg"

	rm -rf "$expandDir"

	if [ ! -d "$appPath" ]; then
		_pkg_fail "Could not assemble the installer application."
		return 1
	fi

	return 0

}


# ------------------------------------------------------------------------------
# add_mas_createinstallmedia_mav
# Processes a Mac App Store system installer into an install DMG that can be
# restored to disk. Required from 10.9 Mavericks through 10.13 High Sierra,
# which use the --applicationpath flag for createinstallmedia.
#
# $1 - Path to MAS install application given by user
# $2 - macOS build string to verify (e.g. "15G31"); empty string skips check
# $3 - Size of created DMG volume
# $4 - Final name of installation DMG volume
# $5 - Path to final destination of install DMG within restorekit
# $6 - Display name of MAS install application
# ------------------------------------------------------------------------------
add_mas_createinstallmedia_mav () {

	# Sierra (10.12) forkbombs on all hosts: a CFBundleShortVersionString
	# mismatch makes createinstallmedia spawn runaway child instances (EAGAIN /
	# error 35). add_mas_createinstallmedia_impl patches Info.plist to match.
	# Darwin 16 = Sierra, so its build strings start with "16".
	local installerBuild="$2"
	[ -z "$installerBuild" ] && installerBuild=$(read_installer_build "$1")
	local isSierra=0
	case "$installerBuild" in 16*) isSierra=1 ;; esac
	local isMavericks=0
	case "$installerBuild" in 13*) isMavericks=1 ;; esac

	# For 10.9-10.12, the installer is no longer available through the Mac App
	# Store and must be sourced from a flat installer package. If the app is
	# not already in /Applications, offer pkg extraction via
	# add_installer_from_pkg. Apple never published a package for Mavericks
	# (10.9), so its note tells the user to supply their own. Sierra on a
	# macOS 26 or later host can't use the MAS because the host's pkg engine
	# rejects its JavaScript distribution scripts. Both notes pause for input,
	# since the pkg prompt clears the screen when it draws its own header.
	local _pkgExtracted=0
	if [ ! -d "$1" ]; then

		if [ "$isMavericks" = "1" ]; then
			disp_print_header
			echo "Install OS X Mavericks is not in /Applications. Apple never published"
			echo "a package source for 10.9, so makedrive cannot download one. If you"
			echo "have a 10.9 installer package in Apple's flat layout (or the DMG"
			echo "containing it), it can be supplied here and is verified against the"
			echo "expected version and build before use."
			echo ""
			disp_pause_for_input
		fi

		if [ "$isSierra" = "1" ]; then
			local hostVer
			hostVer=$(host_macos_version)
			if [ -n "$hostVer" ] && ! conf_version_newer "26" "$hostVer"; then
				disp_print_header
				echo "macOS Sierra (10.12) cannot be downloaded or installed from the Mac App"
				echo "Store on macOS 26 and later. Its installer package uses JavaScript"
				echo "distribution scripts that are incompatible with this host's pkg engine."
				echo ""
				echo "You can proceed by providing the Apple-provided InstallOS.pkg file."
				echo ""
				disp_pause_for_input
			fi
		fi

		add_installer_from_pkg "$1" "$6" || return 1
		_pkgExtracted=1

	fi

	add_mas_createinstallmedia_impl "$1" "$2" "$3" "$4" "$5" "$6" "mav"
	local _result=$?

	[ "$_pkgExtracted" = "1" ] && add_offer_app_removal "$1" "$_result" package

	return $_result

}


# ------------------------------------------------------------------------------
# download_verify_size
# Compares a downloaded file's on-disk size against the size Apple's catalog
# (or the hardcoded CDN table) says it should be. curl --fail catches HTTP
# errors but not silent truncation; an exact size check does, cheaply. A zero
# or empty expected size skips the check.
#
# $1 - Path to the downloaded file
# $2 - Expected size in bytes
# ------------------------------------------------------------------------------
download_verify_size () {

	local actualBytes

	if [ -z "$2" ] || [ "$2" = "0" ]; then
		return 0
	fi

	actualBytes=$(stat -f%z "$1" 2>/dev/null)
	if [ "$actualBytes" != "$2" ]; then
		echo ""
		echo "Downloaded file ${1##*/} is ${actualBytes:-0} bytes but should be $2 bytes."
		echo "The download may have been truncated or altered. Try again."
		return 1
	fi

	return 0

}


# ------------------------------------------------------------------------------
# download_curl_interruptible
# Downloads a single URL with Control-C scoped to cancel just this transfer.
# The script-wide SIGINT trap (postflight_cleanup) would otherwise exit
# makedrive outright, despite the download menus inviting Control-C as a
# cancel key. The scoped trap only marks the interrupt; curl itself receives
# the terminal's SIGINT directly and aborts the transfer.
#
# Returns curl's exit status, or 130 if the transfer was cancelled.
#
# $1 - URL to download
# $2 - Output file path
# ------------------------------------------------------------------------------
download_curl_interruptible () {

	local _dlInterrupted=0 _curlResult

	trap '_dlInterrupted=1' SIGINT
	curl --location --progress-bar --fail "$1" -o "$2" 2>&1
	_curlResult=$?
	trap postflight_cleanup SIGINT

	if [ "$_dlInterrupted" = "1" ]; then
		return 130
	fi
	return "$_curlResult"

}


# ------------------------------------------------------------------------------
# download_fetch_and_process
# Downloads a macOS installer and processes it through the standard add-installer
# pipeline. Handles three source types:
#   cdn_dmg       - single DMG from Apple CDN (10.7-10.12); passes it to
#                   add_installer_from_pkg to assemble the installer app
#   catalog_single - single InstallAssistant.pkg (11+); installer to /
#   catalog_hfs    - packages (10.13-10.15); pkgutil expand → app + InstallESD.dmg
#
# Returns 0 if the image was added, 1 otherwise.
#
# $1 - conf key (e.g. "inst1015i")
# $2 - source type: "cdn_dmg" | "catalog_single" | "catalog_hfs"
# $3 - URL, or pipe-separated list for catalog_hfs: dist_url|pkg1_url|pkg2_url|...
# $4 - display label (e.g. "10.15.7 App Store Install")
# $5 - expected download size in bytes (catalog_hfs: total for the files
#      actually downloaded); empty or 0 skips size verification
# ------------------------------------------------------------------------------
download_fetch_and_process () {

	local confKey="$1" dlType="$2" dlURLs="$3" dlLabel="$4" dlExpectedBytes="${5:-0}"

	# Resolve conf variables via indirect expansion
	local _v appPath buildNum newVolSize finalName instPath dispName addFunc srcPath volName

	_v="${confKey}AppPath";         appPath="${!_v}"
	_v="${confKey}BuildNumber";     buildNum="${!_v}"
	_v="${confKey}NewImageVolSize"; newVolSize="${!_v}"
	_v="${confKey}FinalName";       finalName="${!_v}"
	instPath="${!confKey}"
	_v="${confKey}DispName";        dispName="${!_v}"
	_v="${confKey}AddFunc";         addFunc="${!_v}"
	_v="${confKey}SourceImagePath"; srcPath="${!_v}"
	_v="${confKey}VolName";         volName="${!_v}"

	local tmpDir
	tmpDir=$(mktemp -d "$makedriveScratchDir/download.XXXXXX") || {
		echo "Could not create temporary download directory."
		echo ""
		disp_pause_for_input
		return 1
	}

	local _assembledApp=""

	case "$dlType" in

	cdn_dmg )

		disp_print_header
		echo "Downloading $dlLabel..."
		echo "Press Control-C to cancel."
		echo ""

		local dmgPath="$tmpDir/installer.dmg"
		download_curl_interruptible "$dlURLs" "$dmgPath"
		local dlResult=$?
		if [ "$dlResult" != "0" ]; then
			echo ""
			if [ "$dlResult" = "130" ]; then
				echo "Download cancelled."
			else
				echo "Download failed. Check your network connection and try again."
			fi
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		if ! download_verify_size "$dmgPath" "$dlExpectedBytes"; then
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		echo ""

		if ! add_installer_from_pkg "$appPath" "$dispName" "$dmgPath"; then
			rm -rf "$tmpDir"
			return 1
		fi
		_assembledApp="$appPath"
		;;

	catalog_single )

		disp_print_header
		echo "Downloading $dlLabel..."
		echo "Press Control-C to cancel."
		echo ""

		local pkgPath="$tmpDir/InstallAssistant.pkg"
		download_curl_interruptible "$dlURLs" "$pkgPath"
		local dlResult=$?
		if [ "$dlResult" != "0" ]; then
			echo ""
			if [ "$dlResult" = "130" ]; then
				echo "Download cancelled."
			else
				echo "Download failed. Check your network connection and try again."
			fi
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		if ! download_verify_size "$pkgPath" "$dlExpectedBytes"; then
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		echo ""
		echo "Installing $dlLabel to /Applications..."
		echo "(This may take a few minutes.)"
		echo ""
		if ! installer -pkg "$pkgPath" -target /; then
			echo ""
			echo "Installation failed. Check available disk space and try again."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi
		_assembledApp="$appPath"
		;;

	catalog_hfs )

		# Assemble the installer .app from the downloaded packages using pkgutil.
		# The installer(8) binary rejects 10.13-10.15 packages on arm64/macOS 26+
		# regardless of distribution-file patching, so we expand the packages directly:
		#   InstallAssistantAuto.pkg -> app skeleton with the correct InstallInfo.plist
		#   InstallESDDmg.pkg        -> InstallESD.dmg (7.5 GB base system image)
		#   BaseSystem.dmg           -> raw CDN file; needed by createinstallmedia and
		#                              by read_installer_build to extract ProductBuildVersion
		#   AppleDiagnostics.dmg     -> raw CDN file; needed by createinstallmedia
		#   BaseSystem.chunklist     -> raw CDN file; the xnu kernel's imageboot
		#                              authentication (bsd/kern/chunklist.c) requires this
		#                              sibling file to boot BaseSystem.dmg as root-dmg on
		#                              10.15 - without it, real hardware panics with
		#                              "root image authentication failed (err = 2)" (ENOENT)
		#   AppleDiagnostics.chunklist -> same requirement, for AppleDiagnostics.dmg
		# InstallInfo.plist already has the System Image Info / Payload Image Info
		# keys that createinstallmedia validates, so it only gets one key added
		# (ProductBuildVersion, below).
		disp_print_header
		echo "Downloading $dlLabel..."
		echo "Press Control-C to cancel."
		echo ""

		local -a _hfsURLs
		IFS='|' read -ra _hfsURLs <<< "$dlURLs"
		local _hfsURL _hfsFname
		for _hfsURL in "${_hfsURLs[@]}"; do
			[ -z "$_hfsURL" ] && continue
			_hfsFname="${_hfsURL##*/}"
			# Only download the files listed in the catalog_hfs comment above.
			case "$_hfsFname" in
				InstallAssistantAuto.pkg|InstallESDDmg.pkg|\
				BaseSystem.dmg|AppleDiagnostics.dmg|\
				BaseSystem.chunklist|AppleDiagnostics.chunklist) ;;
				*) continue ;;
			esac
			echo "Downloading $_hfsFname..."
			download_curl_interruptible "$_hfsURL" "$tmpDir/$_hfsFname"
			local hfsDlResult=$?
			if [ "$hfsDlResult" != "0" ]; then
				echo ""
				if [ "$hfsDlResult" = "130" ]; then
					echo "Download cancelled."
				else
					echo "Download of $_hfsFname failed. Check your network connection and try again."
				fi
				echo ""
				rm -rf "$tmpDir"
				disp_pause_for_input
				return 1
			fi
		done

		# The catalog's per-file sizes aren't carried through the URL list,
		# but dlExpectedBytes is the sum for exactly the files downloaded
		# above, so the combined size on disk must match it.
		local _hfsActualBytes=0 _hfsFile
		for _hfsFile in "$tmpDir"/*; do
			[ -f "$_hfsFile" ] && _hfsActualBytes=$(( _hfsActualBytes + $(stat -f%z "$_hfsFile") ))
		done
		if [ -n "$dlExpectedBytes" ] && [ "$dlExpectedBytes" != "0" ] && \
		   [ "$_hfsActualBytes" != "$dlExpectedBytes" ]; then
			echo ""
			echo "The downloaded files total ${_hfsActualBytes} bytes but should total"
			echo "${dlExpectedBytes} bytes. A download may have been truncated or altered."
			echo "Try again."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		local _autoStage="$tmpDir/auto_stage"
		local _esdStage="$tmpDir/esd_stage"

		echo ""
		echo "Expanding installer package..."
		if ! pkgutil --expand-full "$tmpDir/InstallAssistantAuto.pkg" "$_autoStage" 2>/dev/null; then
			echo "Could not expand InstallAssistantAuto.pkg."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		local _stagedApp
		_stagedApp=$(find "$_autoStage/Payload" -maxdepth 2 -name "*.app" -type d 2>/dev/null | head -1)
		if [ -z "$_stagedApp" ]; then
			echo "Could not locate installer app in expanded package."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		echo "Expanding ESD package (this may take several minutes - the package is large)..."
		if ! pkgutil --expand-full "$tmpDir/InstallESDDmg.pkg" "$_esdStage" 2>/dev/null; then
			echo "Could not expand InstallESDDmg.pkg."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		local _esdDmg
		_esdDmg=$(find "$_esdStage" -name "InstallESD.dmg" 2>/dev/null | head -1)
		if [ -z "$_esdDmg" ]; then
			echo "Could not locate InstallESD.dmg in expanded ESD package."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi

		local _sharedSupport="$_stagedApp/Contents/SharedSupport"
		if ! mv "$_esdDmg" "$_sharedSupport/InstallESD.dmg"; then
			echo "Could not place InstallESD.dmg in SharedSupport."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi
		rm -rf "$_esdStage" "$tmpDir/InstallESDDmg.pkg"

		# createinstallmedia reads BaseSystem.dmg and AppleDiagnostics.dmg from
		# SharedSupport. Each .chunklist has to sit beside its .dmg, under the
		# same base name, for the kernel's root-dmg authentication at boot.
		for _dmg in BaseSystem.dmg BaseSystem.chunklist AppleDiagnostics.dmg AppleDiagnostics.chunklist; do
			[ -f "$tmpDir/$_dmg" ] && mv "$tmpDir/$_dmg" "$_sharedSupport/$_dmg"
		done

		# Write the authoritative build number from the catalog dist file into
		# InstallInfo.plist. The catalog's BaseSystem.dmg is the recovery image and
		# may carry a different (older) build string; read_installer_build checks
		# ProductBuildVersion here first and skips the BaseSystem.dmg mount.
		plutil -insert "ProductBuildVersion" -string "$buildNum" \
		    "$_sharedSupport/InstallInfo.plist" 2>/dev/null || true

		rm -rf "$appPath"
		if ! mv "$_stagedApp" "$appPath"; then
			echo "Could not place the installer application in /Applications."
			echo ""
			rm -rf "$tmpDir"
			disp_pause_for_input
			return 1
		fi
		_assembledApp="$appPath"
		;;

	esac

	rm -rf "$tmpDir"

	# Dispatch to the standard add-installer pipeline - same calls as add_menu_image_list
	local addResult=1
	case "$addFunc" in

	COPY_SINGLE )
		add_copy_single_dmg "$dispName" "$instPath" "$volName" "$buildNum" "$srcPath" "$appPath"
		addResult=$?
		;;

	CREATE_INSTALL_MEDIA_MAV )
		add_mas_createinstallmedia_mav "$appPath" "$buildNum" "$newVolSize" "$finalName" "$instPath" "$dispName"
		addResult=$?
		;;

	CREATE_INSTALL_MEDIA )
		add_mas_createinstallmedia "$appPath" "$buildNum" "$newVolSize" "$finalName" "$instPath" "$dispName"
		addResult=$?
		;;

	* )
		disp_print_header
		echo "The AddFunc configured for ${confKey} in makedrive.conf is not"
		echo "recognized ('${addFunc}'), so the downloaded installer was not"
		echo "processed. Correct the conf entry and try again."
		echo ""
		disp_pause_for_input
		;;

	esac

	# The app installed or assembled to /Applications is the only copy of
	# the download, so its removal is offered rather than assumed.
	add_offer_app_removal "$_assembledApp" "$addResult" download

	return "$addResult"

}


# ------------------------------------------------------------------------------
# catalog_fetch_vars
# Fetches Apple's software-update catalogs and prints shell-sourceable
# variable assignments describing the newest installer per macOS generation.
# Shared by startup_sync_versions and download_installer_menu, which need the
# same catalog walk but different outputs:
#
#   sync - MACOS_DL_* version/build pairs only (lightweight startup check)
#   menu - the same pairs, plus MAKEDRIVE_DLCAT_* rows with download URLs
#          and sizes
#
# Callers redirect stdout to a temp file, verify the COUNT marker is present
# (network failure produces no output), and source it.
#
# $1 - Output mode: "sync" or "menu"
# ------------------------------------------------------------------------------
catalog_fetch_vars () {

	local _catURLs _menuOrder
	printf -v _catURLs '%s\n' "${catalogURLs[@]}"
	printf -v _menuOrder '%s\n' "${addMenuOrder[@]}"

	MAKEDRIVE_CATALOG_MODE="$1" \
	MAKEDRIVE_CATALOG_URLS="$_catURLs" \
	MAKEDRIVE_MENU_ORDER="$_menuOrder" \
	python3 << 'MAKEDRIVE_CATALOG_PYEOF'
import subprocess, gzip, plistlib, sys, re, os
from concurrent.futures import ThreadPoolExecutor, as_completed

# Shared catalog walker. MAKEDRIVE_CATALOG_MODE is "sync" or "menu": the
# catalog_fetch_vars banner above says what each one prints.
MODE = os.environ.get("MAKEDRIVE_CATALOG_MODE", "sync")

# Fetch a URL with curl. Returns the raw bytes, or None on any failure.
def fetch(url, timeout=30):
    try:
        r = subprocess.run(
            ["curl", "--silent", "--fail", "--location",
             "--max-time", str(timeout), "--user-agent", "makedrive", url],
            capture_output=True, timeout=timeout + 10)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None

# Catalog index URLs come from catalogURLs in makedrive.conf. MENU_ORDER is
# addMenuOrder, for mapping versions to conf keys (menu mode only).
CATALOG_URLS = [u for u in os.environ.get("MAKEDRIVE_CATALOG_URLS", "").splitlines() if u]
MENU_ORDER   = [k for k in os.environ.get("MAKEDRIVE_MENU_ORDER",   "").splitlines() if k]

# Merge the Products dict from every catalog (gzip-compressed plist). On a key
# collision the earlier catalog wins, so list the freshest catalog first.
products = {}
for url in CATALOG_URLS:
    data = fetch(url, timeout=60)
    if not data:
        continue
    try:
        raw = gzip.decompress(data)
    except Exception:
        raw = data
    try:
        for pid, prod in plistlib.loads(raw).get("Products", {}).items():
            products.setdefault(pid, prod)
    except Exception:
        pass

if not products:
    sys.exit(0)

# A product is a full macOS installer iff its ExtendedMetaInfo carries
# InstallAssistantPackageIdentifiers. Each one's English distribution URL - a
# small XML file - holds the human-readable version and build strings.
installer_products = {
    pid: prod for pid, prod in products.items()
    if "InstallAssistantPackageIdentifiers" in prod.get("ExtendedMetaInfo", {})
    and prod.get("Distributions", {}).get("English")
}

def get_version_build(item):
    pid, prod = item
    data = fetch(prod["Distributions"]["English"], timeout=15)
    if not data:
        return None
    text = data.decode("utf-8", errors="ignore")
    vm = re.search(r"<key>VERSION</key>\s*<string>([^<]+)</string>", text)
    bm = re.search(r"<key>BUILD</key>\s*<string>([^<]+)</string>", text)
    version = vm.group(1).strip() if vm else None
    build   = bm.group(1).strip() if bm else ""
    if not version:
        return None
    return (pid, version, build, prod.get("Packages", []), prod["Distributions"]["English"])

def parse_ver(v):
    try:
        return tuple(int(x) for x in str(v).strip().split("."))
    except Exception:
        return (0,)

def parse_build(b):
    # Apple build strings look like "19H15" or "17F66a": digits, a revision
    # letter, a point number, and an optional hotfix suffix letter. Plain
    # string comparison is wrong here ("19H15" < "19H4" lexically), so parse
    # into a tuple.
    m = re.match(r'^(\d+)([A-Za-z]+)(\d+)([a-zA-Z]*)$', str(b).strip())
    if not m:
        return (0, '', 0, '')
    major, letter, point, suffix = m.groups()
    return (int(major), letter, int(point), suffix)

# Distribution files are fetched concurrently. Keep only the newest version
# and build for each macOS generation (keyed by major, or "10.x" for the 10
# line). Versions before 10.13 and the nonexistent 16-25 range (Apple jumped
# 15 → 26) are dropped as catalog noise; 10.7-10.12 downloads come from
# hardcoded Apple CDN URLs in download_installer_menu instead. Multiple
# products can share the same VERSION string across supplemental updates
# (e.g. 19H2/19H4/19H15 all "10.15.7"), so build must be compared too;
# otherwise whichever entry is processed first wins regardless of how
# outdated it actually is.
newest = {}
with ThreadPoolExecutor(max_workers=15) as ex:
    for fut in as_completed([ex.submit(get_version_build, item)
                             for item in installer_products.items()]):
        r = fut.result()
        if not r:
            continue
        pid, version, build, packages, dist_url = r
        p = parse_ver(version)
        if (p[0] == 10 and (len(p) < 2 or p[1] < 13)) or 16 <= p[0] <= 25:
            continue
        bucket = "10." + str(p[1]) if p[0] == 10 and len(p) > 1 else str(p[0])
        sortKey = (p, parse_build(build))
        if bucket not in newest or sortKey > newest[bucket]["_sortKey"]:
            newest[bucket] = {"version": version, "build": build,
                              "packages": packages, "dist_url": dist_url,
                              "_sortKey": sortKey}

# Emit newest generation first. The output file is sourced by a root shell
# and the version, build, and URL strings came from remote catalog data, so
# anything that doesn't match the only shape it can legitimately have is
# dropped - a value these patterns reject could otherwise break out of its
# double quotes when sourced.
SAFE_VERSION = re.compile(r'^[0-9]+(\.[0-9]+)*$')
SAFE_BUILD   = re.compile(r'^[0-9A-Za-z.]*$')
SAFE_URL     = re.compile(r'^https://[A-Za-z0-9._~:/%+=-]+$')

final = sorted(newest.values(), key=lambda e: parse_ver(e["version"]), reverse=True)

# The version/build pairs are emitted in both modes. The launch sync reads
# them alone; the download menu uses them to bring the conf up to the catalog.
pairs = [e for e in final
         if SAFE_VERSION.match(e["version"]) and SAFE_BUILD.match(e["build"])]
print("MACOS_DL_COUNT=" + str(len(pairs)))
for i, e in enumerate(pairs):
    print('MACOS_DL_VERSION_' + str(i) + '="' + e["version"] + '"')
    print('MACOS_DL_BUILD_'   + str(i) + '="' + e["build"] + '"')

if MODE == "sync":
    sys.exit(0)

# menu mode from here down: build MAKEDRIVE_DLCAT_* download rows.

SKIP = {"InstallAssistantAuto.pkg", "MajorOSInfo.pkg", "InstallInfo.plist",
        "UpdateBrain.zip", "com_apple_MobileAsset_MacSoftwareUpdate.plist"}

def real_packages(packages):
    result = []
    for pkg in packages:
        url  = pkg.get("URL", "")
        name = url.split("/")[-1]
        if name.endswith(".chunklist") or name in SKIP:
            continue
        size = pkg.get("Size", 0)
        if size > 0:
            result.append((url, size))
    return result

# The files download_fetch_and_process's catalog_hfs case actually downloads;
# must match the filename filter there. Used only to size the menu entry so
# it reflects what will really transfer.
HFS_DOWNLOADED = {"InstallAssistantAuto.pkg", "InstallESDDmg.pkg",
                  "BaseSystem.dmg", "AppleDiagnostics.dmg",
                  "BaseSystem.chunklist", "AppleDiagnostics.chunklist"}

def conf_key_for(version):
    p = parse_ver(version)
    major = p[0]
    key_root = (1000 + p[1]) if major == 10 else (major * 100)
    prefix = f"inst{key_root}"
    for k in MENU_ORDER:
        if k.startswith(prefix):
            return k
    return None

rows = []
for entry in final:
    version = entry["version"]
    key     = conf_key_for(version)
    if not key:
        continue
    pkgs = real_packages(entry["packages"])
    p = parse_ver(version)
    if p[0] >= 11:
        # 11+: single InstallAssistant.pkg installs the app via `installer`
        url  = next((u for u, s in pkgs if "InstallAssistant.pkg" in u), "")
        size = next((s for u, s in pkgs if "InstallAssistant.pkg" in u), 0)
        if not url:
            continue
        rows.append((key, entry["build"], "catalog_single", url, size))
    elif p[0] == 10 and p[1] >= 13:
        # 10.13-10.15: pass the distribution URL plus every package URL;
        # download_fetch_and_process's catalog_hfs case decides which files get
        # downloaded and assembled with pkgutil. Chunklist URLs are kept (not
        # filtered) because BaseSystem.chunklist is required for 10.15 to boot.
        all_pkg_urls = [pkg.get("URL", "") for pkg in entry["packages"] if pkg.get("URL", "")]
        dist_url = entry["dist_url"]
        total_size = sum(pkg.get("Size", 0) for pkg in entry["packages"]
                         if pkg.get("URL", "").split("/")[-1] in HFS_DOWNLOADED)
        combined = "|".join([dist_url] + all_pkg_urls)
        rows.append((key, entry["build"], "catalog_hfs", combined, total_size))

# Same sourced-by-root reasoning as above. dtype is script-internal and key
# comes from the local conf, but checking them too costs nothing.
SAFE_KEY  = re.compile(r'^inst[A-Za-z0-9]+$')
SAFE_TYPE = re.compile(r'^[a-z_]+$')

def row_is_safe(key, build, dtype, url, size):
    # url is a single URL, or pipe-separated URLs for catalog_hfs
    return bool(SAFE_KEY.match(key) and SAFE_BUILD.match(build)
                and SAFE_TYPE.match(dtype) and str(size).isdigit()
                and all(SAFE_URL.match(u) for u in url.split("|")))

rows = [r for r in rows if row_is_safe(*r)]
print(f"MAKEDRIVE_DLCAT_COUNT={len(rows)}")
for i, (key, build, dtype, url, size) in enumerate(rows):
    print(f'MAKEDRIVE_DLCAT_{i}_KEY="{key}"')
    print(f'MAKEDRIVE_DLCAT_{i}_BUILD="{build}"')
    print(f'MAKEDRIVE_DLCAT_{i}_TYPE="{dtype}"')
    print(f'MAKEDRIVE_DLCAT_{i}_URL="{url}"')
    print(f'MAKEDRIVE_DLCAT_{i}_BYTES={size}')
MAKEDRIVE_CATALOG_PYEOF

}


# ------------------------------------------------------------------------------
# download_installer_menu
# Presents a list of macOS installers available for direct download from Apple.
# Versions 10.13 and newer come from Apple's software-update catalog (fetched
# on demand). Versions 10.7-10.12 (except 10.9, which has no Apple-hosted
# source) come from hardcoded Apple CDN URLs. After the user selects a version
# the download and processing are handled by download_fetch_and_process.
# ------------------------------------------------------------------------------
download_installer_menu () {

	disp_print_header
	echo "Fetching available installer list from Apple..."
	echo ""

	local syncFile
	syncFile=$(mktemp "$makedriveScratchDir/catalog.XXXXXX") || {
		echo "Could not create temp file."
		echo ""
		disp_pause_for_input
		return 1
	}

	# Same catalog walk as startup_sync_versions, plus download URLs and sizes.
	catalog_fetch_vars menu > "$syncFile" 2>/dev/null

	if ! grep -q "^MAKEDRIVE_DLCAT_COUNT=" "$syncFile" 2>/dev/null; then
		rm -f "$syncFile"
		echo "Could not fetch the installer list from Apple's catalog."
		echo "Check your network connection and try again."
		echo ""
		disp_pause_for_input
		return 1
	fi

	# shellcheck source=/dev/null
	source "$syncFile"
	rm -f "$syncFile"

	# Bring makedrive.conf up to this catalog before listing anything. The
	# launch sync may have been skipped (offline) or served from its two-hour
	# cache, and the rows below download whatever build Apple lists right
	# now, so a conf left behind would label them with an old version and
	# verify them against a build that is no longer the one on offer.
	download_sync_conf "$MACOS_DL_COUNT" reissue

	local catCount="$MAKEDRIVE_DLCAT_COUNT"

	# Build unified download list: catalog entries (newest first, from Python),
	# followed by CDN entries for 10.7-10.12 (newest first; 10.9 intentionally absent).
	local -a dlKeys dlLabels dlTypes dlURLs dlBytes dlBuilds

	local i _kv _tv _uv _bv _buv _labV
	for (( i = 0; i < catCount; i++ )); do
		_kv="MAKEDRIVE_DLCAT_${i}_KEY"
		_tv="MAKEDRIVE_DLCAT_${i}_TYPE"
		_uv="MAKEDRIVE_DLCAT_${i}_URL"
		_bv="MAKEDRIVE_DLCAT_${i}_BYTES"
		_buv="MAKEDRIVE_DLCAT_${i}_BUILD"
		_labV="${!_kv}MenuLabel"
		dlKeys+=("${!_kv}")
		dlLabels+=("${!_labV}")
		dlTypes+=("${!_tv}")
		dlURLs+=("${!_uv}")
		dlBytes+=("${!_bv}")
		dlBuilds+=("${!_buv}")
	done

	# CDN entries - hardcoded Apple URLs, verified 2026-06
	local -a _cdnKeys=( "inst1012i" "inst1011i" "inst1010i" "inst108i" "inst107i" )
	local -a _cdnURLs=(
		"https://updates.cdn-apple.com/2019/cert/061-39476-20191023-48f365f4-0015-4c41-9f44-39d3d2aca067/InstallOS.dmg"
		"https://updates.cdn-apple.com/2019/cert/061-41424-20191024-218af9ec-cf50-4516-9011-228c78eda3d2/InstallMacOSX.dmg"
		"https://updates.cdn-apple.com/2019/cert/061-41343-20191023-02465f92-3ab5-4c92-bfe2-b725447a070d/InstallMacOSX.dmg"
		"https://updates.cdn-apple.com/2021/macos/031-0627-20210614-90D11F33-1A65-42DD-BBEA-E1D9F43A6B3F/InstallMacOSX.dmg"
		"https://updates.cdn-apple.com/2021/macos/041-7683-20210614-E610947E-C7CE-46EB-8860-D26D71F0D3EA/InstallMacOSX.dmg"
	)
	local -a _cdnBytes=( 5007882126 6204629298 5718074248 4449317520 4720237409 )

	local _ck _labV2
	for (( i = 0; i < ${#_cdnKeys[@]}; i++ )); do
		_ck="${_cdnKeys[$i]}"
		_labV2="${_ck}MenuLabel"
		dlKeys+=("$_ck")
		dlLabels+=("${!_labV2}")
		dlTypes+=("cdn_dmg")
		dlURLs+=("${_cdnURLs[$i]}")
		dlBytes+=("${_cdnBytes[$i]}")
		dlBuilds+=("")
	done

	local totalCount=${#dlKeys[@]}
	local dlChoice selIdx _gb _confBuildVar

	while true; do

		disp_print_header

		echo "Choose a macOS installer to download and add to restorekit:"
		echo ""
		echo "  10.9 Mavericks is not available from Apple - add it manually via option 1."
		echo ""

		for (( i = 0; i < totalCount; i++ )); do
			_gb=$(awk -v b="${dlBytes[$i]}" 'BEGIN {printf "%.1f GB", b/1024/1024/1024}')
			printf " %2d. %-45s %s\n" $(( i + 1 )) "${dlLabels[$i]}" "$_gb"
		done

		echo ""
		echo "  X. Return to Main Menu"
		echo ""
		echo "Enter a number to download and add, or X to return:"
		echo ""
		disp_read_choice dlChoice

		case "$dlChoice" in

		[Xx]) return 0 ;;

		*)
			if selIdx=$(menu_choice_index "$dlChoice" "$totalCount"); then

				# A catalog installer is verified against the conf's build
				# once it is installed. If the conf could not be brought up
				# to the build Apple is offering (a locked file, or a version
				# set by hand to one newer than Apple's), say so before the
				# download instead of after it.
				_confBuildVar="${dlKeys[$selIdx]}BuildNumber"
				if [ "${dlTypes[$selIdx]}" = "catalog_single" ] && \
				   [ -n "${dlBuilds[$selIdx]}" ] && [ -n "${!_confBuildVar}" ] && \
				   [ "${dlBuilds[$selIdx]}" != "${!_confBuildVar}" ]; then
					disp_print_header
					echo "Apple is currently offering build ${dlBuilds[$selIdx]} of this installer, but"
					echo "makedrive.conf expects build ${!_confBuildVar} and could not be updated to match,"
					echo "so the download would fail verification. Nothing was downloaded."
					echo ""
					echo "Check that makedrive.conf can be written to, and that its version for"
					echo "this entry is not newer than the one Apple offers, then try again."
					echo ""
					disp_pause_for_input
					continue
				fi

				download_fetch_and_process \
					"${dlKeys[$selIdx]}" \
					"${dlTypes[$selIdx]}" \
					"${dlURLs[$selIdx]}" \
					"${dlLabels[$selIdx]}" \
					"${dlBytes[$selIdx]}"
			fi
			;;

		esac

	done

}


# ------------------------------------------------------------------------------
# add_menu_main
# Top level of the image installer: tags each image category with its count
# of missing images and routes to the installer or diagnostics list, which
# shows its own missing files.
# ------------------------------------------------------------------------------
add_menu_main () {

	local instTag diagTag

	imageToAdd=""

	while [ "$imageToAdd" == "" ]; do

		disp_print_header

		check_file_presence
		instTag=""
		diagTag=""
		[ "$missingInstallersCount" -gt 0 ] && instTag=" ($missingInstallersCount missing)"
		[ "$missingDiagnosticsCount" -gt 0 ] && diagTag=" ($missingDiagnosticsCount missing)"

		echo "Choose the type of image you'd like to add to the restorekit folder:"
		echo ""
		echo " 1. macOS installers$instTag"
		echo ""
		echo " 2. Diagnostics (ASD, AXD, and the Blank Board Serializer)$diagTag"
		echo ""
		echo " X. Exit Image Installer"
		echo ""
		echo "Enter the number or letter for the list you'd like to see and hit return: "
		echo ""
		disp_read_choice imageToAdd

		case "$imageToAdd" in

		[Xx] )
			break
			;;

		1 )
			add_menu_image_list "installer" addMenuInstallers[@] \
				"App Store installers must be in /Applications before they can be added." \
				missingInstallersList \
				|| break
			;;

		2 )
			add_menu_image_list "diagnostic image" addMenuDiagnostics[@] \
				"Diagnostic images are supplied from your own archive as single DMG files." \
				missingDiagnosticsList \
				|| break
			;;

		esac

		imageToAdd=""

	done

}


# ------------------------------------------------------------------------------
# add_menu_image_list
# Lists one category of configured images and dispatches the chosen entry to
# its AddFunc. Returns 0 when the user goes back to the image type menu and 1
# when they exit the image installer entirely.
#
# $1 - Category word used in the menu prompt (e.g. "installer")
# $2 - Name of array variable holding the image keys to list
# $3 - One-line note printed below the menu
# $4 - Name of the missing-list global to display above the menu
# ------------------------------------------------------------------------------
add_menu_image_list () {

	local categoryWord="$1"
	local menuKeys=("${!2}")
	local categoryNote="$3"
	local missingListVar="${4:-}"
	local addMenuIdx addMenuLabelVar addMenuKey addFuncVar instPath imageChoice
	local appPathVar newImageVolSizeVar finalNameVar dispNameVar volNameVar buildNumVar sourcePathVar
	local addMenuLabels=()

	if [ "${#menuKeys[@]}" -eq 0 ]; then
		disp_print_header
		echo "No ${categoryWord} entries are configured in makedrive.conf."
		echo ""
		disp_pause_for_input
		return 0
	fi

	for (( addMenuIdx = 0 ; addMenuIdx < ${#menuKeys[@]} ; addMenuIdx++ )); do
		addMenuLabelVar="${menuKeys[$addMenuIdx]}MenuLabel"
		addMenuLabels+=( "$(printf "%2d. %s" $(( addMenuIdx + 1 )) "${!addMenuLabelVar}")" )
	done

	while true; do

		disp_print_header

		# Recompute each redraw so the list shrinks as images are added.
		if [ -n "$missingListVar" ]; then
			check_file_presence
			disp_print_missing_images "${!missingListVar}"
		fi

		echo "Choose the $categoryWord you'd like to add to the restorekit folder:"
		echo ""

		disp_print_two_column_list addMenuLabels[@]

		echo ""
		echo " R. Return to the image type menu"
		echo " X. Exit Image Installer"
		echo ""
		echo "$categoryNote"
		echo ""
		echo "Enter the number or letter for the software you'd like to add into the"
		echo "restorekit folder and hit return: "
		echo ""
		disp_read_choice imageChoice

		case "$imageChoice" in

		[Rr] )
			return 0
			;;

		[Xx] )
			return 1
			;;

		* )
			if addMenuIdx=$(menu_choice_index "$imageChoice" "${#menuKeys[@]}"); then

				addMenuKey="${menuKeys[$addMenuIdx]}"

				addFuncVar="${addMenuKey}AddFunc"
				instPath="${!addMenuKey}"
				appPathVar="${addMenuKey}AppPath"
				newImageVolSizeVar="${addMenuKey}NewImageVolSize"
				finalNameVar="${addMenuKey}FinalName"
				dispNameVar="${addMenuKey}DispName"
				volNameVar="${addMenuKey}VolName"
				buildNumVar="${addMenuKey}BuildNumber"
				sourcePathVar="${addMenuKey}SourceImagePath"

				case "${!addFuncVar}" in

				"COPY_SINGLE" )
					add_copy_single_dmg \
						"${!dispNameVar}" \
						"$instPath" \
						"${!volNameVar}" \
						"${!buildNumVar}" \
						"${!sourcePathVar}" \
						"${!appPathVar}"
					;;

				"CREATE_INSTALL_MEDIA" )
					add_mas_createinstallmedia \
						"${!appPathVar}" \
						"${!buildNumVar}" \
						"${!newImageVolSizeVar}" \
						"${!finalNameVar}" \
						"$instPath" \
						"${!dispNameVar}"
					;;

				"CREATE_INSTALL_MEDIA_MAV" )
					add_mas_createinstallmedia_mav \
						"${!appPathVar}" \
						"${!buildNumVar}" \
						"${!newImageVolSizeVar}" \
						"${!finalNameVar}" \
						"$instPath" \
						"${!dispNameVar}"
					;;

				* )
					disp_print_header
					echo "The AddFunc configured for ${addMenuKey} in makedrive.conf is not"
					echo "recognized ('${!addFuncVar}'). No action was taken. Correct the"
					echo "conf entry and try again."
					echo ""
					disp_pause_for_input
					;;

				esac

			fi
			;;

		esac

	done

}


# ------------------------------------------------------------------------------
# menu_choice_index
# Turns a numbered-menu answer into a zero-based array index. Prints the index
# and returns 0 for a whole number from 1 to the item count; prints nothing
# and returns 1 for anything else. The base is forced to 10 because bash
# arithmetic reads a leading zero as octal, where "08" is an error that
# unwinds the whole menu loop and "010" quietly selects item 8.
#
# $1 - The text the user entered
# $2 - Number of items in the menu
# ------------------------------------------------------------------------------
menu_choice_index () {

	[[ "$1" =~ ^[0-9]{1,4}$ ]] || return 1

	local choice=$(( 10#$1 ))
	{ [ "$choice" -ge 1 ] && [ "$choice" -le "$2" ]; } || return 1

	echo $(( choice - 1 ))

}


# ------------------------------------------------------------------------------
# conf_build_image_paths
# Rebuilds imageFilePaths, the list the compress and scan track walks, from
# the current path of every image key. Installers come before diagnostics so
# processing leads with the images edited most often, regardless of where
# each family sits in makedrive.conf. Run at launch and again whenever a
# version sync rewrites the conf, because each path carries its version in
# the filename and a stale list would skip the renamed image.
# ------------------------------------------------------------------------------
conf_build_image_paths () {

	local _key

	imageFilePaths=()
	for _key in "${addMenuInstallers[@]}" "${addMenuDiagnostics[@]}"; do
		imageFilePaths+=( "${!_key}" )
	done

}


# ------------------------------------------------------------------------------
# conf_derive_menus
# Builds the image lists from makedrive.conf, so an image block can be added or
# removed there without also editing a list.
#
# addMenuOrder lists image keys oldest to newest, from every MenuLabel key in
# the conf (reversed, since new blocks go at the top). addMenuInstallers and
# addMenuDiagnostics split it for the add image sub-menus and the quick deploy
# chooser: keys with the inst prefix are installers, every other family is a
# diagnostic. imageFilePaths follows through conf_build_image_paths.
#
# $1 - Path to the conf file the keys are read from
# ------------------------------------------------------------------------------
conf_derive_menus () {

	local confFile="$1" _menuKey _key

	addMenuOrder=()
	while IFS= read -r _menuKey; do
		addMenuOrder+=( "$_menuKey" )
	done < <(grep -o '^[A-Za-z][A-Za-z0-9]*MenuLabel=' "$confFile" | sed 's/MenuLabel=$//' | tail -r)

	addMenuInstallers=()
	addMenuDiagnostics=()
	for _key in "${addMenuOrder[@]}"; do
		if [[ "$_key" == inst* ]]; then
			addMenuInstallers+=( "$_key" )
		else
			addMenuDiagnostics+=( "$_key" )
		fi
	done

	conf_build_image_paths

}


# ------------------------------------------------------------------------------
# conf_bt_detail_size
# Prints the total VolSize of the given keys (dataDrive excluded), rounded up
# to the nearest 10, as a bare number; the caller adds the GB. It sums VolSize,
# not NewImageVolSize, because that is what lands on the target disk.
#
# $@ - Image keys of one build type's volume list
# ------------------------------------------------------------------------------
conf_bt_detail_size () {

	local _key _sizeVar _sizes=""

	for _key in "$@"; do
		[ "$_key" = "dataDrive" ] && continue
		_sizeVar="${_key}VolSize"
		_sizes="$_sizes ${!_sizeVar%G}"
	done

	awk -v vals="$_sizes" 'BEGIN {
		n = split(vals, a, " ")
		total = 0
		for (i = 1; i <= n; i++) total += a[i]
		c = int(total / 10)
		if (c * 10 < total) c++
		printf "%d", c * 10
	}'

}


# ------------------------------------------------------------------------------
# conf_derive_build_types
# Builds the build type registry from makedrive.conf.
#
# buildTypeNums (the valid type numbers, in menu order) comes from every
# buildTypeXX_label key, sorted ascending, so a type can be added, removed or
# renumbered there without also editing a list.
#
# buildTypeXX_detail is computed from the volumes' VolSize for any type that
# doesn't define one, so it stays right whatever the type's number. A detail
# defined in the conf is left alone (DataDrive Only, whose "0G = use remaining
# space" volume can't be summed).
#
# $1 - Path to the conf file the labels are read from
# ------------------------------------------------------------------------------
conf_derive_build_types () {

	local confFile="$1"
	local _btLabelNum _btNum _btDetailVar _btVols _btHasImageKey _btHasDataDrive _btVolKey

	buildTypeNums=()
	while IFS= read -r _btLabelNum; do
		buildTypeNums+=( "$_btLabelNum" )
	done < <(grep -o '^buildType[0-9][0-9]*_label=' "$confFile" | sed 's/^buildType//; s/_label=$//' | sort -n)

	for _btNum in "${buildTypeNums[@]}"; do
		_btDetailVar="buildType${_btNum}_detail"
		[ -n "${!_btDetailVar}" ] && continue

		_btVols=()
		eval "_btVols=( \"\${buildType${_btNum}_volumes[@]}\" )"

		_btHasImageKey=0 _btHasDataDrive=0
		for _btVolKey in "${_btVols[@]}"; do
			if [ "$_btVolKey" = "dataDrive" ]; then
				_btHasDataDrive=1
			else
				_btHasImageKey=1
			fi
		done
		[ "$_btHasImageKey" = "0" ] && continue

		if [ "$_btHasDataDrive" = "1" ]; then
			printf -v "$_btDetailVar" 'About %sGB plus DataDrive' "$(conf_bt_detail_size "${_btVols[@]}")"
		else
			printf -v "$_btDetailVar" 'About %sGB' "$(conf_bt_detail_size "${_btVols[@]}")"
		fi
	done

}


# ------------------------------------------------------------------------------
# conf_version_newer
# Returns 0 (true) if $1 is strictly newer than $2 as a dot-separated version.
# Compares integer components left to right; missing components treated as 0.
# ------------------------------------------------------------------------------
conf_version_newer () {
	local IFS=.
	# shellcheck disable=SC2206  # intentional split of dotted version on IFS=.
	local va=($1) vb=($2)
	local i
	for (( i = 0; i < ${#va[@]} || i < ${#vb[@]}; i++ )); do
		local a=${va[i]:-0} b=${vb[i]:-0}
		(( 10#$a > 10#$b )) && return 0
		(( 10#$a < 10#$b )) && return 1
	done
	return 1
}


# ------------------------------------------------------------------------------
# download_sync_conf
# Compares catalog version data (MACOS_DL_* shell vars already loaded) against
# makedrive.conf and updates version strings and build numbers in-place wherever
# Apple's catalog has a newer minor release for an existing major version slot.
#
# Skips INST-A entries and major version slots not currently present in
# addMenuOrder.
#
# Re-sources makedrive.conf after any changes so the running session reflects
# the updated paths and build numbers immediately.
#
# $1 - Number of catalog entries (macOSdlCount)
# $2 - "reissue" to also adopt a different build of the version the conf
#      already names. The download menu passes it, since that build is the
#      one it is about to fetch; the launch sync leaves a same-version build
#      alone so a build number set by hand survives.
# ------------------------------------------------------------------------------
download_sync_conf () {

	local dlCount="$1" adoptReissue="${2:-}"
	local confPath="$makedriveSupportConf"
	local dlIdx dlVer dlBuild _v _b _t
	local osMajor osMinor keyRoot instKey menuKey instPath confVer confBuild changed
	local anyUpdate=0

	for (( dlIdx = 0; dlIdx < dlCount; dlIdx++ )); do
		_v="MACOS_DL_VERSION_${dlIdx}"; dlVer="${!_v}"
		_b="MACOS_DL_BUILD_${dlIdx}";   dlBuild="${!_b}"

		# Derive the numeric root of the inst key from the catalog version
		osMajor="${dlVer%%.*}"
		if [ "$osMajor" = "10" ]; then
			osMinor="${dlVer#*.}"; osMinor="${osMinor%%.*}"
			keyRoot=$(( 1000 + osMinor ))
		else
			keyRoot=$(( osMajor * 100 ))
		fi

		# Find the matching GENERIC public entry in addMenuOrder
		instKey=""
		for menuKey in "${addMenuOrder[@]}"; do
			[[ "$menuKey" == "inst${keyRoot}"* ]] || continue
			_t="${menuKey}DeployType"
			[ "${!_t}" = "GENERIC" ]             || continue
			instKey="$menuKey"
			break
		done
		[ -z "$instKey" ] && continue

		# Extract the version currently encoded in the conf DMG filename
		instPath="${!instKey}"
		confVer="${instPath##*/}"      # e.g. "26.5.1 Install.dmg"
		confVer="${confVer% Install.dmg}"  # e.g. "26.5.1"

		# Nothing to do unless the catalog version is strictly newer, or (for
		# the download menu only) it is the same version under another build.
		# An empty conf build means verification is switched off for that
		# entry, so it is left empty.
		if ! conf_version_newer "$dlVer" "$confVer"; then
			[ "$adoptReissue" = "reissue" ]       || continue
			conf_version_newer "$confVer" "$dlVer" && continue
			_t="${instKey}BuildNumber"; confBuild="${!_t}"
			if [ -z "$dlBuild" ] || [ -z "$confBuild" ] || [ "$dlBuild" = "$confBuild" ]; then
				continue
			fi
		fi

		# Update makedrive.conf using awk literal-string substitution.
		# lsub() does a plain index()-based replace - no regex metacharacter
		# risk from dots in version strings (e.g. "26.5.1").
		# Output is staged to a temp file in the same directory, then renamed
		# into place atomically so a partial write never corrupts the conf.
		local tmpConf
		tmpConf=$(mktemp "${confPath}.XXXXXX") || continue  # can't stage safely; skip this update
		# mktemp creates the staging file mode 600 owned by root (makedrive
		# runs elevated here), and the rename below installs it as the conf,
		# which the unelevated launch pass then can't read. Give the staging
		# file the conf's own owner, group, and mode before it is filled in
		# so the rename changes nothing but the contents.
		chown "$(stat -f '%u:%g' "$confPath")" "$tmpConf" 2>/dev/null
		chmod "$(stat -f '%Lp' "$confPath")" "$tmpConf" 2>/dev/null
		# shellcheck disable=SC2016  # $ refs are awk variables, not shell
		local awkProg='
function lsub(str, from, to,    i) {
    i = index(str, from)
    return i ? substr(str, 1, i-1) to substr(str, i+length(from)) : str
}
$0 ~ ("^" key "BuildNumber=") {
    new_line = key "BuildNumber=\"" new_build "\""
    if ($0 != new_line) { $0 = new_line; n++ }
    print > out; next
}
$0 ~ ("^" key "DispName=") || $0 ~ ("^" key "FinalName=") || $0 ~ ("^" key "MenuLabel=") {
    new_line = lsub($0, old_ver, new_ver)
    if (new_line != $0) { $0 = new_line; n++ }
    print > out; next
}
$0 ~ ("^" key "=") {
    new_line = lsub($0, old_ver " Install.dmg\"", new_ver " Install.dmg\"")
    if (new_line != $0) { $0 = new_line; n++ }
    print > out; next
}
{ print > out }
END { print n+0 }
'
		changed=$(awk \
		    -v key="$instKey" \
		    -v old_ver="$confVer" \
		    -v new_ver="$dlVer" \
		    -v new_build="$dlBuild" \
		    -v out="$tmpConf" \
		    "$awkProg" "$confPath")
		# The update only counts once the rename lands. A conf that can't be
		# replaced (locked in Finder, for example) is left as it was, with
		# no notice claiming otherwise and no staging file left behind.
		if [ "${changed:-0}" -gt 0 ] 2>/dev/null && mv "$tmpConf" "$confPath" 2>/dev/null; then
			makeDriveSyncNotice+="${makeDriveSyncNotice:+, }macOS ${dlVer} (${dlBuild})"
			anyUpdate=1
		else
			rm -f "$tmpConf"
		fi
	done

	if [ "$anyUpdate" = "1" ]; then
		# shellcheck source=/dev/null
		source "$confPath"
		conf_build_image_paths
	fi

}


# ------------------------------------------------------------------------------
# startup_sync_versions
# Runs at launch before the main menu. Fetches a lightweight catalog from
# Apple's servers (version and build only - no package URLs), compares each
# major-version slot against makedrive.conf, and calls download_sync_conf to
# update the conf in-place when newer minor releases exist.
# Sets makeDriveSyncNotice (read by main_menu) if any updates were applied.
# Network failure is non-fatal: the function returns 0 and leaves conf alone.
# ------------------------------------------------------------------------------
startup_sync_versions () {

	local syncVarsFile macOSdlCount=0 dlIdx startTime=$SECONDS elapsed
	local cacheFile="$makedriveSupportDir/catalog-cache"
	local cacheAge cacheFresh=0

	# A catalog result newer than two hours is reused without touching the
	# network, making closely spaced launches effectively instant. The cache
	# lives in the user-editable support directory, so before being sourced
	# as root its contents are validated line by line against the only
	# shapes catalog_fetch_vars is allowed to emit.
	if [ -f "$cacheFile" ]; then
		cacheAge=$(( $(date +%s) - $(stat -f%m "$cacheFile" 2>/dev/null || echo 0) ))
		if [ "$cacheAge" -ge 0 ] && [ "$cacheAge" -lt 7200 ] && \
		   grep -q '^MACOS_DL_COUNT=' "$cacheFile" 2>/dev/null && \
		   ! grep -qEv '^MACOS_DL_COUNT=[0-9]+$|^MACOS_DL_VERSION_[0-9]+="[0-9.]+"$|^MACOS_DL_BUILD_[0-9]+="[0-9A-Za-z.]*"$' "$cacheFile" 2>/dev/null; then
			cacheFresh=1
		fi
	fi

	if [ "$cacheFresh" = "1" ]; then
		syncVarsFile="$cacheFile"
	else
		syncVarsFile=$(mktemp "$makedriveScratchDir/syncvars.XXXXXX") || return 0

		printf "Verifying latest macOS installer versions with Apple..."

		catalog_fetch_vars sync > "$syncVarsFile" 2>/dev/null

		echo " done."

		if ! grep -q "^MACOS_DL_COUNT=" "$syncVarsFile" 2>/dev/null; then
			rm -f "$syncVarsFile"
			elapsed=$(( SECONDS - startTime ))
			[ "$elapsed" -lt 4 ] && sleep $(( 4 - elapsed ))
			return 0
		fi

		mkdir -p "$makedriveSupportDir"
		cp "$syncVarsFile" "$cacheFile"
	fi

	# shellcheck source=/dev/null
	. "$syncVarsFile"
	[ "$cacheFresh" = "1" ] || rm -f "$syncVarsFile"
	macOSdlCount=$MACOS_DL_COUNT

	makeDriveSyncNotice=""
	download_sync_conf "$macOSdlCount"

	for (( dlIdx = 0; dlIdx < macOSdlCount; dlIdx++ )); do
		unset "MACOS_DL_VERSION_${dlIdx}" "MACOS_DL_BUILD_${dlIdx}"
	done
	unset MACOS_DL_COUNT

	# The pause exists only so the on-screen network check is readable; a
	# cache hit prints nothing and gets no artificial delay.
	if [ "$cacheFresh" != "1" ]; then
		elapsed=$(( SECONDS - startTime ))
		[ "$elapsed" -lt 4 ] && sleep $(( 4 - elapsed ))
	fi

}


# ------------------------------------------------------------------------------
# build_ask_to_copy_datadrive
# Asks if you want to copy the contents of the data partition to the selected 
# drive.  If the input is not within proper bounds, it asks again.
# ------------------------------------------------------------------------------
build_ask_to_copy_datadrive () {

	# If you need a partitioned and quickly imaged disk, but don't need all
	# of the other junk on it, you can elect to not copy the large data
	# partition. Otherwise, it's a good idea to copy the whole thing.
	while [ "$okToCopyData" = "" ]; do

		disp_print_header

		# A build type whose volumes are dataDrive only (e.g. "DataDrive Only")
		# always copies the data partition - it's the entire point of that
		# build type, so skip the prompt. Checked by volume composition rather
		# than a specific type number, since that number can change in
		# makedrive.conf.
		local _volumesRef="buildType${diskType}_volumes[@]"
		local _hasImageKey=0 _volKey
		for _volKey in "${!_volumesRef}"; do
			[ "$_volKey" != "dataDrive" ] && _hasImageKey=1
		done
		if [ "$_hasImageKey" = "0" ]; then
			okToCopyData="Y"

		else
			echo "Do you want to copy the contents of the data partition to disk$diskNum?"
			echo ""
			echo "Enter Y or N: "
			disp_read_choice okToCopyData
		fi
			
		# If the input isn't Y or N (either case), null the value and ask again.
		case "$okToCopyData" in
		
		[YyNn] )
			echo ""
			;;
		
		* )
			okToCopyData=""
			;;
		
		esac
		
	done

}


# ------------------------------------------------------------------------------
# build_ask_to_run_again
# Asks if you want to image another drive and sets doDrive accordingly.
# ------------------------------------------------------------------------------
build_ask_to_run_again () {

	disp_print_header
	
	# Answering Y or y will keep the loop running for imaging more disks without
	# having to go back to the main menu.
	echo "Completed disk is ejected."
	echo ""
	echo "If you want to image another drive, connect it before answering 'yes'."
	echo ""
	echo "Do you want to image another drive? Y/N: "
	echo ""
	read -r doDrive
	doDrive="${doDrive%% *}"

}


# ------------------------------------------------------------------------------
# build_disks_behind_volume
# Prints the whole-disk number(s) behind the mounted volume at $1, one per line:
# its own disk and, on APFS, the physical disk under the container. Erasing
# either takes the volume with it. Prints "unreadable" if diskutil can't say.
# ------------------------------------------------------------------------------
build_disks_behind_volume () {

	diskutil info "$1" 2>/dev/null | awk -F': *' '
		/^ *(Part of Whole|APFS Physical Store):/ {
			d = $2
			gsub(/ /, "", d)
			sub(/^disk/, "", d)
			sub(/s.*$/, "", d)
			if (d != "") { print d; found = 1 }
		}
		END { if (!found) print "unreadable" }'

}


# ------------------------------------------------------------------------------
# build_disks_with_backup_volumes
# Prints the whole-disk number(s), one per line, of every APFS container that
# holds a volume with the Backup role (what macOS gives a Time Machine volume).
# The role lives on the volume, so this finds a backup disk that is locked,
# unmounted, or not set up on this Mac.
# ------------------------------------------------------------------------------
build_disks_with_backup_volumes () {

	diskutil apfs list 2>/dev/null | awk '
		/^\+-- Container /                              { container = ""; stores = "" }
		/APFS Container Reference:/                     { container = $NF }
		/APFS Physical Store Disk:/                     { stores = stores " " $NF }
		/APFS Volume Disk \(Role\):.*\(Backup\)[ \t]*$/ { print container stores }
	' | tr ' ' '\n' | sed -E -e 's/^disk//' -e 's/s.*$//' | grep -E '^[0-9]+$'

}


# ------------------------------------------------------------------------------
# build_get_time_machine_disks
# Sets $timeMachineDiskID to the whole-disk number(s) that hold a Time Machine
# backup, without the 'disk' prefix (e.g. "6 7" on APFS: the physical disk and
# its container). build_choose_target_device refuses all of them.
# $timeMachineUnreadable is 1 when a backup is mounted but diskutil couldn't say
# which disk it is on, so the check can't see it.
#
# Read-only: it only asks tmutil, mount and diskutil questions. No one signal
# finds every backup disk, so it uses three:
#   - a local backup destination this Mac has set up and mounted (tmutil)
#   - an APFS volume with the Backup role, mounted or not, set up here or not
#   - a Backups.backupdb folder on a mounted volume (older HFS+ backup disks)
# Only local disks are probed for the folder, since looking inside a network
# share that has gone away can hang. An unmounted HFS+ backup disk shows none of
# these; the erase confirmation is the last word there.
# ------------------------------------------------------------------------------
build_get_time_machine_disks () {

	local mountPoint candidates

	candidates="$(
		tmutil destinationinfo 2>/dev/null | awk '
			/^(>|=)/                          { kind = "" }
			/^Kind/                           { sub(/^Kind *: */, ""); kind = $0 }
			/^Mount Point/ && kind == "Local" { sub(/^Mount Point *: */, ""); print }
		' | while IFS= read -r mountPoint; do
			build_disks_behind_volume "$mountPoint"
		done
		mount 2>/dev/null | awk '/^\/dev\/disk/ { sub(/^[^ ]+ on /, ""); sub(/ \([^)]*\)$/, ""); print }' |
		while IFS= read -r mountPoint; do
			[ -d "$mountPoint/Backups.backupdb" ] && build_disks_behind_volume "$mountPoint"
		done
		build_disks_with_backup_volumes
	)"

	# each disk once, in number order, however many of the signals saw it
	timeMachineUnreadable=""
	case "$candidates" in
	*unreadable* ) timeMachineUnreadable="1" ;;
	esac
	timeMachineDiskID="$(printf '%s\n' "$candidates" | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ')"
	timeMachineDiskID="${timeMachineDiskID% }"

}


# ------------------------------------------------------------------------------
# build_disk_is_time_machine
# Succeeds when whole disk number $1 holds a Time Machine backup. Looks again
# each time: a disk can be attached, or swapped for one with the same number,
# after makedrive starts.
# ------------------------------------------------------------------------------
build_disk_is_time_machine () {

	build_get_time_machine_disks
	[[ " $timeMachineDiskID " == *" $1 "* ]]

}


# ------------------------------------------------------------------------------
# build_eject_target_disk
# Ejects disk $1 after its build, unless it now holds a Time Machine backup (the
# disk was swapped after it was chosen), which is left exactly as found.
# ------------------------------------------------------------------------------
build_eject_target_disk () {

	if build_disk_is_time_machine "$1"; then
		return 0
	fi

	diskutil eject "disk$1"

}


# ------------------------------------------------------------------------------
# build_choose_target_device
# Asks to choose the disk to wipe for imaging.  Will only exit the function once
# valid input is provided and the disk chosen is confirmed as the one to wipe.
# The startup disk and any disk holding a Time Machine backup are refused.
# ------------------------------------------------------------------------------
build_choose_target_device () {

	# Depending on the input, the checks below null out $diskNum to keep asking
	# or move on to verifying it's the disk they want to build onto.
	while [ "$diskNum" == "" ]; do

		disp_print_header

		diskutil list

		# Say which disks are off limits before they're asked for, so a refusal
		# below is no surprise.
		build_get_time_machine_disks
		if [ -n "$timeMachineDiskID" ]; then
			echo "Time Machine backup disks: disk${timeMachineDiskID// /, disk}"
			echo "(makedrive will not erase these)"
		fi
		if [ -n "$timeMachineUnreadable" ]; then
			echo "makedrive could not tell which disk holds a Time Machine backup that is"
			echo "mounted now, so make sure the disk you pick is not that one."
		fi

		echo ""
		echo "Enter the disk number you would like to erase & restore. For example,"
		echo "if the disk you want to erase is disk2, enter \"2\" and hit return."
		echo ""
		echo "You may need to scroll up to see all disks connected to the computer."
		echo ""
		echo "If you don't see the disk listed, connect the drive you would like to restore"
		echo "and hit return to refresh the list."
		echo ""
		echo "To cancel the selection process, enter \"X\" and hit return."
		echo ""
		disp_read_choice diskNum

		# If the input is null, reload the script
		if [ "$diskNum" == "" ]; then
			echo ""

		elif [ "$diskNum" = "X" ] || [ "$diskNum" = "x" ]; then
			break

		# If the disk number doesn't exist, kick it back and ask again. Anything
		# but digits is turned away too: a slice like 2s1 exists as a device,
		# but would slip past the whole-disk checks below.
		elif [[ "$diskNum" == *[!0-9]* ]] || [ ! -e "/dev/disk$diskNum" ]; then
			disp_print_header
			
			echo "That disk number doesn't exist according to the OS. Choose another disk"
			echo "to restore onto."
			echo ""
			disp_pause_for_input
			diskNum=""

		# If the disk to image is a boot disk (bootDiskID may list more than one
		# number on APFS), warn and ask again.
		elif [[ " $bootDiskID " == *" $diskNum "* ]]; then
			disp_print_header
			
			echo "You are currently booted to a volume on disk$diskNum, and erasing disk$diskNum"
			echo "would be an extremely bad idea.  Choose another disk to erase."
			echo ""
			disp_pause_for_input
			diskNum=""

		# A Time Machine backup is never an erase target, however it got named.
		# The formatting steps check again before they touch a disk.
		elif build_disk_is_time_machine "$diskNum"; then
			disp_print_header

			echo "disk$diskNum holds a Time Machine backup, and makedrive never erases one."
			echo "Choose another disk to erase."
			echo ""
			disp_pause_for_input
			diskNum=""

        # Asks if you are OK with erasing the drive that you just chose. If you
        # aren't OK with it, it nulls the input and sends you back to the prompt
		else
			disp_print_header
			
			diskutil list disk"$diskNum"
			echo ""
			echo "This process will wipe all data on the drive shown above. Ensure there is"
			echo "no data on the disk listed before you continue. Are you OK with erasing the"
			echo "drive listed above? Enter Y to continue the imaging process or N to return"
			echo "to the input prompt:"
			echo ""
			read -r okToErase
		
			if [ "$okToErase" = "Y" ] || [ "$okToErase" = "y" ]; then
				echo ""
			else
				diskNum=""
			fi
		fi
	done
	
}


# ------------------------------------------------------------------------------
# build_clean_vol_folder
# Erases /Volumes/DataDriveTempFolder if it exists, because it shouldn't exist
# before a build. This is the fix for drives getting disconnected while imaging,
# which makes the DataDrive partition not copy data on subsequent disks.
# ------------------------------------------------------------------------------
build_clean_vol_folder () {

	disp_print_header
	
	if [ -n "$dataDriveStartName" ] && [ -e "/Volumes/$dataDriveStartName" ]; then
		rm -rf "/Volumes/$dataDriveStartName"
	fi

}


# ------------------------------------------------------------------------------
# deploy_restore_and_configure
# Restores a disk image onto a prepared target volume, then renames, blesses,
# disables Spotlight, and unmounts it. Called per-volume by build_deploy_volume
# and directly by quick_deploy_start.
#
# $1 - deployType  (GENERIC, INST-A, ASD-EFI, AXD-PKG, or COPY)
# $2 - displayName
# $3 - imagePath   (source DMG)
# $4 - startName   (volume name of the prepared partition; ASR target)
# $5 - volName     (conf VolName: the name INST-A and ASD-EFI images restore
#                   with; empty for GENERIC, whose images already restore as
#                   finalName; unused for AXD-PKG and COPY)
# $6 - finalName   (desired final volume name shown to the user)
# $7 - pkgName     (AXD-PKG only: package filename inside the mounted source DMG)
# $8 - pkgTgtVolName (AXD-PKG only: name Apple's package gives the target volume)
#
# Uses globals:  diskNum, spotlightSleepInSeconds
# Sets global:   lastBuildError
# Returns:       0 success | 1 non-fatal error (rename/bless) | 2 fatal error (ASR)
# ------------------------------------------------------------------------------
deploy_restore_and_configure () {

	local deployType="$1"
	local displayName="$2"
	local imagePath="$3"
	local startName="$4"
	local volName="$5"
	local finalName="$6"
	local pkgName="$7"
	local pkgTgtVolName="$8"
	local hadError=0
	local renameSource="$finalName"
	local srcDevice srcMount

	disp_print_header

	echo "Setting up $displayName"
	echo ""

	# Mount all partitions on the target disk before restoring.
	# Works around asr unmounting behavior on Catalina+ (FB6952557).
	diskutil mountDisk "disk$diskNum"
	sleep 2

	# Get the image content onto the target volume. Most images restore with
	# asr; AXD EFI volumes are populated by Apple's installer package, and
	# images asr cannot restore are soft-cloned from a mounted copy instead.
	case "$deployType" in

	AXD-PKG )
		echo "Installing the Apple Server Diagnostics package to the target volume."
		echo ""
		IFS=$'\t' read -r srcDevice srcMount < <(dmgtool_attach_parse "$imagePath" -readonly)
		# The mount point can be empty even when the attach itself succeeds
		# (nothing mountable in the image), so require both before using it.
		if [ -z "$srcDevice" ] || [ -z "$srcMount" ]; then
			[ -n "$srcDevice" ] && hdiutil detach -force "$srcDevice" 2>/dev/null
			lastBuildError="Could not mount the $displayName image."
			echo "Could not mount the $displayName image. The drive may be incomplete."
			echo ""
			disp_pause_for_input
			return 2
		fi
		# These packages were signed with certificates that expired years ago
		# and were never re-issued, so the install requires -allowUntrusted.
		# The package renames the target volume itself, so the rename below
		# starts from the name the package leaves behind.
		if ! installer -verbose -allowUntrusted -pkg "$srcMount/$pkgName" -target "/Volumes/$startName"; then
			hdiutil detach -force "$srcDevice" 2>/dev/null
			lastBuildError="The package install failed for $displayName."
			echo ""
			echo "The package install failed for $displayName. The drive may be incomplete."
			echo ""
			disp_pause_for_input
			return 2
		fi
		hdiutil detach -force "$srcDevice" 2>/dev/null
		renameSource="$pkgTgtVolName"
		;;

	COPY )
		echo "Cloning the contents of the disk image to the target volume."
		echo ""
		IFS=$'\t' read -r srcDevice srcMount < <(dmgtool_attach_parse "$imagePath" -readonly)
		# The mount point can be empty even when the attach itself succeeds
		# (nothing mountable in the image), so require both before using it.
		if [ -z "$srcDevice" ] || [ -z "$srcMount" ]; then
			[ -n "$srcDevice" ] && hdiutil detach -force "$srcDevice" 2>/dev/null
			lastBuildError="Could not mount the $displayName image."
			echo "Could not mount the $displayName image. The drive may be incomplete."
			echo ""
			disp_pause_for_input
			return 2
		fi
		if ! cp -R "$srcMount/" "/Volumes/$startName/"; then
			hdiutil detach -force "$srcDevice" 2>/dev/null
			lastBuildError="Cloning $displayName onto the target volume failed."
			echo ""
			echo "Cloning $displayName onto the target volume failed. The drive may be incomplete."
			echo ""
			disp_pause_for_input
			return 2
		fi
		hdiutil detach -force "$srcDevice" 2>/dev/null
		renameSource="$startName"
		;;

	* )
		echo "Restoring disk image to target volume."
		echo ""
		if ! asr restore --source "$imagePath" --target "/Volumes/$startName/" --erase --noprompt --noverify; then
			lastBuildError="asr restore failed for $displayName."
			echo ""
			echo "asr restore failed for $displayName. The drive may be incomplete."
			echo ""
			disp_pause_for_input
			return 2
		fi
		echo ""
		case "$deployType" in
		INST-A | ASD-EFI ) renameSource="$volName" ;;
		esac
		;;

	esac

	# Rename to final name. GENERIC images already carry finalName; INST-A and
	# ASD-EFI volumes restore with their source volume name, AXD-PKG volumes
	# carry the name Apple's package set, and COPY volumes keep startName.
	if [ "$renameSource" != "$finalName" ]; then
		if ! diskutil rename "/Volumes/$renameSource" "$finalName" && [ "$hadError" = "0" ]; then
			lastBuildError="Could not rename $renameSource to $finalName."
			hadError=1
			echo "Warning: volume rename failed for $renameSource. Drive may not be fully set up."
		fi
	fi

	# Bless volume for boot capability. Diagnostic EFI and serializer volumes
	# keep their boot files at the volume root, so the root folder is blessed
	# for them; everything else blesses the standard CoreServices folder.
	local blessFolder="/Volumes/$finalName/System/Library/CoreServices"
	case "$deployType" in
	ASD-EFI | AXD-PKG | COPY )
		blessFolder="/Volumes/$finalName"
		;;
	esac
	if ! bless -folder "$blessFolder" -label "$finalName"; then
		[ "$hadError" = "0" ] && lastBuildError="$finalName could not be blessed and may not be bootable."
		hadError=1
		echo "Warning: bless failed for $finalName. Volume may not be bootable."
	fi

	# Some older installers (confirmed 10.9) carry a separate .IABootFiles
	# folder at the volume root - a self-contained legacy boot environment
	# (its own boot.efi, kernelcache, Boot.plist) that Apple's
	# createinstallmedia blesses as the actual active boot target instead of
	# CoreServices (confirmed via `bless --info`: "Blessed System Folder is
	# .../.IABootFiles"). Blessing CoreServices above does not change that:
	# the firmware reads the label from whichever folder is blessed, here
	# .IABootFiles, which still carries Apple's original (not $finalName) label.
	# Re-blessing it makes bless regenerate the label from $finalName. We never
	# create it, only re-bless it if present.
	local iaBootFiles="/Volumes/$finalName/.IABootFiles"
	if [ -d "$iaBootFiles" ]; then
		bless -folder "$iaBootFiles" -label "$finalName" 2>/dev/null
	fi

	# Copy datefix script to the root of 10.7-10.9 installer volumes so it can
	# be run from the installer's Terminal to work around expired installer
	# signing certificates that Apple has not re-issued.
	if [[ "$finalName" =~ ^10\.[789]\. ]] && [ -n "${datefix_script:-}" ]; then
		printf '%s' "$datefix_script" > "/Volumes/$finalName/datefix"
		chmod 755 "/Volumes/$finalName/datefix"
	fi

	echo "Disabling Spotlight on target volume."
	touch "/Volumes/$finalName/.metadata_never_index"
	sleep "$spotlightSleepInSeconds"
	mdutil -i off "/Volumes/$finalName"

	echo "Unmounting volume now..."
	diskutil unmount "/Volumes/$finalName"

	return $hadError

}


# ------------------------------------------------------------------------------
# build_deploy_volume
# Iterates over a list of volume keys from makedrive.conf and deploys each one
# to the formatted target disk. The dataDrive entry is handled inline; all
# image volumes are dispatched to deploy_restore_and_configure.
#
# $1 - Name of array variable containing the ordered list of volume keys
# ------------------------------------------------------------------------------
build_deploy_volume () {

	local volumesToDeploy=("${!1}")
	local deployError=0
	local volumeDeployCounter key varLookup
	local deployType displayName imagePath startName volName finalName pkgName pkgTgtVolName

	for (( volumeDeployCounter = 0 ; volumeDeployCounter < ${#volumesToDeploy[@]} ; volumeDeployCounter++ )); do

		if [ "${volumesToDeploy[$volumeDeployCounter]}" = "dataDrive" ]; then

			disp_print_header

			if [ "$okToCopyData" = "Y" ] || [ "$okToCopyData" = "y" ]; then

				echo "Cloning contents of data partition now..."
				echo ""

				# macOS 15.4 switched to openrsync; --inplace caused unexpected EOF errors.
				if ! rsync -rhWE --progress --exclude "*DS_Store" --exclude ".*" "$executionPath/restorekit/" "/Volumes/$dataDriveStartName"; then
					lastBuildError="rsync to DataDrive failed."
					deployError=1
					echo ""
					echo "rsync to the data partition failed. The data partition may be incomplete."
					echo ""
					disp_pause_for_input
				fi

			else
				echo ""
			fi

			if ! diskutil rename "/Volumes/$dataDriveStartName" "$dataDriveFinalName" && [ "$deployError" = "0" ]; then
				lastBuildError="Could not rename the DataDrive partition."
				deployError=1
			fi

			break

		fi

		key="${volumesToDeploy[$volumeDeployCounter]}"

		varLookup="${key}DeployType";  deployType="${!varLookup}"
		varLookup="${key}DispName";    displayName="${!varLookup}"
		varLookup="${key}";            imagePath="${!varLookup}"
		varLookup="${key}StartName";   startName="${!varLookup}"
		varLookup="${key}FinalName";   finalName="${!varLookup}"
		# VolName and the package fields are only defined for the deploy
		# types that use them; the lookups expand empty for every other
		# type, and deploy_restore_and_configure decides what applies.
		varLookup="${key}VolName";        volName="${!varLookup}"
		varLookup="${key}PkgName";        pkgName="${!varLookup}"
		varLookup="${key}PkgTgtVolName";  pkgTgtVolName="${!varLookup}"

		lastBuildError=""
		deploy_restore_and_configure "$deployType" "$displayName" "$imagePath" \
			"$startName" "$volName" "$finalName" "$pkgName" "$pkgTgtVolName"
		local rc=$?
		if [ "$rc" = "2" ]; then
			deployError=1
			break
		elif [ "$rc" = "1" ]; then
			deployError=1
		fi

	done

	return $deployError

}


# ------------------------------------------------------------------------------
# build_drives_start
# Runs the track for building disk drives, like the original script.
# ------------------------------------------------------------------------------
build_drives_start () {

	# While doDrive is Y, keep asking to image another drive.
	while [ "$doDrive" == "Y" ] || [ "$doDrive" == "y" ]; do
		build_menu_chooser

		if [ "$diskType" == "X" ] || [ "$diskType" == "x" ]; then

			break
		fi

		# R leaves the chooser with no type selected, and a type with images
		# missing can't be built. Both go back to the chooser here, before
		# any disk has been chosen.
		if [ -z "$diskType" ] || ! build_check_images_present; then
			diskType=""
			continue
		fi

		build_ask_to_copy_datadrive
		build_choose_target_device
		
		if [ "$diskNum" = "X" ] || [ "$diskNum" = "x" ]; then
			
			diskNum=""
			diskType=""
			okToCopyData=""
			okToErase=""	
			
			break
		fi		

		build_clean_vol_folder
		build_run_build_task
		local buildTaskResult=$?

		build_eject_target_disk "$diskNum"

		if [ "$buildTaskResult" = "0" ]; then
			notify_pushover_send "Your installation drive has finished imaging."
		else
			notify_pushover_send "An error was encountered during imaging: ${lastBuildError}"
		fi
		lastBuildError=""

		# Clean up and see what happens
		diskNum=""
		diskType=""
		okToCopyData=""
		okToErase=""		
		
		build_ask_to_run_again
		
	done

	return 0
}


# ------------------------------------------------------------------------------
# build_check_images_present
# Confirms every image the chosen build type deploys is in restorekit before
# a target disk is picked. The build partitions first, so a missing image
# would otherwise fail a restore on a drive that's already erased.
#
# Uses global: diskType
# Returns 0 if every image is present, 1 after listing the ones that are not.
# ------------------------------------------------------------------------------
build_check_images_present () {

	local volumesRef="buildType${diskType}_volumes[@]"
	local key imagePath missingList=""

	for key in "${!volumesRef}"; do
		[ "$key" = "dataDrive" ] && continue
		imagePath="${!key}"
		[ -f "$imagePath" ] || missingList+="${imagePath##*/} \n"
	done

	[ -z "$missingList" ] && return 0

	disp_print_header
	echo "This drive type can't be built yet, and no disk has been touched."
	echo ""
	disp_print_missing_images "$missingList"
	echo "Add them through Main Menu option 1 or 2, or take them out of this drive"
	echo "type's volume list in makedrive.conf, then try again."
	echo ""
	disp_pause_for_input

	return 1

}


# ------------------------------------------------------------------------------
# build_format_target_disk
# Partitions the disk ID provided, using the partition map type provided, in the
# named and sized structure provided.
#
# $1 - Disk ID to be partitioned for use
# $2 - Disk partition scheme type
# $3 - Volume list array
# ------------------------------------------------------------------------------
build_format_target_disk () {

	# Copy the passed array by name into a local array for indexed access.
	local -a volumesToMake=("${!3}")
	local partitionString=""
	local numOfVolumes="${#volumesToMake[@]}"
	local volumeCounter

	# The picker already refuses a Time Machine backup; look again in case a
	# different disk took the same number after it was confirmed.
	if build_disk_is_time_machine "$1"; then
		echo ""
		echo "disk$1 holds a Time Machine backup, and makedrive never erases one."
		return 1
	fi

	# Each entry contributes three fields: filesystem type, start name, and size.
	for (( volumeCounter = 0 ; volumeCounter < ${#volumesToMake[@]} ; volumeCounter++ )); do
		
		partitionString="$partitionString\$${volumesToMake[$volumeCounter]}VolType \$${volumesToMake[$volumeCounter]}StartName \$${volumesToMake[$volumeCounter]}VolSize "

	done
	
	# Unmount the disk in brute fashion since APFS will cause mounted volumes to linger
	# when attempting to partition the physical device with any mounted containers
	diskutil unmountDisk force "disk$1"
	
	# eval is required to expand the $varName references embedded in partitionString.
	# The values come exclusively from makedrive.conf, which is controlled by the
	# admin who runs the script; this is the intended trust boundary.
	# shellcheck disable=SC2086  # word-splitting of $partitionString into args is intentional
	eval diskutil partitionDisk disk$1 $numOfVolumes $2 $partitionString
	local partitionResult=$?

	return $partitionResult

}


# ------------------------------------------------------------------------------
# build_menu_chooser
# Sets the value of $diskType to the appropriate value
# ------------------------------------------------------------------------------
build_menu_chooser () {

	diskType=""
	
	while [ "$diskType" == "" ]; do
		
		disp_print_header
		
		echo "Enter the number of the type of disk you'd like to create, then hit return."
		echo ""
		for buildTypeNum in "${buildTypeNums[@]}"; do
			labelVar="buildType${buildTypeNum}_label"
			detailVar="buildType${buildTypeNum}_detail"
			echo " ${buildTypeNum}. ${!labelVar}"
			echo "     (${!detailVar})"
			echo ""
		done
		echo "  R. Return to disk build menu"
		echo ""
		echo "  X. Return to the main menu"
		echo ""
		disp_read_choice diskType

		case "$diskType" in
		[Xx] )
			break
			;;

		[Rr] )
			diskType=""
			break
			;;

		* )
			local validType=0
			for buildTypeNum in "${buildTypeNums[@]}"; do
				if [ "$diskType" = "$buildTypeNum" ]; then
					validType=1
					break
				fi
			done
			if [ "$validType" = "0" ]; then
				diskType=""
			else
				echo ""
			fi
			;;

		esac
		
	done

}


# ------------------------------------------------------------------------------
# build_run_build_task
# ------------------------------------------------------------------------------
build_run_build_task () {

	disp_print_header

	local volumesRef="buildType${diskType}_volumes[@]"
	local schemeVar="buildType${diskType}_scheme"
	# shellcheck disable=SC2034  # passed by name to build_* and dereferenced there
	local configVolumeList=( "${!volumesRef}" )
	local diskScheme="${!schemeVar}"

	if ! build_format_target_disk "$diskNum" "$diskScheme" configVolumeList[@]; then
		lastBuildError="Disk partitioning failed."
		echo ""
		echo "Disk partitioning failed. The drive was not modified."
		echo ""
		disp_pause_for_input
		return 1
	fi
	build_deploy_volume configVolumeList[@]

}


# ------------------------------------------------------------------------------
# quick_deploy_menu_choose_image
# Displays available deployment images and returns the selected image key
# ------------------------------------------------------------------------------
quick_deploy_menu_choose_image () {

	local selectedImageNum selectedIdx selectedImageKey key dispNameVar menuIndex=1
	local deployableImages=()
	local menuLabels=()

	# Diagnostic images are excluded: a quick deploy target holds one volume, and
	# diagnostic sets are only useful as the multi-volume pairs a full
	# diagnostics build lays down.
	for key in "${addMenuInstallers[@]}"; do
		dispNameVar="${key}DispName"
		menuLabels+=( "$(printf "%2d. %s" "$menuIndex" "${!dispNameVar}")" )
		deployableImages+=("$key")
		(( menuIndex++ ))
	done

	if [ "${#deployableImages[@]}" -eq 0 ]; then
		disp_print_header
		echo "No deployment images are configured in makedrive.conf"
		echo ""
		disp_pause_for_input "Hit enter to return to the main menu."
		return 1
	fi

	while [ -z "$selectedImageKey" ]; do

		disp_print_header

		echo "Choose the image you'd like to restore to a USB or SD card:"
		echo ""

		disp_print_two_column_list menuLabels[@]

		echo ""
		echo " X. Exit to main menu"
		echo ""
		echo "Enter the number for the image you'd like to restore and hit return: "
		echo ""
		disp_read_choice selectedImageNum

		case "$selectedImageNum" in

		[Xx] )
			return 1
			;;

		* )
			if selectedIdx=$(menu_choice_index "$selectedImageNum" "${#deployableImages[@]}"); then
				selectedImageKey="${deployableImages[$selectedIdx]}"
			fi
			;;

		esac

	done

	quickDeployImageKey="$selectedImageKey"
	return 0

}


# ------------------------------------------------------------------------------
# quick_deploy_format_disk
# Formats target disk with a single partition for deployment.
#
# $1 - Disk number to partition
# $2 - Volume name for the partition
# $3 - Filesystem type (e.g. JHFS+); defaults to JHFS+ if omitted
# $4 - Partition scheme (GPT or APM); defaults to GPT
# ------------------------------------------------------------------------------
quick_deploy_format_disk () {

	local diskNum="$1"
	local volumeName="$2"
	local volType="${3:-JHFS+}"
	local scheme="${4:-GPT}"

	disp_print_header

	# The same last line of defense as build_format_target_disk
	if build_disk_is_time_machine "$diskNum"; then
		echo "disk$diskNum holds a Time Machine backup, and makedrive never erases one."
		return 1
	fi

	echo "Preparing disk$diskNum for restoration..."
	echo ""

	diskutil unmountDisk force "disk$diskNum"

	if ! diskutil partitionDisk "disk$diskNum" 1 "$scheme" "$volType" "$volumeName" 0; then
		return 1
	fi

	return 0

}


# ------------------------------------------------------------------------------
# quick_deploy_start
# Main loop for restoring a single image to a USB drive or SD card.
# Loads conf vars for the chosen image key and calls deploy_restore_and_configure
# directly - no DataDrive copy, no multi-volume iteration.
# ------------------------------------------------------------------------------
quick_deploy_start () {

	local doDeploy="Y"
	local diskNum=""

	while [ "$doDeploy" = "Y" ] || [ "$doDeploy" = "y" ]; do

		if ! quick_deploy_menu_choose_image; then
			break
		fi

		local key="$quickDeployImageKey"
		local varLookup deployType displayName imagePath startName volName finalName volType
		local keyRoot deployScheme

		varLookup="${key}DeployType";  deployType="${!varLookup}"
		varLookup="${key}DispName";    displayName="${!varLookup}"
		varLookup="${key}";            imagePath="${!varLookup}"
		varLookup="${key}StartName";   startName="${!varLookup}"
		varLookup="${key}FinalName";   finalName="${!varLookup}"
		varLookup="${key}VolType";     volType="${!varLookup}"
		varLookup="${key}VolName";     volName="${!varLookup}"

		# Deploy 10.5 and earlier onto APM media: PowerPC Macs can only boot
		# from APM, and the Intel Macs those releases support boot APM
		# properly too, so the resulting media works on both. 10.6 and later
		# are Intel or Apple Silicon only and get GPT. The version comes from
		# the numeric root of the conf key (inst103p → 103, inst1015i → 1015).
		keyRoot="${key#inst}"
		keyRoot="${keyRoot//[a-zA-Z]/}"
		deployScheme="GPT"
		[ -n "$keyRoot" ] && [ "$keyRoot" -le 105 ] 2>/dev/null && deployScheme="APM"

		disp_print_header

		if [ ! -f "$imagePath" ]; then
			echo "The selected image could not be found at:"
			echo "$imagePath"
			echo ""
			disp_pause_for_input
			continue
		fi

		diskNum=""
		build_choose_target_device

		if [ "$diskNum" = "X" ] || [ "$diskNum" = "x" ] || [ -z "$diskNum" ]; then
			diskNum=""
			continue
		fi

		if ! quick_deploy_format_disk "$diskNum" "$startName" "$volType" "$deployScheme"; then
			disp_print_header
			echo "Disk preparation failed. The drive was not modified."
			echo ""
			disp_pause_for_input
			diskNum=""
			continue
		fi

		lastBuildError=""
		deploy_restore_and_configure "$deployType" "$displayName" "$imagePath" \
			"$startName" "$volName" "$finalName"
		local deployRC=$?

		disp_print_header
		echo "Ejecting disk..."
		build_eject_target_disk "$diskNum"

		if [ "$deployRC" = "0" ] && [ -z "$lastBuildError" ]; then
			notify_pushover_send "Your USB/SD card has finished imaging."
		else
			notify_pushover_send "An error was encountered during imaging: ${lastBuildError}"
		fi

		build_ask_to_run_again
		doDeploy="$doDrive"

		diskNum=""

	done

	return 0

}


# ------------------------------------------------------------------------------
# check_file_presence
# Builds per-category lists of configured images missing from restorekit into
# the missingInstallersList and missingDiagnosticsList globals, with matching
# counts. The Main Menu prints a short notice when anything is missing, the
# image type chooser tags each category with its count, and each image list
# prints its own full list through disp_print_missing_images.
# ------------------------------------------------------------------------------
check_file_presence () {

	local _presenceKey _presencePath

	missingInstallersList=""
	missingDiagnosticsList=""
	missingInstallersCount=0
	missingDiagnosticsCount=0

	for _presenceKey in "${addMenuInstallers[@]}"; do
		_presencePath="${!_presenceKey}"
		if [ ! -e "$_presencePath" ]; then
			missingInstallersList+="${_presencePath##*/} \n"
			missingInstallersCount=$(( missingInstallersCount + 1 ))
		fi
	done

	for _presenceKey in "${addMenuDiagnostics[@]}"; do
		_presencePath="${!_presenceKey}"
		if [ ! -e "$_presencePath" ]; then
			missingDiagnosticsList+="${_presencePath##*/} \n"
			missingDiagnosticsCount=$(( missingDiagnosticsCount + 1 ))
		fi
	done

	return 0
}


# ------------------------------------------------------------------------------
# disp_print_missing_images
# Prints one category's list of images missing from restorekit, as most
# recently computed by check_file_presence. Prints nothing when it is empty.
#
# $1 - The missing-image list to print
# ------------------------------------------------------------------------------
disp_print_missing_images () {

	[ -z "$1" ] && return 0

	echo "The following images are not present in restorekit:"
	echo ""
	echo -e "$1" | rs -zet -g8
	echo ""

	return 0
}


# ------------------------------------------------------------------------------
# dmgtool_attach_parse
# Attaches a disk image with -nobrowse -noverify (plus any extra hdiutil
# flags passed after the image path) and prints a single line:
#   <device><TAB><mount point>
# The device is the first-line whole-disk entry, which is what hdiutil
# detach needs; the mount point is the last mounted-volume path, empty if
# nothing mounted. Prints nothing and returns non-zero if the attach fails.
# Callers split the line with: IFS=$'\t' read -r device mountPoint < <(...)
#
# $1   - Path to the disk image
# $2.. - Extra hdiutil attach flags (e.g. -readonly, -shadow <file>)
# ------------------------------------------------------------------------------
dmgtool_attach_parse () {

	local imagePath="$1"; shift
	local attachOut

	attachOut=$(hdiutil attach -nobrowse -noverify "$@" "$imagePath" 2>/dev/null) || return 1
	[ -z "$attachOut" ] && return 1

	printf '%s\t%s\n' \
	    "$(printf '%s\n' "$attachOut" | awk 'NR==1{print $1}')" \
	    "$(printf '%s\n' "$attachOut" | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')"

}


# ------------------------------------------------------------------------------
# dmgtool_compress_dmg
#
# $1 - Path to DMG to compress
# $2 - If processing a batch of DMGs, the current DMG count of the batch
# $3 - If processing a batch of DMGs, the total number of DMGs in the batch
# ------------------------------------------------------------------------------
dmgtool_compress_dmg () {

	disp_print_header
	
	if ! hdiutil imageinfo "$1" | grep -q "$dmgCompressionString"; then
		
		echo "Compressing ${1##*/}"
		echo ""
		
		if [ "$3" != "" ]; then
			
			echo "DMG number $2 of $3"
			echo ""
		fi

		# A staging file left behind by an interrupted run makes hdiutil
		# refuse with "File exists" on every later attempt, so clear it
		# before converting and again if the conversion fails.
		rm -f "$1.new.dmg"

		if ! hdiutil convert "$1" -format "$dmgCompressionType" -o "$1.new.dmg"; then

			rm -f "$1.new.dmg"
			return 1

		else

			# Original goes aside first so a failed second mv can put it back.
			if ! mv "$1" "$1.old.dmg"; then
				rm -f "$1.new.dmg"
				return 1
			fi
			if ! mv "$1.new.dmg" "$1"; then
				mv "$1.old.dmg" "$1"
				rm -f "$1.new.dmg"
				return 1
			fi
			rm -f "$1.old.dmg"

			return 0

		fi
		
	else

		return 0
					
	fi

}


# ------------------------------------------------------------------------------
# dmgtool_scan_dmg
# 
# $1 - Path to DMG to scan for restore
# $2 - If processing a batch of DMGs, the current DMG count of the batch
# $3 - If processing a batch of DMGs, the total number of DMGs in the batch
# ------------------------------------------------------------------------------
dmgtool_scan_dmg () {

	disp_print_header
	
	
	if ! hdiutil imageinfo "$1" | grep -q --text 'CRC32'; then
		
		echo "Scanning ${1##*/} for restore"
		echo ""

		if [ "$3" != "" ]; then
			
			echo "DMG number $2 of $3"
			echo ""
		fi

		if ! asr --verbose imagescan --source "$1"; then
		
			return 1

		else
			
			return 0
		
		fi
		
	else

		return 0

	fi

}


# ------------------------------------------------------------------------------
# dmgtool_prepare_dmg
# Compresses and then scans an image that was just added to restorekit. Both
# steps always run: an image that could not be compressed can still be
# scanned and restored. On failure it says which step did not finish and how
# to retry, and leaves the pause to the caller.
#
# $1 - Path to the DMG in restorekit
# $2 - Display name of the image
#
# Returns 0 if the image is compressed and scanned, 1 otherwise.
# ------------------------------------------------------------------------------
dmgtool_prepare_dmg () {

	local prepFailed=""

	dmgtool_compress_dmg "$1" || prepFailed="compressed"
	dmgtool_scan_dmg "$1"     || prepFailed="${prepFailed:+$prepFailed or }scanned for restore"

	[ -z "$prepFailed" ] && return 0

	disp_print_header
	echo "$2 is in restorekit, but it"
	echo "could not be $prepFailed. Check available disk space, then"
	echo "run Main Menu option 3 to finish preparing it."

	return 1

}


# ------------------------------------------------------------------------------
# disp_print_header
# Clears the screen and prints the script version and current date/time.
# ------------------------------------------------------------------------------
disp_print_header () {

	clear
	echo "makedrive version $currentVersion"
	date
	echo ""

	return 0
}


# ------------------------------------------------------------------------------
# disp_pause_for_input
# Prints a prompt and waits for the user to press return. Centralises the
# "Hit enter to continue." pattern used throughout the script.
#
# $1 - Optional prompt string (default: "Hit enter to continue.")
# ------------------------------------------------------------------------------
disp_pause_for_input () {

	local message="${1:-Hit enter to continue.}"
	echo "$message"
	read -r _

}


# ------------------------------------------------------------------------------
# disp_read_choice
# read -r for the prompt of a menu that asks again on empty input. Once input
# has ended every read fails at once, and such a menu would redraw forever at
# full CPU. A closed Terminal window normally ends the script through the
# SIGHUP trap first; this covers the cases where no hangup arrives (input
# from a pipe or file, or SIGHUP ignored by whatever launched makedrive).
# One failed read is just Control-D at a live terminal, so it is retried; a
# second failure in a row means no input can arrive, and makedrive exits
# through its normal cleanup.
#
# $1 - Name of the variable to read into
# ------------------------------------------------------------------------------
disp_read_choice () {

	read -r "$1" && return 0
	read -r "$1" && return 0

	postflight_cleanup

}


# ------------------------------------------------------------------------------
# disp_discard_typeahead
# Throws away anything typed before a prompt was on screen. Used ahead of a
# question that follows a long unattended step, where Returns pressed while
# waiting would otherwise be read as the answer. Lifting canonical mode makes
# the queued input readable at once and makes read report end of input, rather
# than wait, as soon as the queue is empty.
# ------------------------------------------------------------------------------
disp_discard_typeahead () {

	local sttySaved discard

	[ -t 0 ] || return 0
	sttySaved=$(stty -g 2>/dev/null) || return 0

	stty -icanon min 0 time 0 2>/dev/null
	# shellcheck disable=SC2034  # read needs a target; the input is discarded
	while IFS= read -r discard; do :; done
	stty "$sttySaved" 2>/dev/null

}


# ------------------------------------------------------------------------------
# disp_print_two_column_list
# Prints an array of pre-formatted strings in two balanced columns.
# Left column width is determined by the longest entry in the left half.
#
# $1 - Array variable to print, passed by name (e.g. myArray[@])
# ------------------------------------------------------------------------------
disp_print_two_column_list () {

	local items=("${!1}")
	local count=${#items[@]}
	local leftCount=$(( (count + 1) / 2 ))
	local leftColWidth=0
	local i w rightIdx

	for (( i = 0 ; i < leftCount ; i++ )); do
		w=${#items[$i]}
		(( w > leftColWidth )) && leftColWidth=$w
	done
	leftColWidth=$(( leftColWidth + 3 ))

	for (( i = 0 ; i < leftCount ; i++ )); do
		rightIdx=$(( i + leftCount ))
		if (( rightIdx < count )); then
			printf "%-${leftColWidth}s%s\n" "${items[$i]}" "${items[$rightIdx]}"
		else
			printf "%s\n" "${items[$i]}"
		fi
	done

}


# ------------------------------------------------------------------------------
# main_menu
# Asks which track you'd like to take in the program.  Gives more flexibility
# for adding new features without having to modify as much throughout the rest
# of the script.
# ------------------------------------------------------------------------------
main_menu () {

	while [ "$trackToTake" == "" ]; do
		disp_print_header
		
		check_file_presence

		if [ "$(( missingInstallersCount + missingDiagnosticsCount ))" -gt 0 ]; then
			echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
			echo ""
			echo "One or more images your configuration expects are missing from restorekit."
			echo "Choose option 1 to see what's missing and add images."
			echo ""
			echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
			echo ""
		fi

		if [ -n "$makeDriveSyncNotice" ]; then
			echo "makedrive.conf updated for newer macOS releases: ${makeDriveSyncNotice}."
			echo "Obtain the matching installer before adding it to the restorekit."
			echo ""
		fi

		echo "Welcome to makedrive's Main Menu."
		echo ""
		echo -e "\033[1m1. Add image from local file\033[0m"
		echo ""
		echo -e "\033[1m2. Download and add installer from Apple\033[0m"
		echo ""
		echo -e "\033[1m3. Compress and scan DMGs for restore\033[0m"
		echo ""
		echo -e "\033[1m4. Build your install drive\033[0m"
		echo ""
		echo -e "\033[1m5. Restore image to USB or SD card\033[0m"
		echo ""
		echo -e "\033[1m6. Configure Pushover notifications\033[0m"
		echo ""
		echo -e "\033[1m7. Uninstall makedrive from this Mac\033[0m"
		echo ""
		echo -e "\033[1mX. Exit makedrive\033[0m"
		echo ""
		echo "Enter the number or letter for the function you'd like to run and hit return."
		echo ""
		disp_read_choice trackToTake

		case "$trackToTake" in

		1 )
			add_menu_main
			;;

		2 )
			download_installer_menu
			;;

		3 )
			process_check_dmgs
			;;

		4 )
			doDrive=Y
			build_drives_start
			;;

		5 )
			quick_deploy_start
			;;

		6 )
			notify_pushover_setup
			;;

		7 )
			makedrive_uninstall
			;;

		X|x )
			stayInMainMenuLoop="N"
			;;

		* )
			trackToTake=""
			;;

		esac
		
	done
	
	return 0
}


# ------------------------------------------------------------------------------
# notify_pushover_read_userkey / notify_pushover_read_apptoken
# Read a single Pushover credential from the user's login keychain and print it
# to stdout. Returns an empty string silently when the credential is not present.
# ------------------------------------------------------------------------------
notify_pushover_read_userkey () {
	security find-generic-password \
		-s "makedrive-pushover-userkey" \
		-a "makedrive" \
		-w \
		"$makedrivePushoverKeychain" 2>/dev/null
}

notify_pushover_read_apptoken () {
	security find-generic-password \
		-s "makedrive-pushover-apptoken" \
		-a "makedrive" \
		-w \
		"$makedrivePushoverKeychain" 2>/dev/null
}


# ------------------------------------------------------------------------------
# notify_pushover_delete_credentials
# Removes both Pushover keychain entries. Silently ignores missing entries.
# ------------------------------------------------------------------------------
notify_pushover_delete_credentials () {
	security delete-generic-password \
		-s "makedrive-pushover-userkey" \
		-a "makedrive" \
		"$makedrivePushoverKeychain" >/dev/null 2>&1
	security delete-generic-password \
		-s "makedrive-pushover-apptoken" \
		-a "makedrive" \
		"$makedrivePushoverKeychain" >/dev/null 2>&1
}


# ------------------------------------------------------------------------------
# notify_pushover_remove
# Confirms intent then permanently removes Pushover credentials from the
# user's login keychain.
# ------------------------------------------------------------------------------
notify_pushover_remove () {

	disp_print_header

	echo "Remove Pushover Credentials"
	echo ""
	echo "This will permanently remove your Pushover credentials from your login"
	echo "keychain. makedrive will no longer send Pushover notifications."
	echo ""
	printf "Are you sure you want to remove Pushover credentials? Y/N: "
	read -r confirmRemove
	echo ""

	if [ "$confirmRemove" = "Y" ] || [ "$confirmRemove" = "y" ]; then

		notify_pushover_delete_credentials
		echo "Pushover credentials removed from your login keychain."
		echo "makedrive will no longer send Pushover notifications."

	else
		echo "Removal cancelled."
	fi

	echo ""
	disp_pause_for_input

}


# ------------------------------------------------------------------------------
# makedrive_uninstall
# Permanently removes all makedrive components from this Mac: the Application
# Support folder (including makedrive.conf), Pushover credentials from the
# user's login keychain, and the script file itself. Prompts the user to type
# UNINSTALL to confirm before taking any action.
# ------------------------------------------------------------------------------
makedrive_uninstall () {

	local scriptDir
	scriptDir=$(cd "$executionPath" 2>/dev/null && pwd)
	local scriptPath
	scriptPath="$scriptDir/$(basename "$0")"
	local sideConf="$scriptDir/makedrive.conf"

	disp_print_header
	echo "Uninstall makedrive"
	echo ""
	echo "This will permanently remove the following from this Mac:"
	echo ""
	echo "  * $makedriveSupportDir"
	echo "  * Pushover credentials from your login keychain (if present)"
	echo "  * $scriptPath"
	echo ""
	echo "Type UNINSTALL and press return to confirm, or press return to cancel."
	echo ""
	read -r uninstallConfirm

	if [ "$uninstallConfirm" != "UNINSTALL" ]; then
		echo ""
		echo "Uninstall cancelled."
		echo ""
		disp_pause_for_input
		return 0
	fi

	echo ""
	echo "Uninstalling makedrive..."

	if [ -d "$makedriveSupportDir" ]; then
		rm -rf "$makedriveSupportDir"
		echo "  Removed $makedriveSupportDir"
	fi

	if security find-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
			-w "$makedrivePushoverKeychain" >/dev/null 2>&1; then
		notify_pushover_delete_credentials
		echo "  Pushover credentials removed from login keychain."
	fi

	rm -f "$makedriveLockFile"
	[ -n "$makedriveScratchDir" ] && rm -rf "$makedriveScratchDir"
	# Remove a conf still sitting alongside the script (only present if the
	# startup migration to Application Support did not run or failed). Skip
	# when scriptDir is the support dir, which was already removed above.
	if [ "$sideConf" != "$makedriveSupportConf" ] && [ -f "$sideConf" ]; then
		rm -f "$sideConf"
		echo "  Removed $sideConf"
	fi
	rm -f "$scriptPath"
	echo "  Removed $scriptPath"

	echo ""
	echo "makedrive has been uninstalled from this Mac."
	sleep 2
	exit 0

}


# ------------------------------------------------------------------------------
# notify_pushover_send
# Sends a Pushover notification using credentials stored in the user's login keychain.
# Returns silently if credentials are not configured or the send fails.
#
# $1 - Message text to send
# ------------------------------------------------------------------------------
notify_pushover_send () {

	local userKey appToken

	userKey=$(notify_pushover_read_userkey)
	appToken=$(notify_pushover_read_apptoken)

	if [ -z "$userKey" ] || [ -z "$appToken" ]; then return 0; fi

	# Credentials ride curl's stdin via --config rather than argv, where any
	# process listing could read them for the duration of the send. Message
	# text must not contain double quotes (they would break the config-file
	# quoting); every caller passes fixed makedrive strings.
	curl --silent --max-time 10 --config - \
		"https://api.pushover.net/1/messages.json" \
		> /dev/null 2>&1 <<-CURLEOF
		form-string = "token=${appToken}"
		form-string = "user=${userKey}"
		form-string = "message=${1}"
	CURLEOF

}


# ------------------------------------------------------------------------------
# notify_pushover_setup
# Sub-menu for all Pushover notification management: configure credentials,
# send a test notification, or remove credentials.
# ------------------------------------------------------------------------------
notify_pushover_setup () {

	local pushoverMenuChoice=""

	while [ "$pushoverMenuChoice" == "" ]; do

		disp_print_header

		echo "Pushover Notification Setup"
		echo ""
		echo " 1. Configure or update credentials"
		echo ""
		echo " 2. Send a test notification"
		echo ""
		echo " 3. Remove credentials"
		echo ""
		echo " X. Return to main menu"
		echo ""
		echo "Enter a number or letter and hit return: "
		echo ""
		disp_read_choice pushoverMenuChoice

		case "$pushoverMenuChoice" in

		1 )
			disp_print_header

			echo "Pushover Credential Configuration"
			echo ""
			echo "You will need your Pushover User Key and an Application API Token."
			echo "Both are available from your account at pushover.net."
			echo ""
			echo "Credentials will be stored in your login keychain."
			echo ""

			local userKey appToken

			printf "Enter your Pushover User Key (input masked): "
			read -rs userKey
			echo ""

			printf "Enter your Pushover App Token (input masked): "
			read -rs appToken
			echo ""
			echo ""

			if [ -z "$userKey" ] || [ -z "$appToken" ]; then
				echo "Setup cancelled - both a User Key and App Token are required."
			elif ! [[ "$userKey" =~ ^[A-Za-z0-9]+$ ]] || ! [[ "$appToken" =~ ^[A-Za-z0-9]+$ ]]; then
				echo "Setup cancelled - Pushover keys are strictly alphanumeric, and one"
				echo "of the values entered contains other characters."
			else

				local saveUserKeyResult saveAppTokenResult

				# The secrets ride security(1)'s stdin (-i command mode)
				# instead of -w arguments, which any process listing could
				# read while the command runs. security -i does not propagate
				# command failures in its exit status, so each write is
				# verified by reading the credential back.
				security -i <<-SECEOF
					add-generic-password -U -s makedrive-pushover-userkey -a makedrive -w ${userKey} "${makedrivePushoverKeychain}"
				SECEOF
				saveUserKeyResult=1
				[ "$(notify_pushover_read_userkey)" = "$userKey" ] && saveUserKeyResult=0

				security -i <<-SECEOF
					add-generic-password -U -s makedrive-pushover-apptoken -a makedrive -w ${appToken} "${makedrivePushoverKeychain}"
				SECEOF
				saveAppTokenResult=1
				[ "$(notify_pushover_read_apptoken)" = "$appToken" ] && saveAppTokenResult=0

				userKey=""; appToken=""

				if [ "$saveUserKeyResult" = "0" ] && [ "$saveAppTokenResult" = "0" ]; then
					echo "Pushover credentials saved to your login keychain."
					echo ""
					echo "To verify or remove them, open Keychain Access, select your login"
					echo "keychain, and search for 'makedrive-pushover'."
					echo ""
					printf "Would you like to send a test notification now? Y/N: "
					read -r testConfirm
					echo ""
					if [ "$testConfirm" = "Y" ] || [ "$testConfirm" = "y" ]; then
						notify_pushover_test
					fi
				else
					echo "There was an error saving credentials to the keychain."
				fi

			fi

			echo ""
			disp_pause_for_input
			pushoverMenuChoice=""
			;;

		2 )
			disp_print_header
			notify_pushover_test
			echo ""
			disp_pause_for_input
			pushoverMenuChoice=""
			;;

		3 )
			notify_pushover_remove
			pushoverMenuChoice=""
			;;

		[Xx] )
			break
			;;

		* )
			pushoverMenuChoice=""
			;;

		esac

	done

}


# ------------------------------------------------------------------------------
# notify_pushover_test
# Fetches credentials from the user's login keychain and sends a visible test
# notification, reporting the HTTP result so the user can confirm correct setup.
# ------------------------------------------------------------------------------
notify_pushover_test () {

	local userKey appToken testStatus

	userKey=$(notify_pushover_read_userkey)
	appToken=$(notify_pushover_read_apptoken)

	if [ -z "$userKey" ] || [ -z "$appToken" ]; then
		echo "No Pushover credentials found in the keychain."
		echo "Configure credentials using option 1 before testing."
		return 1
	fi

	echo "Sending test notification..."
	echo ""

	# Credentials on curl's stdin via --config, not argv - see notify_pushover_send.
	testStatus=$(curl \
		--silent \
		--max-time 10 \
		--output /dev/null \
		--write-out "%{http_code}" \
		--config - \
		"https://api.pushover.net/1/messages.json" 2>/dev/null <<-CURLEOF
		form-string = "token=${appToken}"
		form-string = "user=${userKey}"
		form-string = "message=makedrive: Test notification - Pushover is configured correctly."
	CURLEOF
	)

	if [ "$testStatus" = "200" ]; then
		echo "Test notification sent successfully. Check your Pushover device."
		return 0
	else
		echo "Test notification failed (HTTP ${testStatus:-no response})."
		echo "Verify your credentials and network connection."
		return 1
	fi

}


# ------------------------------------------------------------------------------
# postflight_cleanup
# Removes the lockfile to prevent failed subsequent launches and the scratch
# directory, which holds the installer sparseimage, downloads, and the
# version-check files, so an interrupted run doesn't leave those behind. (The
# one temp file outside it is the .new.dmg a compression writes beside its
# image in restorekit; the next compression of that image replaces it.) Also
# corrects permissions on the restorekit folder so it can be manipulated in
# Finder without issue, since makedrive adds files into it as root.
# ------------------------------------------------------------------------------
postflight_cleanup () {

	# Detach any makedrive scratch volumes an interrupted run left mounted,
	# before their backing images are deleted below. Temp volume names are
	# derived from the conf ("<FinalName> temp", the volume name handed to
	# createinstallmedia) rather than globbed, so an unrelated user volume
	# that merely ends in " temp" is never touched. "Shared Support" is the
	# asset volume Mojave+ createinstallmedia mounts.
	local _cleanupKey _cleanupNameVar _cleanupVol
	for _cleanupKey in "${addMenuOrder[@]}"; do
		_cleanupNameVar="${_cleanupKey}FinalName"
		_cleanupVol="/Volumes/${!_cleanupNameVar} temp"
		[ -n "${!_cleanupNameVar}" ] && [ -d "$_cleanupVol" ] && \
		    hdiutil detach -force "$_cleanupVol" 2>/dev/null
	done
	[ -d "/Volumes/Shared Support" ] && hdiutil detach -force "/Volumes/Shared Support" 2>/dev/null

	rm -f "$makedriveLockFile"
	[ -n "$makedriveScratchDir" ] && rm -rf "$makedriveScratchDir"

	if [ -d "$executionPath/restorekit" ]; then
		chmod -RN "$executionPath/restorekit"
		[ -n "$SUDO_USER" ] && chown -Rf "$SUDO_USER" "$executionPath/restorekit"
	fi

	# explicit, so a quit run as true root (no SUDO_USER) doesn't report failure
	# just because the chown above was skipped
	exit 0

}


# ------------------------------------------------------------------------------
# preflight_check_for_restorekit
# Checks to see if the restorekit folder is alongside of the makedrive script, 
# typically on the desktop but not necessarily on a desktop folder. Note that
# this doesn't check the contents of the folder.
# ------------------------------------------------------------------------------
preflight_check_for_restorekit () {

	if [ ! -e "$executionPath/restorekit" ]; then

		disp_print_header
		
		echo "The restorekit folder was not found alongside the makedrive script."
		echo ""
		echo "makedrive cannot continue without the restorekit folder."
		echo ""
		echo "Place restorekit and makedrive together on the desktop."
		echo ""
		echo "You can start from scratch without a full restorekit configuration by creating"
		echo "an empty restorekit folder. It will need DMGs, and those can be added into"
		echo "restorekit using the image installation process within the script."
		echo ""
		echo "Enter 'C' to create the restorekit folder, or any other key to exit."
		read -rn 1 restorekitCheck
		
		case "$restorekitCheck" in
		
		C|c )

			if ! mkdir "$executionPath/restorekit"; then
				echo ""
				echo "Could not create the restorekit folder. Check permissions and try again."
				echo ""
				disp_pause_for_input "Hit enter to exit makedrive."
				exit 1
			fi
			;;
		
		* )
			
			exit
			;;
		
		esac
	fi

}


# ------------------------------------------------------------------------------
# preflight_check_instance
# The re-write of this function works around a bug in Terminal.app where upon
# quitting Terminal, root-owned processes are not actually terminated. There is
# only one small way to get through this check, but the chances of that
# happening are MUCH lower than the likelihood of Terminal breaking things
# ------------------------------------------------------------------------------
preflight_check_instance () {

	# If the lockfile exists, look for another root-owned instance of
	# makedrive actually running before deciding anything.
	if [ -e "$makedriveLockFile" ]; then

		local otherPID killOtherPID

		# Match root-owned bash processes running makedrive, excluding this
		# process itself so the check also works when makedrive is already
		# root here (launched directly with sudo).
		otherPID=$(pgrep -U 0 -f "bash .*makedrive" 2>/dev/null | grep -vx "$$" | head -n 1)

		if [ -n "$otherPID" ]; then

			disp_print_header

			echo "makedrive has detected another instance of the script running."
			echo ""
			echo "If you ran makedrive and quit Terminal.app without exiting the script,"
			echo "this is expected. A bug has been filed for Terminal.app about that."
			echo ""
			echo "This will also happen if you try to use makedrive to image more than one"
			echo "drive at a time. Stuff will break if you try to multi-makedrive."
			echo ""
			echo "To quit the other instance of makedrive and proceed, enter 'P' and"
			echo "hit return."
			echo ""
			echo "To quit this instance of makedrive and let the other copy do its thing,"
			echo "enter 'X' and hit return."
			echo ""
			echo "If you choose to quit the other instance of makedrive, you may need to"
			echo "enter your administrator password in order to proceed."
			echo ""
			echo "Other PID is $otherPID"
			echo ""

			read -r killOtherPID

			if [ "$killOtherPID" == "P" ] || [ "$killOtherPID" == "p" ]; then

				sudo kill -SIGINT "$otherPID"

			else

				exit

			fi

		fi
	fi

}


# ------------------------------------------------------------------------------
# preflight_check_root
# Checks to see if the script is running as root. If not, it presents the
# introduction and warning to users who may not be familiar with the script,
# then re-runs it as root.
# ------------------------------------------------------------------------------
preflight_check_root () {
		
	if [[ $EUID -ne 0 ]]; then
		
		disp_print_header
		
		echo "Welcome to makedrive!"
		echo ""
		echo "This script is intended for the rapid deployment and distribution of"
		echo "macOS install drives. Though many precautions have been taken to"
		echo "prevent data loss, there is still the chance of a problem making"
		echo "your day a bit harder. Back up your important data before using"
		echo "this script on a mission-critical computer."
		echo ""
		echo "makedrive must be run as root for proper operation."
		echo ""
		# Replace this process with the root re-run via exec: nothing of the
		# unprivileged parent remains to fall through on a failed password, or
		# to catch a Control-C meant for the elevated child (the parent's
		# script-wide SIGINT trap would otherwise fire alongside the child's
		# scoped download cancellation). Non-interactive bash exits if exec
		# fails, so nothing runs unprivileged either way.
		exec sudo -p "Enter your admin password and hit return to continue: " "$executionPath/$(basename "$0")"
	fi
		
}

# ------------------------------------------------------------------------------
# migrate_conf_file
# Relocates makedrive.conf from the script directory to Application Support,
# archiving any existing conf file with a timestamp. Keeps the 10 most recent
# archived configurations in a "conf archive" subdirectory.
#
# $1 - Source conf path
# $2 - Target conf path
# $3 - Support directory where archive folder will be created
# ------------------------------------------------------------------------------
migrate_conf_file () {

	local sourceConf="$1"
	local targetConf="$2"
	local supportDir="$3"
	local archiveDir="${supportDir}/conf archive"
	local timestamp archivedFile archiveCount archivesToDelete i

	mkdir -p "$supportDir"
	mkdir -p "$archiveDir"

	if [ -f "$targetConf" ]; then
		timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
		archivedFile="${archiveDir}/makedrive.conf_archived_${timestamp}"

		if ! cp "$targetConf" "$archivedFile"; then
			echo "Warning: Could not archive existing conf file to $archivedFile"
			return 1
		fi
	fi

	if ! mv "$sourceConf" "$targetConf"; then
		echo "Warning: Could not move conf file to $targetConf"
		return 1
	fi

	# Clean up old archives, keeping only the 10 most recent
	archiveCount=$(find "$archiveDir" -name "makedrive.conf_archived_*" -type f 2>/dev/null | wc -l)

	if [ "$archiveCount" -gt 10 ]; then
		archivesToDelete=$(( archiveCount - 10 ))
		find "$archiveDir" -name "makedrive.conf_archived_*" -type f 2>/dev/null \
			| sort | head -n "$archivesToDelete" | while IFS= read -r oldArchive; do
			rm -f "$oldArchive"
		done
	fi

	return 0

}


# ------------------------------------------------------------------------------
# migrate_pushover_credentials
# One-time migration of Pushover credentials from the legacy System Keychain to
# the invoking user's login keychain. Skipped silently if nothing is in the
# System Keychain or if credentials are already present in the login keychain.
# ------------------------------------------------------------------------------
migrate_pushover_credentials () {

	local sysKeychain="/Library/Keychains/System.keychain"

	# Nothing to migrate if System Keychain has no makedrive credentials
	security find-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
		-w "$sysKeychain" >/dev/null 2>&1 || return 0

	# Already migrated - don't overwrite existing login keychain credentials
	security find-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
		-w "$makedrivePushoverKeychain" >/dev/null 2>&1 && return 0

	local oldUserKey oldAppToken
	oldUserKey=$(security find-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
		-w "$sysKeychain" 2>/dev/null)
	oldAppToken=$(security find-generic-password -s "makedrive-pushover-apptoken" -a "makedrive" \
		-w "$sysKeychain" 2>/dev/null)

	[ -z "$oldUserKey" ] || [ -z "$oldAppToken" ] && return 0

	# Migrated values were stored by makedrive and are alphanumeric; anything
	# else is unexpected enough to leave in place rather than re-store.
	if ! [[ "$oldUserKey" =~ ^[A-Za-z0-9]+$ ]] || ! [[ "$oldAppToken" =~ ^[A-Za-z0-9]+$ ]]; then
		return 0
	fi

	# Secrets on security's stdin rather than argv - see notify_pushover_setup.
	security -i 2>/dev/null <<-SECEOF
		add-generic-password -U -s makedrive-pushover-userkey -a makedrive -w ${oldUserKey} "${makedrivePushoverKeychain}"
		add-generic-password -U -s makedrive-pushover-apptoken -a makedrive -w ${oldAppToken} "${makedrivePushoverKeychain}"
	SECEOF

	# Only remove the System Keychain originals once the login keychain copies
	# are confirmed readable (security -i does not report failures via exit
	# status).
	if [ "$(notify_pushover_read_userkey)" = "$oldUserKey" ] && \
	   [ "$(notify_pushover_read_apptoken)" = "$oldAppToken" ]; then
		security delete-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
			"$sysKeychain" >/dev/null 2>&1
		security delete-generic-password -s "makedrive-pushover-apptoken" -a "makedrive" \
			"$sysKeychain" >/dev/null 2>&1
	fi

	oldUserKey=""; oldAppToken=""

}


# ------------------------------------------------------------------------------
# preflight_check_conf
# Validates the image and build type definitions in makedrive.conf before any
# menu is offered: every image key must have the variables the partition and
# deploy code dereference, and the fields build_format_target_disk eval-expands
# unquoted into the diskutil partition string (VolType, StartName, VolSize,
# scheme) must not contain whitespace, which silently misaligns the partition
# argument triplets. A conf typo would otherwise surface only after the target
# disk is partitioned; this turns a destroyed drive into an error message at
# launch.
# ------------------------------------------------------------------------------
preflight_check_conf () {

	local confProblems=""
	local key btNum volsRef deployType suffix _var val

	# Collect every image key referenced anywhere: the add menu list plus the
	# volume lists of every build type (dataDrive is checked separately).
	local -a allKeys=( "${addMenuOrder[@]}" )
	for btNum in "${buildTypeNums[@]}"; do
		volsRef="buildType${btNum}_volumes[@]"
		for key in "${!volsRef}"; do
			[ "$key" = "dataDrive" ] && continue
			case " ${allKeys[*]} " in
			*" $key "* ) ;;
			* ) allKeys+=( "$key" ) ;;
			esac
		done
	done

	for key in "${allKeys[@]}"; do

		# Fields dereferenced for every image during partitioning and deploy.
		# An empty path variable also catches build type entries that have no
		# definition block at all.
		for suffix in "" DeployType DispName FinalName StartName VolSize VolType; do
			_var="${key}${suffix}"
			[ -z "${!_var}" ] && confProblems+="  ${_var} is not set\n"
		done

		_var="${key}DeployType"; deployType="${!_var}"
		case "$deployType" in
		GENERIC )
			for suffix in AppPath NewImageVolSize; do
				_var="${key}${suffix}"
				[ -z "${!_var}" ] && confProblems+="  ${_var} is not set\n"
			done
			;;
		INST-A | ASD-EFI | COPY )
			_var="${key}VolName"
			[ -z "${!_var}" ] && confProblems+="  ${_var} is not set\n"
			;;
		AXD-PKG )
			for suffix in VolName PkgName PkgTgtVolName; do
				_var="${key}${suffix}"
				[ -z "${!_var}" ] && confProblems+="  ${_var} is not set\n"
			done
			;;
		"" ) ;;  # already reported as not set above
		* )
			confProblems+="  ${key}DeployType is '${deployType}' (must be GENERIC, INST-A, ASD-EFI, AXD-PKG, or COPY)\n"
			;;
		esac

		for suffix in VolType StartName VolSize; do
			_var="${key}${suffix}"
			val="${!_var}"
			case "$val" in
			*[[:space:]]* ) confProblems+="  ${_var} contains whitespace ('${val}')\n" ;;
			esac
		done

	done

	# AddFunc routes each add menu entry to its processing function; an
	# unrecognized value would otherwise surface only after a download.
	for key in "${addMenuOrder[@]}"; do
		_var="${key}AddFunc"
		case "${!_var}" in
		COPY_SINGLE|CREATE_INSTALL_MEDIA|CREATE_INSTALL_MEDIA_MAV ) ;;
		* ) confProblems+="  ${_var} is '${!_var}' (must be COPY_SINGLE, CREATE_INSTALL_MEDIA, or CREATE_INSTALL_MEDIA_MAV)\n" ;;
		esac
	done

	# The dataDrive pseudo-key feeds the same partition string.
	for _var in dataDriveStartName dataDriveFinalName dataDriveVolSize dataDriveVolType; do
		val="${!_var}"
		if [ -z "$val" ]; then
			confProblems+="  ${_var} is not set\n"
		else
			case "$val" in
			*[[:space:]]* ) confProblems+="  ${_var} contains whitespace ('${val}')\n" ;;
			esac
		fi
	done

	# Build type partition schemes are eval-expanded too.
	for btNum in "${buildTypeNums[@]}"; do
		_var="buildType${btNum}_scheme"
		val="${!_var}"
		if [ -z "$val" ]; then
			confProblems+="  ${_var} is not set\n"
		else
			case "$val" in
			*[[:space:]]* ) confProblems+="  ${_var} contains whitespace ('${val}')\n" ;;
			esac
		fi
	done

	[ -z "$confProblems" ] && return 0

	disp_print_header
	echo "makedrive.conf has problems that must be corrected before makedrive can run:"
	echo ""
	echo -e "$confProblems"
	echo "Nothing has been modified. Correct the entries above in makedrive.conf and"
	echo "run makedrive again."
	echo ""
	disp_pause_for_input "Hit enter to exit makedrive."
	exit 1

}


# ------------------------------------------------------------------------------
# preflight_check_dependencies
# Verifies required tools and libraries are installed:
#   - Xcode Command Line Tools (setfile for volume icons, python3 for catalog checks)
#   - PIL/Pillow (for icon normalization on pre-2013 EFI boot pickers)
# If Xcode tools are missing, user is offered Apple's installer and makedrive exits.
# If PIL installation fails, icons still work - just may not appear on older Macs.
# ------------------------------------------------------------------------------
preflight_check_dependencies () {

	# Check Xcode CLI Tools
	if ! xcode-select -p &>/dev/null; then

		disp_print_header

		echo "The Xcode Command Line Tools do not appear to be installed."
		echo ""
		echo "makedrive requires them for volume icons (setfile) and for checking"
		echo "macOS installer versions (python3)."
		echo ""
		echo "Enter 'I' to install the Xcode Command Line Tools now, or any other key to exit."
		read -rn 1 xcodeCLTCheck

		case "$xcodeCLTCheck" in

		I|i )

			xcode-select --install
			echo ""
			echo "Follow the prompts to complete installation, then run makedrive again."
			echo ""
			disp_pause_for_input "Hit enter to exit makedrive."
			exit 1
			;;

		* )

			exit
			;;

		esac

	else
		echo ""
	fi

	# Check PIL (after Xcode tools, so python3 is available)
	python3 -c "from PIL import Image" 2>/dev/null && return 0

	# Installing a PyPI package as root is not something to do silently, and
	# the feature it powers is cosmetic - ask once, and remember a refusal in
	# the support directory so the prompt doesn't nag every launch.
	local pilDeclineMarker="$makedriveSupportDir/pillow-declined"
	local pilInstallChoice
	[ -f "$pilDeclineMarker" ] && return 0

	echo "makedrive can install the Pillow imaging library (downloaded from PyPI,"
	echo "installed for the system Python as root) to normalize volume icons for"
	echo "the EFI boot picker on pre-2013 Macs. Without it everything still works;"
	echo "icons just may not appear in the boot picker on those older machines."
	echo ""
	echo "Enter 'I' to install Pillow now, or any other key to skip. If you skip,"
	echo "makedrive won't ask again (delete the following file to be re-asked):"
	echo "  $pilDeclineMarker"
	read -rn 1 pilInstallChoice
	echo ""

	case "$pilInstallChoice" in

	I|i )
		echo "Installing Pillow..."
		if python3 -m pip install -q pillow 2>/dev/null; then
			echo "Pillow installed successfully."
			echo ""
		else
			echo "Warning: Pillow installation failed. Icons will still work,"
			echo "but may not appear in EFI boot pickers on older Macs."
			echo ""
		fi
		;;

	* )
		mkdir -p "$makedriveSupportDir"
		touch "$pilDeclineMarker"
		echo ""
		;;

	esac

}

# ------------------------------------------------------------------------------
# preflight_get_boot_device
# Sets $bootDiskID to the whole-disk number(s) backing the running system, with
# the 'disk' prefix stripped (e.g. "0" or, on APFS, "2 0" for the synthesized
# container plus its physical store). build_choose_target_device refuses any of
# these as an erase target. makedrive exits if the boot disk can't be determined.
# ------------------------------------------------------------------------------
preflight_get_boot_device () {

    disp_print_header

    if [ "$(uname -m)" = "arm64" ]; then

        # Apple Silicon: an APFS system volume lives on a synthesized container
        # (Part of Whole) that is itself backed by a physical store (APFS
        # Physical Store). Erasing either would destroy the boot OS, so both
        # numbers are protected.
        local bootInfo parentWhole physStore diskNumCandidate
        bootInfo=$(diskutil info / 2>/dev/null)
        parentWhole=$(echo "$bootInfo" | awk -F': *' '/Part of Whole/ {print $2}' | tr -d ' ')
        physStore=$(echo "$bootInfo"  | awk -F': *' '/APFS Physical Store/ {print $2}' | tr -d ' ')

        bootDiskID=""
        for diskNumCandidate in "$parentWhole" "$physStore"; do
            diskNumCandidate="${diskNumCandidate#disk}"   # strip leading 'disk'
            diskNumCandidate="${diskNumCandidate%%s*}"     # strip partition suffix
            [ -n "$diskNumCandidate" ] \
                && [[ " $bootDiskID " != *" $diskNumCandidate "* ]] \
                && bootDiskID="${bootDiskID:+$bootDiskID }$diskNumCandidate"
        done

    else

        # Intel: bless reports the booter path; reduce it to the disk number.
        bootDiskID=$(bless -getboot | cut -c 10-50 | cut -f 1 -d s)

    fi

    if [ "$bootDiskID" == "" ]; then
        echo "The boot disk could not be successfully determined."
        echo ""
        echo "Choose your appropriate startup disk in System Settings, reboot"
        echo "the computer, and run makedrive again.  Note that makedrive will not run"
        echo "without first determining the startup disk for data safety reasons."
        echo ""
        disp_pause_for_input "Hit enter to exit makedrive."
        exit 1

    else
        echo ""
    fi

}


# ------------------------------------------------------------------------------
# preflight_get_execution_path
# Gets the execution path of the script for later use.
# ------------------------------------------------------------------------------
preflight_get_execution_path () {

	executionPath=$(dirname "$0")

}


# ------------------------------------------------------------------------------
# process_check_dmgs
# Runs the track for compressing & scanning images for restore.
# ------------------------------------------------------------------------------
process_check_dmgs () {

	local imageProcessCounter imageFailCounter totalImages

	imagesThatFailedCompression=()
	imagesThatFailedScan=()

	totalImages="${#imageFilePaths[@]}"

	# dmgtool_compress_dmg and dmgtool_scan_dmg each check the image first and
	# return immediately when there is nothing to do, so every present image
	# goes straight to both: one hdiutil imageinfo per check, no pre-scan pass.
	# Compress runs before scan because conversion invalidates scan data.
	for (( imageProcessCounter = 0 ; imageProcessCounter < totalImages ; imageProcessCounter++ )); do

		[ -e "${imageFilePaths[$imageProcessCounter]}" ] || continue

		if ! dmgtool_compress_dmg "${imageFilePaths[$imageProcessCounter]}" \
			"$(( imageProcessCounter + 1 ))" "$totalImages"; then
			imagesThatFailedCompression+=( "${imageFilePaths[$imageProcessCounter]}" )
		fi

		if ! dmgtool_scan_dmg "${imageFilePaths[$imageProcessCounter]}" \
			"$(( imageProcessCounter + 1 ))" "$totalImages"; then
			imagesThatFailedScan+=( "${imageFilePaths[$imageProcessCounter]}" )
		fi

	done

	# Report success or failure as appropriate
	disp_print_header
	
	if [ "${#imagesThatFailedCompression[@]}" = "0" ]; then

		echo "No images failed the compression process."
	
	else
		echo "The following images could not be compressed:"
		echo ""
		
		for (( imageFailCounter = 0 ; imageFailCounter < ${#imagesThatFailedCompression[@]} ; imageFailCounter++ )); do

			echo "${imagesThatFailedCompression[$imageFailCounter]##*/}"
			
		done
	fi
	
	echo ""

	if [ "${#imagesThatFailedScan[@]}" = "0" ]; then

		echo "No images failed the scan process."
	
	else
		echo "The following images could not be scanned for restore:"
		echo ""
		
		for (( imageFailCounter = 0 ; imageFailCounter < ${#imagesThatFailedScan[@]} ; imageFailCounter++ )); do

			echo "${imagesThatFailedScan[$imageFailCounter]##*/}"
			
		done
	fi

	echo ""
	disp_pause_for_input
	echo ""

	return 0
}

# Lets a test harness load every function above without running the launch
# sequence below. It only works when the script is sourced: run normally, the
# return fails and the exit stops the script, so it can never skip the startup
# checks and carry on.
if [ -n "${MAKEDRIVE_SOURCE_ONLY:-}" ]; then
	# shellcheck disable=SC2317  # exit 0 is the backstop when run rather than sourced
	return 0 2>/dev/null || exit 0
fi

# SIGHUP is what arrives when the Terminal window is closed; untrapped it ends
# the script on the spot and leaves the lockfile and scratch directory (which
# can hold a multi-gigabyte installer image) behind.

trap postflight_cleanup SIGINT SIGTERM SIGHUP

# Get execution path first - makedrive.conf uses $executionPath to resolve
# paths to restorekit image files.
preflight_get_execution_path

# Source makedrive.conf from whichever location is available. A conf alongside
# the script takes priority over the user Application Support path so that
# distributed updates are picked up on the very first run even before root is
# obtained. The legacy system-wide path (/Library/Application Support/makedrive)
# is checked last as a one-time upgrade fallback for pre-Build 202 installs.
_makedrive_legacy_conf="/Library/Application Support/makedrive/makedrive.conf"
if [ -f "$executionPath/makedrive.conf" ]; then
	_makedrive_active_conf="$executionPath/makedrive.conf"
elif [ -f "$makedriveSupportConf" ]; then
	_makedrive_active_conf="$makedriveSupportConf"
elif [ -f "$_makedrive_legacy_conf" ]; then
	_makedrive_active_conf="$_makedrive_legacy_conf"
else
	echo "makedrive configuration file not found."
	echo "Place makedrive.conf alongside makedrive.command and re-run to install it."
	exit 1
fi
# A conf this account can't read (left root-owned by a Build 202 version
# sync, or the root-only legacy file) would source as nothing here, empty
# the grep-based derivations below, and fail the conf lint with misleading
# "not set" errors before elevation is ever reached. The elevated pass reads
# it without trouble and re-owns the support directory, so go straight there.
if [ ! -r "$_makedrive_active_conf" ]; then
	preflight_check_root
fi
# shellcheck source=/dev/null
. "$_makedrive_active_conf"

# Values computed from makedrive.conf rather than hand-maintained there, so
# they can't drift out of sync with the image and build type blocks that back
# them. See conf_derive_menus and conf_derive_build_types.
conf_derive_menus "$_makedrive_active_conf"
conf_derive_build_types "$_makedrive_active_conf"

# Performing individual checks once at start of execution, rather than every run
# through the main application loop. The conf lint runs first so nothing else
# acts on a broken configuration.
preflight_check_conf
preflight_check_for_restorekit
preflight_get_boot_device
preflight_check_instance
preflight_check_root
preflight_check_dependencies

# Migrate makedrive.conf to the user Application Support path now that root is
# established. A conf alongside the script replaces the one in Application
# Support (natural update path). A conf still at the legacy system-wide location
# is migrated once to the new user path on the first run after upgrade.
# Old confs are archived with timestamps by migrate_conf_file.
if [ -f "$executionPath/makedrive.conf" ]; then
	migrate_conf_file "$executionPath/makedrive.conf" "$makedriveSupportConf" "$makedriveSupportDir"
elif [ -f "$_makedrive_legacy_conf" ] && [ ! -f "$makedriveSupportConf" ]; then
	migrate_conf_file "$_makedrive_legacy_conf" "$makedriveSupportConf" "$makedriveSupportDir"
fi
unset _makedrive_legacy_conf _makedrive_active_conf

migrate_pushover_credentials

# Root-owned scratch space (mode 700, unpredictable name) for what makedrive
# writes temporarily: the installer sparseimage, icon work, package expansion,
# downloads, and the version check files. One directory means the cleanup
# after an interrupt has one thing to remove. It comes before the version
# check because that check uses it.
makedriveScratchDir=$(mktemp -d "/var/tmp/makedrive-scratch.XXXXXX") || {
	echo "Could not create the makedrive scratch directory."
	exit 1
}
makedriveInstTmpImageFile="$makedriveScratchDir/makedrivetemp.sparseimage"

startup_sync_versions

# Ensure the support directory and its contents are owned by the invoking user
# so makedrive.conf can be edited without elevated privileges. makedrive runs as
# root, so files it creates here are root-owned by default. This runs after the
# version sync so the catalog cache it writes is covered on the same launch.
[ -n "$SUDO_USER" ] && chown -Rf "$SUDO_USER" "$makedriveSupportDir"

# Remove anything pre-planted at the fixed lockfile path (a symlink here
# would otherwise redirect the root-owned touch) before creating our own.
rm -f "$makedriveLockFile"
touch "$makedriveLockFile"

stayInMainMenuLoop="Y"

while [ "$stayInMainMenuLoop" == "Y" ] || [ "$stayInMainMenuLoop" == "y" ]; do
	# Where do you want to go today?
	main_menu
	
	# Clean main menu variables for selection
	trackToTake=""

done

# Clean up temporary and lock files
postflight_cleanup

# shellcheck disable=SC2317  # reached by normal fall-through, not dead code
exit 0
