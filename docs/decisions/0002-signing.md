# ADR 0002: Signing path for the dext and helper

- **Status:** accepted for development signing. The helper's control channel
  (Finding 2) is decided in ADR 0003: option (d), since 2026-10-31
- **Date:** 2026-10-30

## Decision so far

- **Path:** Xcode automatic development signing on the user's paid Individual
  team. The Team ID is in the untracked `Config/Local.xcconfig`.
- **Identity:** an "Apple Development" certificate for the team is in the login
  keychain. It is valid until 2027-05-21.
- **Bundle IDs:** prefix `yt.felix.xlr` (PROMPT.md D8). The spike targets are:
  - `yt.felix.xlr.spike.driver`: the dext;
  - `yt.felix.xlr.spike.host`: the activating app.
- **The user approved** Xcode registering this Mac as a development device and
  creating development App IDs and profiles (G0, 2026-10-30).

## Spike layout (`Spike/` at commit `b3aa3cc`)

Phase 4 step 0 replaced these variants with the control-channel spike
(ADR 0003). The dext keeps the bundle ID `yt.felix.xlr.spike.driver`.

| Variant | Dext entitlements | How to build |
|---|---|---|
| A, "hello" | `com.apple.developer.driverkit` | default (`XLR_SPIKE_DEXT_ENTITLEMENTS_NAME=HelloDriver`) |
| B, real set | A plus `driverkit.transport.usb` `[{idVendor: "*"}]` and `driverkit.family.audio` | `XLR_SPIKE_DEXT_ENTITLEMENTS_NAME=HelloDriverFull CURRENT_PROJECT_VERSION=3` |

Both variants match `IOUserResources` and only log (`XLRSpike:`). Neither one
matches the GoXLR. The host carries only `system-extension.install`
(`driverkit.userclient-access` was removed; see Finding 2).

## Results

| Step | Result | Class | Evidence |
|---|---|---|---|
| Unsigned compile of the dext and host, with the dext embedded in `Contents/Library/SystemExtensions` | `BUILD SUCCEEDED` | observed | `Spike/build-spike-unsigned.log` (local) |
| Signed build, first attempt | **Failed**: "PLA Update available". After the user signed in to developer.apple.com, the account page listed no pending agreement (the PLA issued 2026-06-18 shows as accepted on 2026-06-20), and the error didn't recur. We accepted nothing | observed | account page, 2026-10-30 |
| Signed build, second attempt | **Failed**: "Your team has no devices". `-allowProvisioningDeviceRegistration` didn't register this Mac from the CLI | observed | `build-spike-a.log` |
| Device registration | This Mac was registered in the portal as "MacBook Pro (XLR dev)", platform macOS, with the user's approval | observed | portal "Registration Complete" |
| Host with `driverkit.userclient-access` | **Rejected**: "requires approval from Apple to include in a profile". The capability must be assigned to the team and bundle ID by Apple | observed | `build-spike-a.log` |
| Variant A signed, host without `userclient-access` | `BUILD SUCCEEDED`. The dext profile is "DriverKit Team Provisioning Profile: yt.felix.xlr.spike.driver" (platforms OSX and iOS, expires 2027-05-21) and grants `driverkit` = true. The host profile is "Mac Team Provisioning Profile: yt.felix.xlr.spike.host" and grants `system-extension.install` = true | observed | `codesign -d --entitlements`, `security cms -D -i` |
| Variant B signed | `BUILD SUCCEEDED`. The **development** dext profile grants `driverkit.transport.usb` = `[{idVendor = *}]` and `driverkit.family.audio` = true, and this Mac's UDID is in `ProvisionedDevices`. The dext is signed with `transport.usb` = `[{idVendor = 4640}]`, `family.audio` and `driverkit` | observed | same |
| Variant A activation | The user approved it in System Settings → Login Items & Extensions → Driver Extensions. sysextd reached `activated enabled` at 13:34:13. Pressing the host's Activate button again only coalesces with the pending request; it never approves | observed | `systemextensionsctl list`, sysextd log |
| Variant A launch | **Failed**: kernelmanagerd `Error launching dext … Code=8 "Exec format error"`. The cause is in taskgated-helper: "Provisioning profile does not allow this device", then AMFI -413 "No matching profile found". A's profile was created at 15:57:48 UTC, before this Mac was registered at 15:59:12 UTC. Xcode reused the cached profile when it rebuilt A, so the profile lists one earlier team device and not this Mac | observed | amfid, taskgated-helper log; `security cms -D` |
| Variant B v2 replaces A | Accepted with no new user approval: `systemextensionsctl` shows `activated enabled` at version 0.1/2. Launch **failed** the same way: taskgated-helper "matchEntitlement failed value match for entitlement: `com.apple.developer.driverkit.transport.usb`". The profile's `idVendor` is the **string** `*`; the dext's **integer** 4640 doesn't match it | observed | taskgated-helper, amfid log |
| Variant B v3, `idVendor` = string `*` | Accepted with no new approval (`replacing 2 with 3`). The dext process runs as `_driverkit`, and IORegistry shows `HelloDriver <class IOUserService, registered, matched, active>`. `RegisterService()` runs only after a successful `Start`, so Start succeeded | observed | `pgrep`, `ioreg -n HelloDriver` |
| Dext `os_log` lines | **Live only**: a `log stream` running at deactivation captured `kernel: () XLRSpike: HelloDriver Stop` (default level, attributed to process `kernel`). `log show` returns neither the Start nor the Stop line at any level, even a few minutes later. The host's own `Logger` lines are stored normally | observed; why they aren't stored is unknown | `log stream`, `log show --info --debug` |
| Deactivation | The host's deactivation request opens an administrator password prompt (SecurityAgent). After the user authenticated (13:41:19), sysextd went `terminating_for_uninstall` → `terminating_for_uninstall_but_still_running`, the dext logged Stop and exited, and the host got "will complete after reboot". The entry left the list without a reboot | observed | `log stream`, `systemextensionsctl list` |
| Stray re-activation | 4 s later the host window's Activate button queued a new activation (`activated waiting for user`). A second deactivation removed it. Final state: `0 extension(s)`, no dext process, no copies under `/Library/SystemExtensions`, `/Applications/SpikeHost.app` deleted | observed | same |

## Findings

1. **The dext's full entitlement set is available for development** without an
   Apple request: USB transport (wildcard vendor in development) and Family
   Audio. The SIP fallback isn't needed for the driver itself. Variant B v3
   runs with it.
   - **The dext's entitlement value must equal the profile's value.** For
     development the profile grants `idVendor` as the string `*`, so the Debug
     entitlements must carry the string `*`. A narrower integer (4640) is
     rejected at launch. Device matching stays narrow through the Info.plist
     personality (`idVendor` 4640 plus product IDs). A distribution build
     carries whatever vendor value Apple grants in the distribution profile, so
     the real driver needs separate Debug and Release entitlement files.
   - **Activation success doesn't mean the dext runs.** sysextd reports
     `activated enabled` even when AMFI later refuses to exec the binary. Every
     install check must also confirm the dext process and its IORegistry
     service, and read amfid/taskgated-helper on failure.
   - **Check the embedded profile before installing.** Xcode can reuse a cached
     profile that predates a device registration. Before copying to
     `/Applications`, confirm this Mac's provisioning UDID is in the embedded
     profile's `ProvisionedDevices`.
   - **Same-team replacements need no new approval.** Bumping the bundle
     version and resubmitting activation replaced the running dext (v1→v2→v3)
     without another System Settings approval.
2. **The helper's `com.apple.developer.driverkit.userclient-access` is not
   available for development**: Apple must grant it. PROMPT.md §1.1 assumes an
   `IOUserClient` that only the helper may open, so this affects Phases 4–9.
   The options, which need the user's decision before Phase 4:
   - **(a)** Request DriverKit UserClient Access from Apple for
     `yt.felix.xlr.helper` (and goxlrctl). We would wait for approval.
   - **(b)** Control through **AudioDriverKit custom properties**
     (`IOUserAudioCustomProperty`). The helper reads and writes them with
     CoreAudio `AudioObjectGet/SetPropertyData` and is notified through
     property listeners, so no user-client entitlement is needed. The cost:
     any process can address those properties, so the dext must validate
     every request.
   - **(c)** The SIP-disabled developer fallback (PROMPT.md §1.3). It is
     performed by the user and only relaxes this on this Mac.

   **Decided:** the user chose (b) on 2026-10-30. See
   [ADR 0003](0003-control-channel.md).

   **Update 2026-10-31:** the dext-side entitlement
   `com.apple.developer.driverkit.allow-any-userclient-access` *is* available
   for development. With the user's approval, Xcode added the capability to
   App ID `yt.felix.xlr.spike.driver`, and the regenerated profile grants it.
   It lets any process open the dext's user client, so the helper needs no
   grant from Apple (ADR 0003 finding 14). The user chose that channel,
   option (d), on 2026-10-31. Unverified for Developer ID distribution.

   **Also 2026-10-31:** a development dext must sign
   `driverkit.transport.usb` with the profile's exact value
   (`[{idVendor: "*"}]`). A narrower `idVendor` 4640 failed AMFI and the dext
   didn't launch (ADR 0004 finding 1).

3. **Dext logs are only visible live.** The dext's `os_log(OS_LOG_DEFAULT, …)`
   lines show up in `log stream` as process `kernel`, but `log show` doesn't
   return them later (rechecked 2026-10-31 with `/usr/bin/log show`; the
   host's lines are there, the dext's aren't). In zsh, call `/usr/bin/log`:
   a bare `log` is a shell built-in and prints nothing useful. Until that is explained, every hardware test script
   starts `log stream` before activating or plugging in the device, and saves
   the capture to a file. Making them persist (for example a dedicated
   subsystem with `log config`, which needs sudo and the user's approval) is a
   Phase 4 question, when driver code starts.
4. **Deactivation needs the user's password.** Test scripts that swap driver
   builds should prefer version-bumped replacements, which need no prompt, and
   deactivate only at the end.

## Next

1. Phase 4, where driver code starts, adds the pre-install profile check
   (Finding 1) and live log capture (Finding 3) to its install and test
   scripts.
