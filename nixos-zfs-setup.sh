# vim: ts=4 sw=4 ai noet si sta fdm=marker
#
# Edit the variables below. Then run this by issuing:
# `bash ./nixos-zfs-setup.sh`
#
# WARNING: this script will clear partition tables of existing disks.
# Make sure that you set the DISK variable correctly. Additionally, it
# is a good idea to clean your disk(s) current partitions first. Use the
# command `wipefs` for this.
#
###############################################################################
#    nixos-zfs-setup.sh: a bash script that sets up zfs disks for NixOS.      #
#      Copyright (C) 2022  Mark (voidzero) van Dijk, The Netherlands.         #
#                                                                             #
#    This program is free software: you can redistribute it and/or modify     #
#    it under the terms of the GNU General Public License as published by     #
#    the Free Software Foundation, either version 3 of the License, or        #
#    (at your option) any later version.                                      #
#                                                                             #
#    This program is distributed in the hope that it will be useful,          #
#    but WITHOUT ANY WARRANTY; without even the implied warranty of           #
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            #
#    GNU General Public License for more details.                             #
#                                                                             #
#    You should have received a copy of the GNU General Public License        #
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.   #
###############################################################################

set -ex

DISK=(/dev/vda)
#DISK=(/dev/vda /dev/vdb)

# How to name the partitions. This will be visible in 'gdisk -l /dev/disk' and
# in /dev/disk/by-partlabel.
PART_GPT="gpt"
PART_EFI="efi"
PART_ROOT="rpool"

# The type of virtual device for boot and root. If kept empty, the disks will
# be joined (two 1T disks will give you ~2TB of data). Other valid options are
# mirror, raidz types and draid types. You will have to manually add other
# devices like spares, intent log devices, cache and so on. Here we're just
# setting this up for installation after all.
#ZFS_BOOT_VDEV="mirror"
#ZFS_ROOT_VDEV="mirror"

# How to name the boot pool and root pool.
ZFS_ROOT="rpool"

# How to name the root volume in which nixos will be installed.
# If ZFS_ROOT is set to "rpool" and ZFS_ROOT_VOL is set to "nixos",
# nixos will be installed in rpool/nixos, with a few extra subvolumes
# (datasets).
ZFS_ROOT_VOL="nixos"

# Generate a root password with mkpasswd -m SHA-512
ROOTPW=''

# Do you want impermanence? In that case set this to 1. Not yes, not hai, 1.
IMPERMANENCE=0

# If IMPERMANENCE is 1, this will be the name of the empty snapshots
EMPTYSNAP="SYSINIT"

# End of settings.

set +x

MAINCFG="/mnt/etc/nixos/configuration.nix"
HWCFG="/mnt/etc/nixos/hardware-configuration.nix"
ZFSCFG="/mnt/etc/nixos/zfs.nix"

set -x

i=0 SWAPDEVS=()
for d in ${DISK[*]}
do
	sgdisk --zap-all ${d}
	sgdisk -a1 -n1:0:+100K -t1:EF02 -c 1:${PART_GPT}${i} ${d}
	sgdisk -n2:1M:+1G -t2:EF00 -c 2:${PART_EFI}${i} ${d}
	sgdisk -n3:0:+4G -t3:BE00 -c 3:${PART_ROOT}${i} ${d}

	partprobe ${d}
	sleep 2
	(( i++ )) || true
done
unset i d

# Wait for a bit to let udev catch up and generate /dev/disk/by-partlabel.
sleep 3s

# Create the root pool
zpool create \
	-o ashift=12 \
	-o autotrim=on \
	-O acltype=posixacl \
	-O compression=zstd \
	-O dnodesize=auto -O normalization=formD \
	-O relatime=on \
	-O xattr=sa \
	-O mountpoint=none \
	-R /mnt \
	${ZFS_ROOT} ${ZFS_ROOT_VDEV} /dev/disk/by-partlabel/${PART_ROOT}*

# Create the root dataset
zfs create -o mountpoint=legacy -o compression=lz4 ${ZFS_ROOT}/${ZFS_ROOT_VOL}

# Create datasets (subvolumes) in the root dataset
zfs create ${ZFS_ROOT}/${ZFS_ROOT_VOL}/home
(( $IMPERMANENCE )) && zfs create ${ZFS_ROOT}/${ZFS_ROOT_VOL}/keep || true
zfs create -o atime=off ${ZFS_ROOT}/${ZFS_ROOT_VOL}/nix
zfs create ${ZFS_ROOT}/${ZFS_ROOT_VOL}/root
zfs create ${ZFS_ROOT}/${ZFS_ROOT_VOL}/usr
zfs create ${ZFS_ROOT}/${ZFS_ROOT_VOL}/var
zfs create ${ZFS_ROOT}/${ZFS_ROOT_VOL}/var/lib/containers/storage

# Create datasets (subvolumes) in the boot dataset
# This comes last because boot order matters
zfs create -o mountpoint=/boot ${ZFS_ROOT}/${ZFS_ROOT_VOL}/boot

# Make empty snapshots of impermanent volumes
if (( $IMPERMANENCE ))
then
	for i in "" /usr /var
	do
		zfs snapshot ${ZFS_ROOT}/${ZFS_ROOT_VOL}${i}@${EMPTYSNAP}
	done
fi

# Create, mount and populate the efi partitions
i=0
for d in ${DISK[*]}
do
	mkfs.vfat -n EFI /dev/disk/by-partlabel/${PART_EFI}${i}
	mkdir -p /mnt/boot/efis/${PART_EFI}${i}
	mount -t vfat /dev/disk/by-partlabel/${PART_EFI}${i} /mnt/boot/efis/${PART_EFI}${i}
	(( i++ )) || true
done
unset i d

# Mount the first drive's efi partition to /mnt/boot/efi
mkdir /mnt/boot/efi
mount -t vfat /dev/disk/by-partlabel/${PART_EFI}0 /mnt/boot/efi

# Make sure we won't trip over zpool.cache later
mkdir -p /mnt/etc/zfs/
rm -f /mnt/etc/zfs/zpool.cache
touch /mnt/etc/zfs/zpool.cache
chmod a-w /mnt/etc/zfs/zpool.cache
chattr +i /mnt/etc/zfs/zpool.cache

# Generate and edit configs
nixos-generate-config --root /mnt

sed -i 's|fsType = "zfs";|fsType = "zfs"; options = [ "zfsutil" "X-mount.mkdir" ];|g' ${HWCFG}

ADDNR=$(awk '/^  fileSystems."\/" =$/ {print NR+3}' ${HWCFG})
sed -i "${ADDNR}i"' \      neededForBoot = true;' ${HWCFG}

ADDNR=$(awk '/^  fileSystems."\/boot" =$/ {print NR+3}' ${HWCFG})
sed -i "${ADDNR}i"' \      neededForBoot = true;' ${HWCFG}

if (( $IMPERMANENCE ))
then
	# Of course we want to keep the config files after the initial
	# reboot. So, create a bind mount from /keep/etc/nixos -> /etc/nixos
	# here, and copy the files and actually mount the bind later
	ADDNR=$(awk '/^  swapDevices =/ {print NR-1}' ${HWCFG})
	TMPFILE=$(mktemp)
	head -n ${ADDNR} ${HWCFG} > ${TMPFILE}

	tee -a ${TMPFILE} <<EOF
  fileSystems."/etc/nixos" =
    { device = "/keep/etc/nixos";
      fsType = "none";
      options = [ "bind" ];
    };

EOF

	ADDNR=$(awk '/^  swapDevices =/ {print NR}' ${HWCFG})
	tail -n +${ADDNR} ${HWCFG} >> ${TMPFILE}
	cat ${TMPFILE} > ${HWCFG}
	rm -f ${TMPFILE}
	unset ADDNR TMPFILE
fi

if (( $IMPERMANENCE ))
then
	# This is where we copy the config files and mount the bind
	install -d -m 0755 /mnt/keep/etc
	cp -a /mnt/etc/nixos /mnt/keep/etc/
	mount -o bind /mnt/keep/etc/nixos /mnt/etc/nixos
fi

set +x

echo "Now do this (preferably in another shell, this will put out a lot of text):"
echo "nixos-install -v --show-trace --no-root-passwd --root /mnt"
echo "umount -Rl /mnt"
echo "zpool export -a"
echo "swapoff -a"
echo "reboot"
echo "Make note of these instructions because the nixos-install command will output a lot of text."

