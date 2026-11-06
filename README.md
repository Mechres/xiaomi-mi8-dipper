# Xiaomi Mi 8 (dipper): Headless Mainline Linux

[![SoC: Qualcomm SDM845](https://img.shields.io/badge/SoC-Qualcomm%20SDM845%20(Snapdragon%20845)-blue.svg)](#hardware)
[![Kernel: mainline 7.1](https://img.shields.io/badge/Kernel-sdm845--mainline%207.1-green.svg)](#status)
[![OS: postmarketOS](https://img.shields.io/badge/OS-postmarketOS%20edge-purple.svg)](#installing)

A device tree and postmarketOS device package for running **mainline Linux** on
the **Xiaomi Mi 8 (`dipper`)** as a headless node, reachable over USB
networking with SSH, with the built-in AMOLED panel as a text console.
Touch, modem and Wi-Fi are not used.

No Mi 8 device tree exists in mainline or in the sdm845-mainline tree. This
one was written for this phone and debugged without a UART. Three
non-obvious fixes were needed before it would boot and stay up; they are
summarised under [Key findings](#key-findings), and the full investigation is
in [docs/BRING-UP-LOG.md](docs/BRING-UP-LOG.md).

The unit this was developed on has a dead RF transceiver (the modem
crash-loops with `RF stuck in QLINK start state` on any stock firmware), and on
SDM845 the Wi-Fi firmware runs on the modem, so Wi-Fi was never possible on it.
Nothing in this port depends on that fault.

---

## Hardware

| | |
|---|---|
| **SoC** | Qualcomm Snapdragon 845 **SDM845** (4× Kryo 385 Gold + 4× Silver, aarch64) |
| **RAM** | 6 GB (5.5 GB usable) |
| **Storage** | UFS 2.1, 128 GB (`sda`–`sdf` LUNs) |
| **PMICs** | PM8998, PMI8998, PM8005 |
| **Board** | `qcom,board-id = <55 0>` (downstream name "Dipper new MP v2.1"), `msm-id 321 0x20001` |
| **Panel** | Samsung EA8074 AMOLED, 1080×2248, DSI command mode (driver in `kernel/`) |
| **Bootloader** | Xiaomi ABL, unlocked, fastboot; accepts a v0 boot image with an appended DTB |
| **Debug UART** | `uart9` (GPIO 4/5, 1.8 V); test points not located, **not used** for this port |

## Status

| Feature | State |
|---|---|
| Boots from the boot partition | ✅ kernel 7.1.0-rc1-sdm845 (postmarketOS `linux-postmarketos-qcom-sdm845`) |
| All 8 CPUs, cpufreq (qcom-cpufreq-hw) | ✅ up to 2.65 GHz big / 1.77 GHz little |
| CPU idle incl. cluster power collapse | ✅ (needs the interconnect fix below) |
| UFS storage | ✅ rootfs on `userdata` |
| USB networking (CDC NCM gadget) + SSH | ✅ phone `172.16.42.1`, host `172.16.42.2` |
| Charger / fuel gauge (PMI8998) | ✅ `pmi8998-charger`, `qcom-battery` report correctly |
| RTC, thermal zones | ✅ |
| Reboot / reboot to fastboot from Linux | ✅ (see `tools/reboot_to.c`) |
| Display (DSI0, EA8074 panel, DRM/fbcon) | ✅ text console, console blanking/unblank, DCS brightness via `/sys/class/backlight` |
| Bluetooth (WCN3990 on UART6) | ✅ firmware from `linux-firmware-qca`, scans BR/EDR + LE; factory address via `tools/bt-address.start` |
| Buttons, hall sensor (lid switch), vibrator | ✅ power, Vol Up/Down; `SW_LID` on GPIO 124; `qcom,spmi-haptics` force feedback |
| Suspend to idle (s2idle) | ✅ RTC wake tested |
| GPU (Adreno 630, Freedreno) | ✅ OpenGL ES 3.2 / GL via Mesa (`FD630`), devfreq 257–710 MHz; needs the zap shader from your stock ROM |
| Touchscreen (ST FTS5, i2c14) | ✅ multi-touch through `stmfts` (`st,stmfts5`, FTS5 support from sdm845-mainline 7.1) |
| Audio: speaker (TAS2557), 2 microphones (WCD9340) | ✅ ADSP + q6 routing; see `tools/audio-defaults.sh` |
| Modem, Wi-Fi, SLPI/CDSP, cameras | ❌ disabled in the DT (Wi-Fi needs the modem on SDM845) |

---

## Key Findings

These are the three things that made the difference. Each one took a
different debugging technique to find; see the bring-up log for the evidence.

1. **Reserve the TrustZone GPIOs.** Every Xiaomi SDM845 board needs
   `&tlmm { gpio-reserved-ranges = <0 4>, <81 4>; }`. Without it, the pinctrl
   driver touches TZ-owned pins while registering the GPIO chip, the kernel
   dies before USB comes up, and you get a black screen with no USB device and
   no log. Found by diffing against the old Mi 8 Pro (`equuleus`) DT that
   sdm845-mainline carried until 5.15.

2. **Cluster idle hangs once the NoC votes drop.** With the full rootfs,
   the phone hard-hung ~16 s into every boot (watchdog reset, or a silent
   freeze). It is not the deferred-probe timeout that fires at the same
   moment (`deferred_probe_timeout=-1` still hangs). Proven live over SSH: the
   phone runs while something keeps the CPUs awake, dies seconds after they
   are allowed to idle, and survives if one core's deep idle state is
   disabled (so the cluster can never power-collapse).

3. **Root cause: the bootloader's splash scan-out.** The bootloader leaves
   the display controller (MDSS) fetching its splash screen from DDR. As long
   as the interconnect providers have not reached `sync_state()`, they keep
   their maximum boot-time bandwidth votes (the interconnect core drops them
   for all nodes at once, when the last provider syncs), and the stray
   scan-out is harmless. Once they sync and the cluster power-collapses,
   nothing in Linux votes for that memory path and the SoC hangs. With the
   display driver bound (Linux owns MDSS) it does not happen. Found by
   bisecting with a debug kernel parameter that keeps chosen nodes' boot
   votes; the decisive test was the same DT with only `&mdss` disabled,
   which hangs ~10 s after boot. Earlier this DT carried a workaround that
   kept the bandwidth monitors from binding so the providers never synced;
   it is no longer needed. **Keep the display enabled.**

## Installing

You need: an unlocked Mi 8, `pmbootstrap`, `fastboot`, `dtc` and `cpp` on the
host. **This erases `userdata` and replaces `boot`.** To go back, flash the
stock fastboot ROM with its `flash_all.sh` (never `flash_all_lock.sh`).

```sh
# 1. device tree (only the DT sources are downloaded, not a kernel clone)
scripts/fetch-dt-headers.sh /tmp/sdm845-dt
scripts/build-dtb.sh /tmp/sdm845-dt          # -> out/sdm845-xiaomi-dipper.dtb

# 2. device package in a local pmaports checkout
pmbootstrap init                              # pick any device, channel edge
A=$(pmbootstrap config aports)
P=$A/device/testing/device-xiaomi-dipper
mkdir -p "$P"
cp pmaports/device-xiaomi-dipper/* out/sdm845-xiaomi-dipper.dtb "$P"/
pmbootstrap checksum device-xiaomi-dipper
pmbootstrap config device xiaomi-dipper
pmbootstrap config ui none                    # headless

# 3. kernel with the EA8074 panel driver (built in; the DT enables the
#    display and expects it)
kernel/apply-to-pmaports.sh "$A"
pmbootstrap checksum linux-postmarketos-qcom-sdm845
pmbootstrap build --force linux-postmarketos-qcom-sdm845

# 4. build and flash (phone in fastboot: Vol Down + Power)
pmbootstrap install
pmbootstrap flasher flash_rootfs              # rootfs -> userdata
pmbootstrap flasher flash_kernel              # boot.img -> boot
fastboot reboot
```

To try a kernel or DT without touching the boot partition, use
`pmbootstrap flasher boot` (or `fastboot boot <image>`) instead of
`flash_kernel`.

After boot the phone appears as a USB network adapter. It serves DHCP, so the
host gets `172.16.42.2`; then `ssh <user>@172.16.42.1`.

### Fastboot quirks seen on this unit

* After `fastboot flash`, the bootloader sometimes stops answering the next
  command. Power-cycle back into fastboot (hold Power + Vol Down) and retry.
* On some host ports fastboot hangs at the first transfer; a USB 2.0 port or
  hub works reliably.
* Holding Vol Down while Linux runs can reset the phone (PON resin).

## After Installing

* **Pin the kernel.** The display driver lives in your locally built
  `linux-postmarketos-qcom-sdm845`. A plain `apk upgrade` would replace it
  with the repository build, which has no panel driver. Also, the kernel
  enforces module signatures (lockdown is forced to integrity) and every
  build signs with its own key: a flashed `vmlinuz` from one build cannot
  load the modules of another, which first shows up as a missing USB
  gadget. On the phone:
  `apk add "linux-postmarketos-qcom-sdm845=<your version>"` writes the pin
  to `/etc/apk/world`.
* **Bluetooth:** `apk add linux-firmware-qca bluez`, and install
  `tools/bt-address.start` as `/etc/local.d/bt-address.start` so the
  controller uses the factory address from `persist` (read-only mount).
* **Internet over USB:** NAT on the host plus, on the phone,
  `ip route replace default via <host-ip> dev usb0` and a `resolv.conf`.
  The USB subnet and the host-side MAC can be changed with
  `/etc/unudhcpd.conf` (`unudhcpd_host_ip`, `unudhcpd_client_ip`) and
  `/etc/deviceinfo` (`deviceinfo_usb_network_host_addr`); both are copied
  into the initramfs by mkinitfs.

* **GPU firmware.** `apk add linux-firmware-qcom` provides `a630_sqe.fw`
  and `a630_gmu.bin`. The zap shader is signed by Xiaomi and is not
  redistributable: take `firmware/a630_zap.elf` from the vendor image of
  your stock fastboot ROM (`simg2img vendor.img vendor.raw`, then
  `debugfs -R "dump /firmware/a630_zap.elf a630_zap.mbn" vendor.raw`) and
  install it as `/lib/firmware/qcom/sdm845/Xiaomi/dipper/a630_zap.mbn`. msm
  is built in and loads the firmware before the rootfs is mounted, so also
  copy `configs/mkinitfs-gpu.files` to `/etc/mkinitfs/files/` and run
  `mkinitfs`, then flash the regenerated `/boot/boot.img`.

* **Audio firmware** (from your own stock fastboot ROM, not redistributable):
  the ADSP image is split in `modem.img` (FAT): `mcopy -i modem.img
  ::/image/adsp.* .`, merge it with `tools/pil-squash.py adsp.mdt
  adsp.mbn` and install it as
  `/lib/firmware/qcom/sdm845/Xiaomi/dipper/adsp.mbn`. The speaker amp needs
  `/lib/firmware/tas2557_uCDSP.bin`, which is `firmware/tas2557_uCDSP_aac.bin`
  (or the identical `_goer.bin`) from `vendor.img`. Then run
  `tools/audio-defaults.sh` for the mixer routing.

Measured power (battery current with the USB input limit set to 0, so the
phone runs from the battery): **~200 mA with the screen on, ~120 mA with it
off** at 4.26 V.

## Display

The panel driver was generated with
[linux-mdss-dsi-panel-driver-generator](https://github.com/msm8916-mainline/linux-mdss-dsi-panel-driver-generator)
from the panel node in the device tree appended to the stock MIUI kernel
(board-id 55, `qcom,mdss_dsi_ss_notch_fhd_ea8074_cmd`), then adapted to the
7.1 DRM panel API and to the conventions of the in-tree `panel-samsung-ea8076`
driver (Xiaomi Mi Mix 3, the closest relative). The DT side mirrors the
upstream `sdm845-xiaomi-perseus` DT: reset on GPIO 6, TE on GPIO 10
(`mdp_vsync`), `vddio` from L14, `vci` from a fixed regulator switched by
GPIO 35, DSI `vdda` from L26 and the PHY from L1.

The driver is built in (`=y`), like the rest of DRM/msm in this kernel.
Because modules are signature-checked with a per-build key, never swap only
`vmlinuz`: install the rebuilt kernel package so `vmlinuz`, modules and
initramfs come from one build.

## Debugging Without a UART

The bring-up was done with no serial console and no display. Techniques that
worked, all in `tools/`:

* **`reboot_to.c`**: a 10-line static binary calling
  `reboot(LINUX_REBOOT_CMD_RESTART2, "bootloader")`, so a running kernel can
  send the phone back to fastboot without touching the buttons. Build with
  `aarch64-linux-musl-gcc -static -O2 -o reboot_to reboot_to.c`.
* **`99-mi8-kmsglog.sh`**: a postmarketOS initramfs hook (append it as an
  extra cpio to the ramdisk) that copies `/dev/kmsg` onto the stock `cache`
  partition with a 0.3 s sync loop, plus a live copy on TCP port 5555. It
  survives `switch_root`, so the log of a hang in the real system can be read
  back on the next boot. Two traps it works around: the initramfs `kill -9`s
  every process named `sh` before `switch_root`, and `switch_root` deletes the
  initramfs, including `/bin/sync`.
* **`pmos.debug-shell`** on the kernel command line stops the initramfs in a
  telnet shell (`172.16.42.1:23`) before the root partition is mounted. Do not
  `pmos_continue_boot` from it: tearing down its ACM serial gadget oopses
  `u_serial` and contaminates the test.
* **Live experiments over SSH** beat reboot rounds: toggling
  `/sys/devices/system/cpu/cpu*/cpuidle/state1/disable`, `modprobe`ing one
  module at a time, and reading `state_synced` and
  `/sys/kernel/debug/pm_genpd/*/idle_states` narrowed the idle hang down in
  minutes, where each blind reboot cost a manual power cycle.

## Repository Layout

```
dts/sdm845-xiaomi-dipper.dts           device tree (GPL-2.0)
kernel/0001-drm-panel-add-samsung-ea8074.patch  panel driver (GPL-2.0)
kernel/apply-to-pmaports.sh            add it to the pmOS kernel package
pmaports/device-xiaomi-dipper/         postmarketOS device package
scripts/fetch-dt-headers.sh            download DT sources from sdm845-mainline
scripts/build-dtb.sh                   compile the DTB
tools/reboot_to.c                      reboot into fastboot from Linux
tools/99-mi8-kmsglog.sh                persistent + live kernel log hook
tools/bt-address.start                 set the factory Bluetooth address
configs/mkinitfs-gpu.files             GPU firmware into the initramfs
tools/pil-squash.py                    merge split .mdt/.bNN firmware into .mbn
tools/audio-defaults.sh                default speaker/mic mixer routing
docs/BRING-UP-LOG.md                   full investigation, dead ends included
```

## Credits

* [sdm845-mainline](https://gitlab.com/sdm845-mainline/linux) and
  postmarketOS for the kernel and the SDM845 groundwork.
* The `sdm845-xiaomi-equuleus` (Mi 8 Pro) DT from sdm845-mainline 5.13–5.15,
  and the upstream `beryllium`/`polaris` DTs, as references.
* Downstream values (regulators, panel, reserved memory) were read from the
  device tree appended to the stock MIUI kernel.

## License

MIT for scripts and documentation (see `LICENSE`). The device tree is
GPL-2.0, as marked in its SPDX header.
