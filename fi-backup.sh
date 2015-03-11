#!/bin/bash
#
# This file is part of fi-backup.
#
# fi-backup is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# fi-backup is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with fi-backup.  If not, see <http://www.gnu.org/licenses/>.
#
# fi-backup v1.1 - Online Forward Incremental Libvirt/KVM backup
# Copyright (C) 2014 Davide Guerri - davide.guerri@gmail.com
#

# Executables
QEMU_IMG="/usr/bin/qemu-img"
VIRSH="/usr/bin/virsh"
KVM="/usr/bin/kvm"
if [ -x "/usr/bin/qemu-kvm" ]; then
   KVM="/usr/bin/qemu-kvm"
fi

# Defaults and constants
BACKUP_DIRECTORY=
CONSOLIDATION=0
DEBUG=0
SNAPSHOT=1
SNAPSHOT_PREFIX="bimg"
VERBOSE=0

function print_v() {
   local level=$1

   case $level in
      v) # Verbose
      [ $VERBOSE -eq 1 ] && echo -e "[VER] ${*:2}"
      ;;
      d) # Debug
      [ $DEBUG -eq 1 ] && echo -e "[DEB] ${*:2}"
      ;;
      e) # Verbose
      echo -e "[ERR] ${*:2}"
      ;;
      w) # Warning
      echo -e "[WAR] ${*:2}"
      ;;
      *) # Any other level
      echo -e "[INF] ${*:2}"
      ;;
   esac
}

function print_usage() {
   [ -n "$1" ] && print_v e $1

   cat <<EOU

   Usage:

   $0 [-c|-C] [-h] [-d] [-v] [-b <directory>] <domain name>|all

   Options
      -b <directory>    Copy previous snapshot/base image to the specified <directory>
      -c                Consolidation only
      -C                Snapshot and consolidation
      -d                Debug
      -h                Print usage and exit
      -v                Verbose

EOU
}

# Mutual exclusion management: only one instance of this script can be running at one time.
function try_lock() {
   local domain_name=$1

   exec 29>/var/lock/$domain_name.fi-backup.lock

   flock -n 29

   if [ $? -ne 0 ]; then
      return 1
   else
      return 0
   fi
}

function unlock() {
   local domain_name=$1

   rm /var/lock/$domain_name.fi-backup.lock
   exec 29>&-
}

# return 0 if program version is equal or greater than check version
function check_version()
{
    local version=$1 check=$2
    local winner=$(echo -e "$version\n$check" | sed '/^$/d' | sort -nr | head -1)
    [[ "$winner" = "$version" ]] && return 0
    return 1
}


# Function: snapshot_domain()
# Take a snapshot of all block devices of a domain
#
# Input:    Domain name
# Return:   0 on success, non 0 otherwise
function snapshot_domain() {
   local domain_name=$1

   local _ret=
   local backing_file=
   local block_device=
   local block_devices=
   local command_output=
   local new_backing_file=
   local new_parent_backing_file=
   local parent_backing_file=

   local timestamp=$(date "+%Y%m%d-%H%M%S")

   print_v d "Snapshot for domain '$domain_name' requested"
   print_v d "Using timestamp '$timestamp'"

   # Create an external snapshot for each block device
   print_v d "Snapshotting block devices for '$domain_name' using suffix '$SNAPSHOT_PREFIX-$timestamp'"

   command_output=$($VIRSH -q snapshot-create-as "$domain_name" "$SNAPSHOT_PREFIX-$timestamp" --no-metadata --disk-only --atomic 2>&1)
   _ret=$?

   if [ $_ret -eq 0 ]; then
      print_v v "Snapshot for block devices of '$domain_name' successful"

      if [ -n "$BACKUP_DIRECTORY" -a ! -d "$BACKUP_DIRECTORY" ]; then
         print_v e "Backup directory '$BACKUP_DIRECTORY' doesn't exists"
         return 1
      fi
      if [ -n "$BACKUP_DIRECTORY" -a -d "$BACKUP_DIRECTORY" ]; then
         block_devices=$($VIRSH -q -r domblklist "$domain_name" | awk '{print $2}')
         _ret=$?
         if [ $_ret -ne 0 ]; then
            print_v e "Error getting block device list for domain '$domain_name'"
            return $_ret
         fi

         for block_device in "$block_devices"; do
            backing_file=$($QEMU_IMG info "$block_device" | awk '/^backing file: / { print $3 }')

            if [ -f "$backing_file" ]; then
               new_backing_file="$BACKUP_DIRECTORY/$(basename $backing_file)"

               print_v v "Copy backing file '$backing_file' to '$new_backing_file'"
               cp "$backing_file" "$new_backing_file"

               parent_backing_file=$($QEMU_IMG info "$backing_file" | awk '/^backing file: / { print $3 }')
               _ret=$?
               if [ $_ret -ne 0 ]; then
                  print_v e "Problem getting backing file for '$backing_file'"
                  continue
               fi
               if [ -n "$parent_backing_file" ]; then
                  print_v d "Parent backing file: '$parent_backing_file'"
                  new_parent_backing_file=$BACKUP_DIRECTORY/$(basename $parent_backing_file)
                  if [ ! -f $new_parent_backing_file ]; then
                     print_v w "Backing file for current snapshot doesn't exists in '$BACKUP_DIRECTORY'!"
                  fi

                  print_v v "Changing original backing file reference for '$new_backing_file' from '$parent_backing_file' to '$new_parent_backing_file'"
                  command_output=$($QEMU_IMG rebase -u -b "$new_parent_backing_file" "$new_backing_file")
                  _ret=$?
                  if [ $_ret -ne 0 ]; then
                     print_v e "Problem rebasing '$new_backing_file' from '$parent_backing_file' to '$new_parent_backing_file'. Exit code: \n$command_output"
                     continue
                  fi
               else
                  print_v v "No parent backing file for '$backing_file'"
               fi
            else
               print_v e "Error getting backing file for '$block_device'."
               return $_ret
            fi
         done
      else
         print_v d "No backup directory specified"
      fi
   else
      print_v e "Snapshot for '$domain_name' failed! Exit code: $_ret\n'$command_output'"
   fi

   return $_ret
}

# Function: consolidate_domain()
# Consolidate block devices for a domain
# !!! This function will delete all previous file in the backingfiles chain !!!
#
# Input:    Domain name
# Return:   0 on success, non 0 otherwise
function consolidate_domain() {
   local domain_name=$1

   local _ret=
   local backing_file=
   local command_output=
   local parent_backing_file=

   local block_devices=$($VIRSH -q -r domblklist "$domain_name" | awk '/^vd[a-z][[:space:]]+/ {print $2}')
   _ret=$?
   if [ $_ret -ne 0 ]; then
      print_v e "Error getting block device list for domain '$domain_name'"
      return $_ret
   fi

   print_v d "Consolidation of block devices for '$domain_name' requested"
   print_v d "Block devices to be consolidated:\n $(echo $block_devices | sed 's/ /\\n/g')"

   for block_device in "$block_devices"; do
      print_v d "Consolidation of block device: '$block_device' for '$domain_name'"

      backing_file=$($QEMU_IMG info "$block_device" | awk '/^backing file: / { print $3 }')
      if [ -n "$backing_file" ]; then
         print_v d "Parent block device: '$backing_file'"

         # Consolidate the block device
         command_output=$($VIRSH -q blockpull "$domain_name" "$block_device" --wait --verbose 2>&1)
         _ret=$?
         if [ $_ret -eq 0 ]; then
            print_v v "Consolidation of block device '$block_device' for '$domain_name' successful"
         else
            print_v e "Error consolidating block device '$block_device' for '$domain_name':\n $command_output"
            return $_ret
         fi

         # Deletes all old block devices
         print_v v "Deleting old backup files for '$domain_name'"
         while [ -n "$backing_file" ]; do
            print_v d "Processing old backing file '$backing_file' for '$domain_name'"

            # Check if this is a backup backing file...
            echo $backing_file | grep -q "\.$SNAPSHOT_PREFIX-[0-9]\{8\}\-[0-9]\{6\}$"
            if [ $? -ne 0 ]; then
               print_v w "'$backing_file' doesn't seem to be a backup backing file image. Stopping backing file chain removal (manual intervetion requested)..."
               break
            fi
            parent_backing_file=$($QEMU_IMG info "$backing_file" | awk '/^backing file: / { print $3 }')
            _ret=$?
            if [ $_ret -eq 0 ]; then
               print_v v "Deleting backing file '$backing_file'"
               rm "$backing_file"
               if [ $? -ne 0 ]; then
                  print_v w "Cannot delete '$backing_file'! Stopping backing file chain removal (manual intervetion required)..."
                  break
               fi
            else
               print_v e "Problem getting backing file for '$backing_file'"
               break
            fi
            backing_file=$parent_backing_file
            print_v d "Next file in backing file chain: '$parent_backing_file'"
         done
      else
         print_v w "No backing file found for '$block_device'. Nothing to do."
      fi
   done

   return 0
}

# Dependencies check
function dependencies_check() {
   local _ret=0
   local version=

   if [ ! -x "$VIRSH" ]; then
      print_v e "'$VIRSH' cannot be found or executed"
      _ret=1
   fi

   if [ ! -x "$QEMU_IMG" ]; then
      print_v e "'$QEMU_IMG' cannot be found or executed"
      _ret=1
   fi

   if [ ! -x "$KVM" ]; then
      print_v e "'$KVM' cannot be found or executed"
      _ret=1
   fi

   version=$($VIRSH -v)
   if check_version $version '0.9.13'; then
      print_v d "libVirt version '$version' is supported"
   else
      print_v e "Unsupported libVirt version '$version'. Please use libVirt 0.9.13 or greather"
      _ret=2
   fi

   version=$($QEMU_IMG -h | awk '/qemu-img version / { print $3 }' | cut -d',' -f1)
   if check_version $version '1.2.0'; then
      print_v d "$QEMU_IMG version '$version' is supported"
   else
      print_v e "Unsupported $QEMU_IMG version '$version'. Please use 'qemu-img' 1.2.0 or greather"
      _ret=2
   fi

   version=$($KVM --version | awk '/^QEMU emulator version / { print $4 }')
   if check_version $version '1.2.0'; then
      print_v d "KVM version '$version' is supported"
   else
      print_v e "Unsupported KVM version '$version'. Please use KVM 1.2.0 or greather"
      _ret=2
   fi

   return $_ret
}

while getopts "b:cCdhv" opt; do
   case $opt in
      b)
         BACKUP_DIRECTORY=$OPTARG
         if [ ! -d "$BACKUP_DIRECTORY" ]; then
            print_v e "Backup directory '$BACKUP_DIRECTORY' doesn't exists!"
            exit 1
         fi
      ;;
      c)
         if [ $CONSOLIDATION -eq 1 ]; then
            print_usage "-c or -C already specified!"
            exit 1
         fi
         CONSOLIDATION=1
         SNAPSHOT=0
      ;;
      C)
         if [ $CONSOLIDATION -eq 1 ]; then
            print_usage "-c or -C already specified!"
            exit 1
         fi
         CONSOLIDATION=1
         SNAPSHOT=1
      ;;
      d)
         DEBUG=1
         VERBOSE=1
      ;;
      h)
         print_usage
         exit 1
      ;;
      v)
         VERBOSE=1
      ;;
      \?)
         echo "Invalid option: -$OPTARG" >&2
         print_usage
         exit 2
      ;;
   esac
done

shift $(( OPTIND - 1 ));

dependencies_check
[ $? -ne 0 ] && exit 3

DOMAIN_NAME="$1"
if [ -z "$DOMAIN_NAME" ]; then
   print_usage "<domain name> is missing!"
   exit 2
fi

DOMAINS=
if [ $DOMAIN_NAME == "all" ]; then
   DOMAINS=$($VIRSH -q -r list | awk '{print $2;}')
else
   DOMAINS=$DOMAIN_NAME
fi

for DOMAIN in $DOMAINS; do
   _ret=0
   if [ $SNAPSHOT -eq 1 ]; then
      try_lock $DOMAIN
      if [ $? -eq 0 ]; then
         snapshot_domain $DOMAIN
         _ret=$?
         unlock $DOMAIN
      else
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping backup of '$DOMAIN'"
      fi
   fi

   if [ $_ret -eq 0 -a $CONSOLIDATION -eq 1 ]; then
      try_lock $DOMAIN
      if [ $? -eq 0 ]; then
         consolidate_domain $DOMAIN
         _ret=$?
         unlock $DOMAIN
      else
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping consolidation of '$DOMAIN'"
      fi
   fi
done

exit 0
