# Control protocol specification

How our dext and GoXLRKit talk to a GoXLR or GoXLR Mini. This is the protocol
**as we implement it**: where sources disagree, the choice made here is listed
in [LEDGER.md](LEDGER.md) "Conflicts" (L-060 to L-066). The audio streaming
side is in [STREAMING.md](STREAMING.md); the command catalog is in
[commands.md](commands.md); golden byte vectors are in
[`Tests/Vectors/`](../../Tests/Vectors/).

**Status:** specified from static analysis (Phase 1) and the Mini's read-only
baseline (Phase 2). **No DCP command has been sent to hardware yet.** Items
marked *(H2)* are verified in Phase 4, and items marked *(H3)* in Phase 5.

All multi-byte fields are little-endian.

## 1. USB requests (L-020, L-021, L-050, L-051, L-100)

All control traffic uses the default control pipe and targets the Audio
Control interface (0). The Mini has no vendor-specific interface (L-100).

| Purpose | bmRequestType | bRequest | wValue | wIndex | wLength | Data |
|---|---|---|---|---|---|---|
| Read DCP global data | 0xC1 (IN, vendor, interface) | 0 | 0 | 0 | 24 | §2 |
| Reset (DCP version > 1) | 0x41 (OUT, vendor, interface) | 1 | 0 | 0 | 0 | none |
| Send command | 0x41 | 2 | 0 | 0 | 16 + payload | §3 request |
| Read reply | 0xC1 | 3 | 0 | 0 | max payload + 16 | §3 reply |
| Set sample rate (UAC2) | 0x21 (OUT, class, interface) | 1 (`CUR`) | 0x0100 (sampling-frequency control) | 0x2900 (clock 41, interface 0) | 4 | u32 48000 |

The last row is a standard UAC2 request, not DCP. Its bytes come from L-055,
and it is the request Apple's driver sends on every attach (L-112).

Timeouts: 200 ms per control transfer (L-026, L-066).

## 2. DCP global data (L-022)

24 bytes, read once after the device is opened. The device is rejected unless
words 0 and 1 match.

| Offset | Field | Use |
|---|---|---|
| 0 | u32 magic `0x04061973` | must match |
| 4 | u32 magic `0x18101966` | must match |
| 8 | u32 `dcp_version` (name inferred) | > 1 means the reset is `bRequest 1`; otherwise it's command 0:0 (§4) |
| 12 | u32 | unused |
| 16 | u32 maximum command payload size | upper bound for every payload and for the reply read |
| 20 | u32 | unused |

Observed on the Mini (L-114): `dcp_version` 2, maximum payload 1024; word 3
is 1 and word 5 is 0, meanings unknown. The reply was the same after a
power cycle (L-116). Tone runs before and after the read showed no change
it caused (L-115). goxlr-utility says the read initialises audio on Windows
(L-055); the dext still sends it only in its start sequence (§7).

## 3. Command framing (L-023, L-025, L-052)

**Request:** a 16-byte header, then the payload.

| Offset | Field |
|---|---|
| 0 | u32 opcode = `(category & 0xFFF) << 12 \| (index & 0xFFF)` |
| 4 | u16 payload length |
| 6 | u16 sequence number |
| 8 | u32 0 |
| 12 | u32 0 |

**Reply:** a 16-byte header, then the payload, read in one transfer. The checks
run in this order, and the first failure ends the command:

1. At least 16 bytes received, else `replyTooShort`.
2. u32 at 0 equals the request opcode, else `opcodeMismatch` (app local code 5).
3. u16 at 6 equals the request sequence, else `sequenceMismatch` (10).
4. u16 at 4, plus 16, equals the bytes received, else `lengthMismatch` (14).
5. Payload length ≤ the caller's expected maximum, else `replyTooLarge` (15).
6. u32 at 8 is the DCP status: 0 = success; anything else is
   `dcpStatus(code)` (§6).

The u32 at offset 12 of a reply is not checked; its meaning is unknown.

## 4. Sequence numbers and reset (L-024, L-030)

- The host keeps one u16 sequence counter per device.
- **Reset** sets the counter to 0:
  - with `dcp_version` > 1: `bRequest 1` with no data;
  - otherwise: command 0:0, a header-only request with sequence 0;
  - in both cases the reply is then read with `bRequest 3`.
- The counter increments after every completed reply, **including the
  reset's**: the first command after a reset is sent with sequence 1. The
  vectors show the sequence a command was sent with (versions 1, serial 2,
  input state 3). Observed on the Mini (H2, 2026-10-31): versions sent with
  sequence 0 after the `bRequest 1` reset was refused twice; the reset's
  reply header was opcode 0, length 0, sequence 0, status 0.
- **Retry:** if a command fails for any reason, send one reset and retry the
  command once. A second failure is reported. Every GoXLR command sets state,
  so a retry has no extra side effect (inferred from the catalog).
- Only one command is in flight per device. The dext serialises commands.

## 5. Waiting for the reply (L-026, L-027, L-028, L-054, L-062, L-101)

After the OUT transfer, the host waits up to **3000 ms** for the reply:

- **Interrupt mode** (used when the dext owns interface 0): wait for an
  interrupt message on endpoint 0x81 with "response ready" set, then read the
  reply once.
- **Polling mode** (used otherwise): read `bRequest 3` repeatedly. STALL means
  not ready yet. Retry every 10 ms on the Mini and 3 ms on the full GoXLR
  (L-054), within the 3000 ms total.

**Interrupt message**, 6 bytes, a UAC2 interrupt data message:

| Byte | Field | Value |
|---|---|---|
| 0 | `bInfo` | 0x01 (vendor-specific); any other value is a UAC2 class message (for example a clock change) and is not a DCP message |
| 1 | `bAttribute` | 0x01, not checked (the app checks only byte 0, L-027) |
| 2–3 | `wValue` | bit 0 = response ready |
| 4–5 | `wIndex` | bits 5–15 = input-changed flags |

With `v` = the u32 at bytes 2–5, response ready is `v & 1`, and the event
flags are `v & 0xFFE00000` (bits 21–31). The flag 0x200000 appears to mean
bleep (inferred).

## 6. Status codes and errors (L-031)

DCP status codes. The numbering assumes the app's string table starts at 0
(medium confidence):

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | error |
| 2 | timeout |
| 3 | invalid command sequence |
| 4 | invalid opcode category |
| 5 | invalid state |
| 6 | max transfer size exceeded |
| 7 | invalid opcode index |
| 8 | invalid argument |
| 9 | not supported |
| 10 | invalid response sequence |

Our error algebra (GoXLRKit, and the dext's log codes) is one tagged error per
failure. Each keeps the opcode, sequence and raw bytes received:

| Case | Failure |
|---|---|
| `transfer(IOReturn)` | the USB transfer failed |
| `stall` | the device stalled the request |
| `waitTimeout` | no reply within 3000 ms |
| `replyTooShort` | fewer than 16 bytes |
| `opcodeMismatch` | opcode not echoed |
| `sequenceMismatch` | wrong sequence number |
| `lengthMismatch` | header length doesn't match bytes received |
| `replyTooLarge` | payload over the expected maximum |
| `dcpStatus(code)` | the device reported a non-zero status |
| `rejected(reason)` | refused by the dext's allowlist; never sent |

## 7. Device start and stop (L-032, L-033, L-055, L-065, L-112)

What the dext does when it starts on a device *(H2)*:

1. Send UAC2 `SET CUR` sampling frequency 48000 on clock 41 (§1).
2. Read DCP global data (§2) and check the magic words. Record `dcp_version`
   and the maximum payload.
3. Reset (§4).
   - If the reset STALLs, the device is uninitialised: follow L-065's plan
     and report it.
4. Read 0x80F:0 (versions) and 0x80F:1 (serial and date). Choose the
   firmware-dependent payload sizes (§9).
   - The serial is device identity. It may be shown in the helper, but it is
     never logged to files, committed or sent anywhere.
5. Read 0x800:0 (input state) and publish it.
6. Enable events: interrupt mode, or polling 0x800:0 every 20 ms (GU's
   interval, L-054).

The DICE info sequence (0:2 and the 1:0–4:1 caps) is **not** sent: GU never
sends it, and no feature needs it (L-033, L-060).

The helper then applies the user's profile (§8). The device may keep little
or nothing across a power cycle (L-109, L-113; Phase 5 tests it), so the helper
re-applies the full state on every attach, as GU does.

On stop: abort waits, then stop. No command is sent on stop.

## 8. Command policy (allowlist basis) (L-092, commands.md)

**Default deny.** Only the opcodes below are ever sent. The dext checks the
opcode, the index range, the payload length and, where listed, the payload
values. It rejects everything else with `rejected(reason)` (ADR 0003
consequence 2). Payload sizes marked "fw" depend on the firmware gates (§9).

| Opcode | Index | Payload (bytes) | Value constraints | Reply | Class |
|---|---|---|---|---|---|
| 0x800 | 0 | 0 | — | 12 | read |
| 0x80C | 0 | 0 | — | 2 | read |
| 0x80F | 0 | 0 | — | 24 | read |
| 0x80F | 1 | 0 | — | up to 48 | read (identity) |
| 0x801 | 0 | 8·n, n ≥ 1 | each u32 key in the effect key set (commands.md) | 0 | write |
| 0x802 | 0–3 | 1024 | — | 0 | write |
| 0x803 | 0 | 520 or 328 (fw) | — | 0 | write |
| 0x804 | 0–17 (rows 0/1 meaning unknown) | 26 or 22 (fw) | per GU's byte view (inferred): even bytes 0; odd bytes 0x00 or 0x20; the HardTune byte (21, or 25 with Mix2) 0x00, 0x04 or 0x10 | 0 | write |
| 0x805 | 0–3 | 4 | u32 channel 0–10 | 0 | write |
| 0x806 | `(bank << 4) \| ch`: bank 0 with ch 0–10, or bank 1 (fw) with ch 0–7 | 1 | — | 0 | write |
| 0x808 | 0 | 24 | each byte 0–4 | 0 | write |
| 0x809 | 0–10 | 1 | 0 or 1 | 0 | write |
| 0x80A | 0–3 | 1 | — | 0 | write |
| 0x80B | 0 | 8·n, n ≥ 1 | each u32 key in the mic key set; **MicType value 1 (phantom) is hardware-risk** | 0 | write / **risk** |
| 0x811 | 0–3 | 2 | — | 0 | write |
| 0x814 | 0–3 | 2 | — | 0 | write |
| 0x816 | 0 | 5 (fw) | — | 0 | write |
| 0x817 | 0 | 8 or 10 (fw) | — | 0 | write |
| 0x818 | 0 | 1 | 0 or 1 | 0 | write |

- **Never sent:**
  - 0x810 (firmware update, all indices);
  - DICE NVM actions 4:2–4:6;
  - any category other than those above.

  These are firmware or out of scope (D5).
- **Phantom power** (0x80B, key MicType, value 1): **decided by the user
  (2026-10-31): only clients signed by the developer team may send it.** The
  dext reads each client's entitlements when it opens and trusts it only if
  `com.apple.developer.team-identifier` equals the team the dext was built
  for. Every other check still applies, and the dext's write tier must also
  allow mic writes (tier 5); the helper confirms the attached mic first
  (PROMPT.md Phase 5). Untrusted clients get `rejected(hardware-risk)`.
  The Mini turns 48 V on at every power-up (L-130); what the host sends on
  attach is in ADR 0003 consequence 2.
- **Read replies** have exact sizes, except 0x80F:1. A reply that differs is
  `lengthMismatch` or `replyTooLarge`.
- **Inferred fields:** the key numbers for 0x801 and 0x80B, and the channel
  numbering, come from GU (commands.md). Phase 5 verifies them *(H3)*.

The dext enforces this table as a table generated from this section (ADR
0003 consequence 3, decided 2026-10-30).

## 9. Firmware gates (commands.md "Firmware feature gates", L-061)

0x80F:0 reply (24 bytes, six u32 words):

| Word | Field | Decoding |
|---|---|---|
| 0 | firmware version | major = bits 12–15, minor = bits 8–11, patch = bits 0–7 |
| 1 | firmware build | the fourth version component |
| 2 | unknown | — |
| 3 | FPGA count | — |
| 4 | DICE build | — |
| 5 | DICE version | major = bits 20–23, minor = bits 12–19, patch = bits 0–11 |

Gates (GU, inferred until verified), with versions compared as major.minor.patch.build:

| Feature | Full ≥ | Mini ≥ |
|---|---|---|
| Animations (0x816); 520-byte colour map | 1.3.40.0 | 1.1.8.0 |
| Submixes (0x817, 0x818, 0x806 bank 1) | 1.4.2.107 | 1.2.0.46 |
| Mix2: 26-byte routing rows; 10-byte 0x817 | 1.5.0.0 | 1.3.0.0 |

Below a gate, the dext rejects the gated commands, and the helper hides the
feature.

## 10. Input state (0x800:0 reply)

12 bytes:
- bytes 0–3: u32 button bitfield (mask `0x3FFFFFFF`, as the app);
- bytes 4–7: four i8 encoders (Pitch, Gender, Reverb, Echo);
- bytes 8–11: four u8 faders (A–D).

Bit numbers are in commands.md "Input state bits". The Mini has only the
fader mutes, Bleep and Cough.

## 11. Unknowns carried into Phases 4–5

- L-061: which payload sizes the Mini's firmware accepts. Its firmware is
  1.1.8.43 (L-118): animations yes, submixes and Mix2 no.
- L-062: interrupt mode is unused while `usbaudiod` owns interface 0 (ADR
  0004); polling worked for 21,450 commands (L-120). `usbaudiod` receives one
  vendor interrupt per attach and logs it as unsupported.
- commands.md open questions 1–6: the 0x80B key names, routing rows 0/1, the
  0x817 size, the top two button bits, the caps layouts, and persistence.
