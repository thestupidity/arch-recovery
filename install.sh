#!/bin/bash

set -e

echo "Preparing recovery environment."

iwctl station wlan0 connect "Home sweet home"
sleep 3

pacman -Syy --noconfirm wireguard-tools
sleep 2

cryptsetup open /dev/sda3 crypt0
sleep 3

mount -o subvol=@ /dev/mapper/crypt0 /mnt
sleep 2

mount -o subvol=@root /dev/mapper/crypt0 /mnt/root
sleep 2

mount -o subvol=@home /dev/mapper/crypt0 /mnt/home
sleep 2

mount -o subvol=@srv /dev/mapper/crypt0 /mnt/srv
sleep 2

mount -o subvol=@libvirt /dev/mapper/crypt0 /mnt/var/lib/libvirt
sleep 2

mount -o subvol=@cache /dev/mapper/crypt0 /mnt/var/cache
sleep 2

mount -o subvol=@tmp /dev/mapper/crypt0 /mnt/var/tmp
sleep 2

mount -o subvol=@log /dev/mapper/crypt0 /mnt/var/log
sleep 2

mount -o subvol=@snpshots /dev/mapper/crypt0 /mnt/.snapshots
sleep 2

mount /dev/sda2 /mnt/boot
sleep 2


cp /mnt/etc/wireguard/wg0.conf /etc/wireguard/wg0.conf
sleep 1

cp /mnt/etc/ssh/sshd_config.d/sshd.conf /etc/ssh/sshd_config.d/sshd.conf
sleep 1

systemctl enable --now wg-quick@wg0
sleep 3

systemctl restart sshd
sleep 2

echo "Recovery environment ready."
