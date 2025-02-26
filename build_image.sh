#!/bin/bash

set -e
if [ "$DEBUG" ]; then
  set -x
fi

create_loop() {
  local loop_device=$(losetup -f)
  losetup -P $loop_device "${1}"
  echo $loop_device
}

#original shim rootfses have a non standard ext2 filesystem
make_mountable() {
  printf '\000' | dd of=$1 seek=$((0x464 + 3)) conv=notrunc count=1 bs=1 status=none
}

#set required flags on the kernel partition
make_bootable() {
  cgpt add -i 2 -S 1 -T 5 -P 10 -l kernel $1
}

partition_disk() {
  local image_path=$(realpath "${1}")
  local bootloader_size=${2}

  #create partition table with fdisk
  ( 
    echo g #new gpt disk label

    #create 1MB stateful
    echo n #new partition
    echo #accept default parition number
    echo #accept default first sector
    echo +1M #partition size is 1M

    #create 32MB kernel partition
    echo n
    echo #accept default parition number
    echo #accept default first sector
    echo +32M #partition size is 32M
    echo t #change partition type
    echo #accept default parition number
    echo FE3A2A5D-4F32-41A7-B725-ACCC3285A309 #chromeos kernel type

    #create bootloader partition
    echo n
    echo #accept default parition number
    echo #accept default first sector
    echo "+${bootloader_size}M" #set partition size
    echo t #change partition type
    echo #accept default parition number
    echo 3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC #chromeos rootfs type

    #create rootfs partition
    echo n
    echo #accept default parition number
    echo #accept default first sector
    echo #accept default size to fill rest of image
    echo x #enter expert mode
    echo n #change the partition name
    echo #accept default partition number
    echo "shimboot_rootfs:default" #set partition name
    echo r #return to normal more

    #write changes
    echo w
  ) | fdisk $image_path > /dev/null
}

safe_mount() {
  umount $2 2> /dev/null || /bin/true
  rm -rf $2
  mkdir -p $2
  mount $1 $2
}

create_partitions() {
  local image_loop=$(realpath "${1}")
  local kernel_path=$(realpath "${2}")

  #create stateful
  mkfs.ext4 "${image_loop}p1"
  #copy kernel
  dd if=$kernel_path of="${image_loop}p2" bs=1M oflag=sync
  make_bootable $image_loop
  #create bootloader partition
  mkfs.ext2 "${image_loop}p3"
  #create rootfs partition
  mkfs.ext4 "${image_loop}p4"
}

populate_partitions() {
  local image_loop=$(realpath "${1}")
  local bootloader_dir=$(realpath "${2}")
  local rootfs_dir=$(realpath "${3}")

  #mount and write empty file to stateful
  local stateful_mount=/tmp/shim_stateful
  safe_mount "${image_loop}p1" $stateful_mount
  mkdir -p $stateful_mount/dev_image/etc/
  mkdir -p $stateful_mount/dev_image/factory/sh
  touch $stateful_mount/dev_image/etc/lsb-factory
  umount $stateful_mount

  #mount and write to bootloader rootfs
  local bootloader_mount=/tmp/shim_bootloader
  safe_mount "${image_loop}p3" $bootloader_mount
  cp -r $bootloader_dir/* $bootloader_mount
  umount $bootloader_mount

  #write rootfs to image
  local rootfs_mount=/tmp/new_rootfs
  safe_mount "${image_loop}p4" $rootfs_mount
  rsync --archive --human-readable --hard-links --info=progress2 --sparse $rootfs_dir/ $rootfs_mount/
  umount $rootfs_mount
}

create_image() {
  local image_path=$(realpath "${1}")
  local bootloader_size=${2}
  local rootfs_size=${3}
  
  #stateful + kernel + bootloader + rootfs
  local total_size=$((1 + 32 + $bootloader_size + $rootfs_size))
  rm -rf "${image_path}"
  fallocate -l "${total_size}M" "${image_path}"

  partition_disk $image_path $bootloader_size
}