#!/usr/bin/env bash
set -e

# set device type. ** required **
# sda = /dev/sda
# nvme = /dev/nvme0n1
# mmc = /dev/mmcblk0
DEVICE="/dev/mmcblk0"

# if your device supports TRIM set to true
DEVICE_TRIM=""

# set your kernel parameters
KERNEL_PARAMETERS="quiet console=tty0 console=ttyS0,115200n8 ipv6.disable=1 cryptomgr.notests no_timer_check noreplace-smp page_alloc.shuffle=1 rcupdate.rcu_expedited=1 tsc=reliable rw"

# set your root password or leave it blank ""
# for root passwd prompt during install.  
ROOT_PASSWORD=""
ROOT_PASSWORD_RETYPE=""

# set your wifi info
WIFI_INTERFACE="wlan0"
WIFI_SSID=""
WIFI_KEY=""

function begin() {
    echo ""
    tput setaf 6; echo "ARCH LINUX AUTOMATED INSTALL SCRIPT"
    echo "DATA LOSS MAY OCCUR TO ONE OR MORE OF YOUR DRIVES"
    read -p "PROCEED? Y/N " yn
    tput setaf 9
    echo ""
    case $yn in
        [Yy]* )
            ;;
        [Nn]* )
            exit
            ;;
        * )
            exit
            ;;
    esac
}

function password() {
    if [ "$ROOT_PASSWORD" == "" ]; then
        PASSWORD_TYPED="false"
        while [ "$PASSWORD_TYPED" != "true" ]; do
            read -sp 'Type root password: ' ROOT_PASSWORD
            echo ""
            read -sp 'Retype root password: ' ROOT_PASSWORD_RETYPE
            echo ""
            if [ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_RETYPE" ]; then
                PASSWORD_TYPED="true"
            else
                echo "Passwords don't match. Try again."
            fi
        done
    fi
}

function settime() {
    timedatectl set-ntp true
}

function network() {
    if [ -n "$WIFI_INTERFACE" ]; then
        iwctl --passphrase "$WIFI_KEY" station $WIFI_INTERFACE connect $WIFI_SSID
        sleep 10
    fi

    # only ping once otherwise the packer gets stuck
    ping -c 1 -i 2 -W 5 -w 30 www.google.com
    if [ $? -ne 0 ]; then
        echo "Network ping check failed. Cannot continue."
        exit
    fi
    pacman -Syy
}

function drive() {
    SATA_DEVICE="false"
    NVME_DEVICE="false"
    MMC_DEVICE="false"

    if [ -n "$(echo $DEVICE | grep "^/dev/[a-z]d[a-z]")" ]; then
        SATA_DEVICE="true"
    elif [ -n "$(echo $DEVICE | grep "^/dev/nvme")" ]; then
        NVME_DEVICE="true"
    elif [ -n "$(echo $DEVICE | grep "^/dev/mmc")" ]; then
        MMC_DEVICE="true"
    fi
}

function partition() {
    if [ -d /mnt/boot ]; then
        umount /mnt/boot
        umount /mnt
    fi
    partprobe $DEVICE

    if [ "$SATA_DEVICE" == "true" ]; then
        BOOT_PARTITION="${DEVICE}1"
        ROOT_PARTITION="${DEVICE}2"
    fi

    if [ "$NVME_DEVICE" == "true" ]; then
        BOOT_PARTITION="${DEVICE}p1"
        ROOT_PARTITION="${DEVICE}p2"
    fi

    if [ "$MMC_DEVICE" == "true" ]; then
        BOOT_PARTITION="${DEVICE}p1"
        ROOT_PARTITION="${DEVICE}p2"
    fi

    # format GPT
    sgdisk --zap-all $DEVICE
    wipefs -a $DEVICE

    # create a 128MB parition for the EFI and another parition for the linx filesystem that consumes the rest of the disk
    parted -s $DEVICE mklabel gpt mkpart ESP fat32 1MiB 129MiB mkpart root ext4 129MiB 100% set 1 esp on

    # format both partitions
    wipefs -a $BOOT_PARTITION
    wipefs -a $ROOT_PARTITION

    # make the EFI parition FAT32
    mkfs.fat -n ESP -F32 $BOOT_PARTITION

    # make the linux parition ext4
    mkfs.ext4 -L root $ROOT_PARTITION

    PARTITION_OPTIONS="defaults"

    if [ "$DEVICE_TRIM" == "true" ]; then
        PARTITION_OPTIONS="$PARTITION_OPTIONS,noatime"
    fi

    # mount
    mount -o "$PARTITION_OPTIONS" "$ROOT_PARTITION" /mnt
    mkdir -p /mnt/boot
    mount -o "$PARTITION_OPTIONS" "$BOOT_PARTITION" /mnt/boot
}

function install() {
    sed -i 's/#Color/Color/' /etc/pacman.conf
    sed -i 's/#TotalDownload/TotalDownload/' /etc/pacman.conf

    pacstrap /mnt base linux linux-firmware intel-ucode iwd nano

    sed -i 's/#Color/Color/' /mnt/etc/pacman.conf
    sed -i 's/#TotalDownload/TotalDownload/' /mnt/etc/pacman.conf
}

function configure() {
    genfstab -U /mnt >> /mnt/etc/fstab

    if [ "$DEVICE_TRIM" == "true" ]; then
        sed -i 's/relatime/noatime/' /mnt/etc/fstab
        arch-chroot /mnt systemctl enable fstrim.timer
    fi

    arch-chroot /mnt ln -sf /usr/share/zoneinfo/America/Phoenix /etc/localtime
    arch-chroot /mnt hwclock --systohc

    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
    locale-gen
    arch-chroot /mnt locale-gen

    echo "archlinux" > /mnt/etc/hostname

    printf "$ROOT_PASSWORD\n$ROOT_PASSWORD" | arch-chroot /mnt passwd
}

function bootloader() {
    arch-chroot /mnt systemd-machine-id-setup
    arch-chroot /mnt bootctl --path="/boot" install

    arch-chroot /mnt mkdir -p /boot/loader/
    arch-chroot /mnt mkdir -p /boot/loader/entries/
    echo "default arch" > /mnt/boot/loader/loader.conf

    arch-chroot /mnt mkdir -p /etc/pacman.d/hooks/
    echo "[Trigger]" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "Type = Package" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "Operation = Upgrade" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "Target = systemd" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "[Action]" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "Description = Updating systemd-boot" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "When = PostTransaction" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "Exec = /usr/bin/bootctl update" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook
    echo "" >> /mnt/etc/pacman.d/hooks/systemd-boot.hook

    echo "title Arch Linux" >> /mnt/boot/loader/entries/arch.conf
    echo "linux /vmlinuz-linux" >> /mnt/boot/loader/entries/arch.conf
    echo "initrd /intel-ucode.img" >> /mnt/boot/loader/entries/arch.conf
    echo "initrd /initramfs-linux.img" >> /mnt/boot/loader/entries/arch.conf
    echo "options root=UUID=$(blkid -s UUID -o value $ROOT_PARTITION) $KERNEL_PARAMETERS" >> /mnt/boot/loader/entries/arch.conf
}

function services() {
    arch-chroot /mnt systemctl set-default multi-user.target
    arch-chroot /mnt systemctl enable systemd-networkd.service
    arch-chroot /mnt systemctl enable systemd-resolved.service
    arch-chroot /mnt systemctl enable iwd.service

    if [ -n "$WIFI_INTERFACE" ]; then
        echo "[Match]" > /mnt/etc/systemd/network/25-wireless.network
        echo "Name=$WIFI_INTERFACE" >> /mnt/etc/systemd/network/25-wireless.network
        echo "" >> /mnt/etc/systemd/network/25-wireless.network
        echo "[Network]" >> /mnt/etc/systemd/network/25-wireless.network
        echo "DHCP=ipv4" >> /mnt/etc/systemd/network/25-wireless.network
    fi
}

function end() {
    umount -R /mnt/boot
    umount -R /mnt
    tput setaf 6
    echo ""
    echo "Arch Linux Installed"
    echo "Remove USB Boot Device"
    echo "Attempting to Reboot"
    tput setaf 9
    sleep 10
    reboot
}

function main() {
    begin
    password
    settime
    network
    drive
    partition
    install
    configure
    bootloader
    services
    end
}

main $@
