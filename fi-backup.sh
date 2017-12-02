#!/usr/bin/env bash
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
# fi-backup - Online Forward Incremental Libvirt/KVM backup
# Copyright (C) 2013 2014 2015 Davide Guerri - davide.guerri@gmail.com
#

VERSION="2.1.0"
APP_NAME="fi-backup"

# Fail if one process fails in a pipe
set -o pipefail

# Executables
QEMU_IMG="/usr/bin/qemu-img"
VIRSH="/usr/bin/virsh"
QEMU="/usr/bin/qemu-system-x86_64"

# Defaults and constants
BACKUP_DIRECTORY=
CONSOLIDATION=0
DEBUG=0
VERBOSE=0
QUIESCE=0
DUMP_STATE=0
SNAPSHOT=1
SNAPSHOT_PREFIX="bimg"
DUMP_STATE_TIMEOUT=60
DUMP_STATE_DIRECTORY=
CONSOLIDATION_SET=0
CONSOLIDATION_METHOD="blockpull"
CONSOLIDATION_FLAGS=(--wait)
ALL_RUNNING_DOMAINS=0


function print_v() {
   local level=$1

   case $level in
      v) # Verbose
      [ $VERBOSE -eq 1 ] && echo -e "[VER] ${*:2}"
      ;;
      d) # Debug
      [ $DEBUG -eq 1 ] && echo -e "[DEB] ${*:2}"
      ;;
      e) # Error
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
   [ -n "$1" ] && (echo "" ; print_v e "$1\n")

   cat <<EOU
   $APP_NAME version $VERSION - Davide Guerri <davide.guerri@gmail.com>

   Usage:

   $0 [-c|-C] [-q|-s <directory>] [-h] [-d] [-v] [-V] [-b <directory>] [-m <method>] <domain name>|all

   Options
      -b <directory>    Copy previous snapshot/base image to the specified <directory>
      -c                Consolidation only
      -C                Snapshot and consolidation
      -m <method>       Consolidation method: blockcommit or blockpull
      -q                Use quiescence (qemu agent must be installed in the domain)
      -s <directory>    Dump domain status in the specified directory
      -d                Debug
      -h                Print usage and exit
      -v                Verbose
      -V                Print version and exit

EOU
}

# Mutual exclusion management: only one instance of this script can be running
# at one time.
function try_lock() {
   local domain_name=$1

   exec 29>"/var/lock/$domain_name.fi-backup.lock"

   flock -n 29

   if [ $? -ne 0 ]; then
      return 1
   else
      return 0
   fi
}

function unlock() {
   local domain_name=$1

   rm "/var/lock/$domain_name.fi-backup.lock"
   exec 29>&-
}

# return 0 if program version is equal or greater than check version
function check_version()
{
    local version=$1 check=$2
    local winner=

    winner=$(echo -e "$version\n$check" | sed '/^$/d' | sort -Vr | head -1)
    [[ "$winner" = "$version" ]] && return 0
    return 1
}

# Function: get_block_devices()
# Return the list of block devices of a domain. This function correctly
# handles paths with spaces.
#
# Input:    Domain name
# Output:   An array containing a block device list
# Return:   0 on success, non 0 otherwise
function get_block_devices() {
   local domain_name=$1 return_var=$2
   local _ret=

   eval "$return_var=()"

   while IFS= read -r file; do
      eval "$return_var+=('$file')"
   done < <($VIRSH -q -r domblklist "$domain_name" --details|awk \
      '"disk"==$2 {$1=$2=$3=""; print $0}'|sed 's/^[ \t]*//')

   return 0
}

# Function: get_snapshot_chain()
# Return an array of all backing files
#
# Input:    Block Device
# Output:   An array containing a backing file list
# Return:   0 on success, non 0 otherwise
function get_snapshot_chain() {
   local endmost_child=$1 return_var=$2
   local _parent_backing_file=
   local _backing_file=
   local i=0
   local _ret=

   eval "$return_var[$i]=\"$endmost_child\""

   _ret=1

   get_backing_file "$endmost_child" _parent_backing_file
   while [ -n "$_parent_backing_file" ]; do
      ((i++))
      eval "$return_var[$i]=\"$_parent_backing_file\""
      #get next backing file if it exists
      _backing_file="$_parent_backing_file"
      get_backing_file "$_backing_file" _parent_backing_file
      #print_v d "Next file in backing file chain: '$_parent_backing_file'"
      _ret=0
   done 

   return $_ret
}
# Function: get_backing_file()
# Return the immediate parent of a qcow2 image file (i.e. the backing file)
#
# Input:    qcow2 image file name
# Output:   A backing file name
# Return:   0 on success, non 0 otherwise
function get_backing_file() {
   local file_name=$1 return_var=$2
   local _ret=
   local _backing_file=

   _backing_file=$($QEMU_IMG info "$file_name" | \
      awk '/^backing file: / {$1=$2=""; print $0}'|sed 's/^[ \t]*//')
   _ret=$?

   eval "$return_var=\"$_backing_file\""

   return $_ret
}

# Function: dump_state()
# Dump a domain state, pausing the domain right afterwards
#
# Input:    a domain name
# Input:    a timestamp (this will be added to the file name)
# Return:   0 on success, non 0 otherwise
function dump_state() {
   local domain_name=$1
   local timestamp=$2

   local _ret=
   local _timeout=

   local _dump_state_filename="$DUMP_STATE_DIRECTORY/$domain_name.statefile-$timestamp.gz"

   local output=

   output=$($VIRSH qemu-monitor-command "$domain_name" '{"execute": "migrate", "arguments": {"uri": "exec:gzip -c > ' "'$_dump_state_filename'" '"}}' 2>&1)
   if [ $? -ne 0 ]; then
      print_v e "Failed to dump domain state: '$output'"
      return 1
   fi

   _timeout=5
   print_v d "Waiting for dump file '$_dump_state_filename' to be created"
   while [ ! -f "$_dump_state_filename" ]; do
      _timeout=$((_timeout - 1))
      if [ "$_timeout" -eq 0 ]; then
         print_v e "Timeout while waiting for dump file to be created"
         return 4
      fi
      sleep 1
      print_v d "Still waiting for dump file '$_dump_state_filename' to be created ($_timeout)"
   done
   print_v d "Dump file '$_dump_state_filename' created"

   if [ ! -f "$_dump_state_filename" ]; then
      print_v e "Dump file not created ('$_dump_state_filename'), something went wrong! ('$output' ?)"
      return 1
   fi

   _timeout="$DUMP_STATE_TIMEOUT"
   print_v d "Waiting for '$domain_name' to be paused"
   while true; do
      output=$(virsh domstate "$domain_name")
      if [ $? -ne 0 ]; then
         print_v e "Failed to check domain state"
         return 2
      fi
      if [ "$output" == "paused" ]; then
         print_v d "Domain paused!"
         break
      fi
      if [ "$_timeout" -eq 0 ]; then
         print_v e "Timeout while waiting for VM to pause: '$output'"
         return 3
      fi
      print_v d "Still waiting for '$domain_name' to be paused ($_timeout)"
      sleep 1
      _timeout=$((_timeout - 1))
   done

   return 0
}

# Function: snapshot_domain()
# Take a snapshot of all block devices of a domain
#
# Input:    Domain name
# Return:   0 on success, non 0 otherwise
function snapshot_domain() {
   local domain_name=$1

   local _ret=0
   local backing_file=
   local block_device=
   local block_devices=
   local extra_args=
   local command_output=
   local new_backing_file=
   local parent_backing_file=

   local timestamp=
   local resume_vm=0

   timestamp=$(date "+%Y%m%d-%H%M%S")

   print_v d "Snapshot for domain '$domain_name' requested"
   print_v d "Using timestamp '$timestamp'"

   # Dump VM state
   if [ "$DUMP_STATE" -eq 1 ]; then
      print_v v "Dumping domain state"
      dump_state "$domain_name" "$timestamp"
      if [ $? -ne 0 ]; then
         print_v e \
         "Domain state dump failed!"
         return 1
      else
         resume_vm=1
         # Should something go wrong, resume the domain
         trap 'virsh resume "$domain_name" >/dev/null 2>&1' SIGINT SIGTERM
      fi
   fi

   # Create an external snapshot for each block device
   print_v d "Snapshotting block devices for '$domain_name' using suffix '$SNAPSHOT_PREFIX-$timestamp'"

   if [ $QUIESCE -eq 1 ]; then
      print_v d "Quiesce requested"
      extra_args="--quiesce"
   fi

   command_output=$($VIRSH -q snapshot-create-as "$domain_name" \
      "$SNAPSHOT_PREFIX-$timestamp" --no-metadata --disk-only --atomic \
      $extra_args 2>&1)
   if [ $? -eq 0 ]; then
      print_v v "Snapshot for block devices of '$domain_name' successful"

      if [ -n "$BACKUP_DIRECTORY" ] && [ ! -d "$BACKUP_DIRECTORY" ]; then
         print_v e "Backup directory '$BACKUP_DIRECTORY' doesn't exist"
         _ret=1
      elif [ -n "$BACKUP_DIRECTORY" ] && [ -d "$BACKUP_DIRECTORY" ]; then
         #make backup after snapshot
         get_block_devices "$domain_name" block_devices
         if [ $? -ne 0 ]; then
            print_v e "Error getting block device list for domain \
            '$domain_name'"
            _ret=1
         else
            for ((i = 0; i < ${#block_devices[@]}; i++)); do
               block_device="${block_devices[$i]}"
               #if this is the fist run, need entire chain to back up
               print_v d "Getting all backing files for: '$block_device'"
               local snapshot_chain=()
               get_snapshot_chain "$block_device" snapshot_chain
               #backup entire chain except the snapshot just made (0th element of chain)
               for ((j = 1; j < ${#snapshot_chain[@]} ; j++)); do
                  backing_file_base=$(basename "${snapshot_chain[$j]}")
                  new_backing_file="$BACKUP_DIRECTORY/$backing_file_base"

                  print_v v \
                     "Copy backing file '${snapshot_chain[$j]}' to '$new_backing_file'"
                  cp -u "${snapshot_chain[$j]}" "$new_backing_file"
               done
            done
         fi
      else
         print_v d "No backup directory specified"
      fi
   else
      print_v e \
      "Snapshot for '$domain_name' failed! Exit code: $_ret\n'$command_output'"
      _ret=1
   fi

   if [ "$resume_vm" -eq 1 ]; then
      print_v d "Resuming domain"
      virsh resume "$domain_name" >/dev/null 2>&1
      if [ $? -ne 0 ]; then
         print_v e "Problem resuming domain '$domain_name'"
         _ret=1
      else
         print_v v "Domain resumed"
         trap "" SIGINT SIGTERM
      fi
   fi
   return $_ret
}

# Function: consolidate_domain()
# Consolidate block devices for a domain
# !!! This function will delete all previous file in the backing file chain !!!
#
# Input:    Domain name
# Return:   0 on success, non 0 otherwise
function consolidate_domain() {
   local domain_name=$1

   local _ret=
   local backing_file=
   local command_output=
   local parent_backing_file=

   local dom_state=
   dom_state=$($VIRSH domstate "$domain_name" 2>&1)
   if [ "$dom_state" != "running" ]; then
      print_v e "Error: Consolidation requires '$domain_name' to be running"
      return 1
   fi

   local block_devices=''
   get_block_devices "$domain_name" block_devices
   if [ $? -ne 0 ]; then
      print_v e "Error getting block device list for domain '$domain_name'"
      return 1
   fi

   print_v d "Consolidation of block devices for '$domain_name' requested"
   print_v d "Block devices to be consolidated:\n\t${block_devices[*]}"
   print_v d "Consolidation method: $CONSOLIDATION_METHOD"

   for ((i = 0; i < ${#block_devices[@]}; i++)); do
      block_device="${block_devices[$i]}"
      print_v d \
         "Consolidation of '$i' block device: '$block_device' for '$domain_name'"

      get_backing_file "$block_device" backing_file
      if [ -n "$backing_file" ]; then
         print_v d "Parent block device: '$backing_file'"
         snapshot_chain=()
         #get an array of the snapshot chain starting from last child and iterating backwards
         # e.g.    [0]     [1]      [2]     [3]
         #       snap3 <- snap2 <- snap1 <- orig
         #
         # blockcommit: orig -> snap1 -> snap2 -> snap3 [becomes] orig
         # blockpull:   orig -> snap1 -> snap2 -> snap3 [becomes] snap3
         #do this BEFORE consolidation so that we keep complete chain info
         get_snapshot_chain "$block_device" snapshot_chain

         # Consolidate the block device
         #echo "ABOUT TO RUN:" 
         #echo "$VIRSH -q $CONSOLIDATION_METHOD $domain_name $block_device ${CONSOLIDATION_FLAGS[*]}"
         command_output=$($VIRSH -q "$CONSOLIDATION_METHOD" "$domain_name" \
            "$block_device" "${CONSOLIDATION_FLAGS[@]}" 2>&1)
         if [ $? -eq 0 ]; then
            print_v v "Consolidation of block device '$block_device' for '$domain_name' successful"
         else
            print_v e "Error consolidating block device '$block_device' for '$domain_name':\n $command_output"
            return 1
         fi


         if [ "$CONSOLIDATION_METHOD" == "blockcommit" ]; then
            # --delete option for blockcommit doesn't work (tested on
            # LibVirt 1.2.16, QEMU 2.3.0), so we need to manually delete old
            # backing files.
            # blockcommit will pivot the block device file with the base one
            # (the one originally used) so we can delete all the files created
            # by this script, starting from "$block_device".
            #
            print_v d \
              "Not deleting last element of snapshot_chain (top parent) since consolidation method='blockcommit'"
            unset snapshot_chain[${#snapshot_chain[@]}-1]
         else
            print_v d \
               "Not deleting 0th element of snapshot_chain (last child) since consolidation method='blockpull'"
            snapshot_chain=("${snapshot_chain[@]:1}")
         fi
         #echo "Complete Chain=" ${snapshot_chain[@]}

         # Deletes all old block devices
         print_v v "Deleting old backing files for '$domain_name'"

         _ret=$?
         for ((j = 0; j < ${#snapshot_chain[@]}; j++)); do
           print_v v \
              "Deleting old backing file '${snapshot_chain[$j]}' for '$domain_name'"
           rm "${snapshot_chain[$j]}"
           if [ $? -ne 0 ]; then
              print_v w "Could not delete file '${snapshot_chain[$j]}'!"
              break
           fi
         done
      else
         print_v d "No backing file found for '$block_device'. Nothing to do."
      fi
   done

   return 0
}

function libvirt_version() {
    $VIRSH -v
}

function qemu_version() {
    $QEMU --version | awk '/^QEMU emulator version / { print $4 }'
}

function qemu_img_version() {
    $QEMU_IMG -h | awk '/qemu-img version / { print $3 }' | cut -d',' -f1
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

   if [ ! -x "$QEMU" ]; then
      print_v e "'$QEMU' cannot be found or executed"
      _ret=1
   fi

   version=$(libvirt_version)
   if check_version "$version" '0.9.13'; then
      if check_version "$version" '1.0.0'; then
         print_v i "libVirt version '$version' support is experimental"
      else
         print_v d "libVirt version '$version' is supported"
      fi
   else
      print_v e "Unsupported libVirt version '$version'. Please use libVirt 0.9.13 or later"
      _ret=2
   fi

   version=$(qemu_img_version)
   if check_version "$version" '1.2.0'; then
      print_v d "$QEMU_IMG version '$version' is supported"
   else
      print_v e "Unsupported $QEMU_IMG version '$version'. Please use 'qemu-img' 1.2.0 or later"
      _ret=2
   fi

   version=$(qemu_version)
   if check_version "$version" '1.2.0'; then
      print_v d "QEMU/KVM version '$version' is supported"
   else
      print_v e "Unsupported QEMU/KVM version '$version'. Please use QEMU/KVM 1.2.0 or later"
      _ret=2
   fi

   return $_ret
}

TEMP=$(getopt -n "$APP_NAME" -o b:cCm:s:qrdhvV --long backup_dir:,consolidate_only,consolidate_and_snapshot,method:,quiesce,all_running,dump_state_dir:,debug,help,version,verbose -- "$@")
if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

eval set -- "$TEMP"
while true; do 
   case "$1" in 
      -b|--backup_dir)
        BACKUP_DIRECTORY=$2
        if [ ! -d "$BACKUP_DIRECTORY" ]; then
           print_v e "Backup directory '$BACKUP_DIRECTORY' doesn't exist!"
           exit 1
        fi
        shift; shift
      ;;
      -c|--consolidate_only)
         if [ $CONSOLIDATION -eq 1 ]; then
            print_usage "-c or -C already specified!"
          exit 1
         fi
         CONSOLIDATION=1
         SNAPSHOT=0
         shift
      ;;
      -C|--consolidate_and_snaphot)
         if [ $CONSOLIDATION -eq 1 ]; then
            print_usage "-c or -C already specified!"
         exit 1
         fi
         CONSOLIDATION=1
         SNAPSHOT=1
         shift
      ;;
      -m|--method)
         CONSOLIDATION_METHOD=$2
         CONSOLIDATION_SET=1
         if [ "$CONSOLIDATION_METHOD" == "blockcommit" ]; then
            CONSOLIDATION_FLAGS=(--wait --pivot --active)
         elif [ "$CONSOLIDATION_METHOD" == "blockpull" ]; then
            CONSOLIDATION_FLAGS=(--wait)
         else
            print_usage "-m requires specifying 'blockcommit' or 'blockpull'"
            exit 1
         fi
         shift;shift
      ;;
      -q|--quiesce)
         QUIESCE=1
         shift
      ;;
      -r|--all_running)
         ALL_RUNNING_DOMAINS=1
         shift
      ;;
      -s|--dump_state_dir)
         DUMP_STATE=1
         DUMP_STATE_DIRECTORY=$2
         if [ ! -d "$DUMP_STATE_DIRECTORY" ]; then
            print_v e \
               "Dump state directory '$DUMP_STATE_DIRECTORY' doesn't exist!"
            exit 1
         fi
         shift;shift
      ;;
      -d|--debug)
         DEBUG=1
         VERBOSE=1
         shift
      ;;
      -h|--help)
         print_usage
         exit 1
         shift
      ;;
      -v|--verbose)
         VERBOSE=1
         shift
      ;;
      -V|--version)
         echo "$APP_NAME version $VERSION"
         shift
         exit 0
      ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

if [ $ALL_RUNNING_DOMAINS -eq 1 ]; then
   print_v d "all_running_domains = '$ALL_RUNNING_DOMAINS' so all running domains will be backed up"
fi

# Parameters validation
if [ $CONSOLIDATION -eq 1 ]; then
   if [ $QUIESCE -eq 1 ]; then
      print_usage "consolidation (-c | -C) and quiesce (-q) are not compatible"
      exit 1
   fi
   if [ $DUMP_STATE -eq 1 ]; then
      print_usage \
         "consolidation (-c | -C) and dump state (-s) are not compatible"
      exit 1
   fi
   if [ $CONSOLIDATION_SET -eq 0 ]; then
     if check_version "$(qemu_version)" '2.1.0' && \
        check_version "$(libvirt_version)" '1.2.9'; then
        CONSOLIDATION_METHOD="blockcommit"
        CONSOLIDATION_FLAGS=(--wait --pivot --active)
     fi
   fi
fi

if [ $DUMP_STATE -eq 1 ]; then
   if [ $QUIESCE -eq 1 ]; then
      print_usage "dump state (-s) and quiesce (-q) are not compatible"
      exit 1
   fi
fi

dependencies_check
[ $? -ne 0 ] && exit 3

DOMAIN_NAME="$1"

if [ -z "$DOMAIN_NAME" ] && [ $ALL_RUNNING_DOMAINS -eq 0 ]; then
   print_usage "<domain name> is missing!"
   exit 2
fi
if [ ! -z "$DOMAIN_NAME" ] && [ $ALL_RUNNING_DOMAINS -eq 1 ]; then
   print_usage "Setting all_running (-r) and specifying domains not compatible"
   exit 2
fi

DOMAINS_RUNNING=
DOMAINS_NOTRUNNING=
if [ "$ALL_RUNNING_DOMAINS" -eq 1 ]; then
   DOMAINS_RUNNING=$($VIRSH -q -r list --state-running | awk '{print $2;}')
elif [ "$DOMAIN_NAME" == "all" ]; then
   DOMAINS_RUNNING=$($VIRSH -q -r list --state-running | awk '{print $2;}')
   DOMAINS_NOTRUNNING=$($VIRSH -q -r list --all --state-shutoff --state-paused | awk '{print $2;}')
else
   for THIS_DOMAIN in $DOMAIN_NAME; do
     DOMAIN_STATE=$($VIRSH -q domstate "$THIS_DOMAIN")
     if [ "$DOMAIN_STATE" == running ]; then
       DOMAINS_RUNNING="$DOMAINS_RUNNING $THIS_DOMAIN"
     else
       DOMAINS_NOTRUNNING="$DOMAINS_NOTRUNNING $THIS_DOMAIN"
     fi
   done
fi

print_v d "Domains NOTRUNNING to backup: $DOMAINS_NOTRUNNING"
print_v d "Domains RUNNING to backup: $DOMAINS_RUNNING"

for DOMAIN in $DOMAINS_RUNNING; do
   _ret=0
   if [ $SNAPSHOT -eq 1 ]; then
      try_lock "$DOMAIN"
      if [ $? -eq 0 ]; then
         snapshot_domain "$DOMAIN"
         _ret=$?
         unlock "$DOMAIN"
      else
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping backup of '$DOMAIN'"
      fi
   fi

   if [ $_ret -eq 0 ] && [ $CONSOLIDATION -eq 1 ]; then
      try_lock "$DOMAIN"
      if [ $? -eq 0 ]; then
         consolidate_domain "$DOMAIN"
         _ret=$?
         unlock "$DOMAIN"
      else
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping consolidation of '$DOMAIN'"
      fi
   fi
done

for DOMAIN in $DOMAINS_NOTRUNNING; do
   _ret=0
   declare -a all_backing_files=()
   if [ "$BACKUP_DIRECTORY" == "" ]; then
         print_v e "-b flag (directory) required for backing up the shut-off domain '$DOMAIN'"
         print_v e "Skipping backup of '$DOMAIN'"
         _ret=1
   fi
   if [ $_ret -eq 0 ] && [ $CONSOLIDATION -eq 1 ]; then
      print_v e "Consolidation only works with running domains. '$DOMAIN' is not running! Doing full backup only of '$DOMAIN'"
      if [ "$DOMAIN_NAME" != "all" ]; then
         print_v e "Skipping consolidation/backup of '$DOMAIN'"
         _ret=1
      else
         print_v d "Doing full backup (not consolidation) of '$DOMAIN'"
         _ret=0
      fi
   fi

   if [ $_ret -eq 0 ]; then
      try_lock "$DOMAIN"
      _ret=$?
      if [ $_ret -ne 0 ]; then
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping backup of '$DOMAIN'"
      fi
   fi

   if [ $_ret -eq 0 ]; then
      get_block_devices "$DOMAIN" block_devices
      #print_v d "DOMAIN $DOMAIN $BACKUP_DIRECTORY/ $block_devices"
      for ((i = 0; i < ${#block_devices[@]}; i++)); do
         backing_file=""
         block_device="${block_devices[$i]}"
         print_v d "Backing up: cp -up $backing_file $BACKUP_DIRECTORY/"
         cp -up "$block_device" "$BACKUP_DIRECTORY"/ || print_v e "Unable to cp -up $block_device"
         get_backing_file "$block_device" backing_file
         j=0
         all_backing_files[$j]=$backing_file
         while [ -n "$backing_file" ]; do
            ((j++))
            all_backing_files[$j]=$backing_file
            print_v d "Parent block device: '$backing_file'"
            #In theory snapshots are unchanged so we can use one time cp instead of rsync
            print_v d "Backing up: cp -up $backing_file $BACKUP_DIRECTORY/"
            cp -up "$backing_file" "$BACKUP_DIRECTORY"/ || print_v e "Unable to cp -up $backing_file"
            #get next backing file if it exists
            get_backing_file "$backing_file" parent_backing_file
            print_v d "Next file in backing file chain: '$parent_backing_file'"
            backing_file="$parent_backing_file"
         done
      done
      print_v d "All ${#all_backing_files[@]} block files for '$DOMAIN': $block_device : ${all_backing_files[*]}"
      _ret=$?
      unlock "$DOMAIN"
   fi
done

exit $_ret
