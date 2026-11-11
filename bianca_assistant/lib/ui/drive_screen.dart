import 'package:flutter/material.dart';

import '../services/bianca_controller.dart';
import '../services/device_tools.dart';
import 'orb_painter.dart';
import 'settings_sheet.dart';

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key, required this.controller});

  final BiancaController controller;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _orb;
  final _input = TextEditingController();

  BiancaController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _orb = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  }

  @override
  void dispose() {
    _orb.dispose();
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    FocusScope.of(context).unfocus();
    c.sendText(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(
              children: [
                _statusBar(),
                const Spacer(),
                GestureDetector(
                  onTap: c.toggle,
                  child: CustomPaint(
                    size: const Size(200, 200),
                    painter: VoiceOrbPainter(
                      animation: _orb,
                      soundLevel: c.voice.soundLevel,
                      state: c.state,
                      awake: c.isAwake,
                    ),
                  ),
                ),
                const Spacer(),
                if (c.transcript.isNotEmpty) _bubble('Ты: «${c.transcript}»', user: true),
                if (c.reply.isNotEmpty) _bubble(c.reply),
                for (final card in c.cards) _ActionCardView(card: card),
                const SizedBox(height: 8),
                _textInput(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusBar() {
    final active = c.state == BiancaState.listening;
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? const Color(0xFF10B981) : Colors.grey,
            boxShadow: active ? const [BoxShadow(color: Color(0xFF10B981), blurRadius: 8)] : const [],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            c.status,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (c.requireWakeWord)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Chip(label: Text('«Бьянка»', style: TextStyle(fontSize: 11))),
          ),
        IconButton(
          icon: const Icon(Icons.settings, color: Colors.white54),
          onPressed: c.ready ? () => SettingsSheet.show(context, c) : null,
        ),
      ],
    );
  }

  Widget _bubble(String text, {bool user = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: user ? Colors.white.withAlpha(13) : const Color(0xFF3B82F6).withAlpha(31),
        borderRadius: BorderRadius.circular(16),
        border: user ? null : Border.all(color: const Color(0xFF3B82F6).withAlpha(77)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: user ? Colors.white70 : Colors.white,
          fontSize: user ? 15 : 17,
          fontWeight: user ? FontWeight.normal : FontWeight.w500,
        ),
      ),
    );
  }

  Widget _textInput() {
    return TextField(
      controller: _input,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: 'Или напиши Бьянке…',
        isDense: true,
        filled: true,
        fillColor: Colors.white.withAlpha(13),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _submit),
      ),
    );
  }
}

class _ActionCardView extends StatelessWidget {
  const _ActionCardView({required this.card});

  final ActionCard card;

  IconData get _icon => switch (card.type) {
        'CALL' => Icons.call,
        'SMS' => Icons.sms,
        'WHATSAPP' => Icons.chat,
        'CONTACT' => Icons.person_search,
        'LOCATION' => Icons.my_location,
        'NAVIGATION' => Icons.navigation,
        'ALARM' => Icons.alarm,
        'TIMER' => Icons.timer,
        'ERROR' => Icons.error_outline,
        _ => Icons.bolt,
      };

  @override
  Widget build(BuildContext context) {
    final isError = card.type == 'ERROR';
    final accent = isError ? const Color(0xFFEF4444) : const Color(0xFF10B981);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [accent.withAlpha(51), accent.withAlpha(15)]),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withAlpha(128)),
      ),
      child: Row(
        children: [
          Icon(_icon, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(card.title,
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                if (card.subtitle.isNotEmpty)
                  Text(card.subtitle, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
