#!/bin/sh
# Debug aid: persist the kernel log to the (unused) MIUI cache partition so it
# survives a hang + watchdog reset. switch_root deletes the initramfs and the
# initramfs kill -9s every "sh" first, so run from a busybox copy on the cache
# partition itself and flush with a separate sync loop.
for _ in $(seq 1 20); do
	[ -e /dev/disk/by-partlabel/cache ] && break
	sleep 0.5
done
mkdir -p /mnt/c
mount -t ext4 /dev/disk/by-partlabel/cache /mnt/c || exit 0
B=/mnt/c/busybox
cp /bin/busybox $B
f=/mnt/c/mi8-kmsg.log
mv -f $f $f.old 2>/dev/null
setsid $B cat /dev/kmsg > $f 2>/dev/null &
setsid $B sh -c "while :; do $B sync; $B usleep 300000; done" >/dev/null 2>&1 &
# Live copy over the USB network: the host connects to port 5555 before
# switch_root and keeps receiving the kernel log until the hang.
setsid $B nc -l -p 5555 -e $B cat /dev/kmsg >/dev/null 2>&1 &
# Heartbeat through an fd opened now (the /dev path moves at switch_root),
# so the log shows when the CPUs stop even if the kernel prints nothing.
setsid $B sh -c "exec 3>/dev/kmsg; while :; do echo mi8beat >&3; $B usleep 500000; done" >/dev/null 2>&1 &
