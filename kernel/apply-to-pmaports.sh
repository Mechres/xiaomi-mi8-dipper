#!/bin/sh
# Add the Samsung EA8074 panel driver to the postmarketOS sdm845 kernel
# package in a pmaports checkout (built in, so modules stay compatible).
# usage: kernel/apply-to-pmaports.sh <pmaports-dir>
#        pmbootstrap checksum linux-postmarketos-qcom-sdm845
#        pmbootstrap build --force linux-postmarketos-qcom-sdm845
set -e
P=${1:?usage: $0 <pmaports-dir>}
K="$P/device/community/linux-postmarketos-qcom-sdm845"
D=$(cd "$(dirname "$0")" && pwd)
N=0001-drm-panel-add-samsung-ea8074.patch
cp "$D/$N" "$K/"
grep -q "$N" "$K/APKBUILD" || sed -i "/^source=\"/,/^\"/ s#^\"\$#\t$N\n\"#" "$K/APKBUILD"
C="$K/config-postmarketos-qcom-sdm845.aarch64"
grep -q '^CONFIG_DRM_PANEL_SAMSUNG_EA8074=' "$C" ||
	sed -i 's/^CONFIG_DRM_PANEL_SAMSUNG_EA8076=y$/CONFIG_DRM_PANEL_SAMSUNG_EA8074=y\n&/' "$C"
grep -n "$N" "$K/APKBUILD" && grep -n EA8074 "$C"
