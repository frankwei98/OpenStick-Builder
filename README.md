# OpenStick Image Builder
Image builder for MSM8916 based 4G modem dongles

This builder uses the precompiled [kernel](https://pkgs.postmarketos.org/package/v24.06/postmarketos/aarch64/linux-postmarketos-qcom-msm8916) provided by [postmarketOS](https://postmarketos.org/) for Qualcomm MSM8916 devices.

> [!NOTE]
> This branch generates a `debian` image, use the [alpine branch](https://github.com/kinsamanka/OpenStick-Builder/tree/alpine) for an `alpine` image.

## Build Instructions
### Build locally

The builder supports these Linux build hosts:

| Build host | Rootfs build mode |
| --- | --- |
| Ubuntu 22.04 AMD64 | ARM64 cross-toolchain with foreign debootstrap and QEMU |
| Ubuntu 24.04 ARM64 | Native ARM64 debootstrap and chroot without QEMU |

The build scripts detect the host architecture with `dpkg` and fail clearly on
unsupported architectures. The AMD64 path remains available as a compatibility
fallback, while the ARM64-native path avoids emulation during package
configuration and is substantially faster.

By default the builder creates a generic image and the user selects the physical
board after flashing. The generic image uses the historical UZ801 DTB only as a
bootable management fallback; it deliberately leaves `/etc/openstick-board`
absent and reports the board as `UNCONFIGURED` until the user selects one.

The supported board profiles are:

| Profile | Hardware | DTB |
| --- | --- | --- |
| `ufi003` | UFI003 and compatible UFI001B/UFI001C sticks | `msm8916-thwc-ufi001c.dtb` |
| `uz801` | Yiming UZ801 v3 | `msm8916-yiming-uz801v3.dtb` |

- clone
  ```shell
  git clone --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
  cd OpenStick-Builder/
  ```
#### Quick
- build
  ```shell
  cd OpenStick-Builder/
  sudo ./build.sh
  ```

  To create an image that is already configured for one board, set the optional
  build profile:

  ```shell
  sudo env OPENSTICK_BOARD=ufi003 ./build.sh
  ```
#### Detailed
- install dependencies
  ```shell
  sudo scripts/install_deps.sh
  ```
- build hyp and lk2nd

  these custom bootloader allows basic support for `extlinux.conf` file, similar to u-boot and depthcharge.
  ```shell
  sudo scripts/build_hyp_aboot.sh
  ```
- extract Qualcomm firmware

  extracts the bootloader and creates a new partition table that utilizes the full emmc space
  ```shell
  sudo scripts/extract_fw.sh
  ```
- create rootfs using debootstrap
  ```shell
  sudo scripts/debootstrap.sh
  ```

- build gadget-tools
  ```shell
  sudo scripts/build_gt.sh
  ```
- create images
  ```shell
  sudo scripts/build_images.sh
  ```

The generated firmware files will be stored under the `files` directory.

### On the cloud using GitHub Actions
1. Fork this repo
2. Choose a workflow:
   - [Build](../../actions/workflows/build.yml) uses the Ubuntu 22.04 AMD64
     compatibility path.
   - [Build ARM64 Native](../../actions/workflows/build-arm64.yml) uses an
     Ubuntu 24.04 ARM64 runner and builds the ARM64 rootfs natively.
3. Click ***Run workflow***. Leave the board profile as `generic` for
   post-flash selection, or choose a board to create a preconfigured image.
4. Once the workflow is done, open its summary and download the resulting
   artifact.

## Customizations
Edit [`scripts/setup.sh`](scripts/setup.sh) to add/remove packages. Note that this script is running inside the `chroot` environment.

## Firmware Installation
> [!WARNING]  
> The following commands can potentially brick your device, making it unbootable. Proceed with caution and at your own risk!

> [!IMPORTANT]  
> Make sure to perform a backup of the original firmware using the command `edl rf orig_fw.bin`

### Prerequisites
- [EDL](https://github.com/bkerler/edl)
- Android fastboot tool
  ```
  sudo apt install fastboot
  ```

### Steps
- Enter Qualcom EDL mode using this [guide](https://wiki.postmarketos.org/wiki/Zhihe_series_LTE_dongles_(generic-zhihe)#How_to_enter_flash_mode)
- Backup required partitions

  The following files are required from the original firmware:
  
     - `fsc.bin`
     - `fsg.bin`
     - `modem.bin`
     - `modemst1.bin`
     - `modemst2.bin`
     - `persist.bin`
     - `sec.bin`

  Skip this step if these files are already present
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      edl r ${n} ${n}.bin
  done
  ```
- Install `aboot`
  ```shell
  edl w aboot aboot.mbn
  ```
- Reboot to fastboot
  ```shell
  edl e boot
  edl reset
  ```
- Flash firmware
  ```shell
  fastboot flash partition gpt_both0.bin
  fastboot flash aboot aboot.mbn
  fastboot flash hyp hyp.mbn
  fastboot flash rpm rpm.mbn
  fastboot flash sbl1 sbl1.mbn
  fastboot flash tz tz.mbn
  fastboot flash boot boot.bin
  fastboot flash rootfs rootfs.bin
  ```
- Restore original partitions
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      fastboot flash ${n} ${n}.bin
  done
  ```
- Reboot
  ```shell
  fastboot reboot
  ```

## Post-Install
- Network configuration
  
  | wlan0 | |
  | ----- | ---- |
  | ssid | Openstick |
  | password | openstick |
  | ip addr | 192.168.4.1 |

  | usb0 | |
  | ----- | ---- |
  | ip addr | 192.168.5.1 |

- Default user
  
  | | |
  | ----- | ---- |
  | username | user |
  | password | 1 |
 
- Show the recorded board, configured DTB, SIM registration, cellular-data
  state, and Wi-Fi address:

  ```shell
  /usr/local/sbin/openstick-board status
  ```

  A newly flashed generic image reports `Board profile : UNCONFIGURED`. The DTB
  shown at this point is only the boot fallback and is not a hardware detection
  result.

- Select the physical board after flashing:

  ```shell
  sudo /usr/local/sbin/openstick-board select ufi003
  sudo reboot
  ```

  Use `uz801` instead for a Yiming UZ801 v3. The selector records the physical
  board in `/etc/openstick-board`, validates that the requested DTB is installed,
  and backs up the previous configuration. Reboot when the command requests it.
  To undo the last selection:

  ```shell
  sudo /usr/local/sbin/openstick-board rollback
  sudo reboot
  ```

  `/proc/device-tree/model` and `/proc/device-tree/compatible` describe the DTB
  that was already selected; they cannot prove the physical board model. For
  that reason the builder requires an explicit profile and stores it in
  `/etc/openstick-board`.

- Interactive SSH and serial shells show the same bounded status summary at
  login. Non-interactive SSH commands, SCP, and rsync do not receive this
  output. To query only the modem and SIM:

  ```shell
  /usr/local/sbin/openstick-board sim-status
  ```

- To maximize the `rootfs` partition
  ```shell
  resize2fs /dev/disk/by-partlabel/rootfs
  ```

- To update the kernel of the `debian` image
  ```shell
  wget -O - http://mirror.postmarketos.org/postmarketos/<branch>/aarch64/linux-postmarketos-qcom-msm8916-<version>.apk \
          | tar xkzf - -C / --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null
  ```

  Specify the correct `<branch>` and `<version>` values.
