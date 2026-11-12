Real USBTMC-decoded waveform responses from a DSO2D15 with firmware
2.0.0(220831.00), captured during local development on 2026-10-28.
These files contain waveform metadata and samples, not the device identity response.

Packet 1: 128 bytes; total 8099; stream position 0; 99 metadata bytes.
Packet 2: 4029 bytes; total 8099; stream position 99; 4000 sample bytes.
Packet 3: 4029 bytes; total 8099; stream position 4099; 4000 sample bytes.

The three packets complete one frame, yielding 4000 samples per enabled channel.
Do not request a fourth packet to finish this frame: it starts the next capture.

The metadata's voltage fields are 8 characters wide rather than 7. Its channel
mask is therefore at metadata offset 50, sample rate at 54, sampling multiplier
at 63, and trigger time at 69. The capture used channel scales of 0.2 and
0.5 V/div and offsets of 0.072 and -1 V. The regression test checks packet
assembly and sample count for this fixture, not calibrated voltages.

`stale-continuation.bin` was recorded in a later session that started at logical
offset 4099. It exercises recovery when a scope retains a previous transfer cursor
across connection close/open. The test discards it before receiving a fresh frame.
