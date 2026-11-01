# Status

- **Phase:** 5 (writes) and 7 (helper app), in parallel. Device: GoXLR Mini
  (1220:8FE4), firmware 1.1.8.43, driver v10 (writes up to tier 6).
  - **Verified on the Mini:** tiers 1–4 (lighting, faders, volumes, mute,
    routing; L-121–L-123) and tier 5 with a condenser mic: gain, gate
    threshold and attenuation, compressor make-up, phantom power (only the
    team-signed helper can turn it on, after the user confirms), the mic
    meter's scale (L-126–L-136). The Mini turns 48 V on at every power-up
    (L-130); the helper turns it off at attach unless the saved mic is a
    condenser (ADR 0003). Tier 6 (0x801) keys tried did nothing on the Mini
    (L-128); most of goxlr-utility's Mini EQ keys did nothing either (L-136).
  - **Helper (menu bar app, opens at login):** a window with Mixer, Routing,
    Mic, Buttons, Lighting, Profiles and Device pages; host-side buttons (fader mutes
    to all or to one output, hold to mute to all, cough hold/toggle, bleep
    light); colours and animation; own profiles and import of official
    `.goxlr` profiles (with colours); live mic meter and fader positions.
    Runs against the simulator (`--simulate`). GoXLRKit has 68 tests. Checked on the Mini from the app: the attach
    (mic settings), button handling (L-137), colours, every gate, compressor
    and bleep control (L-139), and a dynamic mic (SM7B, gain to 72 dB, L-138).
  - Driver lifecycle bug fixed (L-124, L-125); updates go through
    `goxlrctl driver reset` without an unplug.

## Waiting for you

Decisions:

1. **Button handling** is on since you tried it (2026-10-31), with faders A
   Mic, B Chat, C Music, D System. Keep it, or turn it off on the Buttons
   page.
2. **Restore the mixer at attach** (Profiles page, off): the Mini forgets
   faders, volumes and routing at every power-up; with this on the app sends
   them each time it attaches.
3. **EQ:** most Mini EQ keys did nothing (L-136). Worth a session with you
   talking into the mic to map the bands, or leave the EQ out?
4. **Packaging for other Macs:** the source is public at
   <https://github.com/felixdotyt/goxlr-mini-macos> since 2026-10-31 (MIT; a
   fresh single commit by the GitHub no-reply address, without `PROMPT.md`,
   `PLAN.md` or this history; its working copy is `~/dev/goxlr-mini-macos`).
   For signed downloads you chose a Developer ID request (ADR 0005). The
   [DriverKit entitlement request](distribution/driverkit-entitlement-request.md)
   was submitted on 2026-11-01: USB Transport for
   vendor 4640 and UserClient Access for `yt.felix.xlr.driver`. Apple replies
   by email to the account's address; forum reports suggest a week or two.
   The app is called **GoXLR Mini Mac** since 2026-11-01 (your decision,
   replacing PROMPT.md D8's "XLR Helper"); the bundle IDs are unchanged, so
   the request, which names the app XLR Helper, still covers it.

To try with you at the Mini (each needs you there):
- volumes from the app, with you listening at low volume;
- applying an imported profile;
- the helper starting at login (after your next restart).

## Not yet done

- The Mini's EQ (key map unresolved, L-136).
- Official mic profiles (no sample file).
- Submixes and Stream Mix 2 (not on this firmware; routing writes are
  refused on Mix2 firmware until modelled).
- Phase 6 streaming in the dext.
- **Updated:** 2026-10-31

## Phase 3 results (spec; no hardware)

- **3a, conflicts:** LEDGER L-060 to L-066. Each lists the sources, the
  choice SPEC.md makes, and a read-only-first resolution plan. No conflict
  needed a hardware session yet.
- **3b, Windows captures:** skipped (D3 = no).
- **[protocol/SPEC.md](protocol/SPEC.md):**
  - USB requests;
  - global data;
  - framing and the reply check order;
  - sequence and retry rules;
  - interrupt and polling completion;
  - status codes and our error cases;
  - the dext's start sequence;
  - the default-deny command policy;
  - firmware gates and input state.

  Every section cites ledger ids.
- **[`Tests/Vectors/`](../Tests/Vectors/):** 64 hand-written vectors
  (transport, commands, policy) and an independent checker. 64/64 pass.
  Mutating every byte, the checker misses only fields the spec says not to
  read.
- **Decided** (ADR 0003 consequence 3, the user, 2026-10-30): the dext
  enforces a table generated from SPEC.md §8. The checker's policy function
  is the reference model.

## Phase 2 results (GoXLR Mini, under Apple's driver)

Documents:
- [hardware/baseline-8fe4.md](hardware/baseline-8fe4.md): what ran, which
  driver owns what, the unplanned re-enumeration, and what's left;
- [protocol/STREAMING.md](protocol/STREAMING.md): endpoints, clock and
  feedback, rates, channel maps, latency;
- ledger L-100 to L-112, with L-046 now observed and L-091 resolved.

Tools (committed): `Tools/usbdesc` (descriptor reader, `GET_DESCRIPTOR`
only), `Tools/caprobe` (CoreAudio report) and `Tools/refaudio` (tone
loopback, analysis, clock rate). Raw output is in
`~/dev/goxlr-re/hardware-logs/h0/` and `reference-audio/`.

| PROMPT.md Phase 2 item | Result |
|---|---|
| Descriptors | **Done.** Three UAC2 interfaces. Interrupt endpoint 0x81 (6 bytes, 16 ms); playback 0x08 and capture 0x88, both isochronous and asynchronous, 0x88 marked implicit feedback; 4-byte subslots, 24-bit. Feature units have no controls. |
| Vendor-specific interface | **None.** DCP requests go to the Audio Control interface (L-100). |
| CoreAudio reference | **Done.** One device: 10 out, 21 in, all channels named by the device, 48 kHz only, 14-frame latency and safety offset each way. Channel map vs INF in STREAMING.md: Windows exposes only capture 1–6 of 21. |
| Reference recordings | **Done, adapted.** The mixer was empty, so "Music to Stream Mix" was impossible. The raw taps (capture 9–16) return playback 1–8 bit-transparently with a fixed 15-frame loop: that is the Phase 6 A/B baseline (two identical runs). The device clock measured +17.7 ppm. |
| Cold boot without init | **Audio interfaces enumerate and stream with no host init** (no GoXLR software on this Mac). Apple's driver sends its own UAC2 `SET CUR` of 48 kHz at attach: the same request goxlr-utility uses to initialise the device (L-112). |
| Power-cycle persistence (added) | **Done for the state found.** With no host commands, a power cycle changed nothing: lighting stayed blue, and run 3 matches runs 1–2 (L-113). Settings the host makes are tested in Phase 5. One unplug gave three detaches in 11 s (contact bounce, inferred). |
| DCP global data (L-090, added) | **Done.** The read works under Apple's driver without opening the device: `dcp_version` 2, maximum payload 1024 (L-114). An A/B after a second power cycle showed that a low-frequency wobble on the dry mic input was not caused by the read (L-115). |

Consequences for Phase 4 (ADR 0004, matching):
- With no vendor interface, PROMPT.md's "otherwise" branch applies: the dext
  matches the device by VID/PID, and the user loses audio until Phase 6. Tell
  the user before H2.
- **Candidate to evaluate in ADR 0004 (inferred, unverified):**
  - The dext matches the **device** (`IOUSBHostDevice`), replacing Apple's
    composite driver, which only configures the device and then closes it.
  - It sets the configuration and sends DCP requests on the default pipe.
    The interfaces are left to `usbaudiod`, so Apple's audio keeps working
    during Phases 4–5.
  - This is how goxlr-utility works on macOS with libusb, from user space.
  - **Risks:** whether `usbaudiod` still matches the interfaces under a
    third-party device driver, and how ownership and readiness interact.
- The dext must handle the device's interrupt endpoint itself. Apple's driver
  already polls it (`usbaudiod`), so in the candidate above the dext would not
  receive those messages. That favours polling for "response ready" (as
  goxlr-utility does on macOS) unless the dext owns interface 0.

## Phase 1 results (static only; nothing run against hardware)

Documents:
- [protocol/LEDGER.md](protocol/LEDGER.md): transport, driver duties and the
  goxlr-utility cross-check;
- [protocol/commands.md](protocol/commands.md): the command catalog;
- [FEATURES.md](FEATURES.md): the feature map;
- [protocol/profile-format.md](protocol/profile-format.md).

Local evidence (not committed) is in `~/dev/goxlr-re/evidence/`:
- REA bundles `rea-app-v1.6.4.014.bundle.json` (148 records) and
  `rea-driver-5.12.0.bundle.json` (115);
- the app snapshot;
- per-caller notes and structure summaries.

Checklist from PROMPT.md Phase 1:

| Step | Result |
|---|---|
| 1. Identity and extraction | **Answered.** Hashes match §2. The bundled driver's 61 files are identical to the supplied one's. No firmware files in the installer. |
| 2. Triage | **Answered.** The app is a 32-bit native JUCE program. |
| 3. PE surface | **Answered** for the app, the API DLL and `goxlr_audio.sys`. The app loads the API DLL by name at run time (API ≥ 5.0). `GoXLRAudioCplApp.exe` was not inspected; not needed. |
| 4. Command layer | **Answered:** DCP framing, the four vendor requests, sequence and status handling, 200 ms / 3000 ms timeouts, one retry after 0:0, interrupt-driven "response ready" and "inputs changed" messages, open/init order, and every command category and index the app sends. **Partial:** the official names behind the 0x801/0x80B parameter numbers, routing rows 0/1, and the 0x817 size difference. |
| 5. Driver duties | **Answered:** no vendor requests or rate change at start; every 6-byte interrupt message is forwarded to the app; no VID/PID branches; Linux has no GoXLR quirk. **Partial:** implicit feedback (inferred) and buffer units. Endpoint details need Phase 2 descriptors. |
| 6. Feature catalog | **Answered** in commands.md and FEATURES.md. **Unresolved:** which host-set settings survive a power cycle (Phase 5; with no host commands nothing changed, L-113). |
| 7. Profile formats | **Partial:** `.goxlr` container and XML structure documented; value encodings and the mic-profile format (none shipped) are open. |

Exit criterion: every FEATURES.md command and streaming question has a source,
or is listed as unknown with a plan. **Met.** The streaming unknowns go to the
Phase 2 descriptors.

Design consequences found in Phase 1, for Phase 4:
- The dext can wait for "response ready" on the interrupt endpoint instead of
  polling (LEDGER L-043, L-054).
- A device with no host driver must be initialised by us (L-055).

## Done (Phase 0)

- Workspace: this repo (`git init`) and the skeleton dirs; `~/dev/goxlr-re/`
  holds RE material and is never committed.
- G0 approvals from the user: the install batch, REA registration, Team ID use
  with device and App ID registration, and the bundle prefix `yt.felix.xlr`
  (PROMPT.md D4, D8).
- Toolchain:
  - Node: Homebrew `node@24` 24.22.2 (keg-only), used for REA. `.nvmrc` pins
    24.22.1, and 24.22.2 satisfies `^24.22.1`.
    - REA's build scripts fail on Node 26: they use `stripTypeScriptTypes` mode
      `transform`, which Node 26 removed.
    - Side effect: installing `node@24` broke `node@22` (a shared simdjson
      upgrade). The fix upgraded `node@22` to 22.23.4.
  - Ghidra 12.1.4 at `~/dev/tools/ghidra_12.1.4_PUBLIC` (SHA-256 verified),
    with an arm64 native decompiler built per REA docs.
  - Temurin JDK 21.0.13+9 at `~/dev/tools/jdk-21.0.13+9` (SHA-256 verified).
  - innoextract 1.10-dev at commit `6e9e34e` (Inno Setup up to 6.3.3), at
    `~/dev/tools/bin/innoextract`.
    - It was built by hand with Homebrew boost and cmake, because Homebrew
      refuses source builds: it reports the Command Line Tools as outdated or
      modified.
- REA: `npm ci && npm run build:cached` passes on node@24.
  - `rea doctor --json` reports Ghidra configured and available. All checks
    pass, including `native_decompiler` (mach-o arm64) and `java` (JDK 21).
  - `rea setup --client claude_code` is applied. It wrote the `rea` MCP server
    to `~/.claude.json` (backup in `~/.claude.json.rea.backup`) with
    `GHIDRA_INSTALL_DIR` and `JAVA_HOME`, and installed the skill to
    `~/.claude/skills/reverse-engineer-anything`.
  - The registration uses the versioned path
    `/opt/homebrew/Cellar/node@24/24.22.2_1/bin/node`. Rerun setup after any
    `brew upgrade node@24`.
- SDK check: ADR [0001](decisions/0001-sdk.md). DriverKit 27.0 has
  `IOUSBHostPipe::IsochIO` and frame lists, device requests, and multiple
  `IOUserAudioDevice`s per driver with a shared clock domain.
- Signing spike (`Spike/`, ADR [0002](decisions/0002-signing.md)):
  - Development signing works on the user's team. This Mac is registered.
  - The user approved the spike dext once in System Settings. Later versions
    replaced it without a new approval.
  - Variant B v3 **runs** with the real dext entitlement set: `driverkit`,
    `transport.usb` (`idVendor` string `*` for development) and
    `family.audio`. IORegistry shows `HelloDriver` registered and active.
  - Lessons for Phase 4 (first driver code):
    - Debug entitlements must match the profile's `*`.
    - Check that the embedded profile lists this Mac before installing.
    - `activated enabled` doesn't mean the dext runs; confirm its process and
      IORegistry service.
    - Dext `os_log` lines are visible only live in `log stream`; test scripts
      capture it from the start.
    - Deactivation needs the user's password; prefer version-bumped
      replacements.
  - Removed: `0 extension(s)`, no dext process, `/Applications/SpikeHost.app`
    deleted.
- Control channel decided (user, 2026-10-30): AudioDriverKit custom properties
  through CoreAudio, with no `IOUserClient` (ADR
  [0003](decisions/0003-control-channel.md)). PROMPT.md and PLAN.md are
  updated: Phase 4 starts with a control-channel spike, and the matching ADR
  becomes 0004.
- Control channel revised (user, 2026-10-31): the dext's own user client,
  option (d), because the spike showed custom properties can't return data.
  PROMPT.md, PLAN.md and ADRs 0001 to 0003 are updated.

- Phase 0 exit: REA's MCP tools load in Claude Code, and `binary_session`
  reports Ghidra available. It opened the 32-bit and 64-bit Windows targets.

## Waiting on the user

- **Full GoXLR (8FE0):** is one available? Its descriptors are unverified.
- **Before Phase 5:** how the dext gates 48 V phantom power and other
  hardware-risk writes, since any local process can open the control user
  client (ADR 0003 consequence 2).

## Next

1. Tiers 5–6 (mic gain, EQ and dynamics): mic monitoring off and low volume.
   Phantom power additionally needs the user to confirm the attached mic,
   and a team-signed client to send it (the helper).
2. GoXLRKit device model: a single writer that re-applies state on attach,
   since the device keeps nothing across a power cycle.

## H2 (2026-10-31, GoXLR Mini, firmware 1.1.8.43)

| Check | Result |
|---|---|
| Install | The user approved the driver in System Settings once; v2 replaced v1 with no new approval, effective on a replug |
| Start sequence | v1 stopped at 0x80F:0: it sent sequence 0 after the reset, which the Mini refused (L-117). Fixed in v2 (SPEC.md §4 now explicit); v2 started on the first attempt |
| `goxlrctl info` | Firmware 1.1.8.43, DCP 2, maximum payload 1024; the user checked the serial against the label (not recorded) |
| 10-minute `watch` | 630 s, 539 input events, none lost (consecutive sequence numbers), no disconnects; every fader 0–255, mutes, Bleep, Cough as the user worked them (L-119) |
| Polling | 21,450 polls, 0 failed, 0 retries; 9 client commands, 2 correctly refused (L-120) |
| Audio | Reference runs 12, 13 (driver running) and 14 (after rollback) bit-exact against the Phase 2 baseline |
| Second client | The user's own `goxlrctl watch` ran alongside: on subscribing it got the current state at once (#405), then the same events (#406–#540) as the recorded watch, including two mutes held together. At deactivation it reported the disconnect and kept waiting, as `DriverMonitor` should |
| Rollback | `goxlrctl driver deactivate`, the user's password and a replug: Apple's composite driver and `usbaudiod` back |
| Open | One `usbaudiod` "unsupported interrupt" error per attach; whether it keeps polling 0x81 afterwards (L-120) |

Logs: `~/dev/goxlr-re/hardware-logs/h2/` (local). The helper stays installed
in `/Applications`; the driver is deactivated.

## Phase 4 code (2026-10-31; offline only, nothing sent to the GoXLR yet)

- `Driver/XLRDriver`: the dext. Matches 1220:8FE4, keeps a device session,
  sets the configuration with the interfaces left to Apple's driver (ADR
  0004), and runs SPEC.md's start sequence: global data, reset, 0x80F:0,
  0x800:0. Commands are serialised on one queue, replies are polled
  (bRequest 3, 10 ms, 3000 ms), and a failed command gets one reset and one
  retry. The input state is polled every 20 ms and sent to subscribers as
  events. Every client command passes the generated policy table first;
  write-class commands are refused in Phase 4. The driver never reads or
  logs the serial.
- Policy: `docs/protocol/policy-table.json` is the machine-readable SPEC.md
  §8; `Tools/policygen/policygen.py` generates
  `Driver/XLRDriver/PolicyTable.generated.h` and checks the categories match
  SPEC.md. `Tests/Policy/check_policy.py` runs `policy.json` through the
  dext's C++ evaluator: 26/26. A mutation (phantom power allowed) fails it.
- ABI: `Packages/GoXLRKit/Sources/XLRDriverABI/include/XLRDriverABI.h`, one
  header for the dext and Swift.
- `Packages/GoXLRKit`: the codec (38/38 transport and command vectors), the
  ABI types, `DriverClient` (IOKit) and `DriverMonitor` (reconnects when the
  driver restarts), and a `Simulator`. `swift test`: 6 tests pass.
- `Tools/goxlrctl`: `info`, `watch`, `read`, `driver activate|deactivate|status`,
  each with `--simulate`. Checked against the simulator only.
- `XLR.xcodeproj` (driver + helper): builds signed. With the user's approval
  (2026-10-31), Xcode created development App IDs `yt.felix.xlr.driver`
  (DriverKit, USB transport `idVendor *`, allow-any-userclient-access) and
  `yt.felix.xlr.helper` (System Extension). Both profiles list this Mac and
  grant exactly the signed entitlements. Not yet installed or run.
- Not verified: everything on hardware, including the reset reply's contents
  (no vector), polling under `usbaudiod`, and event delivery to a real client.

## Open questions

- What does one `IOUSBIsochronousFrame` entry cover on high-speed endpoints:
  a 1 ms frame or a 125 µs microframe? See ADR 0001 §3. The Mini's streaming
  endpoints run every microframe (`bInterval` 1, STREAMING.md). Resolve in
  Phase 6.
- Whether `usbaudiod` keeps polling the interrupt endpoint under our driver
  after its one "unsupported interrupt" error per attach (L-120, ADR 0004).
- Why does `log show` drop the dext's `os_log` lines that `log stream` shows?
  See ADR 0002 Finding 3. Resolve early in Phase 4.
- Whether a Developer ID profile grants `allow-any-userclient-access` (ADR
  0003, needed for distribution only).
