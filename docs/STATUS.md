# Status

Updated 2026-11-01. Tested on one GoXLR Mini (firmware 1.1.8.43) with
macOS 27 on Apple silicon. [FEATURES.md](FEATURES.md) maps each feature to its
commands, and the [ledger](protocol/LEDGER.md) records each finding and how it
was measured.

## Checked on the Mini

- Lights, fader assignments and displays, channel volumes, mutes and routing
  (L-121 to L-123, L-141).
- Mic type and 48 V phantom power, gain up to 72 dB, noise gate, compressor,
  bleep volume and the level meter (L-126 to L-139).
- From the app: fader mutes to everything, cough hold and the bleep light
  (L-137).
- After a power-up: the app sends the mic settings (L-131, L-134) and the
  saved mixer when the Mini attaches, and the Mac is heard from about 5 s
  after (L-143, L-144).

## Not tried yet

- Applying an imported official `.goxlr` profile.
- The app opening at login.
- Holding a fader's mute button, muting to one output, and the cough
  button's toggle mode.
- Other firmware versions, other Minis, and Intel Macs.

## Not done

- The Mini's EQ: most of the settings tried did nothing (L-136).
- Official mic profiles (there's no sample file to work from).
- Stream Mix 2 and submixes, on newer firmware. The app refuses routing
  changes on that firmware until they're modelled.
- The full-size GoXLR.
- Audio through this driver; Apple's driver handles the sound.

## Known issues

- The bleep tone is about −37 dBFS at its lowest setting (−34 dB, the lowest
  goxlr-utility offers), which is still loud (L-137).
- After a power-up the Mac is silent for about 5 s, until the app sends the
  fader volumes again (L-143).

## Downloads

There's no signed download yet. Distributing a DriverKit driver needs Apple's
approval; the request was sent on 2026-11-01
([ADR 0005](decisions/0005-packaging.md)). Until then, build it yourself
([README](../README.md#build-it-yourself)). One question remains for
distribution: whether a Developer ID profile allows the driver's user client
the way a development profile does
([ADR 0003](decisions/0003-control-channel.md)).
