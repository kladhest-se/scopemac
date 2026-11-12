Real private-command responses from DSO2D15 firmware 2.0.0(220831.00).
Both channels were enabled; only CH2 had the probe connected to the calibration output.
Each 4128-byte packet contains a 128-byte header and 4000 sample bytes. The
sample-only total is 8000; positions are 0 and 4000. Channel sample blocks are
2000 bytes, alternating CH1/CH2. Both channels have a 10x scope probe setting;
scales were 10 V/div (CH1) and 1 V/div (CH2), offsets 0 and -2.36 V.

Decoded CH1 has 3 ADC counts peak-to-peak with no square wave; CH2 has 135
ADC counts peak-to-peak and the calibration square wave. This distinguishes
real channel separation from the mirrored public-command stream.
