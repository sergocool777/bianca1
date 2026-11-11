import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'services/bianca_controller.dart';
import 'ui/drive_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  runApp(BiancaApp(controller: BiancaController()..init()));
}

class BiancaApp extends StatelessWidget {
  const BiancaApp({super.key, required this.controller});

  final BiancaController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bianca AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF050811)),
      home: DriveScreen(controller: controller),
    );
  }
}
