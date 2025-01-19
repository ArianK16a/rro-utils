#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2022, 2025 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

DEBUG="${DEBUG:-0}"
if [[ $DEBUG != 0 ]]; then
    log="/dev/tty"
else
    log="/dev/null"
fi

if [[ -z $1 ]]; then
    echo usage: generate_rro.sh /path/to/rro.apk
    exit
fi

SRC="$1"

# Create a temporary working directory
TMPDIR=$(mktemp -d)

name=$(basename "$SRC" | sed "s/.apk//g")

if ! apktool d "$SRC" -o "$TMPDIR"/out &> "$log"; then
    echo "Failed to dump $name"
    # Clear the temporary working directory
    rm -rf "$TMPDIR"
    exit
fi

rm -rf ./overlay/"$name"
mkdir -p ./overlay/"$name"

# Copy resources from apktool dump
cp -r "${TMPDIR}"/out/res ./overlay/"${name}"/
rm ./overlay/"${name}"/res/values/public.xml
# If public.xml was the only file in res/values remove it
if [[ -z "$(ls -A ./overlay/"${name}"/res/values)" ]]; then
    rm -rf ./overlay/"${name}"/res/values
fi

# Begin writing Android.bp
printf "runtime_resource_overlay {
    name: \"%s\"," "$name" > ./overlay/"${name}"/Android.bp

# Set theme if necessary
theme=$(echo "$SRC" | sed -n "s/.*overlay\/\([a-zA-Z0-9_-]\+\)\/.*\.apk/\1/gp")
if [[ -n "${theme}" ]]; then
    printf "\n    theme: \"%s\"," "$theme" >> ./overlay/"${name}"/Android.bp
fi

# Choose the partition
partition=$(echo "$SRC" | sed -n "s/.*\/\([a-z_]\+\)\/overlay.*/\1/gp")
if echo "product system_ext" | grep -w -q "$partition"; then
    printf "\n    %s_specific: true," "$partition" >> ./overlay/"${name}"/Android.bp
elif echo "odm" | grep -w -q "$partition"; then
    printf "\n    device_specific: true," >> ./overlay/"${name}"/Android.bp
elif echo "vendor" | grep -w -q "$partition"; then
    printf "\n    vendor: true," >> ./overlay/"${name}"/Android.bp
fi

# Keep raw values if necessary
# Experimental logic: Check if there are values starting with 0 and assume that the leading 0s
# are critical and should be kept
if [[ -n $(find ./overlay/"${name}"/res -type f -print0 | xargs -I 'file' --null sed -n "/\(=\"0[0-9]\+\)/p" file) ]]; then
    printf "\n    aaptflags: [\"--keep-raw-values\"]," >> ./overlay/"${name}"/Android.bp
fi

# Finish the Android.bp
printf "\n}\n" >> ./overlay/"${name}"/Android.bp

# Extract attributes from AndroidManifest.xml
manifest="${TMPDIR}/out/AndroidManifest.xml"
output="./overlay/${name}/AndroidManifest.xml"

extract_attribute_value() {
    local attribute="$1"
    sed -n "s/.*${attribute}=\"\([a-zA-Z0-9._-]\+\)\".*/\1/p" "$manifest"
}

# Required attributes
package=$(extract_attribute_value "package")
targetPackage=$(extract_attribute_value "android:targetPackage")

optional_attributes=(
    "android:targetName"
    "android:isStatic"
    "android:priority"
    "android:requiredSystemPropertyName"
    "android:requiredSystemPropertyValue"
)
optional_properties=()
for attribute in "${optional_attributes[@]}"; do
    value=$(extract_attribute_value "$attribute")
    [[ -n "$value" ]] && optional_properties+=("$attribute=\"$value\"")
done

# Begin writing AndroidManifest.xml
cat <<EOF > "$output"
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="${package}">
    <overlay android:targetPackage="${targetPackage}"$(
for property in "${optional_properties[@]}"; do
    printf "\n                   %s" "$property"
done
)/>
</manifest>
EOF

# Clear the temporary working directory
rm -rf "${TMPDIR}"
