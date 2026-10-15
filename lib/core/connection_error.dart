import 'dart:async';
import 'dart:io';

enum ConnectionFailureKind { unreachable, certificate, approvalTimeout, rejected, expired, busy }

class ConnectionFailure implements Exception {
  const ConnectionFailure(this.kind, this.target, this.details);

  final ConnectionFailureKind kind;
  final String target;
  final String details;

  String get message => switch (kind) {
    ConnectionFailureKind.unreachable =>
      'Нет соединения с $target. Проверьте адрес и порт в QR, VPN на обоих устройствах, Windows Firewall и доступ к сети.',
    ConnectionFailureKind.certificate =>
      'Не удалось проверить устройство $target. Создайте новый QR на нужном устройстве.',
    ConnectionFailureKind.approvalTimeout =>
      'Подтверждение на $target не получено. Откройте Nearbridge на другом устройстве и повторите подключение.',
    ConnectionFailureKind.rejected => 'Подключение отклонено на $target.',
    ConnectionFailureKind.expired => 'Код подключения больше не действует. Создайте новый QR.',
    ConnectionFailureKind.busy => 'Устройство $target занято. Подождите и повторите подключение.',
  };

  @override
  String toString() => '$message\n\nПодробности: $details';
}

class RemoteFailure implements Exception {
  const RemoteFailure(this.status, this.reason);
  final int status;
  final String reason;
  @override
  String toString() => 'Запрос отклонён ($status): $reason';
}

ConnectionFailure describePairingFailure(Object error, String target,
    {required bool waitingForApproval}) {
  final kind = switch (error) {
    HandshakeException() => ConnectionFailureKind.certificate,
    TimeoutException() when waitingForApproval => ConnectionFailureKind.approvalTimeout,
    RemoteFailure(status: 429) => ConnectionFailureKind.busy,
    RemoteFailure(reason: 'Pairing code invalid or expired') => ConnectionFailureKind.expired,
    RemoteFailure(reason: 'Pairing rejected') => ConnectionFailureKind.rejected,
    _ => ConnectionFailureKind.unreachable,
  };
  return ConnectionFailure(kind, target, '$error');
}

