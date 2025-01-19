#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2022, 2025 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

DEBUG="${DEBUG:-0}"
if [[ "$DEBUG" != 0 ]]; then
    log="/dev/tty"
else
    log="/dev/null"
fi

if [[ -z "$1" ]]; then
    echo "usage: beautify_rro.sh /path/to/rro_source [/path/to/original_source]"
    exit
fi

ANDROID_ROOT="../../.."

RRO_DIR="$1"
SRC_DIR=""
targetPackage=$(sed -n "s/.*targetPackage=\"\([a-z.]\+\)\".*/\1/gp" "${RRO_DIR}"/AndroidManifest.xml)
if [[ -n "$2" ]]; then
    SRC_DIR="$2"
else
    case "$targetPackage" in
    "android")
        SRC_DIR="${ANDROID_ROOT}/frameworks/base/core/res"
        ;;
    "com.android.systemui")
        SRC_DIR="${ANDROID_ROOT}/frameworks/base/packages/SystemUI"
        ;;
    "com.android.providers.settings")
        SRC_DIR="${ANDROID_ROOT}/frameworks/base/packages/SettingsProvider"
        ;;
    "lineageos.platform")
        SRC_DIR="${ANDROID_ROOT}/lineage-sdk/lineage/res"
        ;;
    *)
        SRC_DIR="$(rg "package=\"${targetPackage}\"" ${ANDROID_ROOT}/packages/ | grep -v install-in-user-type | sed "s/://g" | awk '{print $1}' | sed "s/\(..\/..\/..\/[a-zA-Z0-9]\+\/[a-zA-Z0-9]\+\/[a-zA-Z0-9]\+\).*/\1/g" | head -1)"
        ;;
    esac

    echo "Guessed source: $SRC_DIR" > "$log"
fi

if [[ -z "$SRC_DIR" ]] || [[ ! -d "$SRC_DIR" ]]; then
    echo "Could not find source for $targetPackage, last guess: $SRC_DIR"
    exit
else
    echo "Using source: $SRC_DIR" > "$log"
fi

# Create a temporary working directory
TMPDIR=$(mktemp -d)

function get_src_path () {
    local name="$1"

    # Allow space between "name" and "="
    # Ignore symbols.xml and overlayable.xml files since these don't contain the actual values
    # Also ignore values-mcc as these folders include carrier specific things
    src_path=$(rg -e "${name//name=/name[ ]*=}" "$SRC_DIR" | grep -v symbols.xml | grep -v overlayable.xml | sed "s/://g" | awk '{print $1}' | grep -v "\-mcc" | grep -v "values-" | LC_ALL=c sort | head -1)
}

function add_aosp_comments () {
    local file="$1"

    # Create a backup
    cp "$file" "${TMPDIR}/$(basename "$file").bak"

    rg "name=" "$file" | sed -e 's/translatable="false"/ /g' \
                                -e 's/[<>]/ /g' \
                                -e 's/.*\(name="[-._a-zA-Z0-9]\+"\).*/\1/' | while read -r name; do
        get_src_path "$name"
        if [[ ! -f ${src_path} ]]; then
            echo "[$(basename "$RRO_DIR")] Resource ${name#*=} not found in ${SRC_DIR//${ANDROID_ROOT//\//\\\/}\//}"
            continue
        fi

        # Is the string translatable?
        if [[ -n $(sed -n "/${name//name=/name[ ]*=}/p" "$src_path" | sed -n "/translatable=\"false\"/p") ]] && [[ -z $(sed -n "/${name}/p" "$file" | sed -n "/translatable=\"false\"/p") ]]; then
            sed -i "s/${name}/${name} translatable=\"false\"/g" "$file"
        fi

        line=$(sed -n "/.*${name//name=/name[ ]*=}.*/=" "$src_path" | head -1)
        if [[ -z $(sed -n "$((line - 1))p" "$src_path" | sed -n "/.*-->.*/p") ]]; then
            echo "Did not find ending string before $name in $src_path" > "$log"
            continue
        fi

        line=$(sed -n "/.*${name}.*/=" "$file" | head -1)
        if [[ -n $(sed -n "$((line - 1))p" "$file" | sed -n "/.*-->.*/p") ]]; then
            echo "There is already a comment for $name in $file, skipping" > "$log"
            continue
        fi

        # Drop everything after our item
        sed "/${name//name=/name[ ]*=}/q" "$src_path" > "${TMPDIR}/before.txt"

        # Search for the last "<!--" before the item and write from there up to the item
        sed -n "$(sed -n /\<\!--/= "${TMPDIR}"/before.txt | tail -1),\$p" "${TMPDIR}"/before.txt | head -n -1  > "${TMPDIR}/comment.txt"

        # Add empty line above comment, skip if this is the first value in this file
        line=$(sed -n "/.*${name}.*/=" "$file" | head -1)
        if [[ ! ${line} -eq $(grep -Pn -m 1 "<.* name=" "$file" | grep -Po "^[0-9]+") ]]; then
            sed -i '1s/^/\n/' "${TMPDIR}"/comment.txt
        fi

        # Insert the comment above the item
        sed -i "$((line - 1)) r ${TMPDIR}/comment.txt" "$file"
    done

    if ! xmllint --format "$file" &> /dev/null; then
        echo "We broke ${file}. Restoring backup"
        cp "${TMPDIR}/$(basename "$file").bak" "$file"
    fi
    rm "${TMPDIR}/$(basename "$file").bak"
}

function init_file () {
    local name=${1}
    if [[ -f ${folder}/${name} ]]; then
        return
    fi

    {
        printf -- "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        printf -- "<!--\n"
        printf -- "     SPDX-FileCopyrightText: %s The LineageOS Project\n" "$(date +%Y)"
        printf -- "     SPDX-License-Identifier: Apache-2.0\n"
        printf -- "-->\n"
        printf -- "<resources xmlns:xliff=\"urn:oasis:names:tc:xliff:document:1.2\">\n"
     } >> "${folder}/${name}"
}

function update_header () {
    local name=${1}

    # Use xliff document 1.2 namespace
    sed -i "s/.*<resources.*/<resources xmlns:xliff=\"urn:oasis:names:tc:xliff:document:1.2\">/g" "${folder}/${name}"
    if [[ -z $(sed -n "/?xml/p" "${folder}/${name}") ]]; then
        sed -i "1 i\<?xml version=\"1.0\" encoding=\"utf-8\"?>" "${folder}/${name}"
    fi
    if [[ -z $(sed -n "/SPDX-FileCopyrightText:/p" "${folder}/${name}") ]]; then
        sed -i "2 i\-->" "${folder}/${name}"
        sed -i "2 i\     SPDX-License-Identifier: Apache-2.0" "${folder}/${name}"
        sed -i "2 i\     SPDX-FileCopyrightText: $(date +%Y) The LineageOS Project" "${folder}/${name}"
        sed -i "2 i\<!--" "${folder}/${name}"
    fi
}

function open_resource_file () {
    local name=${1}
    sed -i "/<\/resources>/d" "${folder}/${name}"
}

function close_resource_file () {
    local name=${1}
    if xmllint --format "$file" &> /dev/null || [[ -n $(tail -n 1 "${folder}/${name}" | sed -n "/<\/resources>/p") ]]; then
        return
    fi
    printf "</resources>\n" >> "${folder}/${name}"
}


find "${RRO_DIR}/res" -maxdepth 1 -mindepth 1 -type d | while read -r folder; do
    # Prepare files
    find "$folder" -maxdepth 1 -mindepth 1 -type f -name "*.xml" | while read -r file; do
        # Merge arrays into one line
        xml_pp -s record_c "$file" | sponge "$file"

        # Remove comments
        xmlstarlet c14n --without-comments "$file" | sponge "$file"

        # Merge strings into one line
        sed -i "/^[[:space:]]*$/d" "$file"
        sed -z "s/\\n/\\\n/g" "$file" | sed -z "s/>\\\n/>\n/g" | sponge "$file"
        open_resource_file "$(basename "$file")"
    done

    # Move the resources into files matching the aosp location
    find "$folder" -maxdepth 1 -mindepth 1 -type f -name "*.xml" | while read -r file; do
        # Don't move elements in files that don't contain resources
        if [[ -z $(sed -n "/^<resources/p" "$file") ]]; then
            continue
        fi

        rg "name=" "$file" | sed -e 's/translatable="false"/ /g' \
                                -e 's/[<>]/ /g' \
                                -e 's/.*\(name="[-._a-zA-Z0-9]\+"\).*/\1/' | while read -r name; do
            get_src_path "$name"
            if [[ ! -f ${src_path} ]]; then
                echo "[$(basename "$RRO_DIR")] Resource ${name#*=} not found in ${SRC_DIR//${ANDROID_ROOT//\//\\\/}\//}"
                continue
            fi

            destination_filename=$(basename "$src_path")
            if [[ "$(basename "$file")" == "$destination_filename" ]]; then
                continue
            fi

            # Create file if necessary
            init_file "$destination_filename"

            # Move the string into the file
            sed -n "/${name}/p" "$file" >> "${folder}/${destination_filename}"
            sed -i "/${name}/d" "$file"
        done
    done

    # Sort the files
    find "$folder" -maxdepth 1 -mindepth 1 -type f -name "*.xml" | while read -r file; do
        close_resource_file "$(basename "$file")"

        update_header "$(basename "$file")"

        if ! xmllint --format "$file" &> /dev/null; then
            echo "$file is not a valid XML, broke the rro"
            continue
        fi

        # Don't sort files that don't contain resources
        if [[ -n $(sed -n "/^<resources/p" "$file") ]]; then
            if [[ -z $(sed -n "/name=\"/p" "$file") ]]; then
                echo "$file is empty after moving resources, remove it" > "$log"
                rm "$file"
                continue
            fi

            rg "name=" "$file" | sed -e "s/[<>]/ /g" \
                                    -e "s/\///g" \
                                    -e "s/.*\(name=\"[-._a-Z0-9]\+\"\).*/\1/g" | while read -r name; do
                get_src_path "$name"
                if [[ ! -f "$src_path" ]]; then
                    line=0
                else
                    line=$(grep -Pn -m 1 "${name}" "$src_path" | grep -Po "^[0-9]+")
                fi

                # Temporary add line number as prefix to the line to sort it
                sed -i "s/\(.*${name}.*\)/${line}\1/g" "$file"
            done

            # Sort the resources according to their line numbers in aosp
            first_real_line=$(grep -Pn -m 1 "<.*name=" "$file" | grep -Po "^[0-9]+")
            (head -n $((first_real_line - 1)) "$file" && (tail -n+"$first_real_line" "$file" | head -n -1) | LC_ALL=c sort -n && tail -n 1 "$file") | sponge "$file"

            # Drop the line number prefix again
            sed -i "s/[0-9]\+\(  .*\)/\1/g" "$file"
        fi

        # Expand arrays again
        XMLLINT_INDENT="    " xmllint --format "$file" | sponge "$file"

        add_aosp_comments "$file"

        # Replace "\> with " \> to follow the recommended style
        sed -i "s/\"\/>/\" \/>/g" "$file"
    done
done

# Add copyright to AndroidManifest.xml and Android.bp
if [[ -n $(head -n 1 "${RRO_DIR}/AndroidManifest.xml" | sed -n "/<manifest/p") ]]; then
    sed -i "1 i\-->" "${RRO_DIR}/AndroidManifest.xml"
    sed -i "1 i\     SPDX-License-Identifier: Apache-2.0" "${RRO_DIR}/AndroidManifest.xml"
    sed -i "1 i\     SPDX-FileCopyrightText: $(date +%Y) The LineageOS Project" "${RRO_DIR}/AndroidManifest.xml"
    sed -i "1 i\<!--" "${RRO_DIR}/AndroidManifest.xml"
fi
if [[ -n $(head -n 1 "${RRO_DIR}/Android.bp" | sed -n "/runtime_resource_overlay/p") ]]; then
    sed -i "1 i\\\\" "${RRO_DIR}/Android.bp"
    sed -i "1 i\\/\/" "${RRO_DIR}/Android.bp"
    sed -i "1 i\\/\/ SPDX-License-Identifier: Apache-2.0" "${RRO_DIR}/Android.bp"
    sed -i "1 i\\/\/ SPDX-FileCopyrightText: $(date +%Y) The LineageOS Project" "${RRO_DIR}/Android.bp"
    sed -i "1 i\\/\/" "${RRO_DIR}/Android.bp"
fi

# Clear the temporary working directory
rm -rf "$TMPDIR"
