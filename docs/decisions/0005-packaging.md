# ADR 0005: Packaging for other Macs

- **Status:** the user chose **B** on 2026-10-31: request Apple's DriverKit
  distribution entitlements. The request is drafted in
  [driverkit-entitlement-request.md](../distribution/driverkit-entitlement-request.md)
  for the user to submit. C (publish the source) can run alongside it. Until
  Apple approves, D6 (this Mac only) stands for builds signed by this team.
- **Date:** 2026-10-31

## Context

What the build is today:

- The dext and helper are signed with an Apple Development certificate on the
  user's paid Individual team (ADR 0002). The helper embeds the dext in
  `Contents/Library/SystemExtensions` and must run from `/Applications` to
  activate it.
- The dext's development profile lists the Macs it may run on
  (`ProvisionedDevices`). On a Mac that isn't listed, activation still reports
  success but AMFI refuses to launch the dext (ADR 0002 finding 1). Today only
  this Mac is registered.
- Dext entitlements: `driverkit`, `driverkit.allow-any-userclient-access`, and
  `driverkit.transport.usb` with `idVendor` `"*"`, the value the development
  profile grants. The helper has `system-extension.install`.
- Builds so far are arm64 only (`ARCHS=arm64`), minimum macOS 14.
- Nothing device-specific is built in: no serial, no team-specific value
  outside the untracked `Config/Local.xcconfig`.

## Options

| | A. Registered Macs | B. Developer ID | C. Build it yourself |
|---|---|---|---|
| Who can use it | Up to 100 Macs per membership year, each registered by the user | Anyone | Anyone with a paid developer account |
| Needs from Apple | Nothing new | DriverKit distribution entitlements: USB transport for vendor 0x1220, normally granted to the device maker, and user-client access. Approval is uncertain (PLAN.md D6) | Nothing; each builder uses their own team and bundle prefix (`XLR_BUNDLE_PREFIX` in `Config/Local.xcconfig`; an unsigned build under another prefix was checked, see README) |
| Signing | Apple Development, exported as a development build | Developer ID, notarized and stapled | The builder's own development signing |
| First launch on another Mac | Not notarized, so Gatekeeper blocks it once ("Open Anyway" in Privacy & Security), then the user approves the driver in Login Items & Extensions | Opens normally, then the user approves the driver | Same as A |
| Upkeep | Rebuild for each newly registered Mac, and before the profile expires on 2027-05-21 (after that the dext is expected not to launch; inferred) | Renew the certificate; notarize each release | Each builder's own |
| Works today | Yes, once a Mac is registered | No | Yes, with README steps |

Option A is a closed beta: the user's own Macs, or people the user knows
who send their Mac's Provisioning UDID (`system_profiler
SPHardwareDataType`). Option B is a public release, and depends on Apple.
Option C needs only documentation, and can run alongside either.

## Work needed whichever option is chosen

1. **Universal build.** Add x86_64 to the Release configuration for Intel Macs.
   Not tested on an Intel Mac.
2. **Versioning.** Set a marketing version and build number. A dext with a
   higher bundle version replaces the running one without another approval
   (ADR 0002 finding 1).
3. **Package script** (`Tools/package/`):
   - archive the Release build and export it (development for A and C,
     `developer-id` for B);
   - verify: `codesign --verify --deep --strict`, the embedded profiles'
     entitlements, and for A that every intended Mac is in
     `ProvisionedDevices`;
   - for B: `notarytool submit --wait`, `stapler staple`, `spctl --assess`;
   - put the app in a disk image with an Applications link.
4. **First-run flow in the helper:**
   - if the driver isn't active, explain the System Settings approval and offer
     Activate;
   - if activation reports success but the dext isn't running, show why (AMFI's
     "profile does not allow this device" means the Mac isn't registered).
5. **Uninstall** (PROMPT.md Phase 9): release this app's mutes, deactivate the
   dext (macOS asks for an administrator password), remove the login item, ask
   before removing settings and profiles, then move the app to the Trash.
6. **Install guide** for recipients: copy to Applications, the Gatekeeper step
   (A), the driver approval, what the mic-type prompt means, and how to
   uninstall.
7. **Acceptance (H6):** the PROMPT.md §8 checklist on a second Mac that has
   never run the driver.

## Decisions for the user

1. Who are the other Macs: your own and people you know (A), or a public
   release (B)?
2. For A: approve registering each Mac in the developer portal. That's an
   account change; the agent doesn't do it without your go-ahead.
3. For B: should the agent draft the entitlement request for you to submit?
4. Do any of the Macs have Intel chips?

## Can proceed without decisions

Items 1 to 6 above. None of them changes the account or touches another Mac.
