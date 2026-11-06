#!/bin/sh
# Compile dts/sdm845-xiaomi-dipper.dts into out/sdm845-xiaomi-dipper.dtb.
# usage: scripts/build-dtb.sh <kernel-tree>
# <kernel-tree> can be a full sdm845-mainline checkout or the minimal tree
# made by scripts/fetch-dt-headers.sh.
set -e
S=${1:?usage: $0 <kernel-tree>}
R=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$R/out"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
	-I "$S/arch/arm64/boot/dts/qcom" -I "$S/scripts/dtc/include-prefixes" -I "$S/include" \
	"$R/dts/sdm845-xiaomi-dipper.dts" -o "$R/out/dipper.pre.dts"
dtc -I dts -O dtb -@ -q -o "$R/out/sdm845-xiaomi-dipper.dtb" "$R/out/dipper.pre.dts"
rm -f "$R/out/dipper.pre.dts"
echo "built $R/out/sdm845-xiaomi-dipper.dtb"
