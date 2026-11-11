import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Уши и голос Бьянки: непрерывное распознавание речи и озвучка.
///
/// Сервис сам перезапускает микрофон, пока [listening] включено,
/// и выдаёт законченные фразы в [onPhrase].
class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  /// Громкость с микрофона 0..15 — для анимации сферы (без перерисовки всего экрана).
  final ValueNotifier<double> soundLevel = ValueNotifier(0);

  void Function(String partial)? onPartial;
  void Function(String phrase)? onPhrase;

  bool _available = false;
  bool _wantListening = false;
  bool _speaking = false;
  int _generation = 0; // защита от двойной отправки одной фразы
  String _pending = '';
  Timer? _silenceTimer;
  Timer? _restartTimer;

  bool get available => _available;
  bool get speaking => _speaking;

  Future<bool> init() async {
    await _tts.setLanguage('ru-RU');
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);

    _available = await _speech.initialize(
      onStatus: _onStatus,
      onError: (error) {
        debugPrint('STT error: ${error.errorMsg}');
        _scheduleRestart(const Duration(milliseconds: 800));
      },
    );
    return _available;
  }

  /// Начать (или продолжить) слушать.
  void startListening() {
    if (!_available) return;
    _wantListening = true;
    _listen();
  }

  /// Перестать слушать (например, пока Бьянка думает или говорит).
  Future<void> stopListening() async {
    _wantListening = false;
    _silenceTimer?.cancel();
    _restartTimer?.cancel();
    _pending = '';
    soundLevel.value = 0;
    _generation++;
    await _speech.cancel();
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await stopListening();
    _speaking = true;
    try {
      await _tts.speak(text);
    } finally {
      _speaking = false;
    }
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    _speaking = false;
  }

  void dispose() {
    _silenceTimer?.cancel();
    _restartTimer?.cancel();
    _speech.cancel();
    _tts.stop();
    soundLevel.dispose();
  }

  // ------------------------------------------------------------------

  void _listen() {
    if (!_wantListening || _speaking || _speech.isListening) return;
    final gen = ++_generation;
    _pending = '';

    _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        localeId: 'ru_RU',
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: false,
      ),
      onSoundLevelChange: (level) => soundLevel.value = level.clamp(0.0, 15.0),
      onResult: (result) {
        if (gen != _generation) return;
        final text = result.recognizedWords.trim();
        if (text.isEmpty) return;
        _pending = text;
        onPartial?.call(text);

        _silenceTimer?.cancel();
        if (result.finalResult) {
          _emit(gen);
        } else {
          // Android иногда долго не присылает finalResult — отправляем после паузы
          _silenceTimer = Timer(const Duration(milliseconds: 1200), () => _emit(gen));
        }
      },
    );
  }

  void _emit(int gen) {
    if (gen != _generation || _pending.isEmpty) return;
    final phrase = _pending;
    _pending = '';
    _generation++; // все последующие колбэки этой сессии игнорируются
    _silenceTimer?.cancel();
    onPhrase?.call(phrase);
  }

  void _onStatus(String status) {
    if (status != 'done' && status != 'notListening') return;
    soundLevel.value = 0;
    if (_pending.isNotEmpty) {
      _emit(_generation);
    } else {
      _scheduleRestart(const Duration(milliseconds: 300));
    }
  }

  void _scheduleRestart(Duration delay) {
    if (!_wantListening || _speaking) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, _listen);
  }
}
