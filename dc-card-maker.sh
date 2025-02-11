#!/bin/bash

# Dreamcast GDMenu maker script for Linux.  Usage:
#
#   dc-card-maker.sh game_list.txt source_dir target_dir
#
# See README.md for detailed instructions
#
# Copyright (C) 2020 Jan Stolarek
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


# Error handling
#
# Handle errors automatically: trap the error signal of executed
# commands and print a useful debugging message when an error occurs,
# stopping execution.
set -o nounset           # Fail on use of unset variable
set -o errexit           # Exit on command failure
set -o pipefail          # Exit on failure of any command in a pipeline
set -o errtrace          # Trap errors in functions and subshells
shopt -s inherit_errexit # Subshells inherit the value of the errexit option
RED=$(if [[ -n ${TERM:+x} ]]; then if [[ "$TERM" != "dumb" ]]; then tput setaf 1; fi; fi)
BOLD=$(if [[ -n ${TERM:+x} ]]; then if [[ "$TERM" != "dumb" ]]; then tput bold; fi; fi)
NORMAL=$(if [[ -n ${TERM:+x} ]]; then if [[ "$TERM" != "dumb" ]]; then tput sgr0; fi; fi)
trap 'echo Error when executing ${BOLD}${BASH_COMMAND}${NORMAL} at line ${BOLD}${LINENO}${NORMAL}! 1>&2' ERR

SCRIPT_PATH=`cd "$(dirname "$0")"; pwd -P`
export PATH="$SCRIPT_PATH/tools:$PATH"

# Check for required commands
for c in genisoimage cdi4dc cdirip unzip; do
    command -v $c >/dev/null 2>&1 || {
        echo -e "$RED""This script requires $c.""$NORMAL" >&2
        echo -e "$RED""See README for details. Aborting script""$NORMAL" >&2
        exit 5
    }
done

# Process command line args
if [ "$#" != 3 ]; then
    echo "Dreamcast SD card maker script (version 1.2.1)"
    echo ""
    echo "Usage: dc-card-maker.sh game_list.txt source_dir target_dir"
    exit 1;
fi

INPUT_FILE=$1
SOURCE_DIR=$2
TARGET_DIR=$3
OUTPUT_FILE=$3/game_list.txt
GDMENU_INI=$(mktemp)
ARCHIVE_FILE=archive.txt
NAME_FILE=name.txt # collides (coincides?) with MadSheep's Windows SD card maker

# Basic sanity checks
if [[ ! -f $INPUT_FILE ]]; then
    echo "Input file does not exist : $1" >&2
    exit 2;
fi

if [[ ! -d $SOURCE_DIR ]]; then
    echo "Source directory does not exist : $2" >&2
    exit 3;
fi

if [[ ! -d $TARGET_DIR ]]; then
    echo "Target directory does not exist : $3" >&2
    exit 4;
fi

# If there are any directories with names consisting of digits only and ending
# with an underscore it means there are leftovers from previous script run.
# Abort the script to avoid problems and potential data loss.
LEFTOVER_DIRS=`find $TARGET_DIR -regextype sed -regex "$TARGET_DIR/*[0-9][0-9]*_"`
if [[ ! -z $LEFTOVER_DIRS ]]; then
    echo -e "$RED""Following directories from previous session found:""$NORMAL" >&2
    for DIR in $LEFTOVER_DIRS; do
        echo "$DIR" >&2
    done
    echo -e "$RED""Aborting script.  Remove these directories and run the script again""$NORMAL" >&2
    exit
fi

# If there are gdemu directories present in the destination derictory append
# underscore to their names.
TARGET_DIRS=`find $TARGET_DIR -regextype sed -regex "$TARGET_DIR/*[0-9][0-9]*"`
if [[ ! -z $TARGET_DIRS ]]; then
    echo "Renaming target directories to avoid name clashes"
    for EXISTING_TARGET_DIR in $TARGET_DIRS; do
        echo "Renaming $EXISTING_TARGET_DIR to $EXISTING_TARGET_DIR""_"
        mv "$EXISTING_TARGET_DIR" "$EXISTING_TARGET_DIR"_
    done
    # Treat gdmenu directory specialy
    if [[ -d "$TARGET_DIR/01_" ]]; then
        mv "$TARGET_DIR/01_" "$TARGET_DIR/gdmenu_old"
    fi
fi

# Values here are hardcoded since we know what the ip.bin contains.  If ip.bin
# ever gets updated these lines need to be updated accordingly
echo "[GDMENU]"          >> $GDMENU_INI
echo "01.name=GDMenu"    >> $GDMENU_INI
echo "01.disc=1/1"       >> $GDMENU_INI
echo "01.vga=1"          >> $GDMENU_INI
echo "01.region=JUE"     >> $GDMENU_INI
echo "01.version=V0.6.0" >> $GDMENU_INI
echo "01.date=20160812"  >> $GDMENU_INI
echo ""                  >> $GDMENU_INI

# Initialize output game list file.
if [[ -e $OUTPUT_FILE ]]; then
    echo "$OUTPUT_FILE exists, backing up as ${OUTPUT_FILE}.bak"
    mv "$OUTPUT_FILE" "$OUTPUT_FILE"".bak"
fi

# Temporary directory for extracting zip archives
TMP_UNZIP_DIR=`mktemp -d -t dc-card-maker-XXXXX`
echo "Created temporary directory for extracting archives: $TMP_UNZIP_DIR"

# Directory 01 reserved for GDMenu, start game directories with 02
INDEX=2


while read GAME; do
    echo "Processing game \"$GAME\""

    # Ensure that names of directories 1-9 start with a 0
    if [[ $INDEX -lt 10 ]]; then
        DIR_NAME=$(printf "%02d" $INDEX)
    else
        DIR_NAME="$INDEX"
    fi

    # Attempt to locate the game subdirectory in the target directory.  If it's
    # already there just restore the game by renaming the temporary directory,
    # don't attempt to extract the game from an archive
    GAME_FOUND=false
    for EXISTING_GAME_DIR in `find $TARGET_DIR -regextype sed -regex "$TARGET_DIR/*[0-9][0-9]*_"`; do
        if [[ "$GAME" == "`cat $EXISTING_GAME_DIR/$ARCHIVE_FILE`" ]]; then
            echo "Game \"$GAME\" located in target directory, placing it in directory \"$DIR_NAME\""
            mv "$EXISTING_GAME_DIR" "$TARGET_DIR/$DIR_NAME"
            (( INDEX++ ))
            echo "$GAME" >> "$OUTPUT_FILE"
            GAME_FOUND=true
            break # if game found don't iterate over remaining directories
        fi
    done

    # If game not found in target directory extract it from a zip archive
    if [[ $GAME_FOUND == false ]]; then
        GAME_ARCHIVE="$SOURCE_DIR/$GAME"
        GAME_TARGET_DIR="$TARGET_DIR/$DIR_NAME"
        GAME_TMP_DIR="$TMP_UNZIP_DIR/$DIR_NAME"

        # Missing archives are not considered fatal, just skip the game
        if [[ ! -f "$GAME_ARCHIVE" ]]; then
            echo -e "$RED""Game archive not found: \"$GAME_ARCHIVE\", skipping""$NORMAL"
            break
        fi

        echo "Extracting archive $GAME_ARCHIVE to temporary directory $GAME_TMP_DIR"
        unzip "$GAME_ARCHIVE" -d "$GAME_TMP_DIR"

        # Extracting errors are fatal - maybe we have no space left on the
        # device?  Abort the script instead of wreaking havoc
        if [[ $? -ne 0 ]]; then
            echo -e "$RED""Error extracting archive: $GAME_ARCHIVE""$NORMAL" >&2
            echo -e "$RED""Aborting script""$NORMAL" >&2
            exit;
        fi

        # Determine whether we are dealing with GDI or CDI image.
        DISC_FILE=`find "$GAME_TMP_DIR" -type f -name *.gdi | head -n 1`
        if [[ ! -z $DISC_FILE ]]; then
            TYPE="gdi"
        else
            DISC_FILE=`find "$GAME_TMP_DIR" -type f -name *.cdi | head -n 1`
            TYPE="cdi"
        fi

        # If we didn't find a GDI or CDI image inside the extracted archive we
        # skip it.  This isn't perfect since the error message might get lost in
        # the output noise, leading to perception that everything went fine when
        # it actually didn't.  But aborting the script in the middle of
        # execution can potentially cause mess so skipping seems like a better
        # solution.
        if [[ -z $DISC_FILE ]]; then
            echo -e "$RED""Couldn't find any GDI or CDI file in $GAME_ARCHIVE""$NORMAL" >&2
            echo -e "$RED""Skipping""$NORMAL" >&2
            break
        fi

        DISC_FILE=`basename "$DISC_FILE"`
        # Rename the gdi/cdi file to disc.gdi/disc.cdi, move the extracted game
        # to target directory, add the game to the game list
        echo "Writing $ARCHIVE_FILE"
        echo "$GAME" > "$GAME_TMP_DIR/$ARCHIVE_FILE"
        if [[ ! -e "$GAME_TMP_DIR/disc.$TYPE" ]]; then
            echo "Renaming disc file \"$DISC_FILE\" to \"disc.$TYPE\""
            mv "$GAME_TMP_DIR/$DISC_FILE" "$GAME_TMP_DIR/disc.$TYPE"
        fi
        # If moving files goes wrong abort immediately - we might be out of
        # space on the SD card
        echo "Moving game from temporary directory to target directory"
        mv "$GAME_TMP_DIR" "$TARGET_DIR" || exit
        (( INDEX++ ))
        echo "Adding \"$GAME\" to $OUTPUT_FILE"
        echo "Game \"$GAME\" has been placed in directory \"$DIR_NAME\""
        echo "$GAME" >> "$OUTPUT_FILE"
    else
        # If a game was already extracted just determine whether we are dealing
        # with GDI or CDI image.
        if [[ ! -z `find "$TARGET_DIR/$DIR_NAME" -type f -name *.gdi | head -n 1` ]]; then
            TYPE="gdi"
        else
            TYPE="cdi"
        fi
    fi

    # Now that the image files are in the target directory we need to extract
    # information required to create a GDMenu entry for the game.  For GDI files
    # this information is stored in an ip.bin file inside a GDI image.  See
    # https://mc.pp.se/dc/ip0000.bin.html for more information.  For CDI files
    # this information is stored in first 16 sectors of the last data track.  To
    # read this information we need to extract the CDI file to a /tmp directory
    # in order to get access to data tracks.
    if [[ $TYPE == "gdi" ]]; then
        gditools.py -i "$TARGET_DIR/$DIR_NAME/disc.gdi" -b ip.bin
        METADATA_FILE="$TARGET_DIR/$DIR_NAME/ip.bin"
    else
        TMP_DIR=`mktemp -d -t dc-card-maker-XXXXX`
        cdirip "$TARGET_DIR/$DIR_NAME/disc.cdi" $TMP_DIR
        # Note: this is potentially fragile, assumes data tracks have *.iso
        # extension
        METADATA_FILE=`find $TMP_DIR -type f -name *.iso | sort | tail -n 1`
    fi

    # Get the metadata
    if [[ -e "$TARGET_DIR/$DIR_NAME/$NAME_FILE" ]]; then
        NAME_INFO=`cat $TARGET_DIR/$DIR_NAME/$NAME_FILE | head -n 1`
    else
        NAME_INFO=`hexdump -v -e '"%c"' -s0x80 -n 128 $METADATA_FILE | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//'`
        echo "$NAME_INFO" > "$TARGET_DIR/$DIR_NAME/$NAME_FILE"
    fi
    DISC_INFO=`hexdump -v -e '"%c"' -s0x2B -n 3 $METADATA_FILE`
    VGA_INFO=`hexdump -v -e '"%c"' -s0x3D -n 1 $METADATA_FILE`
    REGION_INFO=`hexdump -v -e '"%c"' -s0x30 -n 8 $METADATA_FILE | sed 's/[[:blank:]]*//g'`
    VERSION_INFO=`hexdump -v -e '"%c"' -s0x4A -n 6 $METADATA_FILE`
    DATE_INFO=`hexdump -v -e '"%c"' -s0x50 -n 8 $METADATA_FILE`

    # Remove metadata files
    rm "$METADATA_FILE"
    if [[ $TYPE == "cdi" ]]; then
        rm -rf $TMP_DIR
    fi

    # Write menu entry data to INI file
    echo "$DIR_NAME.name=$NAME_INFO"       >> $GDMENU_INI
    echo "$DIR_NAME.disc=$DISC_INFO"       >> $GDMENU_INI
    echo "$DIR_NAME.vga=$VGA_INFO"         >> $GDMENU_INI
    echo "$DIR_NAME.region=$REGION_INFO"   >> $GDMENU_INI
    echo "$DIR_NAME.version=$VERSION_INFO" >> $GDMENU_INI
    echo "$DIR_NAME.date=$DATE_INFO"       >> $GDMENU_INI
    echo ""                                >> $GDMENU_INI

done < "$INPUT_FILE"

# Build GDMenu cdi image and put it in 01 directory
echo "Building GDMenu disc image"
GDMENU_CDI=$(mktemp)
GDMENU_ISO=$(mktemp)
genisoimage -C 0,11702 -V GDMENU -G "$SCRIPT_PATH/data/ip.bin" -r -J -l -input-charset iso8859-1 -o $GDMENU_ISO "$SCRIPT_PATH/data/1ST_READ.BIN" $GDMENU_INI
rm $GDMENU_INI
cdi4dc $GDMENU_ISO $GDMENU_CDI
rm $GDMENU_ISO
mkdir "$TARGET_DIR/01"
mv $GDMENU_CDI "$TARGET_DIR/01/gdmenu.cdi"

# Copy default GDMenu configuration
echo "Copying GDEMU configuration"
install -m 0644 "$SCRIPT_PATH/ini/GDEMU.ini" "$TARGET_DIR"

# Restore backup copy of GDMenu
if [[ -d "$TARGET_DIR/gdmenu_old" ]]; then
    mv "$TARGET_DIR/gdmenu_old" "$TARGET_DIR/01_"
fi

# Remove temporary direcotry
rmdir "$TMP_UNZIP_DIR"

# Report any leftover dirs to the user.  Re-running the script won't be possible
# if these exist.
LEFTOVER_DIRS=`find $TARGET_DIR -regextype sed -regex "$TARGET_DIR/*[0-9][0-9]*_"`
if [[ ! -z $LEFTOVER_DIRS ]]; then
    echo -e "$RED""Following directories at target directory contain old games""$NORMAL"
    for DIR in $LEFTOVER_DIRS; do
        echo -e "$RED"$DIR"$NORMAL"
    done
    echo -e "$RED""Delete or move them to a different location.""$NORMAL"
fi
