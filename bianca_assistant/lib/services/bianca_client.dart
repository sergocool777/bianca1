import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'device_tools.dart';
import 'settings.dart';

class BiancaException implements Exception {
  BiancaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Итог одного хода диалога.
class TurnOutcome {
  TurnOutcome(this.text, this.cards, this.deferred);

  /// Финальный ответ Бьянки (сформулирован моделью).
  final String text;
  final List<ActionCard> cards;

  /// Действия, которые нужно выполнить после озвучки ответа.
  final List<Future<void> Function()> deferred;
}

/// Клиент протокола /api/turn: отправляет реплику, выполняет инструменты телефона
/// и возвращает результаты, пока модель не даст финальный ответ.
class BiancaClient {
  BiancaClient(this.settings, this.tools, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final AppSettings settings;
  final DeviceTools tools;
  final http.Client _http;

  static const _maxRounds = 8;
  static const _timeout =
      Duration(seconds: 90); // первая загрузка модели бывает долгой

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (settings.token.isNotEmpty) 'X-Bianca-Token': settings.token,
      };

  /// [onProgress] — промежуточные события для UI (что сейчас делает Бьянка).
  Future<TurnOutcome> runTurn(
    String text, {
    void Function(String status)? onProgress,
    void Function(ActionCard card)? onCard,
  }) async {
    final cards = <ActionCard>[];
    final deferred = <Future<void> Function()>[];

    var response =
        await _post({'text': text, 'context': await tools.context()});

    for (var round = 0; response['type'] == 'tool_calls'; round++) {
      if (round >= _maxRounds) {
        throw BiancaException('Слишком длинная цепочка действий');
      }

      final calls =
          (response['calls'] as List? ?? const []).cast<Map<String, dynamic>>();
      final results = <Map<String, dynamic>>[];

      for (final call in calls) {
        final name = call['name']?.toString() ?? '';
        final args = (call['arguments'] is Map)
            ? Map<String, dynamic>.from(call['arguments'] as Map)
            : <String, dynamic>{};
        onProgress?.call(_progressLabel(name));
        debugPrint('[tool] $name $args');

        final outcome = await tools.execute(name, args);
        debugPrint('[tool] $name → ${outcome.result}');
        if (outcome.card != null) {
          cards.add(outcome.card!);
          onCard?.call(outcome.card!);
        }
        if (outcome.deferred != null) deferred.add(outcome.deferred!);
        results.add({'id': call['id'], 'result': outcome.result});
      }

      onProgress?.call('Думаю…');
      response = await _post(
          {'toolResults': results, 'context': await tools.context()});
    }

    return TurnOutcome((response['text'] ?? '').toString(), cards, deferred);
  }

  Future<Map<String, dynamic>> health() async {
    final res = await _http
        .get(Uri.parse('${settings.serverUrl}/api/health'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// Забыть текущий диалог (долговременная память остаётся).
  Future<void> resetSession() async {
    try {
      await _http
          .delete(
              Uri.parse(
                  '${settings.serverUrl}/api/session/${settings.sessionId}'),
              headers: _headers)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    await settings.newSession();
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('${settings.serverUrl}/api/turn'),
            headers: _headers,
            body: jsonEncode({'sessionId': settings.sessionId, ...body}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw BiancaException('Мозг слишком долго думает');
    } catch (_) {
      throw BiancaException('Нет связи с сервером ${settings.serverUrl}');
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw BiancaException('Странный ответ сервера (код ${res.statusCode})');
    }
    if (res.statusCode != 200) {
      throw BiancaException(
          data['error']?.toString() ?? 'Ошибка сервера ${res.statusCode}');
    }
    return data;
  }

  static String _progressLabel(String tool) => switch (tool) {
        'find_contact' => 'Ищу в контактах…',
        'make_call' => 'Готовлю звонок…',
        'send_sms' || 'send_whatsapp' => 'Готовлю сообщение…',
        'get_location' => 'Определяю, где ты…',
        'search_nearby' => 'Ищу места рядом…',
        'navigate_to' => 'Открываю 2ГИС…',
        'set_alarm' => 'Ставлю будильник…',
        'set_timer' => 'Запускаю таймер…',
        _ => 'Выполняю $tool…',
      };
}
