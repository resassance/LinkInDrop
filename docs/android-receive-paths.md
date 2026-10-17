# Android receive path aliases

## Failure reproduced from alpha.4

The receive implementation in `v0.3.0-alpha.4` rejects a staging file when its resolved path differs from its original path. Android application directories can have system path aliases, such as `/data/user/0` and `/data/data`. A legitimate file under an aliased application directory can therefore fail the source check before either built-in storage or a selected Android document tree receives it.

The regression tests reproduce this with a private directory reached through a parent symlink. Before the fix, both built-in and selected-filesystem destinations fail over the actual paired TLS upload protocol with `404: This folder or file is unavailable. Refresh the list.` This matches the user's reported response, but the actual failing path on their Samsung A34 has not been captured.

## Change

Resolve the trusted application data directory once when the node starts, before constructing upload, receipt and inbox storage. This uses the same files and installation data; it does not migrate, delete or recreate the device identity. The controller retains its existing path representation so ownership checks for temporary files supplied by Android Share continue to match native paths.

Checks for symlinked files, nested destination escapes and writes into private application data remain in place. Selected external destinations are not globally canonicalized or granted broader access. Android document-tree permissions are unchanged.

Record the original filesystem exception in the receiver's local activity details. The remote response still omits local paths, and the shareable diagnostic report continues to exclude private paths and identities.

## Regression coverage

- Uploads to an aliased private directory using built-in and selected filesystem destinations, including Cyrillic filenames and automatic type sorting.
- Receipt verification, idempotent retry, nested and empty folders, and restart with existing receipts.
- Export of a canonical staging file through the Android `exportReceived` method channel. The document provider is mocked; this is not a real-device SAF test.
- Rejection of nested symlinks that would redirect an incoming file or folder outside the inbox, with the destination left untouched and the original error available locally.

Run with the project's Flutter 3.32.8 toolchain:

```sh
npm install --prefix relay_server
npm test --prefix relay_server
flutter test test/android_receive_paths_test.dart test/reliability_test.dart test/transfer_protocol_test.dart --timeout 2m
flutter test --timeout 2m
flutter analyze --no-fatal-infos
python tool/check_design.py
python -m unittest tool/bootstrap_test.py tool/signing_test.py
```

Install the relay dependencies before running the complete Flutter suite so its relay integration test exercises the production Node.js server, as in CI. The optional Dart relay fixture also fails on the unmodified alpha.4 code with `StreamSink is bound to a stream`; that fixture is not changed here.

Native Android build, signed APK installation, persisted document-tree permissions and actual transfers on the A34 still require device validation. This change does not claim to resolve every possible cause of the generic 404 response.
