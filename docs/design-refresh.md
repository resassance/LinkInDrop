# Design refresh: 0.3.0-alpha.6

The interface follows the selected single-column design, a compact dashed desktop drop target, and rounded menus with a check beside the selected value. Shared controls have a 48 logical pixel minimum height and grow with text. Page content starts at the top, desktop navigation has labels, and the theme menu is at the far right. Settings are open sections; longer explanations are available through accessible help buttons. Success, failure, and pause states have semantic colors as well as text.

## Sending

On Android, Attach opens a draggable sheet with Gallery, Files, and Folders. Gallery uses paged MediaStore queries and loads thumbnails lazily. It supports album selection, numbered multiple selection, video duration, and Android's limited photo access. Denial leaves the system picker available. Files and folders use Android document pickers. Selected originals are streamed into app-owned staging files so background and resumable transfers do not depend on temporary gallery grants. This uses additional disk space; insufficient space produces an error and removes the incomplete staging copy. Removing a selection never deletes the original. Selection is shared across tabs and retained when the sheet or preview is closed.

Next opens a media review with one large preview, one thumbnail strip, recipient, count, size, and final send action. Files retain their original quality. Video playback uses the installed system viewer. Desktop keeps native file/folder selection and drag-and-drop.

Text opens a dedicated editor with paste and explicit send. Send clipboard immediately sends the supported current clipboard value to the selected recipient. Neither manual command broadcasts. Automatic synchronization retains its existing broadcast behavior and privacy checks. Manual commands have been removed from settings.

## Receiving and history

The Received page exposes the receive folder, Change, and Open without going through settings. A folder change is refused during an active transfer. The built-in private folder is labeled separately from a selected public document tree. Existing received files are not moved.

Recent transfers use real photo/video thumbnails. Outgoing thumbnails are cached before temporary originals are cleaned up. Cache files are bounded to 40 entries. Non-media items have document icons; technical connection messages do not masquerade as successful transfers. Errors remain available in activity details and the transfer queue.

Android thumbnails use the native decoder and MediaMetadataRetriever. Windows video thumbnails use the Windows Shell thumbnail provider; codec support depends on Windows. Linux video thumbnails use ffmpeg if available; unsupported formats fall back to a video icon. The brand asset and Android/Windows exports use the refined wave mark.

## Validation

The change includes UI tests for direct clipboard vs editor behavior, attachment selection persistence, denied gallery permission, narrow layout and media review. A three-node TLS test verifies that manual sends reach one recipient while broadcast still reaches both. Existing receive-path regression tests remain in place.

`test/design_ui_test.dart` can also capture native Flutter renders when `LINKINDROP_CAPTURE_DIR` is set. `LINKINDROP_TEST_FONTS` optionally points to Flutter's material_fonts directory for readable screenshots. Captures are generated artifacts, not production data. The fixture photo comes from Flutter's BSD-licensed `examples/image_list/images/coast.jpg` and is used only in tests.

Native permission prompts, a real Android MediaStore/provider, OEM battery restrictions, and device video codecs require a physical-device smoke test. CI builds the actual Android Kotlin bridge and signed APK as well as desktop packages. No emulator or physical Android device is attached to the local workspace.
