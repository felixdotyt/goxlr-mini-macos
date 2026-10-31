# GoXLR command catalog

Feature → DCP command map for the GoXLR (PID 0x8FE0) and GoXLR Mini (0x8FE4),
from static analysis of the official app v1.6.4.014 and a cross-check against
goxlr-utility. Transport, framing and status handling are in
[LEDGER.md](LEDGER.md) (L-020 to L-057).

**Sources:**
- **App** = the official app's call site, with its Evidence ID prefix. The full
  IDs are in `~/dev/goxlr-re/evidence/dcp-command-calls.md` and in the bundle
  `rea-app-v1.6.4.014.bundle.json`.
- **GU** = `goxlr-utility@49ab4e4` (MIT). Paths are under `usb/src/` unless
  given in full.

**Class:**
- **derived** = seen in the official app's code; a string names the action, or
  the layout is plain.
- **inferred** = the meaning comes from reasoning or from GU alone.
- **unknown** = not established.

Nothing here has been observed on hardware yet.

## Opcode

Opcode = `(category << 12) | index`, carried in the first word of the 16-byte
request header (L-023). Categories below 0x800 are generic DICE ones; 0x800 and
above are GoXLR-specific (L-057).

## Generic DICE commands

| Opcode | Name | Request | Reply | Class | Source |
|---|---|---|---|---|---|
| 0:0 | Reset / flush | — | — | derived | App ev_106dc2e0…; GU `commands.rs:36-68` |
| 0:1 | Supports DCP category | u16 category | u16, 1 = supported | inferred | GU `device/base.rs:50-55`; the app's probe routine `0x61f000` is not yet decoded |
| 0:2 | System info | — | ≥ 112 bytes (layout unknown) | derived | App ev_966cf0a0… |
| 1:0, 2:0, 3:0, 4:0 | Peaks / mixer / router / NVM caps | — | 4 / 8 / 12 / 16 bytes | derived | App ev_966cf0a0…; category names per the app's strings (L-056) |
| 4:1 | NVM segment info | u32 segment index | 24 bytes | derived | App ev_966cf0a0… |

The app runs these once after opening the device (L-033). goxlr-utility never
sends them, so the GoXLR evidently doesn't require them (inferred).

## GoXLR commands

| Opcode | Name | Index | Request payload | Reply | Class | App | GU |
|---|---|---|---|---|---|---|---|
| 0x800:0 | Get input state | 0 | — | 12 bytes: u32 button bitfield (app masks 30 bits), 4 × i8 encoders (Pitch, Gender, Reverb, Echo), 4 × u8 faders A–D | derived (length, mask); layout from GU | ev_edd08e2cbb8d, ev_698c4a9d7915 | `device/base.rs:254-283` |
| 0x801:0 | Set effect parameters | 0 | N × {u32 key, i32 value} | — | derived | ev_642428624a82 | `device/base.rs:230-240`; keys below |
| 0x802:i | Set scribble strip | fader 0–3 | 1024 bytes: 128 × 64 px, 1 bit per pixel, column-major in 8-row bands | — | derived (command); layout from GU | ev_10e749e5a1c9 | `scribbles/src/lib.rs:223-243` |
| 0x803:0 | Set colour map | 0 | 520 bytes (328 on firmware before the "1.3.40" layout); 4 bytes per colour, B G R A | — | derived (520) | ev_2b438bb4fabf | `device/base.rs:152-160`; `colouring.rs:79-164` |
| 0x804:i | Set routing row | input 0–17 | 26 bytes = 13 × u16 (22 bytes before Mix2 firmware) | — | derived (size, index range) | ev_6a6642e85d23 | `routing.rs:21-102` |
| 0x805:i | Set fader assignment | fader 0–3 | u32 channel id | — | derived ("Fader Association") | ev_1bcac5ab5b79 | `device/base.rs:121-125` |
| 0x806:i | Set volume | `(bank << 4) \| channel`; bank 0 = channel volume, bank 1 = submix volume | u8, 0–255 (app: percent × 2.55) | — | derived (shape); bank meaning from GU | ev_a034778e8df8, ev_90f16461721f | `device/base.rs:127-130, 193-196` |
| 0x808:0 | Set button LED states | 0 | 24 bytes, one per button bit number | — | derived ("Button State") | ev_9da2425cff64 | `buttonstate.rs:6-12` |
| 0x809:i | Set channel state (mute) | channel | u8, 1 = muted | — | derived (shape); meaning from GU | ev_a500f5a01e50 | `device/base.rs:142-145` |
| 0x80A:i | Set encoder value | encoder 0–3 | i8 | — | derived | ev_81a2ba2ae1b4 | `device/base.rs:132-135` |
| 0x80B:0 | Set mic parameters | 0 | N × {u32 key, u32 value} | — | derived (keys named MIC_TYPE, MIC_GAIN_DYNAMIC, MIC_GAIN_CONDENSER, MIC_GAIN_TRS) | ev_a4380ea774ff, ev_77c24bcc02cb, ev_4d16385550db, ev_da3550f2c005 | `device/base.rs:209-252` |
| 0x80C:0 | Get mic level | 0 | — | u16 | derived (feeds the mic meter) | ev_ee229793f495, ev_121f4cab8854 | `device/base.rs:225-228` |
| 0x80F:0 | Get hardware info: versions | 0 | — | 24 bytes = 6 × u32: firmware version (major bits 12–15, minor 8–11, patch 0–7), firmware build, unknown, FPGA count, DICE build, DICE version (major bits 20–23, minor 12–19, patch 0–11) | derived (field splits); field names from GU | ev_e9485ac92ba6, ev_48029c6dffd8 | `device/base.rs:64-96` |
| 0x80F:1 | Get hardware info: serial | 1 | — | serial as a NUL-terminated string in the first 24 bytes, then the manufacture date (app reads 48 bytes) | derived (string, colourway check) | ev_8925e907a41e | `device/base.rs:98-119` |
| 0x810:i | Firmware update | 0 start, 1 verify, 2 abort, 3 finalise, 4 reboot, 5 poll | — | 4 bytes (0 = OK); poll: 24 bytes of progress | derived | ev_feff628ffd62, ev_c0f267ce597c | `commands.rs:93-111` |
| 0x811:i | Set encoder mode | encoder 0–3 | 2 bytes {mode, resolution} | — | derived (shape); meaning from GU | ev_835f6b26fae3, ev_d99ac27518dd | `device/base.rs:137-140` |
| 0x814:i | Set fader display mode | fader 0–3 | 2 bytes {gradient, meter} | — | derived (shape); meaning from GU | ev_438d60bf8512 | `device/base.rs:162-178` |
| 0x816:0 | Set animation mode | 0 | 5 bytes {enabled, mode, mod1, mod2, waterfall} | — | derived ("Animation") | ev_e88533d13364 | `device/base.rs:285-307` |
| 0x817:0 | Set channel mixes (submix outputs) | 0 | app sends 8 bytes; GU sends 4 + 4 entries, or 5 + 5 with Mix2 firmware | — | derived (size); meaning from GU | ev_823433edcd53 | `daemon/src/device.rs:3954-4032` |
| 0x818:0 | Set monitored mix | 0 | u8 mix (0 = A, 1 = B) | — | derived (size); meaning from GU | ev_941cedaa2e77 | `device/base.rs:204-207` |

Firmware updates (0x810 and DICE NVM actions 4:2–4:6) are out of scope (D5).
Our code must never send them, and the dext's allowlist (ADR 0003) excludes
them.

### Channel, fader and encoder numbers (GU `types/src/lib.rs`)

- **Channels:** Mic 0, LineIn 1, Console 2, System 3, Game 4, Chat 5, Sample 6,
  Music 7, Headphones 8, MicMonitor 9, LineOut 10.
- **Submix channels** (bank 1 of 0x806): Mic 0 to Music 7.
- **Faders:** A 0 to D 3. **Encoders:** Pitch 0, Gender 1, Reverb 2, Echo 3.

These are used for the index of 0x806/0x809, the payload of 0x805 and the
encoder index. The app takes them from its own channel ids; it doesn't number
them with literals at the call sites. So the numbering is **inferred** from GU
until checked on hardware.

### Input state bits (0x800 reply, GU `buttonstate.rs:22-53`)

- Effect select 1–6: bits 0, 5, 10, 15, 1, 6.
- Sampler bank A/B/C: bits 2, 7, 12.
- Sampler pads TL, TR, BR, BL: bits 3, 8, 13, 17. Sampler clear: bit 18.
- Fader 1–4 mute: bits 4, 9, 14, 19.
- Robot 11, HardTune 16, Megaphone 20, FX 21, Bleep 22, Cough 23.

The Mini has only the fader mutes, Bleep and Cough; their bits, and faders A–D
in bytes 8–11, are confirmed on the Mini (L-119). The same bit numbers index
the 24-byte payload of 0x808. Values for 0x808: Colour1 1, Colour2 0, Dimmed
Colour1 2, Flashing 3, Dimmed Colour2 4. On the Mini the six slots match these
bit numbers, 0 is the state found and 4 dims (L-121); flashing showed nothing
there, probably because both colours are the same in its stored map.

The device's event flags (L-027) are separate: the app reads input state when
they fire. It appears to treat flag 0x200000 as bleep and bits 22–25 as the
sampler pads (inferred).

### Routing (0x804; GU `routing.rs`, `daemon/src/device.rs:3161-3222`)

- **One command per input side.** Mic L/R uses indices 2/3, LineIn 4/5, Console
  6/7, System 8/9, Game 10/11, Chat 12/13, Music 14/15, Samples 16/17. The app
  also sends indices 0 and 1, whose meaning is unknown.
- **Payload:** one u16 per output position. In GU's byte view, the high byte of
  the u16 for each output is 0x20 when that input is routed to it.
- **Confirmed on the Mini (L-123):** Music rows 14/15, Broadcast bytes 5/7
  (22-byte rows on firmware without Mix2), and the 0x806 Music index 7.
- **Output byte positions:**
  - Headphones 1/3, Broadcast 5/7, ChatMic 9/11, Sampler 13/15, LineOut 17/19.
  - Mix2 21/23, on firmware with Mix2.
  - The HardTune source byte is at 21, or 25 with Mix2. It is 0x04 when HardTune
    applies to all sources and 0x10 for the one selected source.

### Effect parameter keys (0x801; GU `types/src/lib.rs:259-368`)

The official app builds these from a name → number map we have not yet
resolved, so the numbers below are **inferred** from GU.

- **Mute and gate:** MicInputMute 0x158, BleepLevel 0x73, GateMode 0x10,
  GateThreshold 0x11, GateEnabled 0x14, GateAttenuation 0x15, GateAttack 0x16,
  GateRelease 0x17, MicCompSelect 0x14B.
- **EQ (full GoXLR)**, frequency/gain:
  - 31 Hz 0x126/0x127, 63 Hz 0xF8/0xF9, 125 Hz 0x113/0x114,
  - 250 Hz 0x129/0x12A, 500 Hz 0x116/0x117, 1 kHz 0x11D/0x11E,
  - 2 kHz 0x12C/0x12D, 4 kHz 0x120/0x121, 8 kHz 0x109/0x10A, 16 kHz 0x12F/0x130.
- **Compressor:** Ratio 0x13C, Threshold 0x13D, Attack 0x13E, Release 0x13F,
  MakeUp 0x140.
- **De-esser** 0x0B.
- **Reverb:** 0x2E–0x39, Amount 0x76.
- **Echo:** 0x1E–0x2A, Amount 0x75.
- **Pitch:** Amount 0x5D, Threshold 0x159, Character 0x167. **Gender:** Amount
  0x60.
- **Megaphone:** 0x3A–0x49.
- **Robot:** 0x133–0x13B, PulseWidth 0x146, Waveform 0x147, DryMix 0x14D,
  Threshold 0x157.
- **HardTune:** 0x59–0x5F.
- **Enables:** Robot 0x14E, Megaphone 0xD7, HardTune 0xD8; encoders 1–4 0xD5,
  0xD6, 0x150, 0x151.

### Mic parameter keys (0x80B; GU `types/src/lib.rs:375-407`)

The app sends key = (name id − 1). Which numbers its names map to is
**unknown**; GU's values:

- **Mic and gain:** MicType 0x000 (value 1 = condenser, i.e. phantom power on),
  DynamicGain 0x001, CondenserGain 0x002, JackGain 0x003.
- **Gate:** 0x30200, 0x30400, 0x30600, 0x30900.
- **Compressor:** 0x60200–0x60700.
- **Bleep level:** 0x70100.
- **Mini EQ:** 0x40000–0x40007 and 0x50000–0x50007.
- **Value encodings:** gate and compressor values are f32. The gain is a u16 in
  the upper half of the 4-byte value (16.16 fixed point, inferred). The bleep
  level is the value × 65536.

**Verified on the Mini (firmware 1.1.8.43, L-126–L-130):** MicType 0x000 (1 = 48 V
on), DynamicGain 0x001 and CondenserGain 0x002 (dB << 16; the last one written
applies) and GateThreshold 0x30200 (f32 dB). The Mini turns 48 V on at every
power-up. The 0x801 keys GateEnabled 0x14, GateThreshold 0x11 and MicInputMute
0x158 were accepted but had no visible effect on the Mini.

**Phantom power is the MicType value.** Writing it is a hardware-risk action
(ADR 0003 consequence 2, PROMPT.md Phase 5).

## Firmware feature gates (GU `daemon/src/device.rs:4131-4205`)

| Feature | Full ≥ | Mini ≥ | Effect |
|---|---|---|---|
| Animations; 520-byte colour map | 1.3.40.0 | 1.1.8.0 | 0x816 allowed; 0x803 is 520 bytes, not 328 |
| Submixes | 1.4.2.107 | 1.2.0.46 | 0x817, 0x818 and 0x806 bank 1 |
| No submix correction needed | 1.4.2.110 | 1.2.0.47 | GU applies a headphones/line-out workaround only below these |
| Mix2 / StreamMix2 | 1.5.0.0 | 1.3.0.0 | Routing rows 26 bytes, not 22; 5 entries per mix in 0x817 |

The official app's own gate logic is not yet analysed. Until it is, these
gates are **inferred** from GU. Read the firmware version (0x80F:0) before
choosing payload sizes.

## Open questions

1. Names for the 0x80B keys and the app's split between 0x801 and 0x80B (both
   log "Effect Parameters").
2. Routing indices 0 and 1, and the meaning of all 13 u16 positions.
3. The app's 8-byte 0x817 payload versus GU's 10 bytes with Mix2.
4. The 0x800 button bitfield's top two bits, which the app masks off.
5. Layouts of 0:2 system info and the DICE caps replies (needed only if we use
   them).
6. Which commands the device persists across power cycles. Plan: an H0
   power-cycle check in Phase 2.
