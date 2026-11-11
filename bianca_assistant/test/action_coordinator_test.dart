import 'package:bianca_assistant/services/action_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ActionCoordinator', () {
    test('подтверждение одноразовое и только для неизменного сообщения', () {
      var now = DateTime.utc(2026, 1, 1, 12);
      var nextId = 0;
      final actions = ActionCoordinator(
        clock: () => now,
        idGenerator: () => 'action-${++nextId}',
      );

      final draft = actions.prepareWhatsApp(
          phone: '77010000000', name: 'Мама', text: 'Привет');
      expect(draft.status, PendingActionStatus.awaitingConfirmation);
      expect(
          actions
              .prepareWhatsApp(
                  phone: '77010000000', name: 'Мама', text: 'Привет')
              .id,
          draft.id);
      expect(
          actions.consumeConfirmedWhatsApp(
              phone: '77010000000', text: 'Привет'),
          isNull);

      expect(actions.handleUserText('Да, отправляй!'),
          ConfirmationDecision.confirmed);
      expect(
          actions.consumeConfirmedWhatsApp(
              phone: '77010000000', text: 'Другой текст'),
          isNull);

      final confirmed = actions.consumeConfirmedWhatsApp(
          phone: '77010000000', text: 'Привет');
      expect(confirmed?.status, PendingActionStatus.executed);
      expect(actions.pending, isNull);
      expect(
          actions.consumeConfirmedWhatsApp(
              phone: '77010000000', text: 'Привет'),
          isNull);
    });

    test('новая реплика отменяет старый draft', () {
      final actions = ActionCoordinator(idGenerator: () => 'draft');
      actions.prepareWhatsApp(
          phone: '77010000000', name: 'Мама', text: 'Привет');

      expect(actions.handleUserText('Лучше напиши папе'),
          ConfirmationDecision.cancelled);
      expect(actions.pending, isNull);
      expect(actions.handleUserText('да'), ConfirmationDecision.none);
    });

    test('подтверждение истекает через 60 секунд', () {
      var now = DateTime.utc(2026, 1, 1, 12);
      final actions =
          ActionCoordinator(clock: () => now, idGenerator: () => 'draft');
      actions.prepareWhatsApp(
          phone: '77010000000', name: 'Мама', text: 'Привет');

      now = now.add(const Duration(seconds: 60));
      expect(actions.handleUserText('да'), ConfirmationDecision.expired);
      expect(actions.pending, isNull);
      expect(actions.hasAwaitingConfirmation, isFalse);
    });
  });
}
