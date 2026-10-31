# Phase 5 hardware sessions: GoXLR Mini (1220:8FE4)

Firmware 1.1.8.43. The XLR driver holds the device session; Apple's
`usbaudiod` streams (ADR 0004). Logs are local, in
`~/dev/goxlr-re/hardware-logs/h3/`.

## H3.1: button LEDs (2026-10-31, driver v3, tier 1)

**Snapshot problem.** The GoXLR has no command that reads LED states or the
colour map, so PROMPT.md §7's snapshot can't be read from the device. The
user approved this substitute: write the all-0 state first and have the user
compare. Nothing changed, so all 0 is the state found, and the restore is
writing all 0 again.

| Step | 0x808 payload | The user saw |
|---|---|---|
| Baseline | — | all six buttons lit, one colour |
| 1 | all 0 (Colour2) | no change: the snapshot |
| 2 | slot 4 = 3 (Flashing) | no flashing anywhere |
| 3 | all 4 (Dimmed Colour2) | all six dimmer |
| 4 | slots 4, 14, 22 = 4 | mute 1, mute 3, Bleep dim |
| 5 | slots 9, 19, 23 = 4 | mute 2, mute 4, Cough dim |
| Restore | all 0 | the original look |

Every write returned DCP status 0 on the first attempt. Polling continued
throughout (8,056 polls, 0 failed). As in H2, `usbaudiod` logged one
"unsupported interrupt" at attach (L-120).

**Result (L-121):** each Mini button's LED slot is its button bit number:
mutes 4, 9, 14, 19; Bleep 22; Cough 23. Dimming works. Flashing is invisible
on this device, probably because Colour1 and Colour2 are the same blue in its
stored colour map (inferred).

**Not tested:** persistence of 0x808 across a power cycle; the colour map
(0x803), fader display (0x814) and animation (0x816), the other tier-1
commands.

## H3.2: rest of tier 1 (2026-10-31, driver v3; camera)

The user allowed photos with the OBSBOT webcam through `Tools/camshot`, so the
results below are from photos, not reports.

| Command | Result |
|---|---|
| 0x816 animation | All 0: no change (the state found). `01 00 00 00 00` (RetroRainbow): moving rainbow. Back to all 0: the buttons returned to cyan, but the fader strips and logo stayed in the last rainbow colours |
| 0x803 colour map | All 130 entries `ff ff 00 00` (cyan 00FFFF, B G R A): everything cyan again, matching the original look. Slots 20 and 21 are fader A's strip (the leftmost, labelled Mic): two colours split at the knob |
| 0x814 fader display | Fader A: `00 00` two colours split at the knob (the state found); `01 00` a gradient between them; `00 01` meter mode (whole strip one colour with no signal) |
| Persistence | Before an unplug: fader A's strip red and green, mute 1 dimmed. After the power cycle (Apple's driver, nothing sent): fader A's strip cyan. The colour map is not kept across a power cycle; the Mini reloads its stored colours. Mute 1 was hidden in the photo |

Colour-map layout from goxlr-utility (`usb/src/colouring.rs`, read by an
agent, no line numbers): fader mutes 1–4 at slots 12–19, fader strips at 20,
34, 48, 62 (two colours each), logo at 10, Bleep 126, Cough 128.

**Unplanned re-enumeration at 08:16:38**, twice within 6 s, probably the cable
moved while the camera was aimed (inferred). Each re-attach started a new v3
process; the first exited, the next two stayed alive with no services after
their device went away. At the planned unplug (08:29) the staged v4 could not
replace v3: macOS launched v3 again from its half-removed bundle (`Exec
format error`) and Apple's composite driver took the device. Audio was never
affected. The driver logs for 08:16 were lost (dext logs are live-only and
the capture had been stopped).

## H3.3: tiers 2–4 (2026-10-31, driver v4; reference audio)

Measured through the Broadcast Stream Mix capture (inputs 1–2), which goes
only to the Mac: nothing reached headphones or speakers. Tones at −30 dBFS.

| Step | Write | Stream Mix L/R |
|---|---|---|
| Baseline (run 15) | — | silent (−107 dBFS floor) |
| Route Music (run 16) | 0x804:14 byte 5 = 0x20; 0x804:15 byte 7 = 0x20 | silent (Music volume was 0) |
| Volume 255 (run 17) | 0x806:7 = ff | Music L/R −30.4 dBFS |
| Volume 128 / 64 / 0 (runs 18–20) | 0x806:7 | −57.3 / below −70 / silent |
| Mute (runs 21–22) | 0x809:7 = 1, then 0 | silent, then −30.4 |
| Fader A = Music, meter (runs 23–24, photos) | 0x805:0 = 07; 0x814:0 = 00 01 | fader A's meter moves with the tone |
| Fader A = Mic (run 25, photo) | 0x805:0 = 00 | meter still during the tone |
| After a power cycle (run 26) | — | silent: routing/volume not kept |

Every write returned DCP status 0 on the first attempt. After the power cycle
(the user unplugged once), the Mini was as found: lighting from its stored
colours, mixer silent to the Stream Mix.

## H3.4: tiers 5–6, mic (2026-10-31, driver v10; reference audio)

A condenser mic was on the XLR input (the user confirmed it before phantom
power). The mic was first routed nowhere (0x804 rows 2/3 all zero) and the
mic monitor set to 0 (0x806:9), so nothing reached the headphones. Levels are
the dry mic (capture 21) and the processed mic (capture 7). Band levels come
from an FFT of the run's capture.

| Step | Write | Result |
|---|---|---|
| Baseline (run 27) | — | dry −46.4 dBFS, live (300–1000 Hz band −62 dB); processed digital zero |
| Condenser gain 0 / 25 / 50 dB (runs 28–30) | 0x80B {0x002, dB << 16} | dry −79.6 / −54.3 / −33.1; processed opens only at 50 dB |
| Dynamic gain 40, then condenser gain 0 (runs 31–32) | 0x80B {0x001} then {0x002} | −39.2, then −82.0: the last gain written applies |
| MicType 0 from `goxlrctl` | 0x80B {0x000, 0} | status 0 |
| MicType 1 from `goxlrctl` | 0x80B {0x000, 1} | **refused by the driver** (`hardwareRisk`) |
| MicType 0, gain 40 (run 33) | — | dead input: audio bands −108 to −121 dB |
| Phantom on through the helper | user clicked **Turn On 48 V** | helper: `phantom power on: done` |
| Phantom on, gain 40 (run 35) | 0x80B {0x002} | live: bands −55 to −78 dB, test tone heard through the air |
| Gate on/off, 25 dB (runs 36–38) | 0x801 {0x14, 0 / 1} | no change (processed stays zero) |
| Gate threshold −59 dB (runs 39–40) | 0x801 {0x11, −59}, then 0x80B {0x30200, −59.0f} | 0x801: no change; 0x80B: processed opens (−54.6) |
| Mic input mute (runs 41–42, 45–46) | 0x801 {0x158, 1 / 0} | no change on captures 7, 21 or the Stream Mix |
| Gate threshold −20 dB (run 43) | 0x80B {0x30200, −20.0f} | processed closed again |
| Mic → Stream Mix (run 44) | 0x804:2/3 byte 5/7 = 0x20; 0x806:0 = ff | Stream Mix L/R −54.3 = processed mic; rows reset after |
| Phantom off through the helper (run 47) | `--phantom-off` | dead input again: bands −113 to −128 dB |
| Power cycle, nothing sent (runs 48–49) | — (left at MicType 0, gain 40) | live again; low-frequency settling for about a minute |
| Known gain after the cycle (run 50) | 0x80B {0x002, 40 dB} only | bands 30–50 dB above the dead reference: **48 V back on** |
| Restore (run 51) | 0x80B {0x002, 25 dB} | matches the post-cycle state within about 1 dB |

Every write returned DCP status 0 on the first attempt.

- **The Mini turns 48 V on at every power-up**, whatever MicType was last
  written (runs 27–31 and 48–50; L-130). Software can only turn it off after
  attach, so a user with a ribbon mic gets 48 V at each replug until the host
  acts. The helper now turns it off on attach unless the saved type is a
  condenser (H3.5).
- The power-up gain is about 25 dB (inferred); the session ended with 25 dB
  written, matching the post-cycle state, and everything else as powered up.
- Its gate is in 0x80B; the 0x801 keys tried had no visible effect.

## H3.5: saved mic type on attach (2026-10-31, helper on GoXLRKit)

The user chose to apply the saved mic type on attach (ADR 0003 consequence 2).
The helper turns 48 V off whenever the driver becomes ready, unless the saved
type is a condenser, and never turns it on by itself.

| Saved type | Trigger | Helper | Mic (capture 21) |
|---|---|---|---|
| none | launch | nothing sent | live (unchanged) |
| condenser | `goxlrctl driver reset` | nothing sent | live (run 52) |
| dynamic | `goxlrctl driver reset` | MicType 0: done | dead, bands −118 to −131 dB (run 53) |
| condenser | `--mic-type condenser`, user clicked **Turn On 48 V** | MicType 1: done | live (run 54) |

The session ended as found: condenser saved, 48 V on, gain 25 dB. A real
power cycle with dynamic saved wasn't tested (L-131). The helper then became a
menu bar app that opens at login, so the rule runs without the user starting
it (L-132).

## H3.6: gain and gate for the user's voice (2026-10-31)

Capture-only recordings (`sox`, all 21 inputs, nothing played) while the user
talked (L-133):

- At the Mini's power-up gate threshold the processed mic stayed silent at 25
  and 40 dB gain. That is why the app sounded choppy and late.
- Gate −59 dB opened it; the Stream Mix then carried the mic about 16 dB below
  the processed mic (fader A).
- In silence at 40 dB, room noise opens the gate at −50 dB but not at −45.
  At −42 the gate didn't open for the user's voice either.
- The user found 40 dB with the gate at −59 better. The helper now saves gain
  and gate with the mic type and reapplies them at every attach (L-134); the
  user tunes the gate by ear with the menu's slider.

## H3.7: buttons, strips and bleep from the helper (2026-10-31)

The helper with button handling on; faders A Mic, B Chat, C Music, D System
(the official app's default); no routing set, so every mute was mute-to-all
(L-137):

- All six buttons worked as designed: every press reached the helper, and
  every command it sent returned status 0. The lights followed (dimmed when
  unmuted, lit when muted).
- The capture confirms the mutes: Mute A and a Cough hold silenced the Stream
  Mix completely, and the processed mic kept the speech.
- The Bleep tone is loud at power-up (about −5 dBFS on the processed mic). The
  helper's bleep level brought it to about −37 dBFS at −34 dB, the bottom of
  the range; the user still found it too loud.
- The Mini's power-up colours light the whole strip whatever the knob does.
  With a dark second colour, the strip is lit below the knob only.
- During the session the user ticked and unticked one of Mic's routing outputs.
  Mic's routing was unknown to the app, so the first click wrote a row with
  only that output, and the second left Mic routed nowhere: the Stream Mix went
  silent. The helper now asks before the first write to an input's routing.

## Re-enumeration and driver updates

- v5 adds `goxlrctl driver reset` (`IOUSBHostDevice::Reset`): the Mini
  re-attaches without a power cut and the driver is back within about 80 ms.
- `Tools/usbreenum` re-enumerates the Mini while Apple's driver holds it, so a
  staged driver can match without an unplug (used to switch to v6).
- Each re-attach with an app connected left the old driver process idle
  (L-124); upgrades then needed those processes killed. v7's teardown logs
  found the cause (a client detaching onto the driver's cancelled queue) and
  v8 fixed it: four resets, with and without a watching client, each left
  one driver process, and v7 → v8 switched with no unplug (L-125).
