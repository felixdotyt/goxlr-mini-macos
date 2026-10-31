# ADR 0004: How the dext matches the GoXLR

- **Status:** accepted: **(B) for Phases 4 and 5, then (A) in Phase 6.** The
  user chose (B) on 2026-10-31, subject to the spike below, which passed the
  same day (Results).
- **Date:** 2026-10-31

## Context

PROMPT.md Phase 4 step 1 asks which USB object the dext matches. The facts it
depends on:

- **No vendor interface.** The Mini has one configuration with three UAC2
  interfaces: 0 Audio Control, with the only interrupt endpoint (0x81, 6
  bytes, 16 ms), and 1 and 2 Audio Streaming (L-100). The DCP vendor requests
  are addressed to interface 0 (L-050). So PROMPT.md's "match the vendor
  interface only" branch doesn't apply.
- **Who holds what today** (baseline-8fe4.md, "Which driver claimed what"):
  - `AppleUSBHostCompositeDevice` matches the device, sets the
    configuration, then closes it;
  - `usbaudiod` opens interface 0 and the streaming interfaces, and polls
    0x81.
- **DCP "response ready" arrives on 0x81** as a UAC2 interrupt message
  (L-026 to L-028). Whoever owns interface 0 receives it.
- **A vendor read works from outside today.** The DCP global-data read
  succeeded under Apple's driver, from a user-space IOKit device interface,
  without opening the device, and changed nothing (L-114, L-115).
- **Control no longer needs AudioDriverKit** (ADR 0003, option (d),
  consequence 4). Only streaming (Phase 6) does.

## What USBDriverKit provides (DriverKit 27.0 headers, observed)

| Fact | Source |
|---|---|
| A device session: "Child IOUSBHostInterfaces may open simultaneous sessions, but only one other service may open a session" | `IOUSBHostDevice.iig:57-69` |
| `SetConfiguration(bConfigurationValue, matchInterfaces)`: sends SET_CONFIGURATION; with `matchInterfaces` true, "any interfaces within the new configuration will be registered for matching" | `IOUSBHostDevice.iig:290-302` |
| `IOUSBHostDevice::DeviceRequest(forClient, …)` and `AsyncDeviceRequest` on the default pipe | `IOUSBHostDevice.iig:209-270` |
| An interface session is exclusive: "Only one service may open a session at a time" | `IOUSBHostInterface.iig:58-66` |

## Options

**(A) Match the device and own every interface.** The personality matches
`IOUSBHostDevice` with `idVendor` 0x1220 and `idProduct` 0x8FE4 (later
0x8FE0). The dext calls `SetConfiguration(1, false)` and opens interface 0
itself, so it receives 0x81 directly.
- For: this is the final shape (Phase 6 needs it).
- Against: `usbaudiod` gets no interfaces, so **the user has no GoXLR audio
  from H2 until Phase 6 streams**. PROMPT.md requires telling the user before
  H2.

**(B) Match the device, leave the interfaces to Apple** (the candidate from
Phase 2). The same personality, but `SetConfiguration(1, true)`: the
interfaces are registered for matching and `usbaudiod` takes them as today.
The dext keeps its device session and sends DCP requests with
`DeviceRequest`. It never sees 0x81, so it polls for "response ready", as
goxlr-utility does on macOS.
- For: GoXLR audio keeps working through Phases 4 and 5, and every write
  can be checked by ear and by the reference-audio tools. Moving to (A) for
  Phase 6 changes one argument and adds interface ownership; the personality
  stays.
- Against, all unverified:
  - whether `usbaudiod` still matches interfaces that a third-party device
    driver configured;
  - whether `DeviceRequest` from the device session may address interface 0
    while `usbaudiod` holds it open (the user-space read in L-114 suggests
    the device accepts it; the host stack's rules are the question);
  - how the dext's EP0 traffic interleaves with `usbaudiod`'s UAC2 class
    requests;
  - polling adds latency to every command (L-026 allows 3000 ms);
  - button and fader events, which also arrive on 0x81 (L-027), would need
    polling too until Phase 6.

**(C) Match interface 0.** The dext would take the Audio Control interface
from `usbaudiod`, which then can't run the streaming interfaces. Audio is
lost as in (A), without (A)'s device control. Not a real alternative.

**(D) No dext for control before Phase 6.** The helper would send DCP
requests from user space, as L-114 did. It needs no install until Phase 6.
But it contradicts the architecture the user chose (a dext that owns the
device, PROMPT.md §1.1), and the dext's allowlist would be bypassable by any
process doing the same. Not proposed; recorded because it is possible.

## Recommendation

**(B) for Phases 4 and 5, then (A) in Phase 6**, if the spike below passes.
If the spike shows `usbaudiod` won't take the interfaces, or the default
pipe can't be shared, fall back to (A) and tell the user that audio is lost
until Phase 6.

## Spike (Phase 4 step 1)

A matching spike, not driver code: a second personality in the spike dext,
class `MatchSpike` (`Spike/ControlSpike/MatchSpike.cpp`) on `IOUSBHostDevice`
1220:8FE4, so `SpikeHost` activates it with no new target. The personality has
`idVendor` and `idProduct` and no `IOMatchCategory`, so it competes with
Apple's composite driver. The development profile grants
`driverkit.transport.usb` for any vendor (ADR 0002).

In `Start`, in order, logging each result:
1. Open the device session.
2. `SetConfiguration(1, true)`, the same SET_CONFIGURATION Apple's composite
   driver sends.
3. The DCP global-data read (`0xC1`, `bRequest` 0, `wIndex` 0, 24 bytes),
   the one request already shown to be harmless (L-114).
4. Every 2 s, repeat step 3 and log it (it shows whether EP0 sharing holds).

No other request reaches the device: no DCP command, no reset, no write.

Checks, with `log stream` started before activation and saved
(`~/dev/goxlr-re/hardware-logs/`):
- the dext logs steps 1–3 succeeding;
- `usbaudiod` opens interfaces 0–2, and CoreAudio lists the GoXLR Mini;
- a reference-audio run matches the Phase 2 baseline (raw-tap loopback);
- the repeated reads keep succeeding during that audio run;
- **rollback drill:** deactivate (needs the user's password), replug, and
  confirm `AppleUSBHostCompositeDevice` is back.

Risks the user accepts by approving it:
- If `usbaudiod` doesn't take the interfaces, the GoXLR has no audio until
  the rollback.
- If the dext fails in `Start`, the device has no driver until the
  rollback. Unplugging alone doesn't fix that, because the match stays
  installed.
- Audio on other devices is not affected: nothing in the spike talks to
  coreaudiod.

### Results (2026-10-31, spike v14, Mini 1220:8FE4)

Logs: `~/dev/goxlr-re/hardware-logs/h1/` (local): `matchspike-stream.log`
(started before activation), `match-cycle.txt`, `rollback-cycle.txt`, the
IORegistry after each replug, `analysis-run10.txt` and `analysis-run11.txt`.

| Check | Result | Class |
|---|---|---|
| The dext takes the device | **On replug only.** Activating while the Mini was attached left `AppleUSBHostCompositeDevice` in place. After one replug, `MatchSpike` was the device's driver | observed |
| Steps 1–3 | `Open` 0x0, `SetConfiguration(1, true)` 0x0, global-data read 0x0: 24 bytes, magic ok, `dcp_version` 2, maximum payload 1024 (as L-114) | observed |
| `usbaudiod` takes the interfaces | **Yes**: `AppleUSBAudioControlNub` and `usbaudiod` on interface 0, `usbaudiod` on 1 and 2, as in the baseline. Its attach sequence matched Phase 2: clock 41 read and set to 48000, selector 40 set to 1, the four terminal-latency requests STALLed. No other errors | observed |
| CoreAudio | The GoXLR Mini listed, with the same device UID | observed |
| Audio | Run 10 matches the Phase 2 baseline: all 8 raw-tap loopback channels bit-exact, latency 15 frames | observed |
| Sharing the default pipe | 58 global-data reads from the device session while `usbaudiod` held interface 0, every 2 s, none failed; 1.2–4.4 ms each, including during the audio run | observed |
| Interrupt endpoint | Not visible. `usbaudiod` logs only interrupt failures (as at the unplug), so its polling of 0x81 under `MatchSpike` is assumed, not seen | unknown |
| Rollback drill | The user deactivated the spike (password). `MatchSpike` stopped (57 polls, 0 failed) and `Close` returned 0x0. Apple's composite driver reattached at once, but `usbaudiod` didn't take the interfaces until the replug. After the replug the baseline layout returned, and run 11 matched the baseline (8 of 8 bit-exact, 15 frames) | observed |

Findings:
1. **The development `transport.usb` entitlement must equal the profile's
   value.** v13 signed `[{idVendor: 4640}]` against the profile's
   `[{idVendor: "*"}]`; AMFI reported "Unsatisfied Entitlements:
   com.apple.developer.driverkit.transport.usb" and the dext failed to
   launch ("Exec format error"). v14 signs `"*"`; the personality still
   limits matching to 1220:8FE4. A distribution profile names the vendor ID
   Apple grants (ADR 0002).
2. **Adding a USB personality changed the upgrade states.** v13 showed
   `activated waiting to upgrade` with v12 `terminating for uninstall`, not
   the earlier `terminating for upgrade via delegate`. The `exit` command
   still made way for the next version.
3. **Rollback needs the replug.** Deactivation alone gave the device back to
   the composite driver without audio. PROMPT.md's drill (deactivate, then
   replug) is the procedure.
4. **The `IOUserResources` personality outlives deactivation.** The control
   spike stopped and left Core Audio, but its process stays `terminating for
   uninstall but still running` until a reboot (ADR 0003 finding 7).

Consequences for Phase 4:
- The driver keeps a device session and never opens interfaces in Phases 4
  and 5. The polling interval for "response ready" (L-026) starts from the
  measured 1–4 ms per control transfer.
- Installing or updating a driver that holds the Mini needs a replug before
  it takes effect. Test scripts wait for one, as this spike's did.

### H2 (2026-10-31, the XLR driver, not the spike)

The real driver confirmed (B) on the Mini: the device session sent 21,450
polled commands while `usbaudiod` streamed, audio stayed bit-exact, and the
rollback drill worked through `goxlrctl driver deactivate` (STATUS.md "H2").
Two additions:
- **A USB driver update takes effect on replug.** v2 replaced a running v1
  with no approval: v1 stopped and closed the device when the Mini was
  unplugged, and v2 started on the replug (ADR 0003 finding 7's open case).
- **`usbaudiod` sees one GoXLR vendor interrupt per attach**, logs it as
  unsupported, and logs nothing more about interrupts (L-120). Audio is
  unaffected; whether it keeps polling 0x81 is unknown.

## Not decided here

- The full GoXLR (8FE0): whether one is available; its descriptors are
  unverified.
- Polling interval and backoff for "response ready" under (B): set from the
  spike's EP0 timings (1–4 ms per transfer) when the transport is written.
- Whether `usbaudiod` consuming the interrupt messages has side effects
  once DCP commands run (it receives "response ready" and the event flags,
  L-027, and ignores or logs them). Watch its log in the first command tests.
