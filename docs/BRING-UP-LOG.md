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

Still open: which bandwidth path needs a sleep vote. Something on this board
keeps using DDR or the gladiator NoC while the APSS cluster sleeps.

## 4. Regulators

The downstream DT appended to the stock MIUI kernel (board-id 55, "Dipper new
MP v2.1") keeps `pm8998_l2` (1.2 V) always on; L14 (1.8 V, panel `vddio`) and
L28 (3.3 V) are left on from boot. Describing L2 as always-on did not fix the
idle hang. Tested one at a time on top of the interconnect fix: L14 (1.8 V)
is fine and is now in the DT for the panel; describing **L28 at 3.3 V stops
the kernel before USB comes up, with no watchdog reset**. L28 is left out
until it is understood (probably the touch controller supply).

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
  were from the repo kernel (same `7.1.0-rc1-sdm845` string, different build,
  no `MODVERSIONS`), so the USB gadget modules did not work with it.
  Installing the rebuilt kernel package on the phone fixed it.
* Brightness: `/sys/class/backlight/ae94000.dsi.0`, read-back works.
* `DSI PLL(0) lock failed` at PHY probe is printed once and is harmless.

## 6. Misc observations

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
