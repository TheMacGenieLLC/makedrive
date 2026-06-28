#!/bin/bash

# shellcheck disable=SC2154  # config vars (catalogURLs, imageFilePaths, etc.) are set in makedrive.conf, sourced at runtime

# makedrive.command
#
# Created by:
# Ian Williams, The Mac Genie LLC
# ian@themacgenie.com
#
# https://github.com/TheMacGenie/makedrive
#
# Current script version:
currentVersion="2026-06-27 - Build 201"

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

# Canonical location for makedrive configuration on the host Mac
makedriveSupportDir="/Library/Application Support/makedrive"
makedriveSupportConf="$makedriveSupportDir/makedrive.conf"

# Image definitions, imageFilePaths, and build type configurations are
# loaded from makedrive.conf at startup.

declare -a imagesNeedingCompression
declare -a imagesNeedingScan
declare -a imagesThatFailedCompression
declare -a imagesThatFailedScan

# Main Functions

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

	local testDevice grepReturn dmgBaseDir

	disp_print_header

	# If $5 is empty, we don't have a source DMG yet; prompt the user to find
	# one. If $5 has contents, use that path directly as the source DMG.
	if [ "$5" = "" ]; then
		
		echo "Drag the DMG for $1 into "
		echo "the terminal window and hit return to add the image into restorekit."
		echo ""
		read -r imagePathToAdd
	
	else
		
		imagePathToAdd="$5"
	
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
		echo "Hit enter to continue."
		read -r _
		imagePathToAdd=""
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
			# Otherwise probe the DMG read-only for an embedded Install*.app
			# (e.g. a pre-built installer volume like Mavericks). Retail DVD
			# images that contain no installer app fall through with no source
			# and skip the icon step entirely.
			local iconSource="$6"
			local hasEmbeddedApp="N"
			if [ -z "$iconSource" ]; then
				local probeMount=""
				probeMount=$(hdiutil attach "$2" -nobrowse -readonly -noverify 2>/dev/null \
				    | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
				if [ -n "$probeMount" ]; then
					find "$probeMount" -name "Install*.app" -type d -maxdepth 2 \
					    -print -quit 2>/dev/null | grep -q . && hasEmbeddedApp="Y"
					hdiutil detach -quiet "$probeMount" 2>/dev/null
				fi
			fi

			# Apply icon if a source was found, converting to R/W first.
			# Compress and scan run exactly once, after any icon work is done.
			if [ -n "$iconSource" ] || [ "$hasEmbeddedApp" = "Y" ]; then
				local iconRwDmg="/var/tmp/makedrive-icon-rw.dmg"
				local iconMount=""
				echo "Converting image for icon application..."
				if hdiutil convert "$2" -format UDRW -o "$iconRwDmg"; then
					iconMount=$(hdiutil attach "$iconRwDmg" -nobrowse -noverify 2>/dev/null \
					    | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
					if [ -n "$iconMount" ]; then
						local applySrc="$iconSource"
						[ -z "$applySrc" ] && applySrc=$(find "$iconMount" -name "Install*.app" \
						    -type d -maxdepth 2 -print -quit 2>/dev/null)
						[ -n "$applySrc" ] && dmg_apply_volume_icon "$applySrc" "$iconMount"
						hdiutil detach -quiet "$iconMount" 2>/dev/null
					fi
					rm -f "$2"
					mv "$iconRwDmg" "$2"
				fi
				rm -f "$iconRwDmg"
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
	echo "Hit enter to continue... "
	read -r _
	
	imagePathToAdd=""

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
# verify_installer_build
# Confirms that the installer application at $1 contains the expected macOS
# build string $2. An empty build string always returns success (permissive).
#
# Old-format installers (10.11 El Capitan through 10.15 Catalina) store the
# build version in Contents/SharedSupport/InstallInfo.plist, which is directly
# readable without mounting anything.
#
# New-format installers (Big Sur 11 and later) embed the build metadata inside
# Contents/SharedSupport/SharedSupport.dmg. This function mounts that image
# read-only with -nobrowse, searches plist files for the build string, then
# detaches before returning.
#
# Returns 0 if the build string is found (or is empty), non-zero otherwise.
#
# $1 - Path to the installer application bundle
# $2 - macOS build string to verify (e.g. "19H2"); empty string skips check
# ------------------------------------------------------------------------------
verify_installer_build () {

	# Empty build string: no build configured, skip verification.
	[ -z "$2" ] && return 0

	local installInfo="${1}/Contents/SharedSupport/InstallInfo.plist"
	local ssDmg="${1}/Contents/SharedSupport/SharedSupport.dmg"
	local ssDevice ssResult actualBuild

	# Old-format (10.11–10.15): build string is in InstallInfo.plist directly.
	if [ -f "$installInfo" ]; then
		grep -qF "$2" "$installInfo"
		return $?
	fi

	# New-format (11+): build string is inside SharedSupport.dmg at a known path.
	[ -f "$ssDmg" ] || return 1

	local ssAttach ssDevice ssMountPoint
	ssAttach=$(hdiutil attach -noverify -nobrowse -readonly "$ssDmg" 2>/dev/null)
	ssDevice=$(echo "$ssAttach"    | awk 'NR==1{print $1}')
	ssMountPoint=$(echo "$ssAttach" | awk -F'\t' 'NF>=3{mp=$NF} END{print mp}')
	[ -n "$ssDevice" ] || return 1

	ssResult=1
	actualBuild=$(plutil -extract "Assets.0.Build" raw -o - \
	    "${ssMountPoint}/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml" \
	    2>/dev/null)
	[ "$actualBuild" = "$2" ] && ssResult=0

	hdiutil detach -quiet "$ssDevice" 2>/dev/null
	return "$ssResult"

}


# ------------------------------------------------------------------------------
# add_mas_build_mismatch
# Displays the standard build-mismatch error used by both createinstallmedia
# functions when verify_installer_build returns non-zero.
# ------------------------------------------------------------------------------
add_mas_build_mismatch () {

	disp_print_header

	echo "The installer in /Applications does not match the expected macOS build for"
	echo "the version chosen. Verify the installer and try again."
	echo ""
	echo "Hit enter to continue."
	echo ""

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

	disp_print_header

	# Verify the installer app contains the expected macOS build string.
	# verify_installer_build checks InstallInfo.plist for 10.11–10.15 and mounts
	# SharedSupport.dmg briefly for 11+. An empty build string always passes.
	if verify_installer_build "$1" "$2"; then

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
			echo "Hit enter to continue."
			read -r _
			return 1
		fi

		echo ""
		echo "Creating $6 bootable DMG..."
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
			echo "Hit enter to continue."
			read -r _
			return 1
		fi

		dmg_apply_volume_icon "$1" "/Volumes/$endName"

		diskutil rename "/Volumes/$endName" "$4"

		local appPathForReceiptWipe="${1#/Applications/}"

		rm -rf "/Volumes/$4/$appPathForReceiptWipe/Contents/_MASReceipt/"

		touch "/Volumes/$4/.metadata_never_index"

		sleep 3

		# checking workaround for new (2025 era) behavior for macOS Big Sur installer
		# not properly unmounting causing creation process to fail compress and scan
		# and using force after waiting for disk activity to wind down

		hdiutil detach -force "/Volumes/$4"

		sleep 1

		if ! mv "$makedriveInstTmpImageFile" "$5"; then
			echo ""
			echo "Could not move the completed DMG to restorekit. Check permissions and disk space."
			hdiutil detach -force "/Volumes/Shared Support" 2>/dev/null
			echo ""
			echo "Hit enter to continue."
			read -r _
			return 1
		fi

		# Detach the Shared Support volume left mounted by createinstallmedia.
		hdiutil detach -force "/Volumes/Shared Support"

		dmgtool_compress_dmg "$5"
		dmgtool_scan_dmg "$5"

		echo ""
		echo "$6 is ready for use. Hit enter to continue."
		echo ""

	else

		add_mas_build_mismatch

	fi

	read -r _

}


# ------------------------------------------------------------------------------
# add_mas_createinstallmedia_yos
# Processes a Mac App Store system installer into an install DMG that can be
# restored to disk. Required from 10.11 El Capitan through 10.13 High Sierra,
# which use the --applicationpath flag for createinstallmedia.
#
# $1 - Path to MAS install application given by user
# $2 - macOS build string to verify (e.g. "15G31"); empty string skips check
# $3 - Size of created DMG volume
# $4 - Final name of installation DMG volume
# $5 - Path to final destination of install DMG within restorekit
# $6 - Display name of MAS install application
# ------------------------------------------------------------------------------
add_mas_createinstallmedia_yos () {

	disp_print_header

	# Verify the installer app contains the expected macOS build string.
	# verify_installer_build checks InstallInfo.plist for 10.11–10.15 and mounts
	# SharedSupport.dmg briefly for 11+. An empty build string always passes.
	if verify_installer_build "$1" "$2"; then

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
			echo "Hit enter to continue."
			read -r _
			return 1
		fi

		echo ""
		echo "Creating $6 bootable DMG..."
		echo ""

		local cimOrig="$1/Contents/Resources/createinstallmedia"
		local cimBak="/var/tmp/makedrive-createinstallmedia-orig"
		local cimTemp="/var/tmp/makedrive-createinstallmedia"
		# Remove the bundle-level Apple signature first so macOS has nothing
		# to fail against when the binary is swapped — a missing signature
		# produces no verification loop, whereas a broken one does.
		codesign --remove-signature "$1" 2>/dev/null
		# Strip Apple signing on the binary, re-sign ad-hoc, swap in-place so
		# createinstallmedia's bundle-location check passes, then restore.
		cp -p "$cimOrig" "$cimBak"
		cp "$cimBak" "$cimTemp"
		codesign --remove-signature "$cimTemp" 2>/dev/null
		codesign -f -s - "$cimTemp" 2>/dev/null
		cp "$cimTemp" "$cimOrig"
		rm -f "$cimTemp"
		"$cimOrig" --volume "/Volumes/$newImageVolName" --applicationpath "$1" --nointeraction
		local cimResult=$?
		mv "$cimBak" "$cimOrig"

		if [ "$cimResult" != "0" ]; then
			echo ""
			echo "createinstallmedia failed. Check the installer and available disk space,"
			echo "then try again."
			hdiutil detach -force "/Volumes/$newImageVolName" 2>/dev/null
			hdiutil detach -force "/Volumes/$endName" 2>/dev/null
			rm -f "$makedriveInstTmpImageFile"
			echo ""
			echo "Hit enter to continue."
			read -r _
			return 1
		fi

		dmg_apply_volume_icon "$1" "/Volumes/$endName"

		diskutil rename "/Volumes/$endName" "$4"

		local appPathForReceiptWipe="${1#/Applications/}"

		rm -rf "/Volumes/$4/$appPathForReceiptWipe/Contents/_MASReceipt/"

		touch "/Volumes/$4/.metadata_never_index"

		hdiutil detach -force "/Volumes/$4"

		sleep 1

		if ! mv "$makedriveInstTmpImageFile" "$5"; then
			echo ""
			echo "Could not move the completed DMG to restorekit. Check permissions and disk space."
			echo ""
			echo "Hit enter to continue."
			read -r _
			return 1
		fi

		dmgtool_compress_dmg "$5"
		dmgtool_scan_dmg "$5"

		echo ""
		echo "$6 is ready for use. Hit enter to continue."
		echo ""

	else

		add_mas_build_mismatch

	fi

	read -r _

}


# ------------------------------------------------------------------------------
# add_menu_main
# ------------------------------------------------------------------------------
add_menu_main () {

	local leftCount leftColWidth addMenuIdx addMenuLabelVar addMenuLabel entryWidth
	local leftKey leftNum leftLabelVar leftEntry
	local rightIdx rightKey rightNum rightLabelVar rightEntry
	local addMenuKey addFuncVar instPath appPathVar newImageVolSizeVar finalNameVar
	local dispNameVar volNameVar buildNumVar sourcePathVar

	imageToAdd=""

	# Split list into two columns at the ceiling midpoint; computed once since
	# addMenuOrder is static after conf load.
	leftCount=$(( (${#addMenuOrder[@]} + 1) / 2 ))
	leftColWidth=0
	for (( addMenuIdx = 0 ; addMenuIdx < leftCount ; addMenuIdx++ )); do
		addMenuLabelVar="${addMenuOrder[$addMenuIdx]}MenuLabel"
		addMenuLabel="${!addMenuLabelVar}"
		entryWidth=$(( ${#addMenuLabel} + 4 ))
		if (( entryWidth > leftColWidth )); then leftColWidth=$entryWidth; fi
	done
	leftColWidth=$(( leftColWidth + 3 ))

	while [ "$imageToAdd" == "" ]; do

		disp_print_header

		echo "Choose the software you'd like to add to the restorekit folder:"
		echo ""

		for (( addMenuIdx = 0 ; addMenuIdx < leftCount ; addMenuIdx++ )); do
			leftKey="${addMenuOrder[$addMenuIdx]}"
			leftNum=$(( addMenuIdx + 1 ))
			leftLabelVar="${leftKey}MenuLabel"
			leftEntry=$(printf "%2d. %s" "$leftNum" "${!leftLabelVar}")

			rightIdx=$(( addMenuIdx + leftCount ))
			if (( rightIdx < ${#addMenuOrder[@]} )); then
				rightKey="${addMenuOrder[$rightIdx]}"
				rightNum=$(( rightIdx + 1 ))
				rightLabelVar="${rightKey}MenuLabel"
				rightEntry=$(printf "%2d. %s" "$rightNum" "${!rightLabelVar}")
				printf "%-${leftColWidth}s%s\n" "$leftEntry" "$rightEntry"
			else
				printf "%s\n" "$leftEntry"
			fi
		done
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

				"CREATE_INSTALL_MEDIA_YOS" )
					add_mas_createinstallmedia_yos \
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
		# lsub() does a plain index()-based replace — no regex metacharacter
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
		else
			rm -f "$tmpConf"
		fi
		if [ "${changed:-0}" -gt 0 ] 2>/dev/null; then
			makeDriveSyncNotice+="${makeDriveSyncNotice:+, }macOS ${dlVer} (${dlBuild})"
			[ "$quiet" != "1" ] && echo "  makedrive.conf: ${instKey} updated ${confVer} → ${dlVer} (${dlBuild})"
			anyUpdate=1
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
# Apple's servers (version and build only — no package URLs), compares each
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
# URL — that small XML file holds the human-readable version and build strings.
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

# Distribution files are fetched concurrently. Keep only the newest version and
# build for each macOS generation (keyed by major, or "10.x" for the 10 line).
# Versions before 10.13 and the nonexistent 16–25 range (Apple jumped 15 → 26)
# are dropped as catalog noise.
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
        if key not in newest or p > parse_ver(newest[key]["version"]):
            newest[key] = {"version": version, "build": build}

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

		# DataDrive Only (type 12) always copies the data partition — it's the
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
			echo "to restore onto. Press enter to continue."
			echo ""
			read -r _
			diskNum=""

		# If the disk to image is a boot disk (bootDiskID may list more than one
		# number on APFS), null the input to return you to the input prompt and
		# present a warning not to do it again.
		elif [[ " $bootDiskID " == *" $diskNum "* ]]; then
			disp_print_header
			
			echo "You are currently booted to a volume on disk$diskNum, and erasing disk$diskNum"
			echo "would be an extremely bad idea.  Choose another disk to erase."
			echo "Hit return to continue"
			echo ""
			read -r _
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
# build_deploy_volume
# Deploys the specified source to the specified volume using the arguments to
# perform type-specific operations for smooth deployment.
#
# The array indexes used in the construction of the strings is documented here:
# @1 - Type of disk image to be restored, as defined in makedrive.conf
# @2 - Display name of passed image
# @3 - Path to passed disk image
# @4 - Target volume starting name as formatted from diskutil
# @5 - Master disk image's mounted volume name
# @6 - Target volume final name to be seen by end user
# ------------------------------------------------------------------------------
build_deploy_volume () {

	# Copy the passed array by name into a local array for indexed access.
	local volumesToDeploy=("${!1}")
	local deployInfoArray=()
	local deployError=0
	local volumeDeployCounter
	local key varLookup

    for (( volumeDeployCounter = 0 ; volumeDeployCounter < ${#volumesToDeploy[@]} ; volumeDeployCounter++ )); do
		
		disp_print_header
		
		if [ "${volumesToDeploy[$volumeDeployCounter]}" = "dataDrive" ]; then
			
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
					echo "Hit enter to continue."
					read -r _
				fi

			else
				echo ""
			fi

			diskutil rename "/Volumes/$dataDriveStartName" "$dataDriveFinalName"
			renameResult=$?
			if [ "$renameResult" != "0" ] && [ "$deployError" = "0" ]; then
				lastBuildError="Could not rename the DataDrive partition."
				deployError=1
			fi

			# Bail out of the for loop and skip all of the unnecessary stuff
			break
		
		fi
		
		key="${volumesToDeploy[$volumeDeployCounter]}"

		varLookup="${key}DeployType";  deployInfoArray[1]="${!varLookup}"
		varLookup="${key}DispName";    deployInfoArray[2]="${!varLookup}"
		varLookup="${key}";            deployInfoArray[3]="${!varLookup}"
		varLookup="${key}StartName";   deployInfoArray[4]="${!varLookup}"
		varLookup="${key}FinalName";   deployInfoArray[6]="${!varLookup}"
		# INST-A DMGs restore with the source volume name (e.g. "Mac OS X Install ESD"),
		# which must be renamed to FinalName. GENERIC DMGs already have FinalName as
		# their volume name so VolName is not stored in conf for them.
		if [ "${deployInfoArray[1]}" = "INST-A" ]; then
			varLookup="${key}VolName"; deployInfoArray[5]="${!varLookup}"
		else
			deployInfoArray[5]="${deployInfoArray[6]}"
		fi
		
		# To fix Catalina's weird asr unmounting behavior, try to have it mount everything
		# on the target disk device every time. Hopefully it stops the deployment failures
		# until they fix it for APFS restores. Feedback report FB6952557
		diskutil mountDisk disk"$diskNum"
		sleep 2
		
		
		# This is where the magic happens.
		echo "Setting up ${deployInfoArray[2]}"
		echo ""
	
		# Get the desired data onto the target volume by restoring the source DMG.
		echo "Restoring disk image to target volume."
		echo ""
		if ! asr restore --source "${deployInfoArray[3]}" --target "/Volumes/${deployInfoArray[4]}/" --erase --noprompt --noverify; then
			lastBuildError="asr restore failed for ${deployInfoArray[2]}."
			deployError=1
			echo ""
			echo "asr restore failed for ${deployInfoArray[2]}. The drive may be incomplete."
			echo ""
			echo "Hit enter to continue."
			read -r _
			break
		fi
		echo ""

		# Close the Finder window opened by INST-A DMGs
		if [ "${deployInfoArray[1]}" == "INST-A" ]; then

			sleep "$windowCloseSleepInSeconds"
			osascript -e "tell application \"Finder\" to close Finder window \"${deployInfoArray[5]}\""

		fi

		# Rename each volume appropriately
		diskutil rename "/Volumes/${deployInfoArray[5]}" "${deployInfoArray[6]}"
		renameResult=$?
		if [ "$renameResult" != "0" ] && [ "$deployError" = "0" ]; then
			lastBuildError="Could not rename ${deployInfoArray[5]} to ${deployInfoArray[6]}."
			deployError=1
			echo "Warning: volume rename failed for ${deployInfoArray[5]}. Drive may not be fully set up."
		fi

		# Bless volume appropriately
		case "${deployInfoArray[1]}" in

			INST-A	)
				mkdir "/Volumes/${deployInfoArray[6]}/.dummy"
				if ! bless -folder "/Volumes/${deployInfoArray[6]}/System/Library/CoreServices" -openfolder "/Volumes/${deployInfoArray[6]}/.dummy" -label "${deployInfoArray[6]}"; then
					lastBuildError="${deployInfoArray[6]} could not be blessed and may not be bootable."
					deployError=1
					echo "Warning: bless failed for ${deployInfoArray[6]}. Volume may not be bootable."
				fi
				rm -d "/Volumes/${deployInfoArray[6]}/.dummy"
				;;

			*	)
				if ! bless -folder "/Volumes/${deployInfoArray[6]}/System/Library/CoreServices" -label "${deployInfoArray[6]}"; then
					lastBuildError="${deployInfoArray[6]} could not be blessed and may not be bootable."
					deployError=1
					echo "Warning: bless failed for ${deployInfoArray[6]}. Volume may not be bootable."
				fi
				;;

		esac
	
		# Disable Spotlight on target volume
		echo "Disabling Spotlight on target volume."
		touch "/Volumes/${deployInfoArray[6]}/.metadata_never_index"
		sleep "$spotlightSleepInSeconds"
		mdutil -i off "/Volumes/${deployInfoArray[6]}"
	
		# Unmount the target volume.
		echo "Unmounting volume now..."
		diskutil unmount "/Volumes/${deployInfoArray[6]}"
		
		unset deployInfoArray

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

		diskutil eject disk"$diskNum"

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
		echo "Hit enter to continue."
		read -r _
		return 1
	fi
	build_deploy_volume configVolumeList[@]

}


# ------------------------------------------------------------------------------
# check_file_presence
# Runs the track for checking to see if images are present in restorekit.
# ------------------------------------------------------------------------------
check_file_presence () {

	local missingDMGs=""
	local tempDMGholding=""
	local imagePresenceCounter

	# Run the loop through the imageFilePaths array until there are no more
	# images to scan in the list (array).
	for (( imagePresenceCounter = 0 ; imagePresenceCounter < ${#imageFilePaths[@]} ; imagePresenceCounter++ )); do

		if [ ! -e "${imageFilePaths[$imagePresenceCounter]}" ]; then
			
			tempDMGholding="${imageFilePaths[$imagePresenceCounter]##*/}"
			missingDMGs+="$tempDMGholding \n"
			tempDMGholding=""
			
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
	
	if ! hdiutil imageinfo "$1" | grep "$dmgCompressionString"; then
		
		compressingNow="${1##*/}"
		echo "Compressing $compressingNow"
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
			mv "$1" "$1.old.dmg"
			mv "$1.new.dmg" "$1"
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
	
	
	if ! hdiutil imageinfo "$1" | grep --text 'CRC32'; then
		
		scanningNow="${1##*/}"
		echo "Scanning $scanningNow for restore"
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
		echo -e "\033[1m1. Add installers to the restorekit folder\033[0m"
		echo ""
		echo -e "\033[1m2. Compress and scan DMGs for restore\033[0m"
		echo ""
		echo -e "\033[1m3. Build your install drive\033[0m"
		echo ""
		echo -e "\033[1m4. Configure Pushover notifications\033[0m"
		echo ""
		echo -e "\033[1m5. Uninstall makedrive from this Mac\033[0m"
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
			process_check_dmgs
			;;

		3 )
			doDrive=Y
			build_drives_start
			;;

		4 )
			notify_pushover_setup
			;;

		5 )
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
# notify_pushover_remove
# Confirms intent then permanently removes Pushover credentials from the
# System Keychain. makedrive will no longer send notifications after removal.
# ------------------------------------------------------------------------------
notify_pushover_remove () {

	disp_print_header

	echo "Remove Pushover Credentials"
	echo ""
	echo "This will permanently remove your Pushover credentials from the System"
	echo "Keychain. makedrive will no longer send Pushover notifications."
	echo ""
	printf "Are you sure you want to remove Pushover credentials? Y/N: "
	read -r confirmRemove
	echo ""

	if [ "$confirmRemove" = "Y" ] || [ "$confirmRemove" = "y" ]; then

		security delete-generic-password \
			-s "makedrive-pushover-userkey" \
			-a "makedrive" \
			/Library/Keychains/System.keychain 2>/dev/null

		security delete-generic-password \
			-s "makedrive-pushover-apptoken" \
			-a "makedrive" \
			/Library/Keychains/System.keychain 2>/dev/null

		echo "Pushover credentials removed from the System Keychain."
		echo "makedrive will no longer send Pushover notifications."

	else
		echo "Removal cancelled."
	fi

	echo ""
	echo "Hit enter to continue."
	read -r _

}


# ------------------------------------------------------------------------------
# makedrive_uninstall
# Permanently removes all makedrive components from this Mac: the Application
# Support folder (including makedrive.conf), Pushover credentials from the
# System Keychain, and the script file itself. Prompts the user to type
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
	echo "  * Pushover credentials from the System Keychain (if present)"
	echo "  * $scriptPath"
	echo ""
	echo "Type UNINSTALL and press return to confirm, or press return to cancel."
	echo ""
	read -r uninstallConfirm

	if [ "$uninstallConfirm" != "UNINSTALL" ]; then
		echo ""
		echo "Uninstall cancelled."
		echo ""
		echo "Hit enter to continue."
		read -r _
		return 0
	fi

	echo ""
	echo "Uninstalling makedrive..."

	if [ -d "$makedriveSupportDir" ]; then
		rm -rf "$makedriveSupportDir"
		echo "  Removed $makedriveSupportDir"
	fi

	if security find-generic-password -s "makedrive-pushover-userkey" -a "makedrive" \
			/Library/Keychains/System.keychain &>/dev/null; then
		security delete-generic-password \
			-s "makedrive-pushover-userkey" \
			-a "makedrive" \
			/Library/Keychains/System.keychain 2>/dev/null
		security delete-generic-password \
			-s "makedrive-pushover-apptoken" \
			-a "makedrive" \
			/Library/Keychains/System.keychain 2>/dev/null
		echo "  Pushover credentials removed from the System Keychain."
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
# Sends a Pushover notification using credentials stored in the System Keychain.
# Returns silently if credentials are not configured or the send fails.
#
# $1 - Message text to send
# ------------------------------------------------------------------------------
notify_pushover_send () {

	local userKey appToken

	userKey=$(security find-generic-password \
		-s "makedrive-pushover-userkey" \
		-a "makedrive" \
		-w \
		/Library/Keychains/System.keychain 2>/dev/null)

	appToken=$(security find-generic-password \
		-s "makedrive-pushover-apptoken" \
		-a "makedrive" \
		-w \
		/Library/Keychains/System.keychain 2>/dev/null)

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
			echo "Credentials will be stored in the System Keychain on this Mac."
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
				echo "Setup cancelled — both a User Key and App Token are required."
			else

				local saveUserKeyResult saveAppTokenResult

				security add-generic-password \
					-s "makedrive-pushover-userkey" \
					-a "makedrive" \
					-w "$userKey" \
					-U \
					/Library/Keychains/System.keychain
				saveUserKeyResult=$?

				security add-generic-password \
					-s "makedrive-pushover-apptoken" \
					-a "makedrive" \
					-w "$appToken" \
					-U \
					/Library/Keychains/System.keychain
				saveAppTokenResult=$?

				userKey=""; appToken=""

				if [ "$saveUserKeyResult" = "0" ] && [ "$saveAppTokenResult" = "0" ]; then
					echo "Pushover credentials saved to the System Keychain."
					echo ""
					echo "To verify or remove them, open Keychain Access, select the System"
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
			echo "Hit enter to continue."
			read -r _
			pushoverMenuChoice=""
			;;

		2 )
			disp_print_header
			notify_pushover_test
			echo ""
			echo "Hit enter to continue."
			read -r _
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
# Fetches credentials from the System Keychain and sends a visible test
# notification, reporting the HTTP result so the user can confirm correct setup.
# ------------------------------------------------------------------------------
notify_pushover_test () {

	local userKey appToken testStatus

	userKey=$(security find-generic-password \
		-s "makedrive-pushover-userkey" \
		-a "makedrive" \
		-w \
		/Library/Keychains/System.keychain 2>/dev/null)

	appToken=$(security find-generic-password \
		-s "makedrive-pushover-apptoken" \
		-a "makedrive" \
		-w \
		/Library/Keychains/System.keychain 2>/dev/null)

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
		--form-string "message=makedrive: Test notification — Pushover is configured correctly." \
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

	if [ -e "$makedriveLockFile" ]; then
		
		rm "$makedriveLockFile"
	
	fi

	if [ -e "$makedriveInstTmpImageFile" ]; then
		
		rm "$makedriveInstTmpImageFile"
	
	fi
	
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
				echo "Hit enter to exit makedrive."
				read -r _
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
		echo "diagnostic hard disks and flash drives. Though many precautions have"
		echo "been taken to prevent data loss, there is still the chance of a"
		echo "problem making your day a bit harder. Back up your important"
		echo "data before using this script on a mission-critical computer."
		echo ""
		echo "makedrive must be run as root for proper operation."
		echo ""
		sudo -p "Enter your admin password and hit return to continue: " "$executionPath/$(basename "$0")" && exit
	fi
		
}

# ------------------------------------------------------------------------------
# preflight_check_xcode_cli_tools
# makedrive depends on two tools from the Xcode Command Line Tools: setfile
# (assigns custom volume icons to DMGs) and python3 (fetches macOS version data
# in startup_sync_versions). This runs before the version sync so a missing
# toolchain is resolved up front rather than failing partway through. If the
# tools are absent the user is offered Apple's installer, then makedrive exits.
# ------------------------------------------------------------------------------
preflight_check_xcode_cli_tools () {

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
			echo "Hit enter to exit makedrive."
			read -r _
			exit 1
			;;

		* )

			exit
			;;

		esac

	else
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
        # itself backed by a physical store (APFS Physical Store) — erasing
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
        echo "Hit enter to exit makedrive."
        read -r _
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
	local compCount needComp scanCount needScan

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
		hdiutil imageinfo "${imageFilePaths[$imageCheckCounter]}" | grep "$dmgCompressionString"
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

			compCount=$(( imageCompressCounter + 1 ))
			needComp=${#imagesNeedingCompression[@]}
			
		
			dmgtool_compress_dmg "${imagesNeedingCompression[$imageCompressCounter]}" "$compCount" "$needComp"
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
		hdiutil imageinfo "${imageFilePaths[$imageCheckCounter]}" | grep --text 'CRC32'
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

			scanCount=$(( imageScanCounter + 1 ))
			needScan=${#imagesNeedingScan[@]}
		
			dmgtool_scan_dmg "${imagesNeedingScan[$imageScanCounter]}" "$scanCount" "$needScan"
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
	echo "Hit enter to continue... "
	echo ""
	read -r _
	
	return 0
}

# If the script has to be killed, clean up the temp/lock files

trap postflight_cleanup SIGINT SIGTERM

# Get execution path first — makedrive.conf uses $executionPath to resolve
# paths to restorekit image files.
preflight_get_execution_path

# Source makedrive.conf from whichever location is available. A conf alongside
# the script takes priority over Application Support so that distributed updates
# are picked up on the very first run even before root is obtained.
if [ -f "$executionPath/makedrive.conf" ]; then
	# shellcheck source=/dev/null
	. "$executionPath/makedrive.conf"
elif [ -f "$makedriveSupportConf" ]; then
	# shellcheck source=/dev/null
	. "$makedriveSupportConf"
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
preflight_check_xcode_cli_tools

# Migrate makedrive.conf to Application Support now that root is established.
# A conf alongside the script replaces the one in Application Support, making
# this the natural update path: ship a new conf with a new script release and
# the first root run installs it.
if [ -f "$executionPath/makedrive.conf" ]; then
	mkdir -p "$makedriveSupportDir"
	mv "$executionPath/makedrive.conf" "$makedriveSupportConf"
fi

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
