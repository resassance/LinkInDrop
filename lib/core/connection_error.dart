import '../l10n/messages.dart';
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
      localizeMessage("Нет соединения с {0}. Проверьте адрес и порт в QR, VPN на обоих устройствах, Windows Firewall и доступ к сети.", [target]),
    ConnectionFailureKind.certificate =>
      localizeMessage("Не удалось проверить устройство {0}. Создайте новый QR на нужном устройстве.", [target]),
    ConnectionFailureKind.approvalTimeout =>
      localizeMessage("Подтверждение на {0} не получено. Откройте LinkInDrop на другом устройстве и повторите подключение.", [target]),
    ConnectionFailureKind.rejected => localizeMessage("Подключение отклонено на {0}.", [target]),
    ConnectionFailureKind.expired => localizeMessage("Код подключения больше не действует. Создайте новый QR."),
    ConnectionFailureKind.busy => localizeMessage("Устройство {0} занято. Подождите и повторите подключение.", [target]),
  };

  @override
  String toString() => localizeMessage("{0}\n\nПодробности: {1}", [message, details]);
}

class RemoteFailure implements Exception {
  const RemoteFailure(this.status, this.reason);
  final int status;
  final String reason;
  @override
  String toString() => localizeMessage("Запрос отклонён ({0}): {1}", [status, reason]);
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

