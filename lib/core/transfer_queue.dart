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
    this.state = 'waiting', this.error, this.digest});
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
  double progress = 0;
  int attempts = 0;
  DateTime? nextAttempt;
  Map<String, dynamic> toJson() => {'id': id, 'peer': peerId, 'kind': kind,
    'name': name, 'source': source, 'entry': entry?.toJson(), 'relative': relative,
    'sourceFolder': sourceFolder, 'state': state, 'error': error, 'digest': digest};
  factory TransferJob.fromJson(Map<String, dynamic> value) => TransferJob(
    id: value['id'] as String, peerId: value['peer'] as String, kind: value['kind'] as String,
    name: value['name'] as String, source: value['source'] as String?,
    entry: value['entry'] == null ? null : SharedFile.fromJson(value['entry'] as Map<String, dynamic>),
    relative: value['relative'] as String?, sourceFolder: value['sourceFolder'] as String?,
    state: value['state'] == 'running' ? 'paused' : value['state'] as String,
    error: value['error'] as String?, digest: value['digest'] as String?);
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
    jobs.addAll(values);
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
        final waiting = jobs.where((j) => j.state == 'waiting' && (j.nextAttempt == null || !j.nextAttempt!.isAfter(DateTime.now())));
        if (waiting.isEmpty) break;
        final job = waiting.first;
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

  Future<void> pause(TransferJob job) async {
    if (job.state == 'completed' || job.state == 'cancelled') return;
    job.state = 'paused';
    if (active == job) interrupt();
    await save();
    notifyListeners();
  }

  Future<void> resume(TransferJob job) async {
    if (job.state == 'completed' || job.state == 'cancelled') return;
    if (active == job) return;
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

  Future<void> clearFinished() async {
    jobs.removeWhere((j) => j.state == 'completed' || j.state == 'cancelled');
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
