# LibVirtKvm-Scripts

**Status**
* [![Build Status](https://travis-ci.org/dguerri/LibVirtKvm-scripts.svg?branch=master)](https://travis-ci.org/dguerri/LibVirtKvm-scripts) on master branch
* [![Build Status](https://travis-ci.org/dguerri/LibVirtKvm-scripts.svg?branch=development)](https://travis-ci.org/dguerri/LibVirtKvm-scripts) on development branch

## fi-backup - Online Forward Incremental Backup for Libvirt/KVM VMs

fi-backup can be used to make offline or online _forward incremental_ backups of libvirt/KVM virtual machines.
It works on VMs with multiple disks but only if disk images are in qcow2 format.
It also allows consolidation of backups previously taken. Both backup and consolidation can be performed live, on running domains.

Note
----

By default `fi-backup.sh` guarantees that qcow2 images format is consistent, but this doesn't imply that the contained filesystems are consistent too.
In order to perform consistent backups, you can use two different strategies:

1. use domain quiescence (`-q` option, see below). This requires configuring the domain to use quiescence (e.g. `apt-get install qemu-guest-agent` inside VM);
2. dump domain state (`-s <directory>` option, see below). In this case the domain is paused, its state is dumped, a snapshot of all its disks is performed and then the domain is restarted.

Option number 2 doesn't require agents installed in the domain, but it will pause the VM for some 
seconds (the actual number of secords depends on how busy the VM is and the mount of RAM given to the VM).
For very busy domain, state dump could not complete, expecially if it is done on slow disks (e.g. NFS).

Offline backups work by comparing timestamps on the VM images vs the backup timestamps and doing a 
"cp --update" which only updates the backups if the image timestamp is newer than the backup timestamp.

The Backup method `blockpull` works as: `orig -> snap1 -> snap2 -> ... [becomes] snap3`. 

The blockpull method has the benefit that snap3 will be a compressed image only taking up as much 
space as was used by the VM's OS. For example: 
if you have a 100 GB Virtual Machine file but the VM only uses 10 GB of that 100 GB, 
then the image file created for snap3 will only be about 10 GB, saving you 90 GB of disk space on the 
VM host.  The disadvantage of this method is that it takes a long time for the blockpull to roll all
previous backing files into the snap3 file (can be minutes).

The backup method `blockcommit` works as: `orig -> snap1 -> snap2 -> .... [becomes] orig`. 

The blockcommit method has the benefits that the file name of the VM does not change and the backup
is extremely quick (only a few seconds to roll the few changes back to orig) relative to the blockpull 
method (can take several minutes depending on how large the VM is or how long the snapshot chain is). 
The disadvantage of this method is that it does not shrink the size of orig. 

A recommended method for automating backups via fi-backup.sh is to have the first backup be 
done with `--method=blockpull`
to create a smaller disk image and then for all subsequent backups use `--method=blockcommit`. 

See sample usage below for more information.
For more information about how backups are performed, see [Nuts and Bolts of fi-backup](NUTSNBOLTS.md)

## Apparmor

Please note that in some cases, **apparmor prevents this script from working**:

`fi-backup.sh` uses the `virsh create-snapshot` command. On some distribution (e.g. Ubuntu) this command fails to create external snapshot with apparmor enabled.

See this [bug report](https://bugs.launchpad.net/ubuntu/+source/libvirt/+bug/1004606) for more information and for a workaround.

*Quick and dirty workaround*

Edit `/etc/libvirt/qemu.conf` and set

    security_driver = "none"

## Dependencies

`fi-backup.sh` is designed to run on GNU/Linux. The following software is also required:

* libVirt >= 0.9.13
* QEMU/KVM >= 1.2.0

### Syntax

    fi-backup version 2.1.0 - Davide Guerri <davide.guerri@gmail.com>

    Usage:

    ./fi-backup.sh [-c|-C] [-q|-s <directory>] [-h] [-d] [-v] [-V] [-b <directory>] "<domains separated by spaces>"|all

    Options
       -b, --backup_dir <directory>      Copy previous snapshot/base image to the specified <directory>
       -c, --consolidate_only            Consolidation only
       -C, --consolidate_and_snapshot    Snapshot and consolidation
       -m, --method <method>             Use blockpull or blockcommit for consolidation
       -q, --quiesce                     Use quiescence (qemu agent must be installed in the domain)
       -s, --dump_state_dir <directory>  Dump domain status in the specified directory
       -d, --debug                       Debug
       -r, --all_running                 Backup all running domains only (do not specify domains)
       -h, --help                        Print usage and exit
       -v, --verbose                     Verbose
       -V, --version                     Print version and exit

### Sample usage

#### _Forward incremental_ backup of a virtual machine with one disk
(output might be slightly different depending on the version used)

    ~# mkdir -p /nfs/backup-dir/fi-backups/DGuerri_Domain

    ~# ./fi-backup.sh -b /nfs/backup-dir/fi-backups/DGuerri_Domain -d DGuerri_Domain
    [DEB] libVirt version '0.9.13' is supported
    [DEB] qemu-img version '1.2.0' is supported
    [DEB] KVM version '1.2.0' is supported
    [DEB] Snapshot for domain 'DGuerri_Domain' requested
    [DEB] Using timestamp '20130531-114338'
    [DEB] Snapshotting block devices for 'DGuerri_Domain' using suffix 'bimg-20130531-114338'
    [VER] Snapshot for block devices of 'DGuerri_Domain' successful
    [VER] Copy backing file '/nfs/original-dir/DGuerri_Domain.img' to '/nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.img'
    [VER] No parent backing file for '/nfs/original-dir/DGuerri_Domain.img'

The original images directory content after this backup is shown below.

    ~# ls /nfs/original-dir/DGuerri_Domain* -latr
    -rw------- 1 libvirt-qemu kvm 64108953600 May 31  2013 /nfs/original-dir/DGuerri_Domain.img
    -rw------- 1 libvirt-qemu kvm  1883308032 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-114338

`DGuerri_Domain.bimg-20130531-114338` is the current image for `DGuerri_Domain`.
`DGuerri_Domain.img` is now the backing file for `DGuerri_Domain.bimg-20130531-114338`.

The backup directory now contains the following files:

    ~# ls /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain* -latr
    drwxr-xr-x 2 root root        4096 May 31  2013 .
    drwxr-xr-x 3 root root        4096 May 31  2013 ..
    -rw------- 1 root root 64108953600 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.img

Some time later, another backup is made:

    ~# ./fi-backup.sh -b /nfs/backup-dir/fi-backups/DGuerri_Domain -d DGuerri_Domain
    [DEB] libVirt version '0.9.13' is supported
    [DEB] qemu-img version '1.2.0' is supported
    [DEB] KVM version '1.2.0' is supported
    [DEB] Snapshot for domain 'DGuerri_Domain' requested
    [DEB] Using timestamp '20130531-120054'
    [DEB] Snapshotting block devices for 'DGuerri_Domain' using suffix 'bimg-20130531-120054'
    [VER] Snapshot for block devices of 'DGuerri_Domain' successful
    [VER] Copy backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-114338' to '/nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-114338'
    [DEB] Parent backing file: '/nfs/original-dir/DGuerri_Domain.img'
    [VER] Changing original backing file reference for '/nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-114338' from '/nfs/original-dir/DGuerri_Domain.img' to '/nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.img'

The original images directory content after this backup is shown below.

    ~# ls /nfs/original-dir/DGuerri_Domain* - -latr
    -rw------- 1 libvirt-qemu kvm 64108953600 May 31  2013 /nfs/original-dir/DGuerri_Domain.img
    -rw------- 1 libvirt-qemu kvm  1883308032 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-114338
    -rw------- 1 libvirt-qemu kvm   221446144 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-120054

`DGuerri_Domain.img` is the backing file for `DGuerri_Domain.bimg-20130531-114338` which in turn is the backing file for `DGuerri_Domain.bimg-20130531-120054`.
The image `DGuerri_Domain.bimg-20130531-120054` is the current image for the domain named `DGuerri_Domain`.

The backup directory now contains the following files:

    ~# ls /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain* -latr
    -rw------- 1 root root 64108953600 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.img
    -rw------- 1 root root  1883308032 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-114338

`DGuerri_Domain.img` is the backing file for `DGuerri_Domain.bimg-20130531-114338`.

After some more backups, the content of the original directory is the following:

    ~# ls /nfs/original-dir/DGuerri_Domain*  -latr
    -rw------- 1 libvirt-qemu kvm 64108953600 May 31 12:40 /nfs/original-dir/DGuerri_Domain.img
    -rw------- 1 libvirt-qemu kvm  1883308032 May 31 12:58 /nfs/original-dir/DGuerri_Domain.bimg-20130531-114338
    -rw------- 1 libvirt-qemu kvm  1394475008 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-120054
    -rw------- 1 libvirt-qemu kvm      524288 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-125445
    -rw------- 1 libvirt-qemu kvm      786432 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-125701
    -rw------- 1 libvirt-qemu kvm     3604480 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-125719

And here is the content for the backup directory:

    ~# ls /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain* -latr
    -rw------- 1 root root 64108953600 May 31 12:56 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.img
    -rw------- 1 root root  1883308032 May 31 12:58 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-114338
    -rw------- 1 root root  1394475008 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-120054
    -rw------- 1 root root      524288 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-125445
    -rw------- 1 root root      786432 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-125701

Consolidation example:

    ~# ./fi-backup.sh -c -d DGuerri_Domain
    [DEB] libVirt version '0.9.13' is supported
    [DEB] qemu-img version '1.2.0' is supported
    [DEB] KVM version '1.2.0' is supported
    [DEB] Consolidation of block devices for 'DGuerri_Domain' requested
    [DEB] Block devices to be consolidated:
     /nfs/original-dir/DGuerri_Domain.bimg-20130531-125719
    [DEB] Consolidation of block device: '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125719' for 'DGuerri_Domain'
    [DEB] Parent block device: '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125701'
    [VER] Consolidation of block device '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125719' for 'DGuerri_Domain' successful
    [VER] Deleting old backup files for 'DGuerri_Domain'
    [DEB] Processing old backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125701' for 'DGuerri_Domain'
    [VER] Deleting backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125701'
    [DEB] Next file in backing file chain: '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125445'
    [DEB] Processing old backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125445' for 'DGuerri_Domain'
    [VER] Deleting backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-125445'
    [DEB] Next file in backing file chain: '/nfs/original-dir/DGuerri_Domain.bimg-20130531-120054'
    [DEB] Processing old backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-120054' for 'DGuerri_Domain'
    [VER] Deleting backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-120054'
    [DEB] Next file in backing file chain: '/nfs/original-dir/DGuerri_Domain.bimg-20130531-114338'
    [DEB] Processing old backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-114338' for 'DGuerri_Domain'
    [VER] Deleting backing file '/nfs/original-dir/DGuerri_Domain.bimg-20130531-114338'
    [DEB] Next file in backing file chain: '/nfs/original-dir/DGuerri_Domain.img'
    [DEB] Processing old backing file '/nfs/original-dir/DGuerri_Domain.img' for 'DGuerri_Domain'
    [WAR] '/nfs/original-dir/DGuerri_Domain.img' doesn't seem to be a backup backing file image. Stopping backing file chain removal (manual intervetion required)...

The last error occours because the filename `DGuerri_Domain.img` doesn't have `bimg-<timestamp>` suffix. In this particular case, we can safely remove this file.

    ~# ls /nfs/original-dir/DGuerri_Domain.* -la
    -rw------- 1 libvirt-qemu kvm 64108953600 May 31  2013 /nfs/original-dir/DGuerri_Domain.bimg-20130531-125719
    -rw------- 1 libvirt-qemu kvm 64108953600 May 31 12:40 /nfs/original-dir/DGuerri_Domain.img

Of course the backup images remain untouched. Each image depends on the previous one.

    ~# ls /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain* -latr
    -rw------- 1 root root 64108953600 May 31 12:56 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.img
    -rw------- 1 root root  1883308032 May 31 12:58 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-114338
    -rw------- 1 root root  1394475008 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-120054
    -rw------- 1 root root      524288 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-125445
    -rw------- 1 root root      786432 May 31  2013 /nfs/backup-dir/fi-backups/DGuerri_Domain/DGuerri_Domain.bimg-20130531-125701

The recovery of an incremental backup is possible using the appropriate chain.
For instance, in order to recover the backup with timestamp `20130531-120054`, the following images are needed:

* `DGuerri_Domain.img`
* `DGuerri_Domain.bimg-20130531-114338`
* `DGuerri_Domain.bimg-20130531-120054`

# Contributing to LibVirtKvm-Scripts

* Check out the latest master to make sure the feature hasn't been implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

# Copyright

Copyright (C) 2013 2014 2015 Davide Guerri - <davide.guerri@gmail.com>
See LICENSE.txt for further details.
