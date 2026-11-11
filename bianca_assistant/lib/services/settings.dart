import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Настройки приложения, хранятся в SharedPreferences.
class AppSettings {
  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  // По USB: adb reverse tcp:3000 tcp:3000. По Wi‑Fi: http://<IP компьютера>:3000
  static const defaultServerUrl = 'http://127.0.0.1:3000';

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings._(prefs);
    if (prefs.getString(_kSession) == null) await settings.newSession();
    return settings;
  }

  static const _kServer = 'server_url';
  static const _kToken = 'token';
  static const _kSession = 'session_id';
  static const _kWakeWord = 'require_wake_word';
  static const _kAutoStart2Gis = 'auto_start_2gis';

  String get serverUrl => _prefs.getString(_kServer) ?? defaultServerUrl;
  set serverUrl(String value) {
    var v = value.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    _prefs.setString(_kServer, v.isEmpty ? defaultServerUrl : v);
  }

  String get token => _prefs.getString(_kToken) ?? '';
  set token(String value) => _prefs.setString(_kToken, value.trim());

  String get sessionId => _prefs.getString(_kSession)!;

  Future<void> newSession() => _prefs.setString(_kSession, const Uuid().v4());

  /// true — реагирует только на фразы с «Бьянка» (и короткое время после ответа).
  bool get requireWakeWord => _prefs.getBool(_kWakeWord) ?? false;
  set requireWakeWord(bool value) => _prefs.setBool(_kWakeWord, value);

  bool get autoStart2Gis => _prefs.getBool(_kAutoStart2Gis) ?? false;
  set autoStart2Gis(bool value) => _prefs.setBool(_kAutoStart2Gis, value);
}
