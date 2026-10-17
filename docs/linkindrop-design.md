# LinkInDrop

## Status

The selected design is implemented. The user authorized full project and protocol renaming, merging into main, repository renaming and a new prerelease. Android uses a separate application ID and profile; pairing must be repeated on every device. Release validation uses a fresh main-branch Actions build. Rendered design comparison remains pending.

## Approved direction

- Product name: LinkInDrop.
- Use the light cobalt design from the first concept, with selected-file previews inspired by the fifth concept.
- Show selected photo thumbnails and document rows before transfer. Allow individual items to be removed.
- Use an ordinary rectangular primary button with a text label and file count. Do not use a floating chat-style control or a paper-plane icon.
- Pin desktop settings to the bottom of the left navigation rail.
- Align the mobile received-files action with the transfer heading in one row; show its icon with a tooltip when space is too narrow for the label.
- Preserve the blue flowing wave mark from the selected concept as the shared application symbol.

## Current review mockups

- Desktop with the final name and theme switch: `/workspace/generated_images/exec-a99d3067-0514-4879-9593-f7d8b7c0659b.png`.
- Mobile light theme in Russian: `/workspace/generated_images/exec-bcd63e12-6c44-49c5-ae31-a8243571af99.png`.
- Mobile dark theme in English: `/workspace/generated_images/exec-117e2d01-1ad3-49d9-ba8a-ea914cbf5a1a.png`.

Mock data is illustrative. The three files in the mobile preview total 12.4 MB; the light mockup incorrectly displays 9.4 MB. Production totals must be calculated from the actual selected files. Real filenames must never be translated.

## Mobile layout

- Adapt to a 390 by 844 logical-pixel viewport with readable text, comfortable tap targets and scrolling when content grows.
- Use bottom navigation for transfers, received files, devices and settings.
- Keep selected-file previews compact and preserve filename space.
- Replace desktop drag-and-drop instructions with an add-files action on touch devices.
- Provide a normal full-width transfer button.

## Themes

- Provide a visible sun/moon switch in the desktop and mobile header.
- Share the same layout and components between light and dark themes.
- Persist the user's theme choice.
- Use a neutral navy background, light text and accessible blue accents in dark mode.

## Languages

- Support Russian and English throughout application UI, dialogs, validation, notifications and tray menus.
- Default to the system language: Russian for Russian locales, English for English and other unsupported locales.
- Offer a settings choice of system language, Russian or English; persist manual overrides.
- Use locale-aware plurals, number and size formatting.
- Changing language must not translate user content, device names or actual filenames.
- Validate layout in both languages, including narrow mobile folder views and large system text sizes.

## Application icons

- Use the selected wave symbol consistently in Windows application/window icons, Android launcher/adaptive icons, Linux launcher assets and the tray.
- Prepare production assets from one clean source with platform-appropriate sizes and padding.
- Prepare legible monochrome tray and Android themed-icon variants of the same symbol where required by the platform.
- The generated UI mockups are visual references, not ready-to-ship icon bundles.

## Implementation constraints

- Preserve existing pairing, transfer, remote file browsing, background operation and VPN-routing behavior.
- Do not add source-code comments.
- The complete identifier rename is intentional and incompatible with previous installations; keep the migration notice in both READMEs and release notes.
- The user authorized main-branch merging and prerelease publication. Publish only after the renamed application passes a fresh main-branch build.

## Local implementation checks

Visual comparison is pending. See `../design-qa.md` for the scope and automated validation evidence. The renamed release requires a fresh successful main-branch Actions build.

Current verification status: blocked. Static checks and the bootstrap integration test passed, but Flutter analysis, tests, native builds and visual comparison remain unverified because a usable Flutter runtime could not be initialized. See `../design-qa.md` for the exact scope and blockers. No build or release has been produced.

- `python tool/check_design.py` validates translation coverage, template arguments, generated translation output, Android XML, launcher sizes and shared assets.
- `python -m unittest tool/bootstrap_test.py` validates native asset integration and preserves platform application identifiers.
- `flutter test` includes selection confirmation, failed-queue retention, duplicate protection, theme/language persistence, system-language fallback, header alignment and explicit send confirmation. These tests require Flutter 3.32.8.
- `tool/generate_icons.py` regenerates packaged icon sizes from `assets/icons/source.png` and requires Pillow. The generated platform assets are included, so packaging does not require Pillow.
- `python tool/generate_translations.py` regenerates the Dart dictionary from the Russian and English JSON files.
