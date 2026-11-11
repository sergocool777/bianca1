import 'package:flutter/services.dart';

class AndroidAutomation {
  static const _channel = MethodChannel('bianca/android_automation');

  Future<bool> armDgisAutoStart() async {
    try {
      return await _channel.invokeMethod<bool>('armDgisAutoStart') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> cancelDgisAutoStart() async {
    try {
      await _channel.invokeMethod<void>('cancelDgisAutoStart');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  Future<bool> isDgisAutomationEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isDgisAutomationEnabled') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod<void>('openAccessibilitySettings');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }
}
