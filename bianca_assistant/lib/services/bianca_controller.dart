import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import 'bianca_client.dart';
import 'device_tools.dart';
import 'settings.dart';
import 'voice_service.dart';

enum BiancaState {
  initializing,
  listening,
  thinking,
  speaking,
  waitingConfirmation,
  executing,
  paused,
  error,
}

/// Логика ассистента: слушает → отправляет мозгу → выполняет действия → озвучивает.
class BiancaController extends ChangeNotifier with WidgetsBindingObserver {
  BiancaController();

  // «Бьянка», «Бянка», «Бианка» в любом падеже. \b в Dart не работает с кириллицей.
  static final _wakeWord = RegExp(r'(?<!\p{L})б(?:ь?я|иа)нк\p{L}*(?!\p{L})',
      caseSensitive: false, unicode: true);

  /// Сколько Бьянка «не засыпает» после своего ответа в режиме wake word,
  /// чтобы можно было продолжить разговор без обращения по имени.
  static const _followUpWindow = Duration(seconds: 12);

  AppSettings? _settings;
  AppSettings get settings => _settings!;
  final DeviceTools tools = DeviceTools();
  final VoiceService voice = VoiceService();
  late final BiancaClient client;

  /// Настройки загружены, можно общаться с сервером.
  bool get ready => _settings != null;

  BiancaState state = BiancaState.initializing;
  String status = 'Запускаюсь…';
  String transcript = '';
  String reply = '';
  List<ActionCard> cards = [];

  bool _enabled = true; // пользователь не поставил на паузу
  bool _busy = false;
  bool _inBackground = false;
  DateTime _awakeUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  bool get requireWakeWord => _settings?.requireWakeWord ?? false;
  bool get isAwake => !requireWakeWord || DateTime.now().isBefore(_awakeUntil);

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    final loaded = await AppSettings.load();
    tools.autoStart2Gis = loaded.autoStart2Gis;
    client = BiancaClient(loaded, tools);
    _set(() => _settings = loaded);

    await [
      Permission.microphone,
      Permission.locationWhenInUse,
      Permission.phone,
      Permission.contacts,
    ].request();

    unawaited(tools.refreshPosition());

    voice.onPartial = (text) => _set(() => transcript = text);
    voice.onPhrase = _onPhrase;

    final ok = await voice.init();
    if (!ok) {
      _set(() {
        state = BiancaState.error;
        status = 'Микрофон или распознавание речи недоступны';
      });
      return;
    }
    _resumeListening();
  }

  // ------------------------------------------------------------ управление

  void toggle() {
    _enabled = !_enabled;
    if (_enabled) {
      _resumeListening();
    } else {
      voice.stopListening();
      voice.stopSpeaking();
      _set(() {
        state = BiancaState.paused;
        status = 'На паузе — нажми на сферу';
      });
    }
  }

  void setRequireWakeWord(bool value) {
    settings.requireWakeWord = value;
    _awakeUntil = DateTime.fromMillisecondsSinceEpoch(0);
    if (state == BiancaState.listening) _set(() => status = _listeningStatus());
    notifyListeners();
  }

  /// Текстовый ввод (для отладки без голоса).
  Future<void> sendText(String text) => _process(text.trim());

  Future<void> newConversation() async {
    tools.actions.cancel();
    await client.resetSession();
    _set(() {
      transcript = '';
      reply = '';
      cards = [];
    });
  }

  // ------------------------------------------------------------ диалог

  void _onPhrase(String raw) {
    if (_busy) return;
    final hasWake = _wakeWord.hasMatch(raw);
    if (!isAwake && !hasWake) {
      // Не к нам — продолжаем слушать
      voice.startListening();
      return;
    }
    final command = raw
        .replaceAll(_wakeWord, ' ')
        .replaceAll(RegExp(r'^[\s,.!?]+'), '')
        .trim();
    // Если позвали только по имени — передаём как есть, модель сама отзовётся
    _process(command.isEmpty ? raw : command);
  }

  Future<void> _process(String text) async {
    if (text.isEmpty || _busy || !ready) return;
    tools.actions.handleUserText(text);
    _busy = true;
    await voice.stopListening();
    _set(() {
      state = BiancaState.thinking;
      status = 'Думаю…';
      transcript = text;
      cards = [];
    });

    try {
      final outcome = await client.runTurn(
        text,
        onProgress: (s) => _set(() => status = s),
        onCard: (card) => _set(() => cards = [...cards, card]),
      );

      _set(() {
        reply = outcome.text;
        state = BiancaState.speaking;
        status = 'Говорю…';
      });
      await voice.speak(outcome.text);
      _awakeUntil = DateTime.now().add(_followUpWindow);

      if (outcome.deferred.isNotEmpty) {
        _set(() {
          state = BiancaState.executing;
          status = 'Выполняю действие…';
        });
      }
      for (final action in outcome.deferred) {
        try {
          await action();
        } catch (e) {
          debugPrint('Deferred action failed: $e');
        }
      }
    } on BiancaException catch (e) {
      _set(() {
        state = BiancaState.error;
        status = e.message;
      });
      await voice.speak(e.message);
      await Future<void>.delayed(const Duration(seconds: 1));
    } catch (e) {
      _set(() {
        state = BiancaState.error;
        status = 'Ошибка: $e';
      });
    } finally {
      _busy = false;
      _resumeListening();
    }
  }

  void _resumeListening() {
    if (_disposed || !_enabled || _busy || _inBackground) return;
    if (!voice.available) return;
    _set(() {
      state = tools.actions.hasAwaitingConfirmation
          ? BiancaState.waitingConfirmation
          : BiancaState.listening;
      status = tools.actions.hasAwaitingConfirmation
          ? 'Жду подтверждения отправки…'
          : _listeningStatus();
    });
    voice.startListening();
  }

  String _listeningStatus() =>
      requireWakeWord && !isAwake ? 'Жду «Бьянка»…' : 'Слушаю тебя…';

  // ------------------------------------------------------------ жизненный цикл

  @override
  // ignore: avoid_renaming_method_parameters — `state` уже занято состоянием ассистента
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      // Ушли в звонок / мессенджер / карты — освобождаем микрофон
      _inBackground = true;
      voice.stopListening();
    } else if (lifecycle == AppLifecycleState.resumed) {
      _inBackground = false;
      unawaited(tools.refreshPosition());
      _resumeListening();
    }
  }

  void _set(VoidCallback fn) {
    if (_disposed) return;
    fn();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    voice.dispose();
    super.dispose();
  }
}
