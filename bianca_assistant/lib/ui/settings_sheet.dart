import 'package:flutter/material.dart';

import '../services/bianca_controller.dart';

/// Настройки: адрес сервера, токен, режим wake word, новый диалог.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, required this.controller});

  final BiancaController controller;

  static Future<void> show(BuildContext context, BiancaController controller) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1120),
      builder: (_) => SettingsSheet(controller: controller),
    );
  }

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet>
    with WidgetsBindingObserver {
  late final TextEditingController _url;
  late final TextEditingController _token;
  String? _healthText;
  bool _checking = false;
  bool _dgisAutomationEnabled = false;

  BiancaController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _url = TextEditingController(text: c.settings.serverUrl);
    _token = TextEditingController(text: c.settings.token);
    _refreshDgisAutomationStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshDgisAutomationStatus();
  }

  Future<void> _refreshDgisAutomationStatus() async {
    final enabled = await c.tools.androidAutomation.isDgisAutomationEnabled();
    if (mounted) setState(() => _dgisAutomationEnabled = enabled);
  }

  Future<void> _setAutoStart2Gis(bool value) async {
    setState(() {
      c.settings.autoStart2Gis = value;
      c.tools.autoStart2Gis = value;
    });
    if (value) {
      await _refreshDgisAutomationStatus();
    } else {
      await c.tools.androidAutomation.cancelDgisAutoStart();
    }
  }

  void _save() {
    c.settings.serverUrl = _url.text;
    c.settings.token = _token.text;
  }

  Future<void> _check() async {
    _save();
    setState(() {
      _checking = true;
      _healthText = null;
    });
    String text;
    try {
      final h = await c.client.health();
      if (h['ok'] == true) {
        text = h['modelReady'] == true
            ? '✅ Связь есть, модель ${h['model']} готова'
            : '⚠️ Сервер есть, но модели ${h['model']} нет в Ollama (ollama pull ${h['model']})';
      } else {
        text = '⚠️ Сервер есть, но Ollama не отвечает: ${h['error']}';
      }
    } catch (e) {
      text = '❌ Нет связи с ${c.settings.serverUrl}';
    }
    if (mounted) {
      setState(() {
        _checking = false;
        _healthText = text;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Настройки',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Адрес сервера',
              helperText:
                  'USB: http://127.0.0.1:3000 (adb reverse) · Wi‑Fi: http://IP-компьютера:3000',
            ),
            onChanged: (_) => _save(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Токен (BIANCA_TOKEN)',
              helperText: 'Оставь пустым, если на сервере токен не задан',
            ),
            onChanged: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _checking ? null : _check,
                icon: _checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: const Text('Проверить связь'),
              ),
            ],
          ),
          if (_healthText != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_healthText!,
                  style: const TextStyle(color: Colors.white70)),
            ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Только по слову «Бьянка»'),
            subtitle: const Text('Иначе отвечает на любую фразу'),
            value: c.requireWakeWord,
            onChanged: (v) => setState(() => c.setRequireWakeWord(v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Автоматически нажимать «В путь» в 2ГИС'),
            subtitle: const Text('Только для маршрута, запущенного Бьянкой'),
            value: c.settings.autoStart2Gis,
            onChanged: _setAutoStart2Gis,
          ),
          if (c.settings.autoStart2Gis) ...[
            Text(
              _dgisAutomationEnabled
                  ? 'Служба включена. Автонажатие сработает один раз, если 2ГИС покажет кнопку «В путь».'
                  : 'Включите «Бьянка: автостарт маршрута 2ГИС» в настройках специальных возможностей Android.',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: c.tools.androidAutomation.openAccessibilitySettings,
                icon: const Icon(Icons.accessibility_new),
                label: const Text('Открыть настройки Android'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await c.newConversation();
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Начать новый диалог'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Бьянка забудет текущий разговор, но долговременная память о тебе сохранится.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
