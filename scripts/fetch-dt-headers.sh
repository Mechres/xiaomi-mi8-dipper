#!/bin/sh
# Download only what is needed to compile the device tree (qcom dts/dtsi and
# dt-bindings headers) from the sdm845-mainline kernel, instead of cloning it.
# usage: scripts/fetch-dt-headers.sh <dest-dir> [tag]
set -e
D=${1:?usage: $0 <dest-dir> [tag]}
T=${2:-sdm845-7.1-rc1-r0}
G="https://gitlab.com/api/v4/projects/sdm845-mainline%2Flinux/repository"
mkdir -p "$D" && cd "$D"
for p in arch/arm64/boot/dts/qcom include/dt-bindings; do
	curl -fsSL "$G/archive.tar.gz?sha=$T&path=$p" | tar xz --strip-components=1
done
# dt-bindings/input/linux-event-codes.h is a symlink into include/uapi
mkdir -p include/uapi/linux
curl -fsSL "$G/files/include%2Fuapi%2Flinux%2Finput-event-codes.h/raw?ref=$T" \
	-o include/uapi/linux/input-event-codes.h
echo "DT sources for $T in $D"
