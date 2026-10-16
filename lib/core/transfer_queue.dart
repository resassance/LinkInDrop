import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'connection_error.dart';

class TransferJob {
  TransferJob({required this.id, required this.peerId, required this.kind,
    required this.name, this.source, this.entry, this.relative, this.sourceFolder,
    this.state = 'waiting', this.error, this.digest, this.receipt, this.batchId, this.totalBytes = 0, this.priority = 0, this.skipped = false, this.backupPaused = false});
  final String id;
  final String peerId;
  final String kind;
  final String name;
  final String? source;
  final SharedFile? entry;
  final String? relative;
  final String? sourceFolder;
  String state;
  String? error;
  String? digest;
  String? receipt;
  final String? batchId;
  int totalBytes;
  int priority;
  bool skipped;
  bool backupPaused;
  double bytesPerSecond = 0;
  int get doneBytes => (totalBytes * progress).round();
  int? get remainingSeconds => bytesPerSecond > 0 ? ((totalBytes - doneBytes) / bytesPerSecond).ceil() : null;
  double progress = 0;
  int attempts = 0;
  DateTime? nextAttempt;
  Map<String, dynamic> toJson() => {'id': id, 'peer': peerId, 'kind': kind,
    'name': name, 'source': source, 'entry': entry?.toJson(), 'relative': relative,
    'sourceFolder': sourceFolder, 'state': state, 'error': error, 'digest': digest,
    'receipt': receipt, 'batch': batchId, 'bytes': totalBytes, 'priority': priority, 'skipped': skipped, 'backupPaused': backupPaused};
  factory TransferJob.fromJson(Map<String, dynamic> value) => TransferJob(
    id: value['id'] as String, peerId: value['peer'] as String, kind: value['kind'] as String,
    name: value['name'] as String, source: value['source'] as String?,
    entry: value['entry'] == null ? null : SharedFile.fromJson(value['entry'] as Map<String, dynamic>),
    relative: value['relative'] as String?, sourceFolder: value['sourceFolder'] as String?,
    state: value['state'] == 'running' ? 'paused' : value['state'] as String,
    error: value['error'] as String?, digest: value['digest'] as String?,
    receipt: value['receipt'] as String?, batchId: value['batch'] as String?,
    totalBytes: value['bytes'] as int? ?? 0, priority: value['priority'] as int? ?? 0, skipped: value['skipped'] == true, backupPaused: value['backupPaused'] == true);
}

class TransferQueue extends ChangeNotifier {
  TransferQueue({required this.directory, required this.execute,
    required this.interrupt, required this.completed, required this.discard});
  final Directory directory;
  final Future<void> Function(TransferJob, void Function(double)) execute;
  final void Function() interrupt;
  final Future<void> Function(TransferJob) completed;
  final Future<void> Function(TransferJob) discard;
  final List<TransferJob> jobs = [];
  TransferJob? active;
  bool _pumping = false;
  bool _stopped = false;
  bool _backupEnabled = true;
  Future<void> _saving = Future.value();
  Future<void>? _worker;
  Timer? _retry;
  int get pending => jobs.where((j) => ['waiting', 'running', 'paused', 'failed'].contains(j.state)).length;

  Future<void> load() async {
    final file = File(p.join(directory.path, 'queue.json'));
    if (await file.exists()) {
      final values = jsonDecode(await file.readAsString()) as List;
      jobs.addAll(values.map((value) => TransferJob.fromJson(value as Map<String, dynamic>)));
    }
  }

  Future<void> save() {
    final content = jsonEncode(jobs.map((j) => j.toJson()).toList());
    _saving = _saving.catchError((Object _) {}).then((_) async {
      final file = File(p.join(directory.path, 'queue.json.new'));
      await file.writeAsString(content, flush: true);
      await file.rename(p.join(directory.path, 'queue.json'));
    });
    return _saving;
  }

  Future<void> addAll(Iterable<TransferJob> values) async {
    if (jobs.length + values.length > 20000) throw StateError('В очереди слишком много файлов');
    for (final job in values) {
      if (job.kind == 'backup' && !_backupEnabled && job.state == 'waiting') { job.backupPaused = true; job.state = 'paused'; }
      jobs.add(job);
    }
    await save();
    notifyListeners();
    start();
  }

  void start() {
    if (_stopped || _pumping) return;
    _worker = _pump();
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (!_stopped) {
        final waiting = jobs.where((j) => j.state == 'waiting' && (j.kind != 'backup' || _backupEnabled) && (j.nextAttempt == null || !j.nextAttempt!.isAfter(DateTime.now())));
        if (waiting.isEmpty) break;
        final ordered = waiting.toList()..sort((a, b) {
          final priority = b.priority.compareTo(a.priority);
          return priority == 0 ? jobs.indexOf(a).compareTo(jobs.indexOf(b)) : priority;
        });
        final job = ordered.first;
        active = job;
        job.state = 'running';
        job.error = null;
        notifyListeners();
        await save();
        try {
          await execute(job, (progress) { job.progress = progress; notifyListeners(); });
          if (job.state == 'running') {
            await completed(job);
            job.state = 'completed';
            job.progress = 1;
          }
        } catch (error) {
          if (job.state == 'running') {
            final transient = error is SocketException || error is TimeoutException || error is HttpException ||
              (error is ConnectionFailure && error.kind == ConnectionFailureKind.unreachable);
            job.attempts++;
            job.state = transient && job.attempts < 5 ? 'waiting' : 'failed';
            job.nextAttempt = DateTime.now().add(Duration(seconds: job.attempts * 5));
            job.error = '$error';
          }
        } finally {
          active = null;
          if (_backupEnabled && job.backupPaused && job.state == 'paused') { job.state = 'waiting'; job.backupPaused = false; }
          if (job.state == 'cancelled') await discard(job);
          await save();
          notifyListeners();
        }
      }
    } finally {
      _pumping = false;
      final deferred = jobs.where((j) => j.state == 'waiting' && j.nextAttempt != null).toList();
      if (!_stopped && deferred.isNotEmpty) {
        deferred.sort((a, b) => a.nextAttempt!.compareTo(b.nextAttempt!));
        final delay = deferred.first.nextAttempt!.difference(DateTime.now());
        _retry?.cancel();
        _retry = Timer(delay.isNegative ? Duration.zero : delay, start);
      }
    }
  }

  Future<void> setBackupEnabled(bool enabled) async {
    _backupEnabled = enabled;
    for (final job in jobs.where((job) => job.kind == 'backup')) {
      if (!enabled && (job.state == 'running' || job.state == 'waiting')) {
        job.backupPaused = true;
        job.state = 'paused';
        if (active == job) interrupt();
      } else if (enabled && job.backupPaused && job.state == 'paused' && active != job) {
        job.backupPaused = false;
        job.state = 'waiting';
      }
    }
    notifyListeners();
    await save();
    if (enabled) start();
  }

  Future<void> pause(TransferJob job) async {
    if (job.state == 'completed' || job.state == 'cancelled') return;
    job.backupPaused = false;
    job.state = 'paused';
    if (active == job) interrupt();
    await save();
    notifyListeners();
  }

  Future<void> resume(TransferJob job) async {
    if (job.state == 'completed' || job.state == 'cancelled') return;
    if (active == job) return;
    if (job.kind == 'backup' && !_backupEnabled) return;
    job.backupPaused = false;
    job.state = 'waiting';
    job.error = null;
    job.nextAttempt = null;
    job.attempts = 0;
    await save();
    notifyListeners();
    start();
  }

  Future<void> cancel(TransferJob job) async {
    if (job.state == 'completed') return;
    job.state = 'cancelled';
    if (active == job) interrupt(); else await discard(job);
    await save();
    notifyListeners();
  }

  double batchProgress(String batch) {
    final items = jobs.where((job) => job.batchId == batch && job.state != 'cancelled');
    final total = items.fold<int>(0, (sum, job) => sum + job.totalBytes);
    if (total == 0) return items.isEmpty ? 0 : items.where((job) => job.state == 'completed').length / items.length;
    return items.fold<int>(0, (sum, job) => sum + (job.state == 'completed' ? job.totalBytes : job.doneBytes)) / total;
  }

  Future<void> setPriority(TransferJob job, int priority) async {
    final batch = job.batchId;
    for (final item in jobs.where((item) => batch == null ? item == job : item.batchId == batch)) { item.priority = priority; }
    await save(); notifyListeners();
  }

  Future<void> clearFinished() async {
    final unfinished = jobs.where((j) => j.state != 'completed' && j.state != 'cancelled').map((j) => j.batchId).whereType<String>().toSet();
    jobs.removeWhere((j) => (j.state == 'completed' || j.state == 'cancelled') && (j.batchId == null || !unfinished.contains(j.batchId)));
    await save();
    notifyListeners();
  }

  Future<void> close() async {
    _stopped = true;
    _retry?.cancel();
    if (active != null) { active!.state = 'paused'; interrupt(); }
    await _worker;
    await save();
  }
}
