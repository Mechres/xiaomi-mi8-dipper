# Bring-up log: Xiaomi Mi 8 (dipper) on mainline

This is the engineering narrative, in order, including the wrong turns. The
phone was debugged with no UART and no usable display; every observation came
from USB enumeration on the host, ramoops/pstore attempts, logs persisted to a
spare partition, or a shell once one was available.

## 0. Starting point

* Unlocked bootloader, stock MIUI 12 (Android 10). The modem crash-loops on
  every stock ROM (`rflm_qlnk.cpp:1082 RF stuck in QLINK start state`): a
  board-level RF fault. On SDM845 the WCN3990 Wi-Fi firmware runs on the
  modem, so Wi-Fi is impossible on this unit. Goal: a headless node over USB.
* No Mi 8 DT exists in mainline or sdm845-mainline 7.1 (`equuleus`, the Mi 8
  Pro, existed in sdm845-mainline 5.13–5.15 and was dropped). An open MR for
  dipper was an unreviewed draft.
* A minimal DT was written from `sdm845-xiaomi-beryllium-common.dtsi`: UFS,
  USB peripheral, the RPMh LDOs UFS/USB need, buttons, PMI8998 charger/FG,
  firmware carve-outs taken from the stock kernel's reserved-memory log, and
  a ramoops region at the same address as the stock kernel.

## 1. Black screen, no USB, no log

`fastboot boot` of the pmOS image: ABL accepted it, the screen went black, no
USB device ever enumerated, and the phone never rebooted. A kernel with
`rdinit=/missing panic=5` did reboot by itself, so the kernel was starting. A
custom initramfs probe never managed to write to a raw partition, and nothing
from the mainline kernel ever appeared in ramoops. Tried without effect:
`clk_ignore_unused pd_ignore_unused`, `fw_devlink.sync_state=strict`.

**Fix:** the postmarketOS wiki records that the Mi 8 Pro (`equuleus`) ran on
mainline 5.12–5.15 with USB networking and storage. Its DT was recovered from
the sdm845-mainline `sdm845/5.15` branch and diffed against ours. Every Xiaomi
SDM845 DT (beryllium, polaris, perseus, equuleus) has

```dts
&tlmm { gpio-reserved-ranges = <0 4>, <81 4>; };
```

and ours did not. These GPIOs are TrustZone-owned (fingerprint/eSE SPI); the
pinctrl driver reads every line's config while registering the GPIO chip, and
the access to a firewalled pin kills the kernel early. With the one line
added, the CDC NCM gadget enumerated ~7 s after `fastboot boot`, and UFS came
up with all LUNs.

## 2. Full boot hangs ~16 s in

With the pmOS rootfs flashed to `userdata`, every boot froze roughly 10–20 s
after `switch_root`; the hardware watchdog then reset the phone into the stock
boot partition. On the host: `NETDEV WATCHDOG ... transmit queue 0 timed out`,
then a USB disconnect.

### Getting a log

* `pmos.debug-shell` stops the initramfs before the root mount; the rootfs can
  be inspected read-only with `losetup -r -P --sector-size 4096` on
  `userdata`. Mounting it read-write there and then letting init mount it
  again through a second loop device would risk corruption, so logs went to
  the unused MIUI `cache` partition instead.
* First attempt (logger started in the debug shell, then
  `pmos_continue_boot`): the log showed a NULL dereference in `gs_close`
  (`u_serial`). That is a side effect of the debug shell's ACM gadget being
  torn down while `getty` holds it, not the real hang.
* A proper initramfs hook took four iterations, each fixing one thing:
  1. The initramfs runs `kill -9 $(pidof sh)` before `switch_root`, which
     killed the logger loop (a `#!/bin/sh` script has `argv[0]` = `sh`).
  2. A busybox copy named `mi8log` failed: busybox picks the applet from
     `argv[0]`. A copy at another path still named `busybox` works.
  3. `switch_root` deletes the initramfs, including `/bin/sync`, so nothing
     after the handover was flushed. Mounting with `-o sync` fixed that but
     was so slow the logger fell seconds behind and lost the end.
  4. Final form: busybox copied onto the `cache` partition itself, `cat
     /dev/kmsg` into a file, and a separate `sync` loop every 0.3 s.

### What the log showed

After `switch_root` at ~4.4 s: coresight, rtc, PMI8998 charger, qrtr,
zram swap at ~6 s, then silence until

```
[15.849] gcc-sdm845 100000.clock-controller: sync_state() pending due to 506a000.gmu
[15.849] sdm845-gpucc 5090000.clock-controller: sync_state() pending due to 506a000.gmu
```

which is the deferred-probe timeout. Then the hang.

### Wrong turns

* Blacklisting coresight, `stm_core`, `qcom_smbx`, `pmi8998_fg`: still hangs.
* Disabling the `swapfile` service (it never finished creating `/swapfile`):
  still hangs.
* `deferred_probe_timeout=600`: the phone survived, reached SSH and stayed up
  past the timeout at 627 s. But `deferred_probe_timeout=-1` hung again, so
  the timeout was a coincidence. A 20 s all-core load test at maximum clocks
  (78 °C) was fine, and the battery/charger state was normal.

### Idle

The boots that survived all had extra background loops (the logger's sync
loop, a heartbeat) waking the CPUs. Over SSH on a surviving boot:

* stop the loops → the phone hangs within seconds;
* disable `cpuidle/state1` on all CPUs, stop the loops → idle for 90 s, fine;
* re-enable it on CPUs 0–6, keep CPU 7 disabled (per-core power collapse
  allowed, cluster power collapse impossible) → fine, and the cluster
  domain's usage counter stops moving.

So entering `cluster_sleep_0` (PSCI `0x4100c244`, cluster power collapse plus
the RPMh sleep set) is what hangs. A first workaround deleted
`domain-idle-states` from `&cluster_pd`.

## 3. Root cause: interconnect sync_state

Cluster sleep was enabled in the initramfs-only boots too, and those idled for
minutes. So something from the rootfs had to be involved. Booting with cluster
sleep enabled and the remaining rootfs-only modules blacklisted
(`icc_bwmon camcc_sdm845 reset_qcom_pdc qcom_stats qcom_rng qcom_spmi_rradc
qrtr rtc_pm8xxx`): idle for 150 s with 140 s spent in the cluster state.
Then `modprobe icc_bwmon`: hung within 3 s, right after

```
qnoc-sdm845 17900000.interconnect: sync_state() pending due to 1436400.pmu
```

The bandwidth monitors are the last consumers of the gladiator and memory
NoCs. Until a provider reaches `sync_state()`, qcom icc-rpmh keeps the
bootloader's (maximum) bandwidth in every bucket, the sleep set included. When
bwmon probes, the providers sync, the sleep votes drop to what Linux actually
requested, and the next cluster power collapse never wakes up.

Disabling the bwmon nodes (`status = "disabled"`) made it worse: disabled
consumers do not count, so the providers synced even earlier and the phone
hung ~4 s after the gadget came up. The fix in the DT keeps the nodes enabled
but changes their `compatible`, so no driver binds and `fw_devlink` keeps the
providers waiting forever (in its default strict mode). With that, the
complete rootfs runs with cluster idle and every module loaded.

See section 10 for the actual cause (the bootloader's splash scan-out) and
why this workaround was later removed.

## 4. Regulators

The downstream DT appended to the stock MIUI kernel (board-id 55, "Dipper new
MP v2.1") keeps `pm8998_l2` (1.2 V) always on; L14 (1.8 V, panel `vddio`) and
L28 (3.3 V) are left on from boot. Describing L2 as always-on did not fix the
idle hang. Tested one at a time on top of the interconnect fix: L14 (1.8 V)
is fine and is now in the DT for the panel; describing **L28 at 3.3 V stops
the kernel before USB comes up, with no watchdog reset**. L28 is the `avdd`
of the touch controller (ST FTS `st,fts` at 0x49 on `i2c@a98000`, IRQ GPIO
31, reset GPIO 32), whose driver is not in mainline. Left out for now.

## 5. Display

* The panel node was found in the downstream DTB (board-id 55):
  `qcom,mdss_dsi_ss_notch_fhd_ea8074_cmd`, the one the bootloader names in
  `msm_drm.dsi_display0=`. 1080×2248, command mode, 4 lanes, 60 Hz, no DSC,
  brightness over DCS (0–1023).
* linux-mdss-dsi-panel-driver-generator produced a working driver. Two
  fixes were needed for the 7.1 tree: `linux/device-id/of.h` → `linux/of.h`,
  and `devm_drm_panel_add()` (newer API) → `drm_panel_add()` plus a remove
  callback, as in `panel-samsung-ea8076`. A single-object compile inside the
  pmbootstrap build tree caught the second one in seconds.
* The DT mirrors `sdm845-xiaomi-perseus` (same reset/TE GPIOs).
* First test: the panel lit up with a login prompt but USB never came up.
  Only `vmlinuz` had been replaced; the modules and initramfs on the phone
  were from the repo kernel. The kernel forces lockdown=integrity, so module
  signatures are enforced, and each build signs with its own key: the USB
  gadget modules were rejected.
  Installing the rebuilt kernel package on the phone fixed it.
* Brightness: `/sys/class/backlight/ae94000.dsi.0`, read-back works.
* `DSI PLL(0) lock failed` at PHY probe is printed once and is harmless.

## 6. Bluetooth, buttons, haptics, suspend, power

* Bluetooth: the WCN3990's BT half is a UART device with its own firmware,
  independent of the modem, so it works on this unit even though Wi-Fi
  cannot. DT as on beryllium (`vddio` S4A, `vddxo` L7, `vddrf` L17,
  `vddch0` L25, UART6 on QUP0). Firmware `qca/crbtfw21.tlv` and
  `crnv21.bin` from `linux-firmware-qca`; controller reports SOC 0x40010214.
  The bootloader passes no BD address; Xiaomi keeps it as 6 raw bytes in
  `persist/wlan_bt/bt.mac` (OUI A4:50:46), applied with `btmgmt public-addr`.
* Hall sensor: downstream `hall_key` on GPIO 124 (active low, no pull),
  exposed as `SW_LID` through gpio-keys.
* Haptics: PMI8998 LRA, `qcom,wave-play-rate-us = <4878>` (downstream and
  beryllium agree); `fftest` rumble effects upload and play.
* Display blanking (console blank) and unblank from the power key work, so
  the panel driver's off/on path works.
* s2idle with an RTC alarm: suspends and resumes cleanly.
* Power: with the USB input current limit set to 0 (`current_max` on
  `pmi8998-charger`) the phone runs from the battery and the fuel gauge
  shows the real draw: ~200 mA screen on, ~120 mA screen off at 4.26 V.
  Writing `current_max` back does not restore the original limit (the
  readback follows the hardware's adaptive limit); a reboot does.

## 7. GPU

* `&gpu` enabled with the zap shader from `vendor/firmware/a630_zap.elf`
  (a complete 32-bit ELF, usable as the `.mbn` directly).
* First boot: `adreno_request_fw` failed with -ENOENT at 0.62 s. msm is
  built in and binds the GPU before the rootfs is mounted; putting the three
  firmware files into the initramfs (mkinitfs file list) fixed it.
* Opening the render node is not enough to power it up; a surfaceless EGL
  context (`eglinfo -p surfaceless`) is. Mesa reports `FD630`, OpenGL ES
  3.2. Idle with cluster sleep stays stable with the GPU enabled.
* `gcc`/`gpucc` still report `sync_state() pending due to 506a000.gmu`: the
  GMU node never binds as a device of its own (the GPU driver uses it
  internally).

## 8. Touchscreen

* Downstream: `st,fts` at 0x49 on `i2c@a98000` (mainline `i2c14`, QUP1, needs
  `gpi_dma1`), IRQ GPIO 31, reset GPIO 32 (active low), `avdd` = L28 (3.3 V),
  `vdd` = a 1.8 V switch on GPIO 23 ("disp_vddio_vreg" downstream).
* The L28 mystery: described as fixed 3.3 V with boot-on, always-on and
  `regulator-initial-mode = HPM`, it stopped the kernel before USB (no
  watchdog reset). Described as a range with no initial mode, nothing is sent
  for it at boot and the touch driver enables it later without trouble.
  To test it live, the touch node was first bound to `stmfts` with the module
  blacklisted, then `modprobe stmfts` over SSH while streaming `/dev/kmsg`.
* The controller is an FTS5. `st,stmfts` (FTS4 protocol) fails with -110;
  `st,stmfts5` works. FTS5 support comes from David Heidelberg's and Petr
  Hodina's "Input: support for STM FTS5" series, which sdm845-mainline 7.1
  already carries in its v4 form; v6+ fix a sense-on value that the cover
  letter says broke the Mi 8, but multi-touch reporting worked here with the
  v4 code. The `chip_id`/`fw_ver` sysfs files read 0 with this version.

## 9. Audio

* ADSP: `adsp_pas` with `adsp.mbn` merged from the split `adsp.mdt/.bNN` in
  the stock `modem.img` (the ADSP does not depend on the dead modem). The
  in-kernel pd-mapper (`QCOM_PD_MAPPER`) is enough; `audio_pd` comes up and
  the APR services register. `tools/pil-squash.py` was validated by
  reproducing Xiaomi's own `a630_zap.elf` from its `.mdt` byte-for-byte;
  the first version wrongly copied the whole `.mdt`, which packs the hash
  segment right behind the headers.
* Speaker: TI TAS2557 at 0x4c on i2c5 (reset GPIO 76), QUAT MI2S SD0,
  driven by the `ti,tas2557` driver sdm845-mainline carries. Its firmware
  `tas2557_uCDSP.bin` comes from `vendor/firmware/tas2557_uCDSP_{aac,goer}.bin`
  (the two speaker-supplier variants are byte-identical).
* Codec: WCD9340 on SLIMbus as on beryllium (reset GPIO 64, IRQ GPIO 54,
  same mic bias voltages). The mic bias routing differs from beryllium:
  downstream uses AMIC1 <- MIC BIAS4 and AMIC3 <- MIC BIAS1. With
  beryllium's routing every ADC read only noise.
* Verified without a listener: play a tone on the speaker and record each
  ADC. ADC1 and ADC3 (the two built-in mics) jump from ~0.001 to 0.12-0.32
  RMS, ADC2 (headset input; the Mi 8 has no jack) and ADC4 stay at noise.
  That proves both the speaker and the microphones.

## 10. The idle hang, root-caused

* The interconnect core clears the boot-time (maximum) votes of all nodes
  only when the last provider reaches `sync_state()`. Bisecting providers
  (letting only the CPU or only the LLCC bwmon bind) therefore proved
  nothing: one unsynced provider keeps every node at maximum.
* A debug kernel parameter `icc_keep_init=<node,...>` (patch to
  `icc_sync_state()`, not part of this repo) let chosen nodes keep their
  boot votes. With the display, GPU, audio and touch enabled by then,
  keeping no node at all no longer hung: the extra consumers changed the
  picture.
* The same DT with only `&mdss` disabled hangs ~10 s after boot. The
  bootloader's continuous-splash scan-out is the orphaned DDR user; with the
  display driver bound it is owned by Linux. The bwmon workaround was
  removed; the DT now has a comment to keep `&mdss` enabled.

## 11. Earpiece, UCM, and the silent microphones

* Earpiece: WCD9340 EAR via SLIMBUS_0_RX -> SLIM RX0 (AIF1_PB) -> RX INT0
  -> CLSH DSM -> EAR PA. Verified the same way as the speaker: a tone on the
  earpiece shows up at 0.18 RMS on ADC1. Together with the speaker test this
  maps the mics: ADC3 is the bottom mic (next to the speaker), ADC1 the top.
* After an unrelated reboot every capture read exact digital zeros, but only
  while no SLIMbus playback was running. The codec's `MCLK` DAPM supply is
  only reachable through the machine routing `RX_BIAS <- MCLK` (playback);
  nothing on the capture path depends on it, so a capture-only stream left
  the codec clock off. The first test had passed only because an earlier
  playback left MCLK running. Fix: `"ADC1".."ADC3", "MCLK"` in
  `audio-routing`.
* `configs/ucm2` adds an ALSA UCM profile (HiFi: Speaker on hw:0,0,
  Earpiece on hw:0,1, Mic/Mic2 on hw:0,2), self-tested through `alsaucm`.

## 12. Charge limit

The phone is meant to stay on USB permanently, which keeps the battery at
100 %. The `qcom_smbx` charger has no charge-limit property, but writing its
`status` property sets USBIN_SUSPEND (`Unknown` suspends, any other value
resumes): the phone then runs from the battery while USB data keeps
working, and the input current limit comes back by itself on resume. (Writing
`current_max` instead also works but its readback is the AICL result, not
the written value.) `tools/charge-limit` uses that to hold 60-80 %, with a
failsafe below 20 % or 3.5 V, and resumes charging whenever it stops.
Measured while suspended with the display off: about 40 mA from the battery.

## 13. Package pinning and the 1970 clock

* `apk add ./kernel.apk` pins the package as `name><checksum` in
  `/etc/apk/world`. `apk upgrade -s --available` showed that this does not
  stop a downgrade to the repository kernel (no panel driver, modules signed
  with another key). An exact `name=version` constraint does.
* Services installed while the clock still said 1970 never started after a
  reboot. OpenRC noticed clock skew against files dated at image build time
  and set its deptree mtime to the build date, so newer-but-1970 init
  scripts were never picked up. Fixed by setting the time with busybox
  `ntpd` once (the RTC is not writable; `swclock-offset` stores the offset at
  shutdown), touching the 1970-dated files and `rc-update -u`.

## 14. Misc observations

* `psci: [Firmware Bug]: failed to set PC mode: -3` at boot; the kernel then
  uses OSI mode, which works.
* `coresight-tmc 6048000.etr: probe ... failed with error -13`: debug blocks
  are locked on retail units. Harmless.
* `swapfile` from postmarketOS was removed from the default runlevel; zram is
  enough with 6 GB.
* Busybox `dmesg` has no `-w`; use `cat /dev/kmsg`.
* A single `/dev/tcp` connect attempt made during the USB network handover can
  block for ~2 minutes in SYN retries; give each attempt a timeout when
  polling for SSH.
