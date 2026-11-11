import 'package:bianca_assistant/services/action_coordinator.dart';
import 'package:bianca_assistant/services/android_automation.dart';
import 'package:bianca_assistant/services/device_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

class FakeAndroidAutomation extends AndroidAutomation {
  FakeAndroidAutomation({this.enabled = true});

  final bool enabled;
  int enableChecks = 0;
  int armCalls = 0;
  int cancelCalls = 0;

  @override
  Future<bool> isDgisAutomationEnabled() async {
    enableChecks++;
    return enabled;
  }

  @override
  Future<bool> armDgisAutoStart() async {
    armCalls++;
    return enabled;
  }

  @override
  Future<void> cancelDgisAutoStart() async {
    cancelCalls++;
  }
}

void main() {
  group('WhatsApp confirmation', () {
    test('чат открывается только после подтверждения и один раз', () async {
      final launched = <Uri>[];
      final tools = DeviceTools(launcher: (uri) async {
        launched.add(uri);
        return true;
      });
      final args = {
        'phone': '+7 (701) 000-00-00',
        'name': '',
        'text': 'Привет'
      };

      final draft = await tools.execute('send_whatsapp', args);
      expect(draft.result['status'], 'confirmation_required');
      expect(draft.deferred, isNull);
      expect(launched, isEmpty);

      expect(
          tools.actions.handleUserText('да'), ConfirmationDecision.confirmed);
      final ready = await tools.execute('send_whatsapp', args);
      expect(ready.result['status'], 'whatsapp_composer_ready');
      await ready.deferred!();
      expect(launched.single.host, 'wa.me');
      expect(launched.single.path, '/77010000000');
      expect(launched.single.queryParameters['text'], 'Привет');

      final repeated = await tools.execute('send_whatsapp', args);
      expect(repeated.result['status'], 'confirmation_required');
      expect(repeated.deferred, isNull);
      expect(launched.length, 1);
    });

    test('изменённый после подтверждения текст требует нового согласия',
        () async {
      final tools = DeviceTools(launcher: (_) async => true);
      await tools.execute('send_whatsapp',
          {'phone': '+77010000000', 'name': '', 'text': 'Привет'});
      tools.actions.handleUserText('да');

      final changed = await tools.execute(
        'send_whatsapp',
        {'phone': '+77010000000', 'name': '', 'text': 'Другой текст'},
      );
      expect(changed.result['status'], 'confirmation_required');
      expect(changed.deferred, isNull);
    });
  });

  group('2ГИС auto start', () {
    const args = {
      'destination': 'Кофейня',
      'lat': 43.238,
      'lng': 76.945,
    };

    test('по умолчанию маршрут открывается без армирования', () async {
      final automation = FakeAndroidAutomation();
      final launched = <Uri>[];
      final tools = DeviceTools(
        androidAutomation: automation,
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      );

      final outcome = await tools.execute('navigate_to', args);
      expect(outcome.result['autoStart'], 'disabled');
      expect(automation.enableChecks, 0);
      await outcome.deferred!();
      expect(automation.armCalls, 0);
      expect(launched.single.path, contains('/routeSearch/'));
    });

    test('армируется непосредственно перед открытием маршрута', () async {
      final automation = FakeAndroidAutomation();
      final tools = DeviceTools(
        androidAutomation: automation,
        launcher: (_) async => true,
      )..autoStart2Gis = true;

      final outcome = await tools.execute('navigate_to', args);
      expect(outcome.result['autoStart'], 'armed');
      expect(automation.armCalls, 0);
      await outcome.deferred!();
      expect(automation.armCalls, 1);
      expect(automation.cancelCalls, 0);
    });

    test('без службы возвращает accessibility_required и открывает маршрут',
        () async {
      final automation = FakeAndroidAutomation(enabled: false);
      final launched = <Uri>[];
      final tools = DeviceTools(
        androidAutomation: automation,
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      )..autoStart2Gis = true;

      final outcome = await tools.execute('navigate_to', args);
      expect(outcome.result['autoStart'], 'accessibility_required');
      await outcome.deferred!();
      expect(automation.armCalls, 1);
      expect(automation.cancelCalls, 0);
      expect(launched.single.path, contains('/routeSearch/'));
    });

    test('запасной запуск отменяет армирование', () async {
      final automation = FakeAndroidAutomation();
      final launched = <Uri>[];
      final tools = DeviceTools(
        androidAutomation: automation,
        launcher: (uri) async {
          launched.add(uri);
          return launched.length > 1;
        },
      )..autoStart2Gis = true;

      final outcome = await tools.execute('navigate_to', args);
      await outcome.deferred!();
      expect(automation.armCalls, 1);
      expect(automation.cancelCalls, 1);
      expect(launched, hasLength(2));
      expect(launched.last.path, contains('/search/'));
    });

    test('без координат автонажатие не армируется', () async {
      final automation = FakeAndroidAutomation();
      final tools = DeviceTools(
        androidAutomation: automation,
        launcher: (_) async => true,
      )..autoStart2Gis = true;

      final outcome = await tools.execute(
        'navigate_to',
        {'destination': 'Кофейня', 'lat': null, 'lng': null},
      );
      expect(outcome.result['autoStart'], 'disabled');
      await outcome.deferred!();
      expect(automation.enableChecks, 0);
      expect(automation.armCalls, 0);
    });
  });

  group('Calls', () {
    test('экстренный номер блокируется до запроса разрешения', () async {
      var permissionRequested = false;
      final tools = DeviceTools(phonePermission: () async {
        permissionRequested = true;
        return PermissionStatus.granted;
      });

      final outcome =
          await tools.execute('make_call', {'phone': '112', 'name': ''});
      expect(outcome.result['ok'], isFalse);
      expect(outcome.result['errorCode'], 'emergency_call_blocked');
      expect(outcome.deferred, isNull);
      expect(permissionRequested, isFalse);
    });

    test('без разрешения открывается номеронабиратель', () async {
      final launched = <Uri>[];
      var directCalled = false;
      final tools = DeviceTools(
        phonePermission: () async => PermissionStatus.permanentlyDenied,
        directCall: (_) async {
          directCalled = true;
        },
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      );

      final outcome = await tools
          .execute('make_call', {'phone': '+77010000000', 'name': ''});
      expect(outcome.result['status'], 'dialer_ready');
      await outcome.deferred!();
      expect(directCalled, isFalse);
      expect(launched.single.toString(), 'tel:+77010000000');
    });

    test('при ошибке прямого звонка используется номеронабиратель', () async {
      final launched = <Uri>[];
      final tools = DeviceTools(
        phonePermission: () async => PermissionStatus.granted,
        directCall: (_) async => throw StateError('call failed'),
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      );

      final outcome = await tools
          .execute('make_call', {'phone': '+77010000000', 'name': ''});
      expect(outcome.result['status'], 'call_ready');
      await outcome.deferred!();
      expect(launched.single.scheme, 'tel');
    });
  });
}
