# LinkInDrop native UI design QA

Scope: the app-owned Flutter interface for the selected design. This is a production Flutter application, not an HTML/Sites prototype. Captures use Flutter's renderer at logical pixel ratio 1; browser console checks are not applicable. Android permission prompts and native media-provider behavior remain a device smoke-test gap.

## Source and capture evidence

- Source visual truth: the selected base concept `exec-f9bd84ba-6fcc-42d6-88ef-c5e6dde4979a.png`, merged desktop `exec-59d21736-1f5f-45a8-b03c-bacd63dba543.png`, revised Android transfer `exec-c014ae12-25d0-4223-a203-c05048fdc423.png`, gallery `exec-7d6a0b8f-6236-425d-ab74-a3f83ac9161e.png`, files `exec-8cb12525-1729-4cc9-815e-2fce11d57f1f.png`. Source images are under `/workspace/generated_images/` in the design workspace.
- Implementation captures: `build/design-qa/android-transfer.png`, `android-gallery.png`, `android-attachment-files.png`, `android-received.png`, `android-settings.png`, `android-text.png`, `android-media-preview.png`, `desktop-transfer.png`, `desktop-theme-menu.png`.
- Mobile viewport and capture: 390 × 844 logical/pixel dimensions, density 1. Desktop: 1440 × 1024, density 1. Generated single-mobile sources are 853 × 1840 and are normalized to 390 × 844 for comparison; desktop source is normalized to 1440 × 1024. No OS or browser chrome is compared.
- Combined full-view inputs: `build/design-qa/compare-transfer.png`, `compare-gallery.png`, `compare-files.png`, each containing the normalized source beside the actual Flutter render. Desktop menu and page captures were also inspected directly.
- Relevant state differences: test media uses the BSD Flutter coast photo, one selected item and controlled fixture device names. The source's stock gallery subjects and counts are illustrative data, not application assets. No sample photo is shipped as a production gallery item.

## Comparison history

1. [P1, fixed] Short pages were still vertically centered by the outer Row's loose cross-axis constraints. Stretching that Row and constraining the scroll content to its natural height now anchors Received and Transfer at the same top grid. Updated native captures confirm this.
2. [P2, fixed] Desktop header Flexible consumed unnecessary space and left the theme control away from the right edge. The device-name control is now width-constrained, with the theme menu last in the header.
3. [P2, fixed] The first gallery render showed too much heading space before the grid. A compact drag handle, single-line album menu and selection counter restore the media-first sheet proportions. The footer remains pinned while media scrolls.
4. [P2, fixed] Text and clipboard controls needed equal height while accommodating the longer Russian label. A shared intrinsic-height action row with a 2:3 width ratio and a vertical fallback for large text keeps them aligned.
5. [P1, fixed] Closing the text editor could dispose its controller while the outgoing dialog still rebuilt. The editor now owns its controller for the lifetime of its route widget. The close/reopen interaction passes.
6. [P2, fixed] Cached JPEG previews of outgoing videos could be interpreted as videos again. Thumbnail decoding now follows the cached file format while keeping the original video play affordance.

## Required fidelity surfaces

- Typography: Roboto/Material typography, 26/32 page titles, 20 section headings, 15–16 body baseline, smaller secondary metadata. Labels and long names wrap or ellipsize; controls grow with text. The 320 logical pixel/large-text layout and longer bilingual controls are checked in widget tests.
- Spacing/layout: 16–18 mobile outer gutters, 36 desktop content gutters, consistent 8/12/16/24 gaps, 12-radius controls, minimum 48 touch targets. All settings sections are open; source controls, primary send, and drop area follow the selected hierarchy. The native Material navigation and dialog primitives are retained.
- Color/tokens: flat blue action colors, light/dark surfaces, green success/online, red failure, amber paused states. Generated gradients were intentionally removed. Only the active send action is emphasized when a selection exists.
- Images/icons: supplied/refined raster wave brand and Material icons, real native photo/video thumbnails with format fallback, one media selection strip in preview. Test photo substitution is explicit. Windows codec-dependent video thumbnails and Linux ffmpeg availability are documented.
- Copy/content: separate Text/editor and immediate Send clipboard commands, a visible recipient, Gallery/Files/Folders only, original-quality informational label, no invented PIN/compression/chat features. Receive-folder wording distinguishes private app storage from a selected public tree.

## Interaction checks and limits

Tested: four main destinations, theme selection, long names and narrow widths, direct clipboard without editor, separate text editor, editor cancellation, selection retention across attachment tabs and close/reopen, gallery denial fallback, media-review cancellation, explicit final send, and a TLS three-node manual-target/broadcast regression. Existing Android receive-path tests are retained.

Native media listing/import and permission code is part of the Android build. No attached phone/emulator is available locally, so OEM permissions, background restrictions, actual album contents, external codecs and real file-picker provider behavior are not claimed as device-tested. These are functional smoke-test limits, not a substitute for the app-owned visual comparison.

## Follow-up polish

P3: exact font rasterization and a few icon sizes differ from the image generator. Production Material focus, keyboard, touch and text-scaling behavior takes precedence over reproducing a raster image's incidental details.

final result: passed
