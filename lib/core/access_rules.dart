import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class ShareAccess {
  ShareAccess({this.peerIds, this.expiresAt});
  final Set<String>? peerIds;
  final DateTime? expiresAt;
  bool allows(String peerId, {DateTime? now}) =>
    (expiresAt == null || expiresAt!.isAfter(now ?? DateTime.now())) &&
    (peerIds == null || peerIds!.contains(peerId));
  Map<String, dynamic> toJson() => {'peers': peerIds?.toList(),
    'expires': expiresAt?.millisecondsSinceEpoch};
  factory ShareAccess.fromJson(Map<String, dynamic> data) => ShareAccess(
    peerIds: data['peers'] == null ? null : (data['peers'] as List).cast<String>().toSet(),
    expiresAt: data['expires'] == null ? null : DateTime.fromMillisecondsSinceEpoch(data['expires'] as int));
}

class AccessRules {
  AccessRules(this.directory);
  final Directory directory;
  final Map<String, ShareAccess> rules = {};
  Future<void> _saving = Future.value();
  Future<void> load() async {
    final file = File(p.join(directory.path, 'share-access.json'));
    if (!await file.exists()) return;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    for (final item in data.entries) {
      rules[item.key] = ShareAccess.fromJson(item.value as Map<String, dynamic>);
    }
  }
  bool allows(String resource, String peerId) => rules[resource]?.allows(peerId) ?? true;
  Future<void> set(String resource, ShareAccess access) {
    rules[resource] = access;
    final content = jsonEncode(rules.map((key, value) => MapEntry(key, value.toJson())));
    _saving = _saving.catchError((Object _) {}).then((_) async {
      final file = File(p.join(directory.path, 'share-access.json.new'));
      await file.writeAsString(content, flush: true);
      await file.rename(p.join(directory.path, 'share-access.json'));
    });
    return _saving;
  }
}
