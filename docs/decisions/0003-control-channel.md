# ADR 0003: Control channel between the helper and the dext

- **Status:** accepted: **option (d), a user client owned by the dext**, chosen
  by the user on 2026-10-31. It replaces option (b), chosen on 2026-10-30,
  after the spike showed that (b) can't return data to the host (findings 1
  and 10 to 13).
- **Date:** 2026-10-30; revised 2026-10-31

## Context

PROMPT.md §1.1 assumed an `IOUserClient` that only the helper may open. That
needs `com.apple.developer.driverkit.userclient-access` on the helper, which
Apple must grant: the development profile request was rejected with "requires
approval from Apple" (ADR 0002). The options were:
- (a) request the grant and wait;
- (b) AudioDriverKit custom properties through CoreAudio;
- (c) development with SIP disabled;
- (d), found by the spike: the dext carries
  `com.apple.developer.driverkit.allow-any-userclient-access`, which the
  development profile grants, and serves a user client that any process may
  open.

## Decision

The dext serves its own user client, and the helper and goxlrctl open it
through IOKit (`IOServiceOpen` with the dext's user-client type). They need no
restricted entitlement. The dext carries
`com.apple.developer.driverkit.allow-any-userclient-access`.

The channel, as the spike proved it (Results, v9 to v12):
- **command:** a synchronous structure method. The command id and payload go
  in; the status and reply payload come back;
- **info:** a synchronous method;
- **subscribe:** an async method. The dext sends events and state changes with
  `AsyncCompletion`, up to 16 × 64-bit values each. Anything larger is read
  with a command after the notification.

The dext's driver class keeps serving coreaudiod's own user client: its
`NewUserClient` handles only its own type and passes every other type to
AudioDriverKit.

The real driver publishes **no AudioDriverKit custom properties**. Reads can't
return data (findings 11 and 12), and a failing read on a device crashes
coreaudiod (findings 2 and 13).

Where a setting maps cleanly onto a standard control (`IOUserAudioLevelControl`,
`BooleanControl`, `SelectorControl`), the dext may publish that control too.
That choice is made per feature in Phase 5.

## What the SDK provides (DriverKit 27.0 headers, observed)

| Fact | Source |
|---|---|
| A dext serves a user client by overriding `IOService::NewUserClient` and creating the client class named in its personality (`Create(this, "<key>", …)`) | `IOService.iig:295`; spike `ControlSpike.cpp` |
| `IOUserClient::ExternalMethod` receives scalars, a structure (as OSData, or as a memory descriptor for large structures; the header gives no threshold) and, for async calls, an `OSAction` the dext must retain to use later | `IOUserClient.iig:80-125, 203-210` |
| `AsyncCompletion` sends up to `kIOUserClientAsyncArgumentsCountMax` (16) values | `IOUserClient.iig:51-53, 213-226` |
| `CopyClientEntitlements` returns the opening task's entitlements | `IOUserClient.iig:271` |
| `IOUserAudioDriver` overrides `NewUserClient`; coreaudiod asks for type `kIOUserAudioDriverUserClientType` (1128363364, `'CAHd'`) | `IOUserAudioDriver.iig:87`, `AudioDriverKitTypes.h:42` |
| Custom properties (option (b), not used): `IOUserAudioCustomProperty` on a control, box, stream, clock device, device or driver; types `None`, `String`, `Dictionary` | `IOUserAudioCustomProperty.iig:47-49`, `AudioDriverKitTypes.h:257-262` |

## Consequences

1. **The helper and goxlrctl need no restricted entitlement.** The helper
   keeps only `system-extension.install`, and goxlrctl runs from any terminal.
   The dext gains `allow-any-userclient-access`. The development profile
   grants it (finding 14). Whether a Developer ID profile does is unverified
   and matters for distribution (D6).
2. **Any local process can open the user client**, sandboxed apps included
   (finding 14), so the dext is the security boundary:
   - The dext accepts only commands in an allowlist, with per-command payload
     length and range checks. It rejects and logs anything else, and returns
     its reason in the reply, which (b) couldn't do (finding 3).
   - There is no raw vendor-request passthrough. There is no firmware write
     path; firmware updates are out of scope (D5).
   - Settings that can damage hardware, chiefly 48 V phantom power: **the
     user chose (2026-10-31) to allow them only from clients signed by the
     developer team.** When a user client opens, the dext calls
     `CopyClientEntitlements` and trusts the client only if its
     `com.apple.developer.team-identifier` equals the team in the dext's
     personality (`XLRTrustedTeam`, from `DEVELOPMENT_TEAM`). That
     entitlement is restricted, so only binaries signed through the team's
     profiles carry it. Verified on the Mini (driver v9): the helper app is
     trusted; the ad-hoc-signed `goxlrctl` is not, and its phantom-power
     command was rejected as hardware-risk without reaching the device. A
     command-line tool that needs it must be built as a signed app.
   - **On attach, the helper applies the saved mic type** (the user,
     2026-10-31). The Mini turns 48 V on at every power-up (LEDGER L-130),
     so each time the driver reports ready the helper turns it off unless the
     saved type is a condenser. It never turns 48 V on by itself: that needs
     the user's confirmation, which is also how the type becomes condenser.
     With no saved type it sends nothing. Verified with driver resets
     (L-131). The helper has to be running for this, so it opens at login
     (`SMAppService`, the user's choice, L-132). It can't stop 48 V
     reaching the mic in the seconds between power-up and the driver being
     ready.
3. **Where validation lives** (PROMPT.md §1.2 puts the codec in Swift):
   - (i) typed semantic properties, with encoding in the dext's C++;
   - (ii) a command carrying a command id plus payload, checked against a
     table generated from SPEC.md.
   - **Decided: (ii)**, by the user on 2026-10-30, and unchanged by (d). It
     keeps the codec in Swift and gives one source: SPEC.md §8 becomes the
     dext's table and the test vectors. Phase 4 adds a machine-readable copy
     of the §8 table and a generator for the dext's C++ table. Both the
     dext's table and the Python reference model
     (`Tests/Vectors/check_vectors.py`) must pass `Tests/Vectors/policy.json`.
4. **Phase 4 matching.** Control no longer requires an AudioDriverKit driver:
   any `IOService` can serve a user client. If the dext is an
   `IOUserAudioDriver` (it must be to stream, Phase 6), its `NewUserClient`
   passes coreaudiod's type to the superclass.
5. **Lifecycle.** The user client's `Stop` finishes only after its timers and
   queues have cancelled (finding 15). The helper must expect the dext to
   restart, for example on an update or a crash, and reopen the connection.
   The driver's and its user clients' `Stop` run in either order, so nothing
   on a `Stop` path may wait synchronously on a queue another `Stop` cancels:
   v1–v7 did (`DetachClient` onto the cancelled transport queue), which kept
   the driver's process alive after every re-attach with an app connected
   and blocked upgrades. v8 keeps clients under a lock and lets `Stop` wait
   for in-flight transport calls (LEDGER L-124, L-125).

## Unverified; check first in Phase 4

- Whether a Developer ID profile grants `allow-any-userclient-access`
  (finding 14).
- What a connected client sees when the dext restarts, and how quickly it can
  reopen. The spike never restarted the dext with a client connected.
- The event rate Phase 3 specifies, measured against a real fader rather
  than the spike's timer.
- Large structures arrive as a memory descriptor, at a size the header
  doesn't give. The spike's structures, up to 4096 bytes, arrived inline as
  OSData. No planned command comes close.

## Spike (Phase 4 step 0)

`Spike/ControlSpike` is an AudioDriverKit driver on `IOUserResources`, with
the bundle ID `yt.felix.xlr.spike.driver` and the entitlements `driverkit`
and `family.audio`. It touches no hardware. On the driver object it
publishes:

| Selector | Access | Value |
|---|---|---|
| `'xinf'` | read-only | `{spike, version, blob: OSData 00…0f, timebase}` |
| `'xcmd'` | settable | `{op: echo \| events \| device \| reject, …}` |
| `'xrep'` | read-only | the last accepted command's result |
| `'xevt'` | read-only | `{seq, t}`, where `t` is the dext's `mach_absolute_time` |

The `device` command publishes one audio device with no streams. That device
can't become a default device, and it carries `'xdev'`.

`Spike/ControlProbe` answers each question above from the HAL side:
- `find`: bundle-ID translation, or a search for the `'xinf'` carrier;
- `info` and `echo`: OSData and other types in both directions;
- `reject`: refused writes;
- `events`: latency and rate;
- `device`: the fallback.

The same probe, signed with `com.apple.security.app-sandbox`, answers the
sandbox question.

**Status:** v12 runs (since 06:45 on 2026-10-31). The user stopped v4 and v5
with `sudo kill` so that each next version could start (finding 7); v6 to v11
were stopped with the spike's `exit` command (finding 8). Since v7 the dext
has `com.apple.developer.driverkit.allow-any-userclient-access`, which Xcode
enabled on App ID `yt.felix.xlr.spike.driver` with the user's approval
(2026-10-31). Since v9 it also opens its own user client, type `'xlrc'`, for
`Spike/ControlProbe/UserClientProbe.c` (option (d)). Raw output:
`~/dev/goxlr-re/spike-logs/` (local).

### Results (v4)

| Question | Answer | Class |
|---|---|---|
| Properties visible with no audio device? | **Yes**, as a list. The driver object lists `'xinf'`, `'xcmd'`, `'xrep'` and `'xevt'` with type `'plst'`, and `AudioObjectIsPropertySettable` is right for each. **But every read fails** (finding 1) | observed |
| How does a client find the driver? | **Not by its bundle ID**: `TranslateBundleIDToPlugIn("yt.felix.xlr.spike.driver")` returns 0. The driver appears as a plug-in object (`'aplg'`) whose bundle ID is `com.apple.audio.IOUserAudio`, with no name, although the dext calls `SetName`. Its object ID changed when coreaudiod restarted (42 → 43). The probe finds it by walking `OwnedObjects` for the object that lists `'xinf'` | observed |
| OSData round trip? | **Host to dext: yes** (v6). CFData arrives as OSData, including inside a nested dictionary. CFString, CFNumber and CFBoolean arrive as OSString, OSNumber and OSBoolean. **Dext to host: no.** Reads fail inside coreaudiod (findings 1, 10–12) | observed |
| Notification latency and rate? | **One notification per change, none merged or lost**: 250 at 50 Hz, 1000 at about 440 Hz, and 2000 at about 870 Hz (the dext's timer rate), every one delivered. Write to reply notification: 0.26–0.77 ms. The dext-to-listener latency needs readable values | observed |
| Can sandboxed processes write? | **Yes.** A tool signed with only `com.apple.security.app-sandbox` found the driver, wrote six commands, all six reached the dext, and it got the notifications | observed |

### Results (v9–v12): the dext's own user client, option (d)

`UserClientProbe` opens the `IOUserService` whose `CFBundleIdentifier` is the
dext's, with `IOServiceOpen(…, 'xlrc')`. Selectors: 0 echo (structure in,
same bytes out), 1 info (scalars), 2 subscribe (async), 3 events (`{seq, t}`
per event through `AsyncCompletion`).

| Test | Result | Class |
|---|---|---|
| Open from an unsandboxed CLI | `IOServiceOpen` 0, `info` returns version and timebase. The CLI has no entitlement | observed |
| Echo, 2000 × 64 bytes | all 2000 identical; round trip p50 0.028 ms, p99 0.070 ms, max 0.34 ms | observed |
| Echo, 2000 × 4096 bytes | all 2000 identical; p50 0.027 ms, p99 0.043 ms, max 0.17 ms | observed |
| Events, 5000 at 1 ms | 5000 received, seqs 1–5000 in order, none lost; dext timestamp to callback p50 0.033 ms, p99 1.1 ms, max 5.1 ms. The dext's timer fired every 1.28 ms (p50), not 1 ms | observed |
| Events, 200 at 20 ms | 200 received in order; latency p50 0.063 ms, p99 1.3 ms | observed |
| Open from a sandboxed CLI (`app-sandbox` only) | works: open, echo, and 500 events in order. The sandbox applied (the system created its container). No `iokit-user-client-class` exception needed | observed |
| Open without `allow-any-userclient-access` (v11) | `IOServiceOpen` returns `0xe00002e2` (`kIOReturnNotPermitted`) from both CLIs. coreaudiod's own connection and the property writes still work | observed |
| Core Audio alongside | the custom-property writes and notifications keep working while `'xlrc'` clients come and go | observed |

### Findings

1. **Reads of driver-object custom properties fail, whatever the type.** coreaudiod logs `HALS_IOUAUCDriver.cpp:183 Failed to get property data list size '<sel>', object id 1`, and the client gets `'what'`. The size query a client makes succeeds (8, a CF reference); the fetch fails. v5 and v6 narrowed it down:
   - `SetQualifierAndDataValue` returns 0 for every value (v5).
   - Strings fail as well as dictionaries: `'xs00'` (String, no qualifier).
   - **Unqualified** (`'xinf'`, `'xrep'`, `'xs00'`): the framework calls `GetCustomPropertyValueWithQualifier`, which returns 0 and the stored value (OSDictionary or OSString). coreaudiod still fails. So the value is lost after the dext returns it, while the framework serializes it or sends it back to coreaudiod (v6).
   - **Qualified** (`'xs01'` and `'xd01'`, String qualifier `"q"`): `GetCustomPropertyValueWithQualifier` is never called. These fail earlier, in the qualifier path (v6).
   - The "allow any user client" entitlement doesn't change this (finding 10). The causes are in findings 11 and 12.
2. **The same failing read on a device crashes coreaudiod.** Reading `'xdev'` on the dext's stream-less device made coreaudiod dereference NULL in `HALS_IOUAObject::GetPropertyData` (`CFDataGetBytePtr`, `EXC_BAD_ACCESS` at 0; crash report 23:22:12). launchd restarted it within about 1.5 s, but every app's audio on the Mac dropped, the GoXLR's included. **Rule:** never read a dext custom property on a device until reads work on the driver object, and the real driver must never publish a device-level custom property it can't return.
3. **Errors collapse.** The client sees `'what'` (unknown property) for every failed write: the dext's `kIOReturnNotPermitted`, `kIOReturnUnsupported` and `kIOReturnBadArgument` alike. Writing a read-only property gives `'nope'`. So the dext's reason for a rejection must be readable separately, for example in the reply property.
4. **The CoreAudio client is `coreaudiod`**, which opens `IOUserAudioDriverUserClient` (`IOUserClientCreator` = pid of coreaudiod). No other process connects to the dext.
5. **Writes run the dext's handler synchronously.** The command's result is the write's result. Work deferred to the default queue, such as storing the reply and `PropertiesChanged`, was notified within a millisecond.
6. **A sandboxed tool must be a signed bundle ID.** An ad-hoc-signed CLI with `app-sandbox` traps in `_libsecinit_appsandbox` at launch. Signed with Apple Development and an embedded `Info.plist`, it runs.
7. **A running audio dext isn't replaced by a version bump.** sysextd marks v5 `activated enabled`, but kernelmanagerd logs `Failed to terminate dext …, it is being replaced` and leaves v4 `terminating for upgrade via delegate`, with uninstall at the next reboot. v4's process keeps running with coreaudiod's user client open, so v5 never starts. ADR 0002 Finding 1 ("same-team replacements need no new approval") came from replacing versions that had failed to launch. It holds for approval, not for swapping a running instance. A USB-matched dext would presumably be swapped by a replug (unverified). The `IOUserResources` spike needs a reboot, or the old process stopped.

8. **Stopping the old process starts the new version.** After `sudo kill` of v4 (and later v5), the kernel logged `dext was replaced` and launched the newest staged version against the same `IOUserResources` match. coreaudiod reconnected without crashing. The `exit` command (v6 onward; it traps the dext) does the same without sudo: v6 to v11 each started their successor within 3 s, and coreaudiod kept running (same pid all day). Each trap leaves a crash report for the dext.
9. **Apple's sample puts its custom property on a device**, as String data with a String qualifier, and documents no client-side read (WWDC21 10190). Findings 11 and 13 explain why that path fails too, so the device test was not run.
10. **`allow-any-userclient-access` doesn't fix reads** (v7). With the entitlement granted and signed, every read fails exactly as in v6.
11. **Qualifiers are broken between the HAL and the dext.** The client library converts a CFString qualifier itself (`HALC_ProxyObject::GetPropertyData` → `CACFString::GetUnicodeString`), so a client must pass a real CFString. Passing serialized bytes instead crashed the probe (not coreaudiod) in that call. What reaches the dext is 8 bytes that aren't a serialized object: AudioDriverKit logs `_CreateObjectFromSerializedData: Could not copy object from OSSerialization object` and dumps bytes that look like a pointer (inference). The getter is never called. The real driver must not use qualifiers. (observed; the pointer reading is inferred)
12. **Unqualified reads fail in coreaudiod, after the dext answers.** The dext-side flow, from AudioDriverKit's code and runtime logs: the user client's size method (selector 13) calls `IOUserAudioDriver::_GetPropertySize`, which finds the custom property, calls `GetCustomPropertyValueWithQualifier`, then sizes the value with `OSSerialization::createFromObject`. In v8 that serialization succeeds (16 bytes for `"plain"`, 152 for `'xinf'`), and coreaudiod throws `Failed to get property data list size` about 30 µs later (microsecond log timestamps, three reads). Nothing on the dext's side changes this. Hypothesis, unverified: the dext's buffer starts with signature byte `0xd4`, while the format IOKit's `IOCFSerialize` writes, and which the dext accepts on writes, starts with `0xd3`; coreaudiod may not accept the first. Checking it means analyzing coreaudiod's `HALS_IOUAUCDriver`.
13. **A device read would hit the same failure without a check.** Finding 2's crash is `HALS_IOUAObject::GetPropertyData` passing a NULL CFData to `CFDataGetBytePtr`: the device path gets the same empty result and doesn't test it. So a device-level String property would most likely crash coreaudiod again. Not run: the information wasn't worth dropping every app's audio. (inferred from the crash report)
14. **`allow-any-userclient-access` is what lets other processes open a dext user client.** With it, unsandboxed and sandboxed CLIs open `'xlrc'` with no entitlement of their own. Without it (v11), both get `kIOReturnNotPermitted`. The development profile grants it once the App ID has the capability. Whether a Developer ID profile grants it without Apple's approval is unverified (ADR 0002).
15. **A user-client `Stop` must wait for its timer's cancel handler.** v9 crashed the dext in `TimerDispatchSourceWasCanceled` when the client exited: `Stop` returned before the cancel handler ran, and `free()` released the timer under it. v10 calls `Stop(provider, SUPERDISPATCH)` from the cancel handler; every open and close since (about a dozen, v10 and v12) ended cleanly, and the only dext crash reports are the `exit` traps. The driver's own `Stop` had the same pattern and got the same fix. The real driver needs a regression test for it (consequence 5).
16. **IOKit calls a two-value async callback as `IOAsyncCallback2`** (`refcon, result, arg0, arg1`), not with an argument array. The probe crashed on its first event until v10 used that form.

### Outcome

The user chose (d) on 2026-10-31 (Decision above). The spike stays installed
until Phase 4 replaces it.

## Not chosen

- **(a) Request `userclient-access` from Apple.** The wait time is unknown,
  and (d) reaches the same kind of channel from the dext's side (finding 14).
  It stays available if distribution (D6) can't use (d).
- **(b) AudioDriverKit custom properties.** Chosen first, then dropped:
  reads can't return data (findings 1 and 10 to 12), and a failing read on a
  device crashes coreaudiod (findings 2 and 13). Writes and change
  notifications work, but they can't report device state.
- **(c) SIP-disabled development.** It lowers this Mac's security and isn't
  needed for the driver itself (ADR 0002 Finding 1).
