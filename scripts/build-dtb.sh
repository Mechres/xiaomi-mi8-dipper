#!/bin/sh
# Compile the Mi 8 device tree. Pass wifi to build the experimental variant.
# usage: scripts/build-dtb.sh <kernel-tree> [wifi]
# <kernel-tree> can be a full sdm845-mainline checkout or the minimal tree
# made by scripts/fetch-dt-headers.sh.
set -e
S=${1:?usage: $0 <kernel-tree> [wifi]}
case ${2-} in
	'') DT=sdm845-xiaomi-dipper ;;
	wifi) DT=sdm845-xiaomi-dipper-wifi ;;
	*) printf 'usage: %s <kernel-tree> [wifi]\n' "$0" >&2; exit 2 ;;
esac
R=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$R/out"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
	-I "$S/arch/arm64/boot/dts/qcom" -I "$S/scripts/dtc/include-prefixes" -I "$S/include" \
	"$R/dts/$DT.dts" -o "$R/out/$DT.pre.dts"
dtc -I dts -O dtb -@ -q -o "$R/out/$DT.dtb" "$R/out/$DT.pre.dts"
rm -f "$R/out/$DT.pre.dts"
echo "built $R/out/$DT.dtb"
