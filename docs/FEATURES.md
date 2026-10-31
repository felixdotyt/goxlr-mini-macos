# Feature parity matrix

Official GoXLR App v1.6.4.014 features, mapped to device commands
([commands.md](protocol/commands.md)), with the side that implements each
behaviour.

**Side:**
- **device**: the GoXLR does it once configured.
- **host**: our helper must do it, because the official app implements it in
  software.
- **both**: the host decides and the device executes.

**Status:** `spec` means the static analysis plus cross-check is done and the
feature awaits implementation. Every row is static only until the Phase 2/5
hardware sessions.

The persistence column says whether the device keeps the setting across a power
cycle. It is **unknown** for every row. In the state found in Phase 2, the
Mini's mixer outputs were empty under Apple's driver (LEDGER L-109): no routing
to the Stream Mix or Chat Mic Mix, and a silent processed mic. A power cycle
with no host commands changed nothing: the lighting stayed blue and the mixer
outputs stayed empty (L-113). goxlr-utility re-applies the whole profile on
every connect. Both suggest the device keeps little or nothing (inferred).
Phase 5 tests each row by setting it, power cycling, and reading it back.

| Feature | Commands | Side | Full | Mini | Firmware gate (inferred, from GU) | Persists? | Status |
|---|---|---|---|---|---|---|---|
| Channel volumes | 0x806 bank 0 | device | ✓ | ✓ | — | no (L-123) | verified on the Mini (L-123); helper Mixer page (app path not yet tried on the Mini) |
| Fader assignment | 0x805 | both (host picks, device applies) | ✓ | ✓ | — | unknown | verified on the Mini (L-123); helper Mixer page (app path not yet tried on the Mini) |
| Fader position read-back | 0x800 (faders A–D) | device | ✓ | ✓ | — | n/a | verified (L-119); shown live on the helper's Mixer page |
| Mute buttons, cough modes (hold/toggle, mute-to-X) | 0x809, 0x804, effect key MicInputMute; button events from 0x800 | host logic; device mutes | ✓ | ✓ | — | unknown | **implemented in the helper** (GoXLRKit `MixerModel`, unit-tested): mute to all (0x809) or to one output (routing rows), hold to mute to all, cough hold/toggle, bleep light; off until the user turns on button handling. Verified on the Mini: fader mutes to all, cough hold, bleep light (L-137); a fader-button hold, mute-to-X and the cough's toggle mode not yet tried. 0x809 verified (L-123); MicInputMute had no visible effect on the Mini (L-128) |
| Routing matrix | 0x804 | device | ✓ | ✓ | Mix2 changes row size | no (L-123) | Music and Mic rows verified (L-123, L-129); helper Routing page writes whole rows (row size from the firmware gate); indices 0/1 open |
| Mic type and phantom power | 0x80B MicType | device | ✓ | ✓ | — | no: 48 V on at every power-up (L-130) | verified on the Mini (L-127): value 1 = 48 V on; **hardware-risk**, team-signed clients only (ADR 0003); the helper applies the saved mic type on attach (L-131) |
| Mic gain (dynamic, condenser, TRS) | 0x80B | device | ✓ | ✓ | — | unknown | verified on the Mini (L-126): the last gain key written applies; the helper saves it and sends it at every attach (L-134) |
| Mic level meter | 0x80C (polled) | device data, host display | ✓ | ✓ | — | n/a | verified linear on the Mini (L-135), full scale inferred; live meter in the helper |
| EQ, 10-band (full) / 6-band (Mini) | 0x801 EQ keys (full); 0x80B 0x4xxxx/0x5xxxx keys (Mini) | device | ✓ | ✓ | — | unknown | Mini: only the 90 Hz key (and weakly 8 kHz) changed anything (L-136); not in the helper yet |
| Compressor | 0x801 and/or 0x80B keys | device | ✓ | ✓ | — | unknown | Mini: 0x80B threshold, ratio, attack, release (L-139) and make-up (L-136) verified; all in the helper's Mic page, each with a one-line description |
| Noise gate | 0x801 and/or 0x80B keys | device | ✓ | ✓ | — | unknown | Mini: 0x80B GateThreshold 0x30200 verified (L-128); 0x801 gate keys had no visible effect; the power-up threshold silenced speech (L-133); the helper saves the threshold and sends it at every attach (L-134); attenuation (L-136), attack and release (L-139) verified; all in the helper |
| De-esser | 0x801 key 0x0B | device | ✓ | ? | — | unknown | spec |
| Bleep (swear) button and level | 0x801 BleepLevel, 0x80B 0x70100; event flag 0x200000 | both (trigger path unknown) | ✓ | ✓ | — | unknown | the device makes the tone (the user heard it at H2 with no host logic); the helper lights the button while held. the helper's bleep level works (L-137): the tone is about −5 dBFS at power-up and −37 dBFS at −34 dB, the lowest in goxlr-utility's range; the user finds that still too loud |
| Effects: reverb, echo, pitch, gender | 0x801 keys; encoders 0x80A, 0x811 | device DSP; presets on the host | ✓ | — | — | unknown | spec |
| Effects: megaphone, robot, HardTune | 0x801 keys; HardTune routing byte in 0x804 | device DSP; presets on the host | ✓ | — | — | unknown | spec |
| Effect preset banks (FX select 1–6) | button events; 0x801 reload | host | ✓ | — | — | n/a | spec |
| Sampler (pads, banks, record, play) | button events; LEDs 0x808; audio via the "Sample" devices | host | ✓ | — | — | n/a | spec; audio path needs Phase 6 |
| Button lighting | 0x808, 0x803 | both | ✓ | ✓ | 520-byte colour map ≥ 1.3.40 (full) / 1.1.8 (Mini) | 0x803 no (L-122) | verified on the Mini (L-121, L-122) |
| Global colours and fader meters | 0x803, 0x814 | device | ✓ | ✓ | as above | no (L-122) | verified on the Mini (L-122); the helper sets fader display modes (0x814) and edits the colour map (GU's layout; the Mini's lights only; sent on request). Sent from the app once: a strip shows the knob only when its two colours differ; the first colour is below the knob (L-137) |
| Animations | 0x816 | device | ✓ | ✓ (Ripple refused per GU) | ≥ 1.3.40 / 1.1.8 | unknown | mode 0 seen on the Mini (L-122); the helper's Lighting page sends modes, modifiers and waterfall (the user sent some from the app on 2026-10-31; nothing recorded) |
| Scribble strips | 0x802 (host renders 128 × 64 1-bit images) | host renders, device shows | ✓ | — | — | unknown | spec |
| Submixes and monitor mix | 0x817, 0x818, 0x806 bank 1 | device | ✓ | ✓ | ≥ 1.4.2.107 / 1.2.0.46 | unknown | spec; 0x817 size differs (commands.md Q3) |
| Stream Mix 2 | 0x804 (26-byte rows), 0x817 | device | ✓ | ✓ | ≥ 1.5.0 / 1.3.0 | unknown | spec |
| Device info: firmware, DICE version, serial, colourway | 0x80F:0, 0x80F:1 | device | ✓ | ✓ | — | n/a | verified (L-118); helper Device page (serial shown on request, never stored) |
| Profiles and mic profiles (load, save, import official `.goxlr`) | all of the above | host | ✓ | ✓ | — | n/a | **in the helper**: own JSON profiles holding any of mixer, mic (with processing) and colours, applied part by part; five starting profiles on first launch (layout, lights off, SM7B, condenser, processing off); update, export and import as files; a profile picker in the menu bar; and import of official profiles (volumes, routing, fader channels and displays, mute functions; the four sample profiles import); official mic profiles not covered (no sample) |
| Firmware update | 0x810, DICE 4:x | — | — | — | — | — | **out of scope (D5)**; never sent |

## Not yet mapped

- Device settings pages (hold times, VOD "stream no music" mode, sample-rate
  options). These are mostly host settings; to be mapped from the app UI
  strings when the helper is designed (Phase 7).
- Anything firmware-gated in the official app itself: its gate checks are not
  yet analysed; the gates above come from goxlr-utility.
