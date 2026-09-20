#!/bin/sh -e

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections
echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections
echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
rm -f "/etc/locale.gen"

apt update -qqy
apt upgrade -qqy
apt autoremove -qqy
apt install -qqy --no-install-recommends \
    bridge-utils \
    ca-certificates \
    curl \
    dnsmasq \
    e2fsprogs \
    exfatprogs \
    hostapd \
    iproute2 \
    iptables \
    libconfig11 \
    locales \
    modemmanager \
    netcat-traditional \
    net-tools \
    network-manager \
    openssh-server \
    qrtr-tools \
    rmtfs \
    sudo \
    systemd-timesyncd \
    tzdata \
    util-linux \
    wireguard-tools \
    wpasupplicant
apt clean
rm -rf /var/lib/apt/lists/*

# Cloneable images have no shared login credential.
usermod --lock root
useradd --create-home --shell /bin/bash --password '!' openstick
useradd --system --user-group --no-create-home --shell /usr/sbin/nologin openstick-setup
printf 'openstick ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/openstick
chmod 0440 /etc/sudoers.d/openstick
visudo -cf /etc/sudoers.d/openstick
printf 'Complete OpenStick setup over USB before logging in.\n' > /etc/nologin
chmod 0644 /etc/nologin
# Both login and sshd must enforce the persistent first-boot gate.
for pam_service in login sshd; do
    sed -i '1i account requisite pam_nologin.so' "/etc/pam.d/${pam_service}"
done
