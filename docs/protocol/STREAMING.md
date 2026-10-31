# Streaming

USB descriptors, endpoints, clock, feedback, rates and channel maps that the
dext's audio path (Phase 6) must handle. Facts link to
[LEDGER.md](LEDGER.md) ids.

**Coverage:** GoXLR Mini (1220:8FE4, `bcdDevice` 0x0100) only; firmware
version unknown, since reading it needs DCP command 0x80F:0 (SPEC.md §9). The full GoXLR
(1220:8FE0) has not been connected yet. Everything here is **observed** on
hardware unless marked otherwise
([baseline-8fe4.md](../hardware/baseline-8fe4.md)).

## Device and configuration (L-100)

- USB 2.0 high speed. Device class EF/02/01 with an Interface Association
  Descriptor grouping all three interfaces as one UAC2 function (01/00/20).
- One configuration, `bmAttributes` 0xC0 (self-powered), `bMaxPower` 0.
- No serial number string (`iSerialNumber` 0).

| Interface | Alt | Class | Endpoint | Role |
|---|---|---|---|---|
| 0 | 0 | Audio Control (01/01/20) | 0x81 IN interrupt, 6 bytes, `bInterval` 8 (16 ms) | Topology, clock, notifications |
| 1 | 0 | Audio Streaming (01/02/20) | none | Playback idle |
| 1 | 1 | Audio Streaming | 0x08 OUT isochronous, async, data; 280 bytes, `bInterval` 1 | Playback, 10 ch |
| 2 | 0 | Audio Streaming | none | Capture idle |
| 2 | 1 | Audio Streaming | 0x88 IN isochronous, async, **implicit feedback**; 588 bytes, `bInterval` 1 | Capture, 21 ch |

There is **no vendor-specific interface**. The DCP vendor requests go to
interface 0 (L-050), which is the Audio Control interface itself (L-100). This
constrains Phase 4 matching (ADR 0004).

## Topology (L-104, L-105)

```
Clock source 41 "Internal" (internal, programmable) ─▶ Clock selector 40 (1 input)
                                                          │ clocks every terminal
Playback:  IT 2  USB streaming, 10 ch ─▶ FU 10 ─▶ OT 20 speaker (0x0301)
Capture:   IT 1  microphone (0x0201), 21 ch ─▶ FU 11 ─▶ OT 22 USB streaming
```

- Clock source 41: frequency control read/write, validity read-only.
  Selector 40: read/write.
- The feature units declare **no controls** on any channel. There is no UAC2
  volume or mute, so the device mixer is reachable only through DCP.
- The AC header declares a read-only latency control. The terminals don't
  declare one, and the device STALLs `GET CUR` of terminal latency.

## Formats and rates (L-102, L-103, L-104, L-107)

- Format Type I PCM, 4-byte subslots, 24-bit resolution, in both directions.
  CoreAudio shows it as 24-bit signed integer, high-aligned in 32 bits.
- **48 kHz only** (CoreAudio's available rates come from the device's
  sampling-frequency `RANGE`).
- Packet sizing, every microframe (`bInterval` 1 at high speed):
  - 48 kHz is 6 frames per microframe on average.
  - The maximum packet holds 7 frames in both directions: 280 = 7 × 40
    bytes out, 588 = 7 × 84 bytes in. That leaves room for one extra frame
    when the device clock runs fast.
- Both endpoints' CS_ENDPOINT descriptors: `bLockDelayUnits` 2 (decoded PCM
  samples), `wLockDelay` 8; no pitch or data-overrun controls.

## Clock and feedback (L-103, L-110)

- Both directions are asynchronous, and the device clock is the master.
- There is no explicit feedback endpoint: 0x88 is marked as implicit feedback
  data. The host derives the playback frame count from the capture stream:
  each OUT microframe carries as many frames as the matching IN microframe
  delivered. This confirms L-046 (inferred in Phase 1 from the Windows
  driver).
- Measured over 30 s under Apple's driver, the device clock ran at
  48000.85 Hz, **+17.7 ppm** against the Mac's host clock, with no timeline
  discontinuities.
- **Consequence for Phase 6:**
  - the dext must run the capture stream whenever playback runs;
  - it must size OUT packets from IN packet frame counts;
  - its zero timestamps must follow the device clock, not the host clock.

## Start sequence used by Apple's driver (L-104, L-112)

On every attach, `usbaudiod`:
1. reads the clock source's sampling frequency (`CUR`: 48000);
2. sets selector 40 to input 1;
3. sets the clock source to 48000 (`SET CUR`);
4. asks for the terminals' latency, which the device STALLs.

Step 3 is the same class request goxlr-utility uses when it recovers an
uninitialised device (L-055).

## Channel maps (L-106)

Channel names come from the device's string descriptors (UAC2
`iChannelNames`). CoreAudio channels are 1-based; the INF's
`SoundDeviceProfiles` `ChannelIndex` is 0-based.

**Playback (10 ch).** Every channel is in the Windows INF.

| CoreAudio ch | USB channel name | Windows device (INF) |
|---|---|---|
| 1–2 | System L/R | System |
| 3–4 | Game L/R | Game |
| 5–6 | Chat L/R | Chat |
| 7–8 | Music L/R | Music |
| 9–10 | Sample Source Mix L/R | Sample |

**Capture (21 ch).** Only channels 1–6 are in the INF.

| CoreAudio ch | USB channel name | Windows device (INF) |
|---|---|---|
| 1–2 | Broadcast Stream Mix L/R | Broadcast Stream Mix |
| 3–4 | Chat Mic Mix L/R | Chat Mic |
| 5–6 | Sample Source Mix L/R | Sample |
| 7–8 | GoXLR-Mic L/R (processed) | not exposed |
| 9–10 | GoXLR-System L/R | not exposed |
| 11–12 | GoXLR-Game L/R | not exposed |
| 13–14 | GoXLR-Chat L/R | not exposed |
| 15–16 | GoXLR-Music L/R | not exposed |
| 17–18 | GoXLR-Line In L/R | not exposed |
| 19–20 | GoXLR-Console (SPDIF) L/R | not exposed |
| 21 | GoXLR-Dry Mic (unprocessed), mono | not exposed |

Capture channels 9–16 are raw taps of playback 1–8. They return the played
samples bit-transparently with a fixed 15-frame loop (L-108), so they give
Phase 6 an exact A/B test.

## Latency (L-107, L-108)

- **CoreAudio, under Apple's driver:**
  - device latency 14 frames each way, safety offset 14 frames each way;
  - `usbaudiod` logs 250 µs safety offsets once its low-latency mode is on;
  - buffer range 15–4096 frames, default 512.
- **Loop latency** (playback to raw tap) on the HAL sample timeline: **15
  frames**, identical on every channel and across runs. This excludes the
  reported device latency and safety offsets.

## Open

- What one `IOUSBIsochronousFrame` entry covers at high speed (STATUS open
  question); packets here are per microframe.
- The full GoXLR's descriptors (8FE0).
- The contents of interrupt messages on 0x81: Apple's driver polls the
  endpoint but logs nothing, so this waits for Phase 4.
- Rates other than 48 kHz on other firmware.
