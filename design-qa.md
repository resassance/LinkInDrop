# LinkInDrop design verification

Date: 2026-10-17

final result: blocked

The blocked result concerns visual verification. No running-application screenshots were captured or normalized against the approved mockups. Successful compilation and automated layout checks do not replace visual comparison.

## Automated validation

The earlier design revision passed 62 Flutter tests, two relay-server tests, analysis with no errors or warnings, and Windows/Linux/Android builds in [run 39002395492](https://github.com/resassance/LinkInDrop/actions/runs/39002395492). It had 208 informational lint findings. That run predates the complete application-ID and protocol rename and is not evidence for the renamed release.

The release workflow requires a fresh successful Build run on main whose commit exactly matches the release tag. It verifies the Android certificate before packaging; it uploads artifacts only after that build succeeds. Current results are available in [Actions](https://github.com/resassance/LinkInDrop/actions/workflows/build.yml).

Local bootstrap and signing integration tests passed for the complete rename. The signing test verifies that changing a keystore alias preserves the original certificate. Translation/resource checks and Python compilation also passed.

## Remaining visual and device checks

Compare desktop at 1440 × 1024 and mobile at 390 × 844 against the selected references, in light/dark themes and Russian/English. Check typography, spacing, assets, copy, enlarged text and long filenames. The reference light mobile total was illustrative; production totals use actual selected file sizes.

Windows tray interactions, Android launcher appearance, notifications, background operation and NekoBox interoperability require native device validation.

The user explicitly authorized full renaming, merging into main, repository renaming and a new prerelease. The new Android ID and protocol require a separate installation and fresh device pairing, as documented in both READMEs and the release notes.
