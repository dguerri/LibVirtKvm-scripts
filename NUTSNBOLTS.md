Forward incremental Backup
--------------------------

Initial configuration. "Current image" pointer is an abstraction for the image currently used by qemu to run a given domain.

      Current image
            |
            v
    +-----------------+
    |   disk.qcow2    |
    +-----------(R/W)-+

Run `fi-backup`.

                                 Current image
                                       |
                                       v
    +------------------+   +------------------------+
    |    disk.qcow2    |<--| disk.bimg-<timestamp1> |
    +------------(R/O)-+   +------------------(R/W)-+


After the first run, `disk.qcow2` is the backing file of `disk.bimg-<timestamp1>`. That means that `disk.qcow2` is used in read-only mode by qemu. Thus, it can be safely copied to perform our backup.


                                                               Current image
                                                                     |
                                                                     v
    +------------------+   +------------------------+   +------------------------+
    |    disk.qcow2    |<--| disk.bimg-<timestamp1> |<--| disk.bimg-<timestamp2> |
    +------------(R/O)-+   +------------------(R/O)-+   +------------------(R/W)-+

After the second run, `disk.qcow2` has not changed, so we can just copy `disk.bimg-<timestamp1>` to our backup storage.
This is the "key" of forward incremental backup: `disk.bimg-<timestamp1>` contains just the deltas since the first `fi-backup` run.


Consolidation
-------------

Consolidation copies the content of backing files into the current image, allowing us to remove them.
This reduces the number of image files, reduces the size of disk images and improves domain performances.

                                                               Current image
                                                                     |
                                                                     v
    +------------------+   +------------------------+   +------------------------+
    |    disk.qcow2    |<--| disk.bimg-<timestamp1> |<--| disk.bimg-<timestamp2> |
    +------------(R/O)-+   +------------------(R/O)-+   +------------------(R/W)-+


Running in consolidation mode will "copy" backing images content back into the current image.

                                                              Current image
                                            +--block-pull--+        |
                                            |              |        v
    +------------------+   +----------------+-------+   +--v---------------------+
    |    disk.qcow2    |<--| disk.bimg-<timestamp1> | X | disk.bimg-<timestamp2> |
    +-----------(R/O)--+   +------------------(R/O)-+   +------------------(R/W)-+

After that, old backing files can be deleted.
`fi-backup.sh` will automatically delete every old backing file with extension `bimg-<timestampX>`. In the example above, `disk.qcow2` will not be automatically deleted and a warning is printed.
It is safe to manually delete `disk.qcow2`, as the only image needed after the consolidation is `disk.bimg-<timestamp2>`:

           Current image
                 |
                 v
    +------------------------+
    | disk.bimg-<timestamp2> |
    +------------------(R/W)-+


Restore
-------

Restore procedure for a domain A, with images in directory B, backup directory C is the following. Thanks to [svorobyov](https://github.com/svorobyov) for these steps.

1. clean up the directory B from all images for domain A;
2. copy the desired chains of the backing images for domain A from C to B (although it is not recommended, chains can be of different lengths, e.g., recover disk 1 to the state two days back and disk 2 to the state three days);
3. specify (using `virsh`, `virt-manager`, `virt-install`, ...) that the disks for A are the last images of the chains in 2 (this is important, otherwise the VM state description may be inconsistent)
4. optionally, consolidate for domain A (which will use chains of images in B)

Restore of backup with domain state dump can be performed

TBW
`<qemu-command-line> -incoming "exec: gzip -c -d <path/to/state/file>"`


