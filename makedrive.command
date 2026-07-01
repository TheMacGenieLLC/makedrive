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
currentVersion="2026-06-30 - Build 201"

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
trackToTake=""

# Script-internal temporary file paths
makedriveInstTmpImageFile="/var/tmp/makedrivetemp.sparseimage"
makedriveLockFile="/var/tmp/makedrivelockfile"

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

declare -a imagesNeedingCompression
declare -a imagesNeedingScan
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
# then falls back to InstallAssistant.icns. Does nothing if neither is found.
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
# ------------------------------------------------------------------------------
add_copy_single_dmg () {

	local testDevice grepReturn dmgBaseDir _pkgExtractedApp=""

	disp_print_header

	# If $5 is empty, we don't have a source DMG yet; prompt the user to find
	# one. If $5 points to an existing file, use it directly. If $5 is set but
	# the file doesn't exist, the installer has not been assembled yet - offer
	# pkg extraction to source it from the Apple-provided flat package.
	if [ "$5" = "" ]; then

		echo "Drag the DMG for $1 into "
		echo "the terminal window and hit return to add the image into restorekit."
		echo ""
		read -r imagePathToAdd

		# Dragging a file into Terminal backslash-escapes spaces (and other
		# special characters) in the path. read -r keeps those backslashes
		# verbatim, so the quoted path handed to hdiutil below would name a
		# file that doesn't exist. Strip the escaping backslashes so the path
		# matches the real file.
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
	
	# testDevice is a local variable that is set to the device ID of the mounted
	# disk image.  Since we need to mount the image with its own name to verify
	# if it is correct, we need the device ID to properly unmount. 
	testDevice=$(hdiutil attach "$imagePathToAdd" -nobrowse -noverify -readonly | head -n 1 | awk '{print $1}')

	if [ -z "$testDevice" ]; then
		disp_print_header
		echo "The disk image could not be mounted. Verify the file and try again."
		echo ""
		disp_pause_for_input
		imagePathToAdd=""
		[ -n "$_pkgExtractedApp" ] && rm -rf "$_pkgExtractedApp"
		return 1
	fi

	# If the image has an ambiguous volume name, run a build number
	# comparison to prevent adding the wrong DMG into restorekit. Otherwise, if
	# the mounted volume name is unambiguous, look for the expected name.
	if [ "$3" = "Mac OS X Install DVD" ] || [ "$3" = "Mac OS X Install ESD" ]; then

		grep -qF "$4" "/Volumes/$3/System/Library/CoreServices/SystemVersion.plist"

		grepReturn=$?

	else

		[ -d "/Volumes/$3" ]

		grepReturn=$?

	fi
	
	# Unmount the disk image using the trimmed output from above.
	hdiutil detach -quiet "$testDevice"
		
	# If the grep returns 0, that means it successfully matched the DMG,
	# and the source image is what we want to add into restorekit.
	if [ "$grepReturn" = "0" ]; then
		
		disp_print_header
		
		echo "$1 appears valid and is"
		echo "copying to restorekit now."
		echo ""
		
		# Get the base directory path to ensure no rsync errors if the full
		# directory hierarchy is not present
		dmgBaseDir=$(dirname "$2")
	
		# If the directory doesn't exist, then create it to prevent errors
		if [ ! -d "$dmgBaseDir" ]; then
		
			mkdir -p "$dmgBaseDir"
	
		fi

		if rsync -Wh --progress "$imagePathToAdd" "$2"; then

			# Determine icon source. Use $6 (external app path) when provided.
			# Otherwise probe the DMG read-only for an embedded installer
			# bundle (e.g. a pre-built installer volume like Mavericks, or a
			# retail DVD). Modern installers are named "Install*.app"; classic
			# retail DVDs (10.3 Panther / 10.4 Tiger) ship an extensionless
			# "Install Mac OS X" bundle under "Welcome to Mac OS X". DVDs with
			# no installer bundle fall through with no source and skip the icon
			# step entirely.
			local iconSource="$6"
			# If no app path was passed but we just extracted one from a pkg,
			# use the extracted app as the icon source before probing the DMG.
			[ -z "$iconSource" ] && [ -n "$_pkgExtractedApp" ] && iconSource="$_pkgExtractedApp"
			local hasEmbeddedApp="N"
			if [ -z "$iconSource" ]; then
				local probeMount=""
				probeMount=$(hdiutil attach "$2" -nobrowse -readonly -noverify 2>/dev/null \
				    | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
				if [ -n "$probeMount" ]; then
					find "$probeMount" -type d -maxdepth 2 \
					    \( -name "Install Mac OS X" \
					       -o -name "Install Mac OS X*.app" \
					       -o -name "Install OS X*.app" \
					       -o -name "Install macOS*.app" \) \
					    -print -quit 2>/dev/null | grep -q . && hasEmbeddedApp="Y"
					hdiutil detach -quiet "$probeMount" 2>/dev/null
				fi
			fi

			# Apply icon if a source was found, converting to R/W first.
			# Compress and scan run exactly once, after any icon work is done.
			if [ -n "$iconSource" ] || [ "$hasEmbeddedApp" = "Y" ]; then
				local iconRwDmg="/var/tmp/makedrive-icon-rw.dmg"
				local iconShadow="/var/tmp/makedrive-icon.shadow"
				local iconMergedDmg="/var/tmp/makedrive-icon-merged.dmg"
				local iconMount=""
				echo "Converting image for icon application..."
				if hdiutil convert "$2" -format UDRW -o "$iconRwDmg"; then
					# DVD-style images (Apple_Driver_ATAPI) refuse -readwrite on Apple
					# Silicon. A shadow file provides a writable overlay without altering
					# the base; we merge it back before handing off to dmgtool_compress.
					rm -f "$iconShadow"
					iconMount=$(hdiutil attach "$iconRwDmg" -shadow "$iconShadow" \
					    -nobrowse -noverify 2>/dev/null \
					    | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
					if [ -n "$iconMount" ]; then
						local applySrc="$iconSource"
						[ -z "$applySrc" ] && applySrc=$(find "$iconMount" -type d -maxdepth 2 \
						    \( -name "Install Mac OS X" \
						       -o -name "Install Mac OS X*.app" \
						       -o -name "Install OS X*.app" \
						       -o -name "Install macOS*.app" \) \
						    -print -quit 2>/dev/null)
						[ -n "$applySrc" ] && dmg_apply_volume_icon "$applySrc" "$iconMount"
						hdiutil detach -quiet "$iconMount" 2>/dev/null
					fi
					echo "Merging icon changes..."
					if hdiutil convert "$iconRwDmg" -shadow "$iconShadow" \
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
        for idx in range(8):
            f.seek(base + idx * 4)
            if struct.unpack('>I', f.read(4))[0]:
                f.seek(base + idx * 4)
                f.write(b'\\x00\\x00\\x00\\x00')
" "$iconMergedDmg" 2>/dev/null
						rm -f "$2"
						mv "$iconMergedDmg" "$2"
					else
						rm -f "$2"
						mv "$iconRwDmg" "$2"
					fi
				fi
				rm -f "$iconRwDmg" "$iconShadow" "$iconMergedDmg"
			fi

			dmgtool_compress_dmg "$2"
			dmgtool_scan_dmg "$2"

			disp_print_header

			echo "$1 was successfully copied into restorekit."
		
		else
			
			echo ""
			echo "$1 was NOT successfully copied into restorekit."
			echo "Check the image source and destination, then try again."
		
		fi
	
	# If the grep returns non-zero, it means there is no match in the volumes
	# folder for the intended image's correct volume name. This indicates the
	# image either did not mount, or more likely, it is the wrong DMG.
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
	[ -n "$_pkgExtractedApp" ] && rm -rf "$_pkgExtractedApp"

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
# Three installer layouts are handled, newest first:
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
#   Fallback: a build-number-shaped token scanned out of InstallInfo.plist, for
#     any installer that happens to record it there.
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
		local ssAttach ssDevice ssMountPoint
		ssAttach=$(hdiutil attach -noverify -nobrowse -readonly "$ssDmg" 2>/dev/null)
		ssDevice=$(echo "$ssAttach"     | awk 'NR==1{print $1}')
		ssMountPoint=$(echo "$ssAttach" | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
		if [ -n "$ssDevice" ]; then
			build=$(plutil -extract "Assets.0.Build" raw -o - \
			    "${ssMountPoint}/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml" \
			    2>/dev/null)
			hdiutil detach -quiet "$ssDevice" 2>/dev/null
		fi
		printf '%s' "$build"
		return 0
	fi

	# InstallESD generation (10.7-10.15): read ProductBuildVersion from the
	# SystemVersion.plist inside BaseSystem.dmg.
	if [ -f "$esdDmg" ] || [ -f "$directBase" ]; then
		local esdDevice="" baseDmg=""

		if [ -f "$directBase" ]; then
			baseDmg="$directBase"
		else
			local esdAttach esdMountPoint
			esdAttach=$(hdiutil attach -noverify -nobrowse -readonly "$esdDmg" 2>/dev/null)
			esdDevice=$(echo "$esdAttach"     | awk 'NR==1{print $1}')
			esdMountPoint=$(echo "$esdAttach" | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
			[ -n "$esdMountPoint" ] && baseDmg="${esdMountPoint}/BaseSystem.dmg"
		fi

		if [ -n "$baseDmg" ] && [ -f "$baseDmg" ]; then
			local baseAttach baseDevice baseMountPoint
			baseAttach=$(hdiutil attach -noverify -nobrowse -readonly "$baseDmg" 2>/dev/null)
			baseDevice=$(echo "$baseAttach"     | awk 'NR==1{print $1}')
			baseMountPoint=$(echo "$baseAttach" | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
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
	# For catalog-assembled 10.15 installers this plist is the authoritative
	# source; for others it provides a regex-scannable build token.
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
# installer layout. An empty build string always returns success (permissive).
#
# Returns 0 if the builds match (or $2 is empty), non-zero otherwise.
#
# $1 - Path to the installer application bundle
# $2 - macOS build string to verify (e.g. "16G29"); empty string skips check
# ------------------------------------------------------------------------------
verify_installer_build () {

	# Empty build string: no build configured, skip verification.
	[ -z "$2" ] && return 0

	[ "$(read_installer_build "$1")" = "$2" ]

}


# ------------------------------------------------------------------------------
# add_mas_build_mismatch
# Displays the standard build-mismatch error used by both createinstallmedia
# functions when verify_installer_build returns non-zero.
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
# add_mas_createinstallmedia_impl
# Shared implementation for both createinstallmedia wrapper functions below.
# $7 = "mav" selects the --applicationpath path with codesign workarounds
# (Yosemite through High Sierra); any other value uses --downloadassets
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

		# On Golden Gate and later, AMFI validates any binary marked as a platform
		# binary via trust cache - a per-OS-build whitelist of Apple-shipped hashes.
		# Old installer bundles contain many such binaries (createinstallmedia,
		# framework dylibs, nested helper daemons) that are absent from newer trust
		# caches. codesign --deep recurses only into bundle containers, silently
		# skipping standalone Mach-O executables in any Resources directory.
		# Signing by file path strips the platform claim from each binary directly,
		# replacing it with a locally trusted ad-hoc signature that bypasses the
		# trust cache check. Sign all exec-bit files first so the outer bundle seal
		# reflects their updated hashes.
		echo "Re-signing installer binaries..."
		local _rsBin
		while IFS= read -r -d '' _rsBin; do
			codesign -f -s - "$_rsBin" 2>/dev/null
		done < <(find "$1" -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \) -print0)
		echo "Re-signing installer bundle..."
		codesign -f -s - "$1" 2>/dev/null
		echo ""

		# Apple shipped a Sierra installer where CFBundleShortVersionString in
		# Info.plist does not match the version createinstallmedia was built to
		# expect. The binary checks this and forkbombs when they differ. Patch
		# Info.plist to match what the binary expects before running.
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
			echo "Re-signing installer binaries..."
			local _rsBin
			while IFS= read -r -d '' _rsBin; do
				codesign -f -s - "$_rsBin" 2>/dev/null
			done < <(find "$1" -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \) -print0)
			echo "Re-signing installer bundle..."
			codesign -f -s - "$1" 2>/dev/null
			echo ""
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

	diskutil rename "/Volumes/$endName" "$4"

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

	dmgtool_compress_dmg "$5"
	dmgtool_scan_dmg "$5"

	echo ""
	echo "$6 is ready for use."
	echo ""
	disp_pause_for_input

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
# package, so the thin Payload can be extracted and version-checked first and
# the multi-GB InstallESD.dmg is only extracted once the version matches. The
# Payload's bundled InstallInfo.plist records the macOS version (e.g. 10.12.6)
# but not the build; the exact build still lives only inside InstallESD.dmg, so
# the authoritative build check (verify_installer_build) runs later against the
# assembled app. This pre-check exists to catch the wrong package being supplied
# before paying for the multi-GB extraction, comparing at major.minor
# granularity so a point-release difference is left to the build check.
#
# The InstallESD.dmg is moved (not copied) into the assembled app - a move on
# the same volume is instant and uses no additional disk space.
#
# The caller is responsible for removing $1 after it is no longer needed.
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
	local expandDir="/private/var/tmp/makedrive_pkgexpand"
	local pkgPath esdMember compDir payloadPath stageApp stagedAppDir
	local expectedVer pkgVer instInfo
	local _dmgDevice=""
	local suppliedPath="${3:-}"

	# Pull the dotted version (e.g. 10.12.6) out of the display name for the
	# pre-extraction check; empty if the name carries no version-shaped token.
	expectedVer=$(printf '%s' "$2" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

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
			echo ""
			echo "File not found. Verify the path and try again."
			echo ""
			disp_pause_for_input
			return 1
		fi

	fi

	# If a DMG was provided, mount it and locate the single installer package
	# at its root; subsequent xar calls read from pkgPath on the mounted volume.
	case "$pkgPath" in *.dmg|*.DMG)
		disp_print_header
		echo "Mounting installer disk image..."
		echo ""
		local _dmgOut _dmgMount
		_dmgOut=$(hdiutil attach -nobrowse -readonly -noverify "$pkgPath" 2>/dev/null)
		_dmgDevice=$(printf '%s' "$_dmgOut" | awk 'NR==1{print $1}')
		_dmgMount=$(printf '%s' "$_dmgOut" | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
		if [ -z "$_dmgDevice" ] || [ -z "$_dmgMount" ]; then
			echo "Could not mount the disk image. Verify the file and try again."
			echo ""
			disp_pause_for_input
			return 1
		fi
		pkgPath=$(find "$_dmgMount" -maxdepth 1 -name "*.pkg" -type f | head -1)
		if [ -z "$pkgPath" ]; then
			echo "No installer package found on the disk image."
			echo ""
			hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
			_dmgDevice=""
			disp_pause_for_input
			return 1
		fi
		;;
	esac

	disp_print_header

	# Locate the InstallESD.dmg member and the component directory holding it.
	# Both the ESD and the thin Payload live side by side under that directory.
	esdMember=$(xar -tf "$pkgPath" 2>/dev/null | grep -m1 '/InstallESD.dmg$')
	if [ -z "$esdMember" ]; then
		echo "This does not look like a macOS installer package (no InstallESD.dmg)."
		echo ""
		[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
		disp_pause_for_input
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
		echo "Could not read the package. Verify the file and try again."
		echo ""
		rm -rf "$expandDir"
		[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
		disp_pause_for_input
		return 1
	fi
	payloadPath="$expandDir/$compDir/Payload"
	if [ ! -f "$payloadPath" ]; then
		echo "Unexpected package structure: Payload not found."
		echo ""
		rm -rf "$expandDir"
		[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
		disp_pause_for_input
		return 1
	fi

	stageApp="$expandDir/stage"
	mkdir -p "$stageApp"
	bsdtar -C "$stageApp" -xf "$payloadPath" 2>/dev/null
	stagedAppDir=$(find "$stageApp" -maxdepth 1 -name "*.app" | head -1)
	if [ -z "$stagedAppDir" ]; then
		echo "Could not extract the installer application from the package."
		echo ""
		rm -rf "$expandDir"
		[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
		disp_pause_for_input
		return 1
	fi

	# Pre-extraction version check. The thin app's InstallInfo.plist names the
	# macOS version the bundled ESD provides; compare it (major.minor) to the
	# version expected for the chosen installer before extracting the ESD.
	instInfo="$stagedAppDir/Contents/SharedSupport/InstallInfo.plist"
	pkgVer=$(plutil -extract "System Image Info.version" raw -o - "$instInfo" 2>/dev/null)
	if [ -n "$expectedVer" ] && [ -n "$pkgVer" ] && \
	   [ "$(printf '%s' "$expectedVer" | cut -d. -f1-2)" != "$(printf '%s' "$pkgVer" | cut -d. -f1-2)" ]; then
		echo "This package is for macOS $pkgVer, but the chosen installer expects"
		echo "macOS $expectedVer. Verify you supplied the correct package and try again."
		echo ""
		rm -rf "$expandDir"
		[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
		disp_pause_for_input
		return 1
	fi

	# Version matches - extract the multi-GB ESD and assemble the installer.
	echo "Extracting installer content..."
	echo ""
	if ! xar -x -C "$expandDir" -f "$pkgPath" "$esdMember" 2>/dev/null; then
		echo "Could not extract the installer content. Check available disk space."
		echo ""
		rm -rf "$expandDir"
		[ -n "$_dmgDevice" ] && hdiutil detach -quiet "$_dmgDevice" 2>/dev/null
		disp_pause_for_input
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
		echo "Could not assemble the installer application."
		echo ""
		disp_pause_for_input
		return 1
	fi

	return 0

}


# ------------------------------------------------------------------------------
# add_mas_createinstallmedia_mav
# Processes a Mac App Store system installer into an install DMG that can be
# restored to disk. Required from 10.10 Yosemite through 10.13 High Sierra,
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

	# Sierra (10.12) has a known forkbomb issue on all hosts: CFBundleShortVersionString
	# mismatch causes createinstallmedia to spawn runaway child instances (EAGAIN /
	# error 35). Fixed by patching Info.plist to match the version the binary expects
	# before running. Darwin 16 = macOS Sierra 10.12; build strings always start with "16".
	local installerBuild="$2"
	[ -z "$installerBuild" ] && installerBuild=$(read_installer_build "$1")
	local isSierra=0
	case "$installerBuild" in 16*) isSierra=1 ;; esac
	local isMavericks=0
	case "$installerBuild" in 13*) isMavericks=1 ;; esac

	# For 10.10-10.12, the installer is no longer available through the Mac App Store
	# and must be sourced from Apple's direct-download flat package. If the app is not
	# already in /Applications, offer pkg extraction via add_installer_from_pkg.
	# Sierra on Golden Gate has the additional constraint that its JavaScript distribution
	# scripts are rejected by the host's pkg engine - surfaced here so the user
	# understands why the MAS cannot be used, before the pkg prompt appears.
	# Mavericks (10.9) has no canonical Apple package source; the app must already
	# be present in /Applications.
	local _pkgExtracted=0
	if [ ! -d "$1" ]; then

		if [ "$isMavericks" = "1" ]; then
			disp_print_header
			echo "Install OS X Mavericks is not in /Applications and has no canonical"
			echo "package source. To add this installer:"
			echo ""
			echo "  Option 1: Mount an existing 10.9.5 createinstallmedia image, copy"
			echo "             Install OS X Mavericks.app to /Applications, and try again."
			echo ""
			echo "  Option 2: Place a pre-built 10.9.5 installer DMG directly into"
			echo "             the restorekit Install folder."
			echo ""
			disp_pause_for_input
			return 1
		fi

		if [ "$isSierra" = "1" ]; then
			local hostVer
			hostVer=$(host_macos_version)
			if [ -n "$hostVer" ] && ! conf_version_newer "26" "$hostVer"; then
				disp_print_header
				echo "macOS Sierra (10.12) cannot be downloaded or installed from the Mac App"
				echo "Store on Golden Gate (macOS 26+). Its installer package uses JavaScript"
				echo "distribution scripts that are incompatible with this host's pkg engine."
				echo ""
				echo "You can proceed by providing the Apple-provided InstallOS.pkg file."
				echo ""
			fi
		fi

		add_installer_from_pkg "$1" "$6" || return 1
		_pkgExtracted=1

	fi

	add_mas_createinstallmedia_impl "$1" "$2" "$3" "$4" "$5" "$6" "mav"
	local _result=$?

	[ "$_pkgExtracted" = "1" ] && rm -rf "$1"

	return $_result

}


# ------------------------------------------------------------------------------
# download_fetch_and_process
# Downloads a macOS installer and processes it through the standard add-installer
# pipeline. Handles three source types:
#   cdn_dmg       - single DMG from Apple CDN (10.7-10.12); passes it to
#                   add_installer_from_pkg to assemble the installer app
#   catalog_single - single InstallAssistant.pkg (11+); installer to /
#   catalog_hfs    - packages (10.13-10.15); pkgutil expand → app + InstallESD.dmg
# After the pipeline completes the assembled/installed app is removed.
#
# $1 - conf key (e.g. "inst1015i")
# $2 - source type: "cdn_dmg" | "catalog_single" | "catalog_hfs"
# $3 - URL, or pipe-separated list for catalog_hfs: dist_url|pkg1_url|pkg2_url|...
# $4 - display label (e.g. "10.15.7 App Store Install")
# ------------------------------------------------------------------------------
download_fetch_and_process () {

	local confKey="$1" dlType="$2" dlURLs="$3" dlLabel="$4"

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
	tmpDir=$(mktemp -d -t makedrive-dl) || {
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
		if ! curl --location --progress-bar --fail "$dlURLs" -o "$dmgPath" 2>&1; then
			echo ""
			echo "Download failed. Check your network connection and try again."
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
		if ! curl --location --progress-bar --fail "$dlURLs" -o "$pkgPath" 2>&1; then
			echo ""
			echo "Download failed. Check your network connection and try again."
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
		# We leave InstallInfo.plist untouched (it already has the System Image Info /
		# Payload Image Info keys that createinstallmedia validates).
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
			# Only download the files we need for assembly; skip everything else.
			# BaseSystem.dmg and AppleDiagnostics.dmg are raw files (not pkgs) that
			# must be present in SharedSupport for createinstallmedia and build
			# number detection to work.
			case "$_hfsFname" in
				InstallAssistantAuto.pkg|InstallESDDmg.pkg|\
				BaseSystem.dmg|AppleDiagnostics.dmg) ;;
				*) continue ;;
			esac
			echo "Downloading $_hfsFname..."
			if ! curl --location --progress-bar --fail "$_hfsURL" \
			          -o "$tmpDir/$_hfsFname" 2>&1; then
				echo ""
				echo "Download of $_hfsFname failed. Check your network connection and try again."
				echo ""
				rm -rf "$tmpDir"
				disp_pause_for_input
				return 1
			fi
		done

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

		# BaseSystem.dmg and AppleDiagnostics.dmg are raw CDN files (not packages)
		# that createinstallmedia reads from SharedSupport.
		for _dmg in BaseSystem.dmg AppleDiagnostics.dmg; do
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

	# Dispatch to the standard add-installer pipeline - same calls as add_menu_main
	case "$addFunc" in

	COPY_SINGLE )
		add_copy_single_dmg "$dispName" "$instPath" "$volName" "$buildNum" "$srcPath" "$appPath"
		;;

	CREATE_INSTALL_MEDIA_MAV )
		add_mas_createinstallmedia_mav "$appPath" "$buildNum" "$newVolSize" "$finalName" "$instPath" "$dispName"
		;;

	CREATE_INSTALL_MEDIA )
		add_mas_createinstallmedia "$appPath" "$buildNum" "$newVolSize" "$finalName" "$instPath" "$dispName"
		;;

	esac

	# Clean up any app that was installed or assembled to /Applications
	[ -n "$_assembledApp" ] && [ -d "$_assembledApp" ] && rm -rf "$_assembledApp"

	return 0

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
	syncFile=$(mktemp -t makedrive-dlcatalog) || {
		echo "Could not create temp file."
		echo ""
		disp_pause_for_input
		return 1
	}

	# Extended catalog fetch: mirrors startup_sync_versions but also captures
	# download URLs and sizes for the latest installer per major version.
	local _catURLs _menuOrder
	printf -v _catURLs '%s\n' "${catalogURLs[@]}"
	printf -v _menuOrder '%s\n' "${addMenuOrder[@]}"
	MAKEDRIVE_CATALOG_URLS="$_catURLs" MAKEDRIVE_MENU_ORDER="$_menuOrder" \
	python3 << 'MAKEDRIVE_DLCAT_PYEOF' > "$syncFile" 2>/dev/null
import subprocess, gzip, plistlib, sys, re, os
from concurrent.futures import ThreadPoolExecutor, as_completed

def fetch(url, timeout=30):
    try:
        r = subprocess.run(
            ["curl", "--silent", "--fail", "--location",
             "--max-time", str(timeout), "--user-agent", "makedrive", url],
            capture_output=True, timeout=timeout + 10)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None

CATALOG_URLS = [u for u in os.environ.get("MAKEDRIVE_CATALOG_URLS", "").splitlines() if u]
MENU_ORDER   = [k for k in os.environ.get("MAKEDRIVE_MENU_ORDER",   "").splitlines() if k]

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
    # string comparison is wrong here ("19H15" < "19H4" lexically, since
    # '1' < '4') - parse into a tuple so the point number compares
    # numerically.
    m = re.match(r'^(\d+)([A-Za-z]+)(\d+)([a-zA-Z]*)$', str(b).strip())
    if not m:
        return (0, '', 0, '')
    major, letter, point, suffix = m.groups()
    return (int(major), letter, int(point), suffix)

raw_results = []
with ThreadPoolExecutor(max_workers=15) as ex:
    for fut in as_completed([ex.submit(get_version_build, item)
                             for item in installer_products.items()]):
        r = fut.result()
        if r:
            raw_results.append(r)

# Keep latest per major version; skip pre-10.13 and 16-25.
# 10.13-10.15 use catalog_hfs (installer → temp HFS+ volume).
# 10.7-10.12 are handled separately via hardcoded Apple CDN URLs below.
# Multiple catalog products can share the same VERSION string (e.g. three
# different builds - 19H2, 19H4, 19H15 - all reporting "10.15.7" for
# supplemental updates), so build must be compared too; otherwise whichever
# entry is processed first wins regardless of how outdated it actually is.
newest = {}
for pid, version, build, packages, dist_url in raw_results:
    p = parse_ver(version)
    if (p[0] == 10 and (len(p) < 2 or p[1] < 13)) or 16 <= p[0] <= 25:
        continue
    bucket = "10." + str(p[1]) if p[0] == 10 and len(p) > 1 else str(p[0])
    sortKey = (p, parse_build(build))
    if bucket not in newest or sortKey > newest[bucket]["_sortKey"]:
        newest[bucket] = {"version": version, "build": build, "packages": packages, "dist_url": dist_url, "_sortKey": sortKey}

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

def conf_key_for(version):
    p = parse_ver(version)
    major = p[0]
    key_root = (1000 + p[1]) if major == 10 else (major * 100)
    prefix = f"inst{key_root}"
    for k in MENU_ORDER:
        if k.startswith(prefix) and not k.endswith("a"):
            return k
    return None

final = sorted(newest.values(), key=lambda e: parse_ver(e["version"]), reverse=True)
count = 0
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
        # 10.13-10.15: download distribution file + all packages into one directory,
        # then `installer -pkg dist -target <hfs_volume>` assembles the .app without
        # needing write access to the sealed system volume (which blocks -target / on 11+).
        all_pkg_urls = [pkg.get("URL", "") for pkg in entry["packages"]
                        if pkg.get("URL", "") and not pkg.get("URL", "").endswith(".chunklist")]
        dist_url = entry["dist_url"]
        total_size = sum(pkg.get("Size", 0) for pkg in entry["packages"] if pkg.get("URL", ""))
        combined = "|".join([dist_url] + all_pkg_urls)
        rows.append((key, entry["build"], "catalog_hfs", combined, total_size))

print(f"MAKEDRIVE_DLCAT_COUNT={len(rows)}")
for i, (key, build, dtype, url, size) in enumerate(rows):
    print(f'MAKEDRIVE_DLCAT_{i}_KEY="{key}"')
    print(f'MAKEDRIVE_DLCAT_{i}_BUILD="{build}"')
    print(f'MAKEDRIVE_DLCAT_{i}_TYPE="{dtype}"')
    print(f'MAKEDRIVE_DLCAT_{i}_URL="{url}"')
    print(f'MAKEDRIVE_DLCAT_{i}_BYTES={size}')
MAKEDRIVE_DLCAT_PYEOF

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

	local catCount="$MAKEDRIVE_DLCAT_COUNT"

	# Build unified download list: catalog entries (newest first, from Python),
	# followed by CDN entries for 10.7-10.12 (newest first; 10.9 intentionally absent).
	local -a dlKeys dlLabels dlTypes dlURLs dlBytes

	local i _kv _tv _uv _bv _labV
	for (( i = 0; i < catCount; i++ )); do
		_kv="MAKEDRIVE_DLCAT_${i}_KEY"
		_tv="MAKEDRIVE_DLCAT_${i}_TYPE"
		_uv="MAKEDRIVE_DLCAT_${i}_URL"
		_bv="MAKEDRIVE_DLCAT_${i}_BYTES"
		_labV="${!_kv}MenuLabel"
		dlKeys+=("${!_kv}")
		dlLabels+=("${!_labV}")
		dlTypes+=("${!_tv}")
		dlURLs+=("${!_uv}")
		dlBytes+=("${!_bv}")
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
	done

	local totalCount=${#dlKeys[@]}
	local dlChoice selIdx _gb

	while true; do

		disp_print_header

		echo "Choose a macOS installer to download from Apple:"
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
		echo "Enter a number to download, or X to return:"
		echo ""
		read -r dlChoice

		case "$dlChoice" in

		[Xx]) return 0 ;;

		*)
			if [ "$dlChoice" -ge 1 ] 2>/dev/null && \
			   [ "$dlChoice" -le "$totalCount" ] 2>/dev/null; then
				selIdx=$(( dlChoice - 1 ))
				download_fetch_and_process \
					"${dlKeys[$selIdx]}" \
					"${dlTypes[$selIdx]}" \
					"${dlURLs[$selIdx]}" \
					"${dlLabels[$selIdx]}"
			fi
			;;

		esac

	done

}


# ------------------------------------------------------------------------------
# add_menu_main
# ------------------------------------------------------------------------------
add_menu_main () {

	local addMenuIdx addMenuLabelVar addMenuKey addFuncVar instPath
	local appPathVar newImageVolSizeVar finalNameVar dispNameVar volNameVar buildNumVar sourcePathVar
	local addMenuLabels=()

	imageToAdd=""

	for (( addMenuIdx = 0 ; addMenuIdx < ${#addMenuOrder[@]} ; addMenuIdx++ )); do
		addMenuLabelVar="${addMenuOrder[$addMenuIdx]}MenuLabel"
		addMenuLabels+=( "$(printf "%2d. %s" $(( addMenuIdx + 1 )) "${!addMenuLabelVar}")" )
	done

	while [ "$imageToAdd" == "" ]; do

		disp_print_header

		echo "Choose the software you'd like to add to the restorekit folder:"
		echo ""

		disp_print_two_column_list addMenuLabels[@]

		echo ""
		echo " X. Exit Image Installer"
		echo ""
		echo "If you need to copy an App Store OS installer into restorekit, ensure the"
		echo "installer application bundle is in /Applications before proceeding."
		echo ""
		echo "Enter the number or letter for the software you'd like to add into the"
		echo "restorekit folder and hit return: "
		echo ""
		read -r imageToAdd

		case "$imageToAdd" in

		[Xx] )
			break
			;;

		* )
			if [ "$imageToAdd" -ge 1 ] 2>/dev/null && \
			   [ "$imageToAdd" -le "${#addMenuOrder[@]}" ] 2>/dev/null; then

				addMenuIdx=$(( imageToAdd - 1 ))
				addMenuKey="${addMenuOrder[$addMenuIdx]}"

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

				esac

			fi
			;;

		esac

		imageToAdd=""

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
# Skips beta inst keys (suffix 'a'), INST-A entries, and major version slots not
# currently present in addMenuOrder.
#
# Re-sources makedrive.conf after any changes so the running session reflects
# the updated paths and build numbers immediately.
#
# $1 - Number of catalog entries (macOSdlCount)
# ------------------------------------------------------------------------------
download_sync_conf () {

	local dlCount="$1" quiet="${2:-0}"
	local confPath="$makedriveSupportConf"
	local dlIdx dlVer dlBuild _v _b
	local osMajor osMinor keyRoot instKey menuKey instPath confVer changed
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
			[[ "$menuKey" == *a ]]               && continue   # skip beta slots
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

		# Nothing to do if the catalog version is not strictly newer
		conf_version_newer "$dlVer" "$confVer" || continue

		# Update makedrive.conf using awk literal-string substitution.
		# lsub() does a plain index()-based replace - no regex metacharacter
		# risk from dots in version strings (e.g. "26.5.1").
		# Output is staged to a temp file in the same directory, then
		# renamed into place atomically so a partial write never corrupts
		# the conf. The change count is printed to stdout and captured.
		local tmpConf
		tmpConf=$(mktemp "${confPath}.XXXXXX")
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
		if [ "${changed:-0}" -gt 0 ] 2>/dev/null; then
			mv "$tmpConf" "$confPath"
			makeDriveSyncNotice+="${makeDriveSyncNotice:+, }macOS ${dlVer} (${dlBuild})"
			[ "$quiet" != "1" ] && echo "  makedrive.conf: ${instKey} updated ${confVer} → ${dlVer} (${dlBuild})"
			anyUpdate=1
		else
			rm -f "$tmpConf"
		fi
	done

	if [ "$anyUpdate" = "1" ]; then
		# shellcheck source=/dev/null
		source "$confPath"
		[ "$quiet" != "1" ] && echo ""
	fi

}


# ------------------------------------------------------------------------------
# startup_sync_versions
# Runs at launch before the main menu. Fetches a lightweight catalog from
# Apple's servers (version and build only - no package URLs), compares each
# major-version slot against makedrive.conf, and calls download_sync_conf in
# quiet mode to update the conf in-place when newer minor releases exist.
# Sets makeDriveSyncNotice (read by main_menu) if any updates were applied.
# Network failure is non-fatal: the function returns 0 and leaves conf alone.
# ------------------------------------------------------------------------------
startup_sync_versions () {

	local syncVarsFile macOSdlCount=0 dlIdx startTime=$SECONDS elapsed
	syncVarsFile=$(mktemp -t makedrive-syncvars) || { echo " done."; return 0; }

	printf "Verifying latest macOS installer versions with Apple..."

	local _catURLs
	printf -v _catURLs '%s\n' "${catalogURLs[@]}"
	MAKEDRIVE_CATALOG_URLS="$_catURLs" python3 << 'MAKEDRIVE_SYNC_PYEOF' > "$syncVarsFile" 2>/dev/null
import subprocess, gzip, plistlib, sys, re, os
from concurrent.futures import ThreadPoolExecutor, as_completed

# Fetch a URL with curl (follows redirects, fails on HTTP errors). Returns the
# raw response bytes, or None on any network/process failure.
def fetch(url, timeout=30):
    try:
        r = subprocess.run(
            ["curl", "--silent", "--fail", "--location",
             "--max-time", str(timeout), "--user-agent", "makedrive", url],
            capture_output=True, timeout=timeout + 10)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None

# Catalog index URLs come from makedrive.conf (catalogURLs), passed in via the
# MAKEDRIVE_CATALOG_URLS environment variable, one URL per line.
CATALOG_URLS = [u for u in os.environ.get("MAKEDRIVE_CATALOG_URLS", "").splitlines() if u]

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
# InstallAssistantPackageIdentifiers. Collect each one's English distribution
# URL - that small XML file holds the human-readable version and build strings.
dist_urls = [
    prod["Distributions"]["English"]
    for prod in products.values()
    if "InstallAssistantPackageIdentifiers" in prod.get("ExtendedMetaInfo", {})
    and prod.get("Distributions", {}).get("English")
]

def get_version_build(dist_url):
    data = fetch(dist_url, timeout=15)
    if not data:
        return None, ""
    text = data.decode("utf-8", errors="ignore")
    vm = re.search(r"<key>VERSION</key>\s*<string>([^<]+)</string>", text)
    bm = re.search(r"<key>BUILD</key>\s*<string>([^<]+)</string>", text)
    return (vm.group(1).strip() if vm else None), (bm.group(1).strip() if bm else "")

def parse_ver(v):
    try:
        return tuple(int(x) for x in str(v).strip().split("."))
    except Exception:
        return (0,)

def parse_build(b):
    # See matching comment in download_installer_menu's copy of this
    # function - plain string comparison of build numbers is wrong
    # ("19H15" < "19H4" lexically), so parse into a tuple instead.
    m = re.match(r'^(\d+)([A-Za-z]+)(\d+)([a-zA-Z]*)$', str(b).strip())
    if not m:
        return (0, '', 0, '')
    major, letter, point, suffix = m.groups()
    return (int(major), letter, int(point), suffix)

# Distribution files are fetched concurrently. Keep only the newest version and
# build for each macOS generation (keyed by major, or "10.x" for the 10 line).
# Versions before 10.13 and the nonexistent 16-25 range (Apple jumped 15 → 26)
# are dropped as catalog noise. Multiple products can share the same VERSION
# string across supplemental updates (e.g. 19H2/19H4/19H15 all "10.15.7"), so
# build must be compared too - see matching comment in download_installer_menu.
newest = {}
with ThreadPoolExecutor(max_workers=15) as ex:
    for fut in as_completed([ex.submit(get_version_build, u) for u in dist_urls]):
        version, build = fut.result()
        if not version:
            continue
        p = parse_ver(version)
        if (p[0] == 10 and (len(p) < 2 or p[1] < 13)) or 16 <= p[0] <= 25:
            continue
        key = "10." + str(p[1]) if p[0] == 10 and len(p) > 1 else str(p[0])
        sortKey = (p, parse_build(build))
        if key not in newest or sortKey > newest[key]["_sortKey"]:
            newest[key] = {"version": version, "build": build, "_sortKey": sortKey}

# Emit newest generation first as shell-sourceable assignments.
final = sorted(newest.values(), key=lambda e: parse_ver(e["version"]), reverse=True)
print("MACOS_DL_COUNT=" + str(len(final)))
for i, e in enumerate(final):
    print('MACOS_DL_VERSION_' + str(i) + '="' + e["version"] + '"')
    print('MACOS_DL_BUILD_'   + str(i) + '="' + e["build"] + '"')
MAKEDRIVE_SYNC_PYEOF

	echo " done."

	if ! grep -q "^MACOS_DL_COUNT=" "$syncVarsFile" 2>/dev/null; then
		rm -f "$syncVarsFile"
		elapsed=$(( SECONDS - startTime ))
		[ "$elapsed" -lt 6 ] && sleep $(( 6 - elapsed ))
		return 0
	fi

	# shellcheck source=/dev/null
	. "$syncVarsFile"
	rm -f "$syncVarsFile"
	macOSdlCount=$MACOS_DL_COUNT

	makeDriveSyncNotice=""
	download_sync_conf "$macOSdlCount" 1

	for (( dlIdx = 0; dlIdx < macOSdlCount; dlIdx++ )); do
		unset "MACOS_DL_VERSION_${dlIdx}" "MACOS_DL_BUILD_${dlIdx}"
	done
	unset MACOS_DL_COUNT

	elapsed=$(( SECONDS - startTime ))
	[ "$elapsed" -lt 6 ] && sleep $(( 6 - elapsed ))

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

		# DataDrive Only (type 12) always copies the data partition - it's the
		# entire point of that build type, so skip the prompt.
		if [ "$diskType" == "12" ]; then
			okToCopyData="Y"
			
		else
			echo "Do you want to copy the contents of the data partition to disk$diskNum?"
			echo ""
			echo "Enter Y or N: "
			read -r okToCopyData
		fi
			
		# If the input is none of the valid inputs, null the value and return to
		# the prompt for input. Accounts for case of input.
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
# build_choose_target_device
# Asks to choose the disk to wipe for imaging.  Will only exit the function once 
# valid input is provided and the disk chosen is confirmed as the one to wipe.
# ------------------------------------------------------------------------------
build_choose_target_device () {

	# As long as the $diskNum is empty, keep asking for input. Depending on the
	# input, the checking function will null out the input to keep asking or
	# route the user to the next input and verify it is the disk they want to
	# build onto.
	while [ "$diskNum" == "" ]; do
		
		disp_print_header
		
		diskutil list
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
		read -r diskNum

		# If the input is null, reload the script
		if [ "$diskNum" == "" ]; then
			echo ""

		elif [ "$diskNum" = "X" ] || [ "$diskNum" = "x" ]; then
			break

		# If the disk number doesn't exist, kick it back and ask again.  This 
		# should handle any kind of spurious inputs you can encounter.
		elif [ ! -e "/dev/disk$diskNum" ]; then
			disp_print_header
			
			echo "That disk number doesn't exist according to the OS. Choose another disk"
			echo "to restore onto."
			echo ""
			disp_pause_for_input
			diskNum=""

		# If the disk to image is a boot disk (bootDiskID may list more than one
		# number on APFS), null the input to return you to the input prompt and
		# present a warning not to do it again.
		elif [[ " $bootDiskID " == *" $diskNum "* ]]; then
			disp_print_header
			
			echo "You are currently booted to a volume on disk$diskNum, and erasing disk$diskNum"
			echo "would be an extremely bad idea.  Choose another disk to erase."
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
# Checks to see if the /Volumes/DataDriveTempFolder exists, and if it does, it 
# erases the folder since it shouldn't exist before building the disk.  This is 
# a solution to the problem of drives getting disconnected while imaging (and 
# having it cause the DataDrive partition to not copy data on subsequent disks.)
# ------------------------------------------------------------------------------
build_clean_vol_folder () {

	disp_print_header
	
	# Check to see if the folder is persisting for some reason. If it is, delete
	# it to prevent issues with creating the new DataDrive.
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
# $1 - deployType  (GENERIC or INST-A)
# $2 - displayName
# $3 - imagePath   (source DMG)
# $4 - startName   (volume name of the prepared partition; ASR target)
# $5 - asrName     (volume name after ASR: VolName for INST-A, FinalName for GENERIC)
# $6 - finalName   (desired final volume name shown to the user)
#
# Uses globals:  diskNum, windowCloseSleepInSeconds, spotlightSleepInSeconds
# Sets global:   lastBuildError
# Returns:       0 success | 1 non-fatal error (rename/bless) | 2 fatal error (ASR)
# ------------------------------------------------------------------------------
deploy_restore_and_configure () {

	local deployType="$1"
	local displayName="$2"
	local imagePath="$3"
	local startName="$4"
	local asrName="$5"
	local finalName="$6"
	local hadError=0

	disp_print_header

	echo "Setting up $displayName"
	echo ""

	# Mount all partitions on the target disk before restoring.
	# Works around asr unmounting behavior on Catalina+ (FB6952557).
	diskutil mountDisk "disk$diskNum"
	sleep 2

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

	# Rename to final name (INST-A only; GENERIC images already carry finalName)
	if [ "$asrName" != "$finalName" ]; then
		if ! diskutil rename "/Volumes/$asrName" "$finalName" && [ "$hadError" = "0" ]; then
			lastBuildError="Could not rename $asrName to $finalName."
			hadError=1
			echo "Warning: volume rename failed for $asrName. Drive may not be fully set up."
		fi
	fi

	# Bless volume for boot capability.
	local coreServices="/Volumes/$finalName/System/Library/CoreServices"
	if ! bless -folder "$coreServices" -label "$finalName"; then
		[ "$hadError" = "0" ] && lastBuildError="$finalName could not be blessed and may not be bootable."
		hadError=1
		echo "Warning: bless failed for $finalName. Volume may not be bootable."
	fi

	# Some older installers (confirmed 10.9) carry a separate .IABootFiles
	# folder at the volume root - a self-contained legacy boot environment
	# (its own boot.efi, kernelcache, Boot.plist) that Apple's
	# createinstallmedia blesses as the actual active boot target instead of
	# CoreServices (confirmed via `bless --info`: "Blessed System Folder is
	# .../.IABootFiles"). Blessing CoreServices above does not change that -
	# the firmware reads the label from whichever folder is actually blessed,
	# and for these volumes that is .IABootFiles, still carrying Apple's
	# original (not $finalName) label. Re-blessing it directly here makes
	# bless regenerate its label using $finalName, the same way it already
	# does correctly for CoreServices on volumes that lack this folder. We
	# never create this folder ourselves - only re-bless it if already present.
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

	# Disable Spotlight on target volume
	echo "Disabling Spotlight on target volume."
	touch "/Volumes/$finalName/.metadata_never_index"
	sleep "$spotlightSleepInSeconds"
	mdutil -i off "/Volumes/$finalName"

	# Unmount the target volume
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
	local deployType displayName imagePath startName asrName finalName

	for (( volumeDeployCounter = 0 ; volumeDeployCounter < ${#volumesToDeploy[@]} ; volumeDeployCounter++ )); do

		if [ "${volumesToDeploy[$volumeDeployCounter]}" = "dataDrive" ]; then

			disp_print_header

			# If the user chose to copy the contents of DataDrive
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
		# INST-A DMGs restore with the source volume name (e.g. "Mac OS X Install ESD"),
		# which must be renamed to FinalName. GENERIC DMGs already have FinalName as
		# their volume name so VolName is not stored in conf for them.
		if [ "$deployType" = "INST-A" ]; then
			varLookup="${key}VolName";  asrName="${!varLookup}"
		else
			asrName="$finalName"
		fi

		lastBuildError=""
		deploy_restore_and_configure "$deployType" "$displayName" "$imagePath" \
			"$startName" "$asrName" "$finalName"
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

	# While the doDrive variable is set to Y, keep running through and asking to
	# image another drive.  Once the answer is no, exit.
	while [ "$doDrive" == "Y" ] || [ "$doDrive" == "y" ]; do
		build_menu_chooser
		
		if [ "$diskType" == "X" ] || [ "$diskType" == "x" ]; then
			
			break
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

		# Run the appropriate function for each drive type
		build_clean_vol_folder
		build_run_build_task
		local buildTaskResult=$?

		diskutil eject "disk$diskNum"

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
# build_format_target_disk
# Parameters passed to build_format_target_disk will allow the function to properly
# partition the disk ID provided, using the partition map type provided, in the
# named and sized structure provided. The function also provides the initial
# spotlight deactivation to keep things calm prior to each volume itself being
# restored or changed once formatted.
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

	# Build the partition argument string by stepping through each volume entry.
	# Each entry contributes three fields: filesystem type, start name, and size.
	for (( volumeCounter = 0 ; volumeCounter < ${#volumesToMake[@]} ; volumeCounter++ )); do
		
		partitionString="$partitionString\$${volumesToMake[$volumeCounter]}VolType \$${volumesToMake[$volumeCounter]}StartName \$${volumesToMake[$volumeCounter]}VolSize "

	done
	
	# Unmount the disk in brute fashion since APFS will cause mounted volumes to linger
	# when attempting to partition the physical device with any mounted containers
	diskutil unmountDisk force "disk$1"
	
	# Partition the disk using the passed info and constructed string.
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
		read -r diskType

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

	local selectedImageNum selectedImageKey key dispNameVar menuIndex=1
	local deployableImages=()
	local menuLabels=()

	# Build arrays of all configured images and matching display labels once
	for key in "${addMenuOrder[@]}"; do
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
		read -r selectedImageNum

		case "$selectedImageNum" in

		[Xx] )
			return 1
			;;

		* )
			if [ "$selectedImageNum" -ge 1 ] 2>/dev/null && [ "$selectedImageNum" -le "${#deployableImages[@]}" ] 2>/dev/null; then
				selectedImageKey="${deployableImages[$((selectedImageNum - 1))]}"
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
# GPT is always used - quick deploy targets modern USB/SD media.
#
# $1 - Disk number to partition
# $2 - Volume name for the partition
# $3 - Filesystem type (e.g. JHFS+); defaults to JHFS+ if omitted
# ------------------------------------------------------------------------------
quick_deploy_format_disk () {

	local diskNum="$1"
	local volumeName="$2"
	local volType="${3:-JHFS+}"

	disp_print_header

	echo "Preparing disk$diskNum for restoration..."
	echo ""

	# Unmount all volumes on the disk
	diskutil unmountDisk force "disk$diskNum"

	if ! diskutil partitionDisk "disk$diskNum" 1 GPT "$volType" "$volumeName" 0; then
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
		local varLookup deployType displayName imagePath startName asrName finalName volType

		varLookup="${key}DeployType";  deployType="${!varLookup}"
		varLookup="${key}DispName";    displayName="${!varLookup}"
		varLookup="${key}";            imagePath="${!varLookup}"
		varLookup="${key}StartName";   startName="${!varLookup}"
		varLookup="${key}FinalName";   finalName="${!varLookup}"
		varLookup="${key}VolType";     volType="${!varLookup}"
		if [ "$deployType" = "INST-A" ]; then
			varLookup="${key}VolName";  asrName="${!varLookup}"
		else
			asrName="$finalName"
		fi

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

		if ! quick_deploy_format_disk "$diskNum" "$startName" "$volType"; then
			disp_print_header
			echo "Disk preparation failed. The drive was not modified."
			echo ""
			disp_pause_for_input
			diskNum=""
			continue
		fi

		lastBuildError=""
		deploy_restore_and_configure "$deployType" "$displayName" "$imagePath" \
			"$startName" "$asrName" "$finalName"
		local deployRC=$?

		disp_print_header
		echo "Ejecting disk..."
		diskutil eject "disk$diskNum"

		if [ "$deployRC" = "0" ] && [ -z "$lastBuildError" ]; then
			notify_pushover_send "Your USB/SD card has finished imaging."
		else
			notify_pushover_send "An error was encountered during imaging: ${lastBuildError}"
		fi

		disp_print_header
		echo "Completed disk is ejected."
		echo ""
		echo "If you want to image another drive, connect it before answering 'yes'."
		echo ""
		echo "Do you want to image another drive? Y/N: "
		echo ""
		read -r doDeploy
		doDeploy="${doDeploy%% *}"

		diskNum=""

	done

	return 0

}


# ------------------------------------------------------------------------------
# check_file_presence
# Runs the track for checking to see if images are present in restorekit.
# ------------------------------------------------------------------------------
check_file_presence () {

	local missingDMGs=""
	local imagePresenceCounter

	# Run the loop through the imageFilePaths array until there are no more
	# images to scan in the list (array).
	for (( imagePresenceCounter = 0 ; imagePresenceCounter < ${#imageFilePaths[@]} ; imagePresenceCounter++ )); do

		if [ ! -e "${imageFilePaths[$imagePresenceCounter]}" ]; then
			missingDMGs+="${imageFilePaths[$imagePresenceCounter]##*/} \n"
		fi
		
	done
	
	if [ "$missingDMGs" != "" ]; then
		
		echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
		echo ""
		echo "The following files are not present in restorekit:"
		echo ""
		echo -e "$missingDMGs" | rs -zet -g8
		echo ""
		echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
		echo ""
	
	fi
	
	missingDMGs=""

	return 0
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

		if ! hdiutil convert "$1" -format "$dmgCompressionType" -o "$1.new.dmg"; then
		
			return 1

		else

			# Rename original aside, move compressed into place, then remove original.
			# Staging the rename means the original is recoverable if the second mv fails.
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

		if [ -n "$makeDriveSyncNotice" ]; then
			echo "makedrive.conf updated for newer macOS releases: ${makeDriveSyncNotice}."
			echo "Obtain the matching installer before adding it to the restorekit."
			echo ""
		fi

		echo "Welcome to makedrive's Main Menu."
		echo ""
		echo -e "\033[1m1. Add installer from local file\033[0m"
		echo ""
		echo -e "\033[1m2. Download installer from Apple\033[0m"
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
		read -r trackToTake

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
# user's login keychain. makedrive will no longer send notifications after removal.
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

	curl \
		--silent \
		--max-time 10 \
		--form-string "token=${appToken}" \
		--form-string "user=${userKey}" \
		--form-string "message=${1}" \
		"https://api.pushover.net/1/messages.json" \
		> /dev/null 2>&1

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
		read -r pushoverMenuChoice

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
			else

				local saveUserKeyResult saveAppTokenResult

				security add-generic-password \
					-s "makedrive-pushover-userkey" \
					-a "makedrive" \
					-w "$userKey" \
					-U \
					"$makedrivePushoverKeychain"
				saveUserKeyResult=$?

				security add-generic-password \
					-s "makedrive-pushover-apptoken" \
					-a "makedrive" \
					-w "$appToken" \
					-U \
					"$makedrivePushoverKeychain"
				saveAppTokenResult=$?

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

	testStatus=$(curl \
		--silent \
		--max-time 10 \
		--output /dev/null \
		--write-out "%{http_code}" \
		--form-string "token=${appToken}" \
		--form-string "user=${userKey}" \
		--form-string "message=makedrive: Test notification - Pushover is configured correctly." \
		"https://api.pushover.net/1/messages.json" 2>/dev/null)

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
# Removes the lockfile to prevent failed subsequent launches and clears any
# leftover temp files (installer sparseimage, version-sync scratch files).
# Also corrects permissions on the restorekit folder so it can be manipulated
# in Finder without issue, since makedrive adds files into it as root.
# ------------------------------------------------------------------------------
postflight_cleanup () {

	rm -f "$makedriveLockFile"
	rm -f "$makedriveInstTmpImageFile"
	
	if [ -d "$executionPath/restorekit" ]; then
		chmod -RN "$executionPath/restorekit"
		[ -n "$SUDO_USER" ] && chown -Rf "$SUDO_USER" "$executionPath/restorekit"
	fi

	rm -f "/var/tmp/makedrive-syncvars."*

	exit

}


# ------------------------------------------------------------------------------
# preflight_check_for_restorekit
# Checks to see if the restorekit folder is alongside of the makedrive script, 
# typically on the desktop but not necessarily on a desktop folder. Uses the 
# current location of the script as the basis for its search. Note that this
# doesn't check the contents of the folder.
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

	# If the lockfile exists, then we'll check to see if a root-owned instance
	# of makedrive is currently running.
	if [ -e "$makedriveLockFile" ]; then

		# Look for a root-owned bash process running makedrive
		# shellcheck disable=SC2009  # need the matching bash process line
		ps -u root | grep bash | grep makedrive
		dupInstanceRunning=$?

		# If the last command returned "0", then we know another instance is running
		if [ "$dupInstanceRunning" = "0" ] && [[ $EUID -ne 0 ]]; then

			disp_print_header

			local otherPID killOtherPID
			# Save the process ID of
			# shellcheck disable=SC2009  # need the full ps line to extract the PID
			otherPID=$(ps -u root | grep bash | grep makedrive | head -n 1 | awk '{print $2}')
		
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
			echo "If you choose to quit the other instance of makedrive, you will need to"
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
# Checks to see if the script is running as root. If not, it re-runs the script
# as root to ensure proper execution of the script.  Also, it presents the
# introduction and warning to users who may not be familiar with the script.
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
		sudo -p "Enter your admin password and hit return to continue: " "$executionPath/$(basename "$0")" && exit
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
	# Count existing archives by sorting files and removing excess ones
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

	security add-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
		-w "$oldUserKey" -U "$makedrivePushoverKeychain" 2>/dev/null
	security add-generic-password -s "makedrive-pushover-apptoken" -a "makedrive" \
		-w "$oldAppToken" -U "$makedrivePushoverKeychain" 2>/dev/null

	security delete-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
		"$sysKeychain" >/dev/null 2>&1
	security delete-generic-password -s "makedrive-pushover-apptoken" -a "makedrive" \
		"$sysKeychain" >/dev/null 2>&1

	oldUserKey=""; oldAppToken=""

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

	echo "Installing PIL (Pillow) for icon normalization..."
	echo "(This is needed for boot picker compatibility on pre-2013 Macs.)"
	echo ""

	if python3 -m pip install -q pillow 2>/dev/null; then
		echo "PIL installed successfully."
		echo ""
	else
		echo "Warning: PIL installation failed. Icons will still work,"
		echo "but may not appear in EFI boot pickers on older Macs."
		echo ""
	fi

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

    # Determine every whole-disk number that backs the running system so the
    # build menu can refuse to erase it. The mechanism differs per platform.
    if [ "$(uname -m)" = "arm64" ]; then

        # Apple Silicon: derive the boot disk(s) from the root volume. An APFS
        # system volume lives on a synthesized container (Part of Whole) that is
        # itself backed by a physical store (APFS Physical Store) - erasing
        # either would destroy the boot OS, so both numbers are protected.
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

	local imageCheckCounter imageCompressCounter imageScanCounter imageFailCounter
	local compressionPresent scanInfoPresent compressResult scanResult

	imagesNeedingCompression=()
	imagesThatFailedCompression=()
	imagesNeedingScan=()
	imagesThatFailedScan=()

	# Check all DMGs for compression info, and add any images not compressed
	# with the configured format ($dmgCompressionString) to the array
	for (( imageCheckCounter = 0 ; imageCheckCounter < ${#imageFilePaths[@]} ; imageCheckCounter++ )); do

		disp_print_header

		echo "Checking images for compression information now..."
		echo ""

		[ -e "${imageFilePaths[$imageCheckCounter]}" ] || continue
		hdiutil imageinfo "${imageFilePaths[$imageCheckCounter]}" | grep -q "$dmgCompressionString"
		compressionPresent=$?
	
		# If hdiutil/grep returns not 0 (non-success, image is not correct format), then 
		# add that image to the imagesNeedingCompression array. Otherwise, nothing
		# happens at all and the image is OK to continue
		if [ "$compressionPresent" != "0" ]; then
		
			imagesNeedingCompression+=( "${imageFilePaths[$imageCheckCounter]}" )
		
		fi
	
	done
	
	# If the size of the imagesNeedingCompression array is not zero, run through
	# the array and compress all DMGs in need of compression
	if [ "${#imagesNeedingCompression[@]}" != "0" ]; then
		
		for (( imageCompressCounter = 0 ; imageCompressCounter < ${#imagesNeedingCompression[@]} ; imageCompressCounter++ )); do

			dmgtool_compress_dmg "${imagesNeedingCompression[$imageCompressCounter]}" \
				"$(( imageCompressCounter + 1 ))" "${#imagesNeedingCompression[@]}"
			compressResult=$?

			# If dmgtool_compress_dmg returns not 0 (non-success, cannot scan
			# for restore), then add that image to the imagesThatFailedCompression
			# array. Otherwise, no action.

			if [ "$compressResult" != "0" ]; then

				imagesThatFailedCompression+=( "${imagesNeedingCompression[$imageCompressCounter]}" )

			fi
		
		done
		
	fi
	
	# Now that everything has been compressed, check all DMGs for ASR scan info
	# and add any images lacking scan data to the imagesNeedingScan array
	for (( imageCheckCounter = 0 ; imageCheckCounter < ${#imageFilePaths[@]} ; imageCheckCounter++ )); do

		disp_print_header

		echo "Checking images for scan information now..."
		echo ""

		[ -e "${imageFilePaths[$imageCheckCounter]}" ] || continue
		hdiutil imageinfo "${imageFilePaths[$imageCheckCounter]}" | grep -q --text 'CRC32'
		scanInfoPresent=$?
	
		# If 2nd grep returns not 0 (non-success, no checksum is found), then 
		# add that image to the imagesNeedingScan array. Otherwise, nothing
		# happens at all.
		if [ "$scanInfoPresent" != "0" ]; then

			imagesNeedingScan+=( "${imageFilePaths[$imageCheckCounter]}" )
		
		fi
	
		echo ""
	
	done
	
	# If the size of the imagesNeedingScanArray is not zero, run through the
	# array and scan all DMGs in need of ASR scan data
	if [ "${#imagesNeedingScan[@]}" != "0" ]; then
		
		for (( imageScanCounter = 0 ; imageScanCounter < ${#imagesNeedingScan[@]} ; imageScanCounter++ )); do

			dmgtool_scan_dmg "${imagesNeedingScan[$imageScanCounter]}" \
				"$(( imageScanCounter + 1 ))" "${#imagesNeedingScan[@]}"
			scanResult=$?

			# If dmgtool_scan_dmg returns not 0 (non-success, cannot scan
			# for restore), then add that image to the imagesThatFailedScan
			# array. Otherwise, no action.
			if [ "$scanResult" != "0" ]; then
	
				imagesThatFailedScan+=( "${imagesNeedingScan[$imageScanCounter]}" )
				
			fi
			
		done

	fi
	
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

# If the script has to be killed, clean up the temp/lock files

trap postflight_cleanup SIGINT SIGTERM

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
	# shellcheck source=/dev/null
	. "$executionPath/makedrive.conf"
elif [ -f "$makedriveSupportConf" ]; then
	# shellcheck source=/dev/null
	. "$makedriveSupportConf"
elif [ -f "$_makedrive_legacy_conf" ]; then
	# shellcheck source=/dev/null
	. "$_makedrive_legacy_conf"
else
	echo "makedrive configuration file not found."
	echo "Place makedrive.conf alongside makedrive.command and re-run to install it."
	exit 1
fi

# Performing individual checks once at start of execution, rather than every run
# through the main application loop
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
unset _makedrive_legacy_conf

# Ensure the support directory and its contents are owned by the invoking user
# so makedrive.conf can be edited without elevated privileges. makedrive runs as
# root, so files it creates here are root-owned by default.
[ -n "$SUDO_USER" ] && chown -Rf "$SUDO_USER" "$makedriveSupportDir"

migrate_pushover_credentials

startup_sync_versions

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
