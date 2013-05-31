# LibVirtKvm-Scripts

## fi-backup - Online Forward Incremental Backup for Libvirt/KVM VMs

fi-backup can be used to make ***online*** _forward incremental_ backup of libvirt/KVM virtual machines.
It works on VMs with multiple disks but only if disk images are in qcow2 format.
It also allows consolidation of backups previously taken.

Please note that the integrity of these backup is not assured because fi-backup only performs backup of VMs disks (CPU status and RAM aren't saved).

See sample usage below for more information.

### Syntax

    Usage:

      ./fi-backup.sh [-c|-C] [-h] [-d] [-v] [-b <directory>] <domain name>|all

    Options
       -b <directory>    Copy previous snapshot/base image to the specified <directory>
       -c                Consolidation only
       -C                Snapshot and consolidation
       -d                Debug
       -h                Print usage and exit
       -v                Verbose

### Sample usage

#### _Forward incremental_ backup of a virtual machine with one disk

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

And here is the content fo the backup directory:

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
    [WAR] '/nfs/original-dir/DGuerri_Domain.img' doesn't seem to be a backup backing file image. Stopping backing file chain removal (manual intervetion requested)...

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
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

# Copyright

Copyright (C) 2013 Davide Guerri - Unidata S.p.A. - <davide.guerri@gmail.com>
See LICENSE.txt for further details.

