import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'shared_folders.dart';
import 'transfer_queue.dart';

class PhotoBackup {
  PhotoBackup({required this.directory, required this.sources, required this.enqueue,
    required this.available, required this.changed, this.verifyCopy});
  final Directory directory;
  final SharedFolders sources;
  final Future<void> Function(List<TransferJob>) enqueue;
  final bool Function(String peerId) available;
  final void Function() changed;
  final Future<bool> Function(String peer, String receipt, String digest)? verifyCopy;
  final Map<String, Map<String, dynamic>> copies = {};
  bool verifying = false;
  int verified = 0;
  int missing = 0;
  DateTime? lastVerified;
  bool enabled = false;
  String? peerId;
  bool scanning = false;
  String? lastError;
  DateTime? lastScan;
  int copied = 0;
  final Map<String, String> _versions = {};
  final Set<String> _receipts = {};
  final Set<String> _queued = {};
  Timer? _timer;
  Future<void>? _running;
  Future<void> _saving = Future.value();

  Future<void> load(List<TransferJob> jobs) async {
    await sources.load();
    final file = File(p.join(directory.path, 'photo-backup.json'));
    if (await file.exists()) {
      final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      enabled = value['enabled'] == true;
      peerId = value['peer'] as String?;
      _versions.addAll((value['versions'] as Map? ?? {}).cast<String, String>());
      _receipts.addAll((value['receipts'] as List? ?? []).cast<String>());
      copied = value['copied'] as int? ?? 0;
      for (final entry in ((value['copies'] as Map?) ?? {}).entries) { copies[entry.key as String] = (entry.value as Map).cast<String, dynamic>(); }
    }
    for (final job in jobs.where((j) => j.kind == 'backup' && j.state != 'cancelled' && j.state != 'completed')) {
      if (job.digest != null) _queued.add('${job.peerId}:${job.digest}');
    }
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(scan()));
    unawaited(scan());
  }

  Future<void> save() {
    final content = jsonEncode({'enabled': enabled, 'peer': peerId, 'versions': _versions,
      'receipts': _receipts.toList(), 'copied': copied, 'copies': copies});
    _saving = _saving.catchError((Object _) {}).then((_) async {
      final file = File(p.join(directory.path, 'photo-backup.json.new'));
      await file.writeAsString(content, flush: true);
      await file.rename(p.join(directory.path, 'photo-backup.json'));
    });
    return _saving;
  }

  Future<void> scan() {
    if (scanning) return _running ?? Future.value();
    return _running = _scan();
  }

  Future<void> _scan() async {
    final peer = peerId;
    if (!enabled || scanning || peer == null || !available(peer)) return;
    scanning = true;
    lastError = null;
    changed();
    try {
      final batch = <TransferJob>[];
      final planned = <String>{};
      for (final root in sources.roots()) {
        final pending = <(String, int)>[('', 0)];
        var visited = 0;
        while (pending.isNotEmpty && enabled) {
          if (++visited > 100000) throw StateError('Слишком много папок для одной проверки');
          final next = pending.removeLast();
          final page = await sources.list(root.id, next.$1, offset: next.$2);
          if (page.nextOffset != null) pending.add((next.$1, page.nextOffset!));
          for (final entry in page.entries) {
            if (entry.isDirectory) { pending.add((entry.relativePath!, 0)); continue; }
            if (!RegExp(r'\.(jpe?g|png|heic|webp)$', caseSensitive: false).hasMatch(entry.name)) continue;
            final fingerprint = '${root.id}:${entry.relativePath}:${entry.version}:${entry.size}';
            var digest = entry.version == null || entry.version!.startsWith('0:') ? null : _versions[fingerprint];
            if (digest == null) {
              final source = await sources.open(root.id, entry.relativePath!);
              try { digest = (await sha256.bind(source.stream).first).toString(); }
              finally { await source.close(); }
              _versions[fingerprint] = digest;
            }
            final receipt = '$peer:$digest';
            if (_receipts.contains(receipt) || _queued.contains(receipt) || !planned.add(receipt)) continue;
            final date = entry.modifiedAt != null && entry.modifiedAt!.millisecondsSinceEpoch > 0 ? entry.modifiedAt! : DateTime.now();
            final relative = 'Photos/${date.year}/${date.month.toString().padLeft(2, '0')}/${digest.substring(0, 12)}_${entry.name}';
            batch.add(TransferJob(id: randomToken(16), peerId: peer, kind: 'backup',
              name: entry.name, totalBytes: entry.size, source: entry.relativePath, sourceFolder: root.id, relative: relative, digest: digest));
          }
        }
      }
      if (batch.isNotEmpty) {
        _queued.addAll(planned);
        try { await enqueue(batch); } catch (_) { for (final job in batch) { _queued.remove('${job.peerId}:${job.digest}'); } rethrow; }
      }
      lastScan = DateTime.now();
      await save();
    } catch (error) { lastError = '$error'; }
    finally { scanning = false; changed(); }
  }

  Future<void> completed(TransferJob job) async {
    if (job.kind != 'backup' || job.digest == null) return;
    final key = '${job.peerId}:${job.digest}';
    if (_receipts.add(key)) copied++;
    if (job.receipt != null) copies[key] = {...job.toJson(), 'valid': true};
    _queued.remove(key);
    await save();
    changed();
  }

  Future<void> verify() async {
    final peer = peerId;
    if (verifying || scanning || peer == null || !available(peer) || verifyCopy == null) return;
    verifying = true; verified = 0; missing = 0; lastError = null; changed();
    try {
      for (final entry in copies.entries.where((entry) => entry.value['peer'] == peer).toList()) {
        final item = entry.value;
        final valid = await verifyCopy!(peer, item['receipt'] as String, item['digest'] as String);
        item['valid'] = valid; item['verifiedAt'] = DateTime.now().millisecondsSinceEpoch;
        if (valid) { verified++; } else { missing++; _receipts.remove(entry.key); _queued.remove(entry.key); }
        changed();
      }
      lastVerified = DateTime.now(); await save();
    } catch (error) { lastError = '$error'; }
    finally { verifying = false; changed(); }
  }

  void cancelled(TransferJob job) {
    if (job.digest != null) _queued.remove('${job.peerId}:${job.digest}');
  }
  Future<void> close() async { enabled = false; _timer?.cancel(); await _running; await _saving; }
}
