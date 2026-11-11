import 'dart:math';

import 'package:flutter/material.dart';

import '../services/bianca_controller.dart';

/// Живая сфера Бьянки: цвет показывает состояние, размер — громкость голоса.
class VoiceOrbPainter extends CustomPainter {
  VoiceOrbPainter({
    required this.animation,
    required this.soundLevel,
    required this.state,
    required this.awake,
  }) : super(repaint: Listenable.merge([animation, soundLevel]));

  final Animation<double> animation;
  final ValueNotifier<double> soundLevel;
  final BiancaState state;
  final bool awake;

  Color get _color => switch (state) {
        BiancaState.speaking ||
        BiancaState.executing =>
          const Color(0xFF10B981),
        BiancaState.thinking => const Color(0xFFF59E0B),
        BiancaState.waitingConfirmation => const Color(0xFF8B5CF6),
        BiancaState.error => const Color(0xFFEF4444),
        BiancaState.paused ||
        BiancaState.initializing =>
          const Color(0xFF64748B),
        BiancaState.listening =>
          awake ? const Color(0xFF8B5CF6) : const Color(0xFF3B82F6),
      };

  @override
  void paint(Canvas canvas, Size size) {
    final progress = animation.value;
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width * 0.32;
    final pulse = state == BiancaState.thinking
        ? sin(progress * 6 * pi) * 8
        : sin(progress * 2 * pi) * 6;
    final expansion = soundLevel.value * 2.2 + pulse;
    final color = _color;

    final glowPaint = Paint()
      ..color = color.withAlpha(71)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 35);
    canvas.drawCircle(center, baseRadius + expansion + 20, glowPaint);

    final corePaint = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white.withAlpha(230), color, color.withAlpha(51)],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(
          Rect.fromCircle(center: center, radius: baseRadius + expansion));
    canvas.drawCircle(center, baseRadius + expansion * 0.5, corePaint);
  }

  @override
  bool shouldRepaint(covariant VoiceOrbPainter old) =>
      old.state != state || old.awake != awake;
}
