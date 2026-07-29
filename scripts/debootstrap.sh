#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
RELEASE=${RELEASE=trixie}
DEBOOTSTRAP_KEYRING=${DEBOOTSTRAP_KEYRING=$(pwd)/build/debian-archive-keyring.gpg}
HOST_NAME=${HOST_NAME=openstick-debian}

rm -rf ${CHROOT}

debootstrap --foreign --arch arm64 \
    --keyring "${DEBOOTSTRAP_KEYRING}" "${RELEASE}" "${CHROOT}"

cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

chroot ${CHROOT} qemu-aarch64-static /bin/bash /debootstrap/debootstrap --second-stage

cat << EOF > ${CHROOT}/etc/apt/sources.list
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free-firmware
EOF

mount -t proc proc ${CHROOT}/proc/
mount -t sysfs sys ${CHROOT}/sys/
mount -o bind /dev/ ${CHROOT}/dev/
mount -o bind /dev/pts/ ${CHROOT}/dev/pts/
mount -o bind /run ${CHROOT}/run/

cp scripts/setup.sh ${CHROOT}
chroot ${CHROOT} qemu-aarch64-static /bin/sh -c /setup.sh

# cleanup
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a}
done;

rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup systemd services
cp -a configs/system/* ${CHROOT}/etc/systemd/system

cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin
install -D -m 0755 scripts/openstick-usb-gadget.sh \
    ${CHROOT}/usr/sbin/openstick-usb-gadget
install -D -m 0644 configs/openstick-usb-gadget.conf \
    ${CHROOT}/etc/default/openstick-usb-gadget
install -D -m 0755 scripts/openstick-resize-rootfs.sh \
    ${CHROOT}/usr/sbin/openstick-resize-rootfs
install -D -m 0644 configs/logind.conf.d/50-openstick-power-key.conf \
    ${CHROOT}/etc/systemd/logind.conf.d/50-openstick-power-key.conf
install -D -m 0755 scripts/openstick-modem-isolate.sh \
    ${CHROOT}/usr/sbin/openstick-modem-isolate
install -D -m 0644 configs/openstick-modem-isolation.conf \
    ${CHROOT}/etc/default/openstick-modem-isolation
install -D -m 0644 configs/udev/80-openstick-modem-isolation.rules \
    ${CHROOT}/etc/udev/rules.d/80-openstick-modem-isolation.rules

mkdir -p \
    ${CHROOT}/etc/systemd/system/multi-user.target.wants \
    ${CHROOT}/etc/systemd/system/usb-gadget.target.wants
ln -sf /etc/systemd/system/openstick-usb-gadget.service \
    ${CHROOT}/etc/systemd/system/usb-gadget.target.wants/openstick-usb-gadget.service
ln -sf /etc/systemd/system/getty@ttyGS0.service \
    ${CHROOT}/etc/systemd/system/usb-gadget.target.wants/getty@ttyGS0.service
ln -sf /etc/systemd/system/openstick-usb-dhcp.service \
    ${CHROOT}/etc/systemd/system/usb-gadget.target.wants/openstick-usb-dhcp.service
ln -sf /etc/systemd/system/openstick-resize-rootfs.service \
    ${CHROOT}/etc/systemd/system/multi-user.target.wants/openstick-resize-rootfs.service

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
scripts/render-usb-management.sh ${CHROOT} configs/usb-management.conf
chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*

# The package service reads the system-wide dnsmasq configuration. Mask it so
# only the explicitly DHCP-only OpenStick instance can start.
rm -f ${CHROOT}/etc/systemd/system/multi-user.target.wants/dnsmasq.service
ln -sf /dev/null ${CHROOT}/etc/systemd/system/dnsmasq.service

# install kernel
wget -O - http://mirror.postmarketos.org/postmarketos/v24.06/aarch64/linux-postmarketos-qcom-msm8916-6.6-r5.apk \
    | tar xkzf - -C ${CHROOT} --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# create missing directory
mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

# update fstab
echo "PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46\t/boot\text2\tdefaults\t0 2" > ${CHROOT}/etc/fstab

# Remove build-time identity immediately before packaging the cloneable image.
scripts/deidentify-rootfs.sh ${CHROOT}

# backup rootfs
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C rootfs .
