# Official profile format (`.goxlr`)

These notes are for importing official GoXLR profiles (PROMPT.md Phase 1 step
7). They describe structure only; no profile content is copied here.

**Sources:**
- the five profiles shipped with app installer v1.6.4.014;
- REA inventory `ev_d293c9db…`;
- extraction `ev_c6a6319c…`;
- a local structure summary `~/dev/goxlr-re/evidence/profile-xml-schema.txt`
  (not committed);
- for the value encodings, REA bundle
  `~/dev/goxlr-re/evidence/rea-app-profile-importer.bundle.json` (not
  committed), from the app v1.6.4.014.

Everything is **derived** from those files unless marked otherwise. Mic profiles
are not covered: the installer ships an empty `MicProfiles` folder.

## Container

- A ZIP archive with stored (uncompressed) entries.
- **Entries:**
  - `profile.xml` (≈ 25 KB);
  - `scribble1.png` … `scribble4.png`: 256 × 128 PNG images, one per fader
    scribble strip. The device strip is 128 × 64 at 1 bit per pixel
    (commands.md 0x802), so the PNGs are presumably drawn at twice the
    device's resolution (inferred).
- The `Default.goxlr` installed under the user's app-data folder is damaged and
  unreadable:
  - it has 1776 U+FFFD replacement sequences;
  - every LF has become CR LF;
  - its five ZIP entry headers are intact, but the replaced bytes are lost.

  This looks like a text-mode re-encoding during packaging (inferred). The
  importer must reject such files cleanly rather than half-load them. It does:
  the end record's central-directory offset was itself re-encoded, so the
  file has no valid end record (`StoredZipError.noEndRecord` in the opt-in
  sample test).
- `profile.xml` in the good samples is UTF-8 with CR LF line ends and a blank
  line after the XML declaration (JUCE's default output). CR LF inside the
  entry is therefore not damage; damage shows as failed offsets, sizes or
  CRC-32.

## `profile.xml`

A JUCE `ValueTree` serialised as XML. Most attribute names repeat their element
name as a prefix (e.g. `mute1colour0` on `mute1`).

| Element | What it holds |
|---|---|
| `ValueTreeRoot` | `version` (1 in the samples); `loudness`; `device` = the USB product ID the profile was made for (36832 = 0x8FE0, full GoXLR) |
| `mixerTree` | Channel levels: `headphoneLevel`, `micLevel`, `chatLevel`, `gameLevel`, `consoleLevel`, `musicLevel`, `lineInLevel`, `systemLevel`, `sampleLevel`, `mic2headphoneSubLevel`, and in one sample `lineOutLevel`. Routing switches named `<input>To<output>` for inputs mic, lineIn, system, game, chat, music, sample, console and outputs Stream, Chat, HP, Sampler, LineOut. One sample also has `MiniLockFadersToLabels`. |
| `FaderMeter0` … `FaderMeter3` | Per-fader channel assignment (`listIndex`), colours and display mode |
| `scribble1` … `scribble4` | Scribble strip: icon file, two text lines, alpha, inverted flag, colour |
| `mute1` … `mute4` | Fader mute buttons: state, colours, `Function` (mute behaviour), blink, previous level |
| `effects1` … `effects6` | Effect preset bank buttons: name, colours, state |
| `reverbEncoder`, `echoEncoder`, `pitchEncoder`, `genderEncoder` | Encoder colours and `active_set`. Six presets each (`…preset1`–`6`) with upper-case parameter names, e.g. `REVERB_DECAY`, `DELAY_FB_L`, `PITCH_RANGE`, `GENDER_RANGE`, plus a `…_KNOB_POSITION` |
| `megaphoneEffect`, `robotEffect`, `hardtuneEffect` | Button colours and state (`hardtuneEffect` also `HARDTUNE_SOURCE`); six presets each with upper-case parameters (`MEGAPHONE_STYLE`, `TRANS_*`, `ROBOT_*`, `HARDTUNE_*`) |
| `sampleBankA`–`C`, `sampleTopLeft`, `sampleTopRight`, `sampleBottomLeft`, `sampleBottomRight`, `sampleClear` | Sampler buttons. Each pad has `sampleStackA`–`C` children listing samples (`stackSize`) |
| `swear`, `muteChat`, `fxClear`, `logoX` | Bleep, cough, FX clear and logo buttons: colours and state. In one sample `muteChat` also has `coughButtonToggleSetting`, `coughButtonMuteSourceSelection`, `coughButtonIsOn` and an unprefixed `blink` |
| `globalColour` | Global colour |
| `selectedContext` | UI selection state (selected bank, effect bank) |
| `browserPreviewTree`, `AppTree` | App UI and last connected device id. Host state, not device settings |

The samples don't all carry the same attributes (one lacks
`FaderMeter<n>Display`; only that one has the cough and `MiniLockFadersToLabels`
attributes), so an importer must treat every attribute as optional.

## Value encodings

Each value below is classed as in commands.md. "Samples" means the four good
profiles; Evidence IDs are in the bundle named under **Sources**.

| Value | Encoding | Class |
|---|---|---|
| Levels: `mixerTree` `…Level`, `mute<n>prevLevel` | Decimal integers. The samples use only 0–255, the u8 range of 0x806 volumes. | derived (range); the link to 0x806 inferred |
| `mic2headphoneSubLevel` | The mic monitor level (channel 9, MicMonitor). | inferred from the name |
| Routing switches `<input>To<output>` | 8192 = routed, 0 = not routed; the samples have no other values. 8192 is 0x2000, a u16 whose high byte is 0x20, the "routed" byte of 0x804 rows. | derived (values); the link to 0x804 inferred |
| Colours: `…colour0`, `…colour1` | Eight hex digits, AARRGGBB. Upper and lower case both occur, even within one profile. Each colour-named profile carries its colour in the RGB digits with alpha FF; unused slots are often `00000000`. What alpha does on the device is unknown. | derived |
| Colours, imported | The helper takes colour 0 and 1 of the four faders, four mute buttons, `swear` (Bleep), `muteChat` (Cough) and `logoX` when all are readable, as each fader's colours below and above the knob (the map's slot order, L-137) and button on/off (goxlr-utility's meaning). That the official app orders a fader's colours the same way is inferred: imported as is, its default profile (colour 0 black, colour 1 cyan) lights the strip above the knob. The four samples have all of them. | derived (presence); meaning inferred |
| `…offStyle` | `DIMMED`, `COLOUR2` or `DIMMEDCOLOUR2`. The samples use all three, and these are the value strings the app keeps next to `offStyle` (ev_1abab184…). | derived |
| `FaderMeter<n>Display` | The samples use `GRADIENT`. The app also has `METER`, `GRADIENT_METER` and `TWO COLOR` next to it (ev_1abab184…). | derived (strings); each string's look inferred from its name |
| `FaderMeter<n>listIndex` | A position in the app's fader channel list: 0 Mic, 1 Chat, 2 Music, 3 Game, 4 Console, 5 Line In, 6 System, 7 Sample, 8 Headphones, 9 Line Out. | 0, 1, 2 and 6 derived from the samples: each fader's scribble label and icon follow its index, also when a profile swaps two faders. 3–5 and 7–9 derived from the order in which the app builds its channel list (ev_8cf4f7bf…); that this list is the one `listIndex` indexes is inferred, but it matches all four observed positions |
| `mute<n>Function` | The samples have only `All`. The app labels its five mute functions `Mute All`, `Mute to Stream`, `Mute to Voice Chat`, `Mute to Phones` and `Mute to Line Out` (ev_9d065836…). A parser routine classifies a string by case-sensitive substring, in the order `All`, `Stream`, `Chat`, `Phones`, `Line Out`, and falls back to mute all (ev_6435f4e6…, substring search ev_d5f42d00…). | derived (strings and routines); that these routines serve this attribute is inferred (they are reached indirectly) |
| `…state`, `…blink`, `…selected`, `…velocity` | Integers. Every sample has 0, except `velocity`, which is 127. | derived (values); meaning unknown |
| `muteChat` behaviour attributes | All 0 in the one sample that has them. The app's cough settings have `Hold`/`Toggle` and a five-item "Mute to …" list, so `coughButtonToggleSetting` presumably picks hold or toggle and `coughButtonMuteSourceSelection` an item of that list. | inferred; encodings unknown |
| `MiniLockFadersToLabels` | 0 in the one sample that has it. | meaning unknown |

### Importer

`OfficialProfile` (GoXLRKit) reads these values as typed facts and builds no
device commands:
- **Read:** `ValueTreeRoot` `version` and `device`, `mixerTree` levels, routing
  and `MiniLockFadersToLabels`, `FaderMeter0`–`3`, `mute1`–`4`, `muteChat`,
  `swear`, `logoX` and `globalColour`.
- **Skipped:** effects and encoders, the sampler, scribbles and their PNGs,
  `fxClear`, `selectedContext`, `browserPreviewTree`, `AppTree` and `loudness`.
- **Raw values:** every value without an established meaning stays raw, and
  its typed view is nil. Function strings must match exactly, unlike the
  app's substring match, so an unexpected string stays unknown rather than
  becoming mute all.
- **Rejected:** a container that fails the stored-ZIP checks (sizes, local
  headers, CRC-32), a missing `profile.xml`, malformed XML (with its
  position), entity declarations, and a root other than `ValueTreeRoot`.

## Mapping to device commands (inferred)

The upper-case preset parameter names correspond to the effect parameters sent
with 0x801. goxlr-utility's key names map closely (e.g. `REVERB_DECAY` ↔
Reverb Decay 0x2F). The exact name → key table is part of commands.md open
question 1.

Colours, button states and fader display map to 0x803, 0x808 and 0x814.
`mixerTree` maps to 0x806 volumes and 0x804 routing rows.

## Open

- The scaling of each effect parameter.
- Confirmation of the inferred encodings: a profile saved with fader channels
  3–5 and 7–9, and with each mute function, would settle `listIndex` and
  `Function`.
- What colour alpha, `…state`, `MiniLockFadersToLabels` and the cough
  behaviour attributes encode, and how `offStyle` maps to 0x808 button states.
- Mic profile format: not shipped, so a user-supplied sample is needed if the
  user wants mic-profile import.
- Profiles from newer firmware or app versions (submix fields, Mix2) are not
  represented in these samples (all `version` 1).
