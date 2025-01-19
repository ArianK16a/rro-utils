#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2022, 2025 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

DEBUG="${DEBUG:-0}"
if [[ ${DEBUG} != 0 ]]; then
    log="/dev/tty"
else
    log="/dev/null"
fi

if [[ -z ${1} ]]; then
    echo usage: generate_rro.sh /path/to/rro.apk
    exit
fi

SRC="${1}"

# Create a temporary working directory
TMPDIR=$(mktemp -d)

name=$(basename ${SRC} | sed "s/.apk//g")

if ! apktool d "${SRC}" -o "${TMPDIR}"/out &> "${log}"; then
    echo "Failed to dump ${name}"
    # Clear the temporary working directory
    rm -rf "${TMPDIR}"
    exit
fi

rm -rf ./overlay/${name}
mkdir -p ./overlay/${name}

# Copy resources from apktool dump
cp -r ${TMPDIR}/out/res ./overlay/${name}/
rm ./overlay/${name}/res/values/public.xml
# If public.xml was the only file in res/values remove it
if [[ -z "$(ls -A ./overlay/${name}/res/values)" ]]; then
    rm -rf ./overlay/${name}/res/values
fi

# Begin writing Android.bp
printf "runtime_resource_overlay {
    name: \"${name}\"," > ./overlay/${name}/Android.bp

# Set theme if necessary
theme=$(echo $SRC | sed -n "s/.*overlay\/\([a-zA-Z0-9_-]\+\)\/.*\.apk/\1/gp")
if [[ ! -z "${theme}" ]]; then
    printf "\n    theme: \"${theme}\"," >> ./overlay/${name}/Android.bp
fi

# Choose the partition
partition=$(echo $SRC | sed -n "s/.*\/\([a-z_]\+\)\/overlay.*/\1/gp")
if echo "product system_ext" | grep -w -q ${partition}; then
    printf "\n    ${partition}_specific: true," >> ./overlay/${name}/Android.bp
elif echo "odm" | grep -w -q ${partition}; then
    printf "\n    device_specific: true," >> ./overlay/${name}/Android.bp
elif echo "vendor" | grep -w -q ${partition}; then
    printf "\n    vendor: true," >> ./overlay/${name}/Android.bp
fi

# Keep raw values if necessary
# Experimental logic: Check if there are values starting with 0 and assume that the leading 0s
# are critical and should be kept
if [[ ! -z $(find ./overlay/${name}/res -type f | xargs -I 'file' sed -n "/\(=\"0[0-9]\+\)/p" file) ]]; then
    printf "\n    aaptflags: [\"--keep-raw-values\"]," >> ./overlay/${name}/Android.bp
fi

# Finish the Android.bp
printf "\n}\n" >> ./overlay/${name}/Android.bp

# Get attributes from AndroidManifest.xml
package=$(sed -n "s/.*package=\"\([a-z.]\+\)\".*/\1/gp" ${TMPDIR}/out/AndroidManifest.xml)
targetPackage=$(sed -n "s/.*targetPackage=\"\([a-z.]\+\)\".*/\1/gp" ${TMPDIR}/out/AndroidManifest.xml)
targetName=$(sed -n "s/.*targetName=\"\([a-Z.]\+\)\".*/\1/gp" ${TMPDIR}/out/AndroidManifest.xml)
isStatic=$(sed -n "s/.*isStatic=\"\([a-z]\+\)\".*/\1/gp" ${TMPDIR}/out/AndroidManifest.xml)
priority=$(sed -n "s/.*priority=\"\([0-9]\+\)\".*/\1/gp" ${TMPDIR}/out/AndroidManifest.xml)
requiredSystemPropertyName=$(sed -n "s/.*requiredSystemPropertyName=\"\([-a-Z0-9._]\+\)\".*/\1/gp" ${TMPDIR}/out/AndroidManifest.xml)
requiredSystemPropertyValue=$(sed -n "s/.*requiredSystemPropertyValue=\"\([-a-Z0-9._]\+\)\".*/\1/gp" ${TMPDIR}/out/AndroidManifest.xml)

# Begin writing AndroidManifest.xml
printf "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"
    package=\"${package}\">
    <overlay android:targetPackage=\"${targetPackage}\"" > ./overlay/${name}/AndroidManifest.xml

# Write optional properties and close the overlay block
optional_properties=""
if [[ ! -z "${targetName}" ]]; then
    optional_properties="${optional_properties}\n                   android:targetName=\"${targetName}\""
fi
if [[ ! -z "${isStatic}" ]]; then
    optional_properties="${optional_properties}\n                   android:isStatic=\"${isStatic}\""
fi
if [[ ! -z "${priority}" ]]; then
    optional_properties="${optional_properties}\n                   android:priority=\"${priority}\""
fi
if [[ ! -z "${requiredSystemPropertyName}" ]]; then
    optional_properties="${optional_properties}\n                   android:requiredSystemPropertyName=\"${requiredSystemPropertyName}\""
fi
if [[ ! -z "${requiredSystemPropertyValue}" ]]; then
    optional_properties="${optional_properties}\n                   android:requiredSystemPropertyValue=\"${requiredSystemPropertyValue}\""
fi
printf "${optional_properties}/>\n" >> ./overlay/${name}/AndroidManifest.xml

# Close the manifest
printf "</manifest>\n" >> ./overlay/${name}/AndroidManifest.xml

# Clear the temporary working directory
rm -rf "${TMPDIR}"
