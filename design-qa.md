# LinkInDrop design verification

Date: 2026-10-17

final result: blocked

The selected design is implemented in the existing Flutter application. The blocked result concerns visual verification: no running-application screenshots were captured or compared with the approved references. Compilation and automated checks have passed.

## Authorization and validated source

The user authorized GitHub Actions validation on 2026-10-17. Code is uploaded to the separate `design/linkindrop` branch. The main branch, tags and releases have not been changed.

- Successful run: https://github.com/resassance/nearbridge/actions/runs/39002395492
- Validated code commit: `627e5dc056be233c3a1e2bec6370ace96b830604`.
- Subsequent documentation-only changes do not alter the validated application.

## Approved references

| Reference | Image size | Intended logical viewport |
| --- | --- | --- |
| `/workspace/generated_images/exec-a99d3067-0514-4879-9593-f7d8b7c0659b.png` | 1486 × 1059 | Desktop 1440 × 1024 |
| `/workspace/generated_images/exec-bcd63e12-6c44-49c5-ae31-a8243571af99.png` | 853 × 1844 | Mobile 390 × 844, Russian, light |
| `/workspace/generated_images/exec-117e2d01-1ad3-49d9-ba8a-ea914cbf5a1a.png` | 853 × 1844 | Mobile 390 × 844, English, dark |

These paths identify references from the implementation environment, not screenshots of the running app. The light mobile reference has an illustrative total-size error; production totals use actual selected file sizes.

## Passed checks

- All 62 Flutter tests, including explicit send confirmation, failed-queue retention, concurrent additions, theme/language persistence, system locale fallback, mobile header alignment, legacy profile reuse, network transfer and remote folder browsing.
- Two relay-server tests and the bootstrap integration test.
- 382 matching Russian/English translation templates, 375 referenced translation keys, placeholder consistency, Android XML, launcher dimensions and shared assets.
- `flutter analyze --no-fatal-infos`: zero errors, zero warnings and 208 informational lint findings. This is not a lint-free result.
- Linux and Windows release compilation and packaging.
- Android release compilation, packaging and verification against the pinned permanent signing certificate.
- Local Python tool compilation and `git diff --check` before uploading source.

The workflow runs Flutter 3.32.8. CI exposed and verified fixes for accidentally renamed protocol headers and incorrect compact-layout selection. Persistence tests were separated from widget tests to keep filesystem I/O outside Flutter's simulated clock.

## Build artifacts

| Platform | Download |
| --- | --- |
| Windows | https://github.com/resassance/nearbridge/actions/runs/39002395492/artifacts/12089747719 |
| Linux | https://github.com/resassance/nearbridge/actions/runs/39002395492/artifacts/12089472117 |
| Android | https://github.com/resassance/nearbridge/actions/runs/39002395492/artifacts/12089347890 |

Artifacts contain the packaged build and checksum and are retained for 14 days. The workflow artifact names retain the internal nearbridge prefix; packaged application names use LinkInDrop.

## Verification still required

No implementation screenshots were captured. Screenshot normalization and reference comparison were not performed. Typography, layout, colors, rendered assets and visible copy remain visually unverified, including enlarged text. Automated mobile layout checks do not replace visual comparison.

Windows tray interactions, Android launcher appearance, notifications and background behavior require native runtime validation. Successful compilation does not establish these interactions work on physical devices.

Earlier SDK setup attempts failed; a memory-related cause was not confirmed. Actions now provides the successful runtime/build evidence above. During validation, the local workspace was replaced; the uploaded branch preserves the application source.

No release was created.
