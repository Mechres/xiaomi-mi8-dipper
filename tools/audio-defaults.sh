#!/bin/sh
# Default ALSA routing for the Mi 8: MultiMedia1 (hw:0,0) plays on the
# bottom speaker (TAS2557 on QUAT MI2S), MultiMedia2 (hw:0,1) records the
# main microphone (WCD9340 AMIC1 -> ADC1 -> DEC0 -> SLIM TX0). ADC3 is the
# second microphone. Run once, then `alsactl store` and enable the alsa
# service (`rc-update add alsa boot`) to keep it across reboots.
a() { amixer -q -c0 cset name="$1" "$2"; }
a "QUAT_MI2S_RX Audio Mixer MultiMedia1" 1
a "MultiMedia2 Mixer SLIMBUS_0_TX" 1
a "AIF1_CAP Mixer SLIM TX0" 1
a "CDC_IF TX0 MUX" DEC0
a "ADC MUX0" AMIC
a "AMIC MUX0" ADC1
a "DEC0 Volume" 84
a "ADC1 Volume" 12
