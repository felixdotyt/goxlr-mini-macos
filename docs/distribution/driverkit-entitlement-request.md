# DriverKit entitlement request

For ADR 0005 option B: distributing the app with Developer ID. Apple must
approve the driver's entitlements for distribution first.

**Submitted 2026-11-01.** Apple's confirmation: it will review the request and
reply with a status update.

## What the form asked, and what was sent

The form (signed in) has these fields; Name, Email and Organization come from
the account:

| Field | Sent |
|---|---|
| Company / Product URL | <https://github.com/felixdotyt/goxlr-mini-macos> |
| Which entitlement | DriverKit Entitlement |
| Which DriverKit entitlements | USB Transport, UserClient Access (others unticked, Audio included) |
| USB Vendor ID (decimal) | 4640 |
| UserClient Bundle IDs ("bundle IDs of driver extensions") | `yt.felix.xlr.driver` |
| Description | the text below, in the first person, with both bundle IDs, the repository link, and "I'm an individual developer, not affiliated with TC-Helicon." Nothing about vendor permission. |

The form has no separate box for the base `com.apple.developer.driverkit`
entitlement; choosing DriverKit Entitlement is assumed to cover it.

The app was renamed GoXLR Mini Mac after the request was sent (2026-11-01);
its bundle IDs, which the request names, are unchanged.

The rest of this file is the draft the form was filled from.

## Where

<https://developer.apple.com/contact/request/system-extension/> (sign in as
the account holder; linked from <https://developer.apple.com/system-extensions/>).
The form's fields couldn't be read without signing in, so the text below is
grouped by topic rather than by field. Forum reports suggest:

- one vendor ID per entry; list the IDs in the description as well, in hex and
  in decimal, because the entitlement takes decimal values;
- approval "generally takes a week or two" (an Apple engineer, 2026), sometimes
  longer, with no status page;
- Apple engineers point stuck requests to a code-level support request.

These are forum reports, not Apple documentation (sources at the end).

## What to request

| Entitlement | For | Value |
|---|---|---|
| `com.apple.developer.driverkit` | the driver, `yt.felix.xlr.driver` | true |
| `com.apple.developer.driverkit.transport.usb` | the driver | `idVendor` 4640 (0x1220, TC-Helicon) |
| `com.apple.developer.driverkit.userclient-access` | the app, `yt.felix.xlr.helper` | `yt.felix.xlr.driver` |

Notes:

- The development build uses `driverkit.allow-any-userclient-access` on the
  driver instead of the app-side entitlement, because the app-side one needs
  Apple's approval (ADR 0002 finding 2). For distribution, asking for the
  narrower app-side entitlement is the better request; if Apple prefers
  `allow-any-userclient-access`, the driver already refuses commands from
  apps not signed by the same team.
- Not requested: `driverkit.family.audio`. Apple's USB audio driver keeps the
  audio; this driver only sends control requests. Phase 6 (streaming in the
  driver) would need it, in a later request.
- Your Team ID is in `Config/Local.xcconfig` (not committed).

## Description (to paste)

> XLR Helper is a macOS menu bar app with a DriverKit driver for the
> TC-Helicon GoXLR Mini USB mixer (USB vendor 0x1220 = 4640, product 0x8FE4 =
> 36836). TC-Helicon's control software for the GoXLR is Windows-only. On a
> Mac, the Mini works as a class-compliant audio interface, but its mixer,
> routing, buttons, mic settings (including phantom power) and lighting can't
> be controlled.
>
> The driver matches only that vendor and product, as an `IOUSBHostDevice`,
> and sends the device's vendor-specific control requests. Apple's USB audio
> driver keeps handling the audio. The driver exposes a user client to the app,
> checks every command against a default-deny table, and never sends
> firmware-update commands. Phantom power can be switched on only from our
> team-signed app, after the user confirms a condenser mic.
>
> The development build, with the development DriverKit entitlements, runs on
> our registered Mac. We'd like to distribute it with Developer ID and
> notarization to other GoXLR Mini owners. We are not affiliated with
> TC-Helicon.

Add, if true when you submit: whether the source is public (and where), and
whether you have asked TC-Helicon or Music Tribe for permission. Apple usually
grants USB transport to the device maker; a forum thread shows a third party
granted vendor IDs it doesn't own, without vendor consent being mentioned, but
that doesn't establish Apple's policy.

## After approval

Each step changes the account or signs with your identity, so you do it or
approve it:

1. Check the App IDs in Certificates, Identifiers & Profiles: the driver's
   should show the USB transport entitlement with vendor 4640, the app's the
   user-client access.
2. Create a Developer ID Application certificate, if you don't have one.
3. Create Developer ID provisioning profiles for the driver and the app.
4. In the repo (the agent can do this): Release entitlements with the granted
   values (`idVendor` as granted, the app-side user-client access instead of
   `allow-any`), a Release export with `developer-id`, notarization with
   `notarytool` (your credentials, entered by you), stapling, and a disk image.
5. Install on a Mac that has never run the driver and run the PROMPT.md §8
   checklist (H6).

## Sources

- [Apple: System Extensions and DriverKit](https://developer.apple.com/system-extensions/)
- [Forums: Vendor ID Approval](https://developer.apple.com/forums/thread/842434)
- [Forums: DriverKit USB Transport entitlement request pending](https://developer.apple.com/forums/thread/847453)
- [Forums: USB transport for all vendor IDs](https://developer.apple.com/forums/thread/700261)
