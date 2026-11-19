# Experimental Wi-Fi on a Mi 8 with a working modem

The `wifi` device tree enables the modem remote processor and the WCN3990
Wi-Fi node with the downstream dipper supply assignments. Start with a
Mi 8 whose Wi-Fi works in Android. The original port's test phone had a
faulty modem. Keep the base boot image and its matching signed modules
available while testing this variant.

## Prepare firmware and RMTFS

Use the `modem.img` from the matching stock ROM or a read-only copy of the
phone's `modem` partition. Its FAT filesystem has the files under `/image`.
Keep the extracted firmware and generated board binary local.

1. Merge `modem.mdt` and `modem.b*` with `tools/pil-squash.py modem.mdt modem.mbn`.
   In the target Linux root, place `modem.mbn`, `mba.mbn`, `wlanmdsp.mbn`,
   `modemr.jsn`, and `modemuw.jsn` under `/usr/lib/firmware/qcom/sdm845/Xiaomi/dipper/`.
2. Create a `board-2.bin` from the stock `bdwlan.bin` using `ath10k-bdencoder`
   from the QCA repository. The tested phone used the board names
   `bus=snoc,qmi-board-id=ff,qmi-chip-id=30214` and `bus=snoc,qmi-board-id=ff`
   for that payload. With both files in the same directory, pass the
   following JSON to `ath10k-bdencoder -c dipper-board.json -o board-2.bin`
   and place the result at `/usr/lib/firmware/ath10k/WCN3990/hw1.0/dipper/board-2.bin`.
   [QCA board data encoder](https://github.com/qca/qca-swiss-army-knife/tree/6df4dae3e2f5e4c2903f3cafd40996fc1b3639ce/tools/scripts/ath10k)

   ```json
   [
     {
       "names": ["bus=snoc,qmi-board-id=ff,qmi-chip-id=30214", "bus=snoc,qmi-board-id=ff"],
       "data": "bdwlan.bin"
     }
   ]
   ```

3. Install `linux-firmware-ath10k`, `qrtr`, `rmtfs-openrc`, and `iw` in the
   target root. Set `rmtfs_avoid_writing="true"` in `/etc/conf.d/rmtfs` and
   leave `rmtfs_files_path` unset so RMTFS uses the existing radio partitions.
   Add `rmtfs` to the OpenRC default runlevel with `rc-update add rmtfs default`.
   The tested daemon ran with `-s -P -r` to coordinate the modem and use the
   partitions read-only.

## Build and test the optional tree

Build `out/sdm845-xiaomi-dipper-wifi.dtb` with
`scripts/build-dtb.sh /tmp/sdm845-dt wifi`. Copy it into the local device
package as `sdm845-xiaomi-dipper.dtb`, run `pmbootstrap checksum
device-xiaomi-dipper`, and generate a boot image using the prepared rootfs
and matching kernel modules. Use `fastboot boot` for the trial.

After the trial boots, check `rc-service rmtfs status` and `iw dev`. In
the headless setup, run `ip link set wlan0 up` and `iw dev wlan0 scan`.
With NetworkManager running, use `nmcli device wifi rescan ifname wlan0`
and `nmcli device wifi list ifname wlan0`.

On one Mi 8, the Wi-Fi variant scanned for access points, associated, received
an IPv4 DHCP lease, and passed local traffic after an explicit reconnect and
after a normal reboot. Wi-Fi traffic recovered after three RTC-woken `s2idle`
cycles, with RMTFS still running after each wake.

Stopping RMTFS during earlier testing was followed by a full phone reboot.
Use a normal reboot when switching variants.
