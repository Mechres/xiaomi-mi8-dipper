#!/bin/sh
# Add the Samsung EA8074 panel driver and ST FTS5 touch fix to the
# postmarketOS sdm845 kernel package in a pmaports checkout.
# usage: kernel/apply-to-pmaports.sh <pmaports-dir>
#        pmbootstrap checksum linux-postmarketos-qcom-sdm845
#        pmbootstrap build --force linux-postmarketos-qcom-sdm845
set -e
P=${1:?usage: $0 <pmaports-dir>}
K="$P/device/community/linux-postmarketos-qcom-sdm845"
D=$(cd "$(dirname "$0")" && pwd)
for N in 0001-drm-panel-add-samsung-ea8074.patch 0002-input-stmfts-bound-fts5-fifo-reads.patch; do
	cp "$D/$N" "$K/"
	grep -Fq "$N" "$K/APKBUILD" || sed -i "/^source=\"/,/^\"/ s#^\"\$#\t$N\n\"#" "$K/APKBUILD"
	grep -Fn "$N" "$K/APKBUILD"
done
C="$K/config-postmarketos-qcom-sdm845.aarch64"
grep -q '^CONFIG_DRM_PANEL_SAMSUNG_EA8074=' "$C" ||
	sed -i 's/^CONFIG_DRM_PANEL_SAMSUNG_EA8076=y$/CONFIG_DRM_PANEL_SAMSUNG_EA8074=y\n&/' "$C"
grep -n EA8074 "$C"
