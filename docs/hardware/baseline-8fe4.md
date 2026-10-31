# Hardware baseline H0: GoXLR Mini (1220:8FE4)

- **Date:** 2026-10-30
- **Host:** macOS 27.0 (Darwin 27.0.0), Apple Silicon. The device was on a
  USB 2.0 hub chain (VIA Labs), location 0x01113400.
- **Driver:** Apple's. Our dext was not installed (`0 extension(s)`).
- **Host software:** no GoXLR software, daemon or system extension on this
  Mac, so no host here sent the device a DCP command. One vendor request,
  the global-data read, was sent at 22:55:09, after every other test except
  runs 4 and 5.
- **Vendor requests sent:** none. The only requests our tools sent were
  standard `GET_DESCRIPTOR` reads. Apple's driver sent its own UAC2 class
  requests at attach (below).
- **Raw logs:** `~/dev/goxlr-re/hardware-logs/h0/` and
  `~/dev/goxlr-re/reference-audio/` (not committed).

## What ran

| Step | Tool | Effect on the device |
|---|---|---|
| IORegistry and system_profiler | `ioreg`, `system_profiler` | none |
| Descriptor dump | [`Tools/usbdesc`](../../Tools/usbdesc/) | Standard `GET_DESCRIPTOR` IN only (device, strings); configuration from the IOUSBLib cache. The device is never opened. |
| CoreAudio report | [`Tools/caprobe`](../../Tools/caprobe/) | Property reads only |
| Reference loopback ×2 | [`Tools/refaudio`](../../Tools/refaudio/) `refaudio`, `analyze.py` | Played one −30 dBFS tone per output channel for 4 s and recorded all inputs. The user consented and set headphones low. No settings changed. |
| Clock rate, 30 s | `Tools/refaudio/clockrate.swift` | Played silence, kept no audio |

Results are in [STREAMING.md](../protocol/STREAMING.md) and the ledger
(L-100 to L-112). In short:

1. **No vendor interface.** There are three UAC2 interfaces: control (with
   interrupt endpoint 0x81, 6 bytes, 16 ms) and two streaming interfaces.
2. **Channels:** 10 playback and 21 capture channels, all named by the device.
   The 15 capture channels beyond the Windows INF's six are raw input taps
   plus a dry mic.
3. **Streaming:** 48 kHz only, 24-bit, asynchronous, with implicit feedback
   from the capture endpoint. The device clock measured +17.7 ppm against the
   host.
4. **No init needed for audio.** The audio interfaces enumerate and stream
   with no host initialisation. Playback 1–8 come back on raw taps 9–16
   **bit-transparently**, 15 frames later.
5. **The mixer is empty** in the state found:
   - no played channel reaches the Broadcast Stream Mix, Chat Mic Mix or
     Sample Source Mix;
   - the processed mic is digital zero;
   - the Sample outputs (9–10) reach nothing.

   The reference "Music to Stream Mix" recording that PROMPT.md asks for
   therefore isn't possible until routing can be set (Phase 5). The raw-tap
   loopback is the A/B baseline for Phase 6 instead.

## Which driver claimed what

| Object | Clients |
|---|---|
| Device (`IOUSBHostDevice`) | `AppleUSBHostCompositeDevice` (configures, then closes). Device user clients held by Steam, ChatGPT, Google Chrome and GeForce NOW: third-party apps enumerating USB devices. |
| Interface 0 (Audio Control) | `AppleUSBAudioControlNub` and `usbaudiod` (`AppleUSBHostFrameworkInterfaceClient`) |
| Interfaces 1 and 2 (Audio Streaming) | `usbaudiod` |

Apple's USB audio runs in the user-space daemon `usbaudiod`, not in a kernel
extension. CoreAudio's device UID is
`AppleUSBAudioEngine:TC-Helicon:GoXLRMini:1113400:1,2`; its model UID is
`GoXLRMini:1220:8FE4`.

## Apple's driver at attach (from `usbaudiod`'s log)

1. Reads the sampling frequency of clock 41 (48000).
2. Sets clock selector 40 to input 1.
3. Sets clock 41 to 48000.
4. Reads terminal latency (`a1 01 0700 0100 0004` and `… 0200 …`), twice
   each; the device STALLs all four requests.
5. Polls interrupt endpoint 0x81. Message contents aren't logged.

## Unplanned re-enumeration

At 18:54:53.418 `usbaudiod` failed to queue an interrupt request
(`0xe0005000`). About 300 ms later the device was torn down, and it attached
again 26 ms after that, with USB address 12 → 13. None of our tools were
running then. Our last USB request (`usbdesc`) was at 18:50:27, and our
last CoreAudio property read at 18:51:24. The
cause is unknown. This happened while the user was setting up for the tone
test, and the user will be asked whether the cable or hub was disturbed.

Both reference runs came after this re-attach. Phase 8 should treat a
sub-second detach and re-attach as a normal event (L-111).

The user's unplug at 22:50 (next section) logged the same sequence: an
interrupt-queue error, then teardown a few hundred milliseconds later. So the
log can't tell this event from a cable disconnect.

## Power cycle (22:50, with the user)

The user unplugged the Mini's USB cable and plugged it back in. A read-only
watcher polled the IORegistry (`power-cycle.txt`). It stopped at the first
re-attach, and `usbaudiod`'s log gives the full sequence (L-113):

| Detach | Re-attach | Gone for |
|---|---|---|
| 22:50:03.493 | 22:50:03.995 | 0.5 s |
| 22:50:04.628 | 22:50:12.728 | 8.1 s |
| 22:50:13.171 | 22:50:14.206 | 1.0 s |

The two short ones look like contact bounce (inferred). Each detach came
320–530 ms after `usbaudiod` failed to queue an interrupt request
(`0xe0005000`).

After the last attach:
- **Descriptors:** unchanged (`descriptors-8fe4-post-cycle.txt`; the serial
  string was not compared).
- **CoreAudio report:** unchanged apart from object IDs.
- **Apple's driver:** set 48 kHz again at 22:50:14.3, as in L-112.
- **Lighting:** blue before and after (user report).
- **Run 3:** matches runs 1 and 2 (`refaudio-run3.txt`, `analysis-run3.txt`):
  - capture 9–16 return playback 1–8 bit-exact, 15 frames late;
  - the mixer outputs are still empty;
  - noise floors are within 0.2 dB, and the dry mic is at −100.1 dBFS (runs
    1–2: −91 to −102).

So a power cycle with no host commands changes nothing we can see. Whether
settings the host makes survive one is a Phase 5 test.

The user says blue is the colour the unit was set up with. So the lighting
is probably stored on the device, while the mixer outputs come up empty
(inferred; L-113).

## First vendor request (22:55, with the user)

`Tools/dcpglobal` sent the DCP global-data read once, without opening the
device (`dcpglobal-1.txt`, L-114):
- **Request:** `c1 00 0000 0000 1800`, 200 ms timeout.
- **Reply:** 24 bytes, both magic words match, `dcp_version` 2, maximum
  payload 1024, word 3 = 1, word 5 = 0.
- **Device:** no re-enumeration (same `sessionID`); `usbaudiod` logged
  nothing.

Tone runs 4 (22:55:30) and 5 (22:57:25) match run 3 on every channel but one.
The dry mic (capture 21) rose from −100.1 to −58.5 and −58.9 dBFS (L-115):

| Band | Run 3 | Run 4 | Run 5 |
|---|---|---|---|
| 1–20 Hz | −107.0 | −59.8 | −60.3 |
| 20–100 Hz | −108.6 | −73.0 | −74.3 |
| 100–300 Hz | −124.2 | −104.3 | −105.6 |
| 300–1000 Hz | −117.8 | −105.6 | −108.3 |
| 1–3 kHz | −114.1 | −109.0 | −110.4 |
| 3–8 kHz | −111.1 | −109.5 | −109.5 |
| 8–24 kHz | −105.7 | −103.9 | −103.7 |

Levels are dBFS over a 32768-sample Hann-windowed block. The rise is a
wobble near 5 Hz, steady across both runs. The unchanged hiss above 3 kHz
argues against a preamp gain change. The mic signal isn't routed anywhere.

## A/B: is the read the cause? (23:05, with the user)

The user power-cycled the Mini again. A script (`ab-cycle.txt`) waited until
the Mini had been attached for 5 s, then ran:
1. tone runs 6 and 7;
2. the global-data read (`dcpglobal-2.txt`);
3. tone runs 8 and 9.

It would have stopped before the read if the device had re-enumerated.

| Run | Time | Before or after the read | Dry mic | 1–20 Hz | 20–100 Hz | 8–24 kHz |
|---|---|---|---|---|---|---|
| 6 | 23:05:38 | before | −40.1 | −53.2 | −67.9 | −105.9 |
| 7 | 23:05:45 | before | −45.7 | −46.8 | −66.3 | −105.8 |
| 8 | 23:05:51 | after | −56.4 | −58.2 | −78.1 | −105.8 |
| 9 | 23:05:57 | after | −57.9 | −59.6 | −81.0 | −105.9 |

Levels are dBFS. The "Dry mic" column is refaudio's silence RMS for capture
21. Every other channel matched run 3, apart from noise-floor changes under
1.5 dB.

**The read is not the cause** (L-115):
- The wobble was there after the power cycle, before any read.
- It was weaker after the read.

It survives a power cycle, so it isn't volatile device state. An outside
cause is likely (inferred): vibration or handling picked up by whatever is
on the mic input. Its fall over 25 s fits settling after the replug.

This replug was clean: one detach, gone 15.0 s, no bounce. The read returned
the same 24 bytes as at 22:55 (L-116).

## Not done yet

- **Cause of the 18:54:53 re-enumeration:** unknown. The user doesn't think
  the cable or hub was touched, and the log sequence at detach varies
  between unplugs (L-116), so the log can't settle it.
