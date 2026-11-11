import 'package:uuid/uuid.dart';

enum PendingActionStatus {
  awaitingConfirmation,
  confirmed,
  executed,
  cancelled,
  expired
}

enum ConfirmationDecision { none, confirmed, cancelled, expired }

class PendingWhatsAppAction {
  PendingWhatsAppAction({
    required this.id,
    required this.phone,
    required this.name,
    required this.text,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String phone;
  final String name;
  final String text;
  final DateTime createdAt;
  final DateTime expiresAt;
  PendingActionStatus status = PendingActionStatus.awaitingConfirmation;
}

class ActionCoordinator {
  ActionCoordinator(
      {DateTime Function()? clock, String Function()? idGenerator})
      : _clock = clock ?? DateTime.now,
        _idGenerator = idGenerator ?? (() => const Uuid().v4());

  static const confirmationTtl = Duration(seconds: 60);

  final DateTime Function() _clock;
  final String Function() _idGenerator;
  PendingWhatsAppAction? _current;

  PendingWhatsAppAction? get pending => _current;

  bool get hasAwaitingConfirmation {
    final action = _current;
    if (action == null) return false;
    if (_isExpired(action)) {
      action.status = PendingActionStatus.expired;
      _current = null;
      return false;
    }
    return action.status == PendingActionStatus.awaitingConfirmation;
  }

  PendingWhatsAppAction prepareWhatsApp({
    required String phone,
    required String name,
    required String text,
  }) {
    final current = _current;
    if (current != null &&
        current.status == PendingActionStatus.awaitingConfirmation &&
        !_isExpired(current) &&
        current.phone == phone &&
        current.text == text) {
      return current;
    }

    if (current != null) current.status = PendingActionStatus.cancelled;
    final now = _clock();
    final action = PendingWhatsAppAction(
      id: _idGenerator(),
      phone: phone,
      name: name,
      text: text,
      createdAt: now,
      expiresAt: now.add(confirmationTtl),
    );
    _current = action;
    return action;
  }

  ConfirmationDecision handleUserText(String text) {
    final action = _current;
    if (action == null) return ConfirmationDecision.none;
    if (_isExpired(action)) {
      action.status = PendingActionStatus.expired;
      _current = null;
      return ConfirmationDecision.expired;
    }

    if (_confirmations.contains(_normalizeCommand(text))) {
      action.status = PendingActionStatus.confirmed;
      return ConfirmationDecision.confirmed;
    }

    action.status = PendingActionStatus.cancelled;
    _current = null;
    return ConfirmationDecision.cancelled;
  }

  PendingWhatsAppAction? consumeConfirmedWhatsApp({
    required String phone,
    required String text,
  }) {
    final action = _current;
    if (action == null) return null;
    if (_isExpired(action)) {
      action.status = PendingActionStatus.expired;
      _current = null;
      return null;
    }
    if (action.status != PendingActionStatus.confirmed ||
        action.phone != phone ||
        action.text != text) {
      return null;
    }

    action.status = PendingActionStatus.executed;
    _current = null;
    return action;
  }

  void cancel() {
    final action = _current;
    if (action == null) return;
    action.status = PendingActionStatus.cancelled;
    _current = null;
  }

  bool _isExpired(PendingWhatsAppAction action) =>
      !_clock().isBefore(action.expiresAt);

  static String _normalizeCommand(String text) => text
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static const _confirmations = {
    'да',
    'давай',
    'отправь',
    'отправляй',
    'подтверждаю',
    'ага',
    'угу',
    'конечно',
    'да отправь',
    'да отправляй',
    'да давай',
  };
}
