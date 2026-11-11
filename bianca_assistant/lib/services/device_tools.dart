import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show Locale;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'action_coordinator.dart';
import 'android_automation.dart';

/// Карточка выполненного действия для экрана.
class ActionCard {
  const ActionCard(this.type, this.title, [this.subtitle = '']);

  final String
      type; // CALL, SMS, WHATSAPP, CONTACT, LOCATION, NAVIGATION, ALARM, TIMER, ERROR
  final String title;
  final String subtitle;
}

/// Результат выполнения инструмента телефона.
class ToolOutcome {
  const ToolOutcome(this.result, {this.card, this.deferred});

  ToolOutcome.success(
    String status,
    Map<String, dynamic> result, {
    ActionCard? card,
    Future<void> Function()? deferred,
  }) : this({'ok': true, 'status': status, ...result},
            card: card, deferred: deferred);

  ToolOutcome.error(String message, {String? title, String code = 'tool_error'})
      : result = {
          'ok': false,
          'status': 'error',
          'errorCode': code,
          'error': message
        },
        card = ActionCard('ERROR', title ?? 'Не получилось', message),
        deferred = null;

  /// Уходит обратно модели.
  final Map<String, dynamic> result;
  final ActionCard? card;

  /// Действия, уводящие из приложения (звонок, мессенджер, карты),
  /// выполняются после того, как Бьянка озвучит ответ.
  final Future<void> Function()? deferred;
}

typedef DirectCall = Future<void> Function(String phone);
typedef PhonePermission = Future<PermissionStatus> Function();
typedef ExternalLauncher = Future<bool> Function(Uri uri);

/// Инструменты телефона — «руки» Бьянки.
class DeviceTools {
  DeviceTools({
    ActionCoordinator? actions,
    DirectCall? directCall,
    PhonePermission? phonePermission,
    ExternalLauncher? launcher,
    AndroidAutomation? androidAutomation,
  })  : actions = actions ?? ActionCoordinator(),
        androidAutomation = androidAutomation ?? AndroidAutomation(),
        _directCall = directCall ?? _defaultDirectCall,
        _phonePermission = phonePermission ?? _requestPhonePermission,
        _launcher = launcher ?? _defaultLaunch;

  final ActionCoordinator actions;
  final AndroidAutomation androidAutomation;
  final DirectCall _directCall;
  final PhonePermission _phonePermission;
  final ExternalLauncher _launcher;

  bool autoStart2Gis = false;

  Position? lastPosition;
  String? lastAddress;

  List<fc.Contact>? _contacts;
  DateTime? _contactsLoadedAt;

  Future<ToolOutcome> execute(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'find_contact':
          return await _findContact(_str(args['query']));
        case 'make_call':
          return await _makeCall(_str(args['phone']), _str(args['name']));
        case 'send_sms':
          return await _sendSms(
              _str(args['phone']), _str(args['text']), _str(args['name']));
        case 'send_whatsapp':
          return await _sendWhatsApp(
              _str(args['phone']), _str(args['text']), _str(args['name']));
        case 'get_location':
          return await _getLocation();
        case 'navigate_to':
          return await _navigateTo(
            _str(args['destination']),
            lat: _double(args['lat']),
            lng: _double(args['lng']),
          );
        case 'search_nearby':
          return await _searchNearby(
            _str(args['query']),
            openMap: args['open_map'] == true,
          );
        case 'set_alarm':
          return await _setAlarm(
              _int(args['hour']), _int(args['minute']), _str(args['label']));
        case 'set_timer':
          return await _setTimer(_int(args['seconds']), _str(args['label']));
        default:
          return ToolOutcome.error(
              'Телефон не умеет выполнять инструмент $name',
              code: 'unknown_tool');
      }
    } catch (e, st) {
      debugPrint('Tool $name failed: $e\n$st');
      return ToolOutcome.error('Ошибка на телефоне: $e',
          code: 'device_exception');
    }
  }

  // ---------------------------------------------------------------- контекст

  /// Сведения о телефоне, которые прикладываются к каждому запросу.
  Future<Map<String, dynamic>> context() async {
    final now = DateTime.now();
    unawaited(refreshPosition());
    final permissions = await Future.wait([
      Permission.microphone.status,
      Permission.contacts.status,
      Permission.phone.status,
      Permission.locationWhenInUse.status,
    ]);
    return {
      'localTime': now.toUtc().toIso8601String(),
      'utcOffsetMinutes': now.timeZoneOffset.inMinutes,
      'timezone': now.timeZoneName,
      if (lastPosition != null)
        'coords': {
          'lat': lastPosition!.latitude,
          'lng': lastPosition!.longitude
        },
      if (lastAddress != null) 'address': lastAddress,
      'capabilities': {
        'microphone': permissions[0].name,
        'contacts': permissions[1].name,
        'phone': {'directCall': permissions[2].isGranted, 'dialer': true},
        'locationWhenInUse': permissions[3].name,
        'whatsapp': {'composerIntent': true, 'automaticSend': false},
        'backgroundListening': false,
      },
    };
  }

  bool _refreshing = false;

  Future<Position?> refreshPosition(
      {Duration timeLimit = const Duration(seconds: 6)}) async {
    if (_refreshing) return lastPosition;
    _refreshing = true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return lastPosition;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return lastPosition;
      }
      lastPosition ??= await Geolocator.getLastKnownPosition();
      lastPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: timeLimit,
      );
      return lastPosition;
    } catch (_) {
      return lastPosition;
    } finally {
      _refreshing = false;
    }
  }

  // ---------------------------------------------------------------- контакты

  Future<List<fc.Contact>> _ensureContacts() async {
    final stale = _contactsLoadedAt == null ||
        DateTime.now().difference(_contactsLoadedAt!) >
            const Duration(minutes: 5);
    if (_contacts == null || stale) {
      final status =
          await fc.FlutterContacts.permissions.request(fc.PermissionType.read);
      if (status == fc.PermissionStatus.granted ||
          status == fc.PermissionStatus.limited) {
        _contacts = await fc.FlutterContacts.getAll(
            properties: {fc.ContactProperty.phone});
        _contactsLoadedAt = DateTime.now();
      }
    }
    return _contacts ?? const [];
  }

  /// Если модель передала имя контакта (например, «Мамуля»), но подставила старый номер
  /// другого контакта из истории — находим правильный контакт по имени.
  Future<(String phone, String name)?> _resolveByName(
      String phone, String name) async {
    if (name.isEmpty) return (phone, name);
    final contacts = await _ensureContacts();
    if (contacts.isEmpty) return (phone, name);

    final matches = ContactMatcher.match(name, contacts);
    if (matches.isEmpty) return (phone, name);

    final targetDigits = _last10(phone);
    final matchesPhone = matches.any(
      (c) => c.phones.any(
          (p) => _last10(p.number) == targetDigits && targetDigits.isNotEmpty),
    );
    if (matchesPhone) return (phone, name);

    // Номер не принадлежит найденному по имени контакту!
    if (matches.length == 1 && matches.first.phones.isNotEmpty) {
      final right = matches.first;
      return (right.phones.first.number, right.displayName ?? name);
    }
    return null; // Несколько кандидатов — пусть модель уточнит
  }

  static String _last10(String phone) {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    return d.length > 10 ? d.substring(d.length - 10) : d;
  }

  Future<ToolOutcome> _findContact(String query) async {
    if (query.isEmpty) {
      return ToolOutcome.error('Не указано, кого искать',
          code: 'invalid_query');
    }

    final status =
        await fc.FlutterContacts.permissions.request(fc.PermissionType.read);
    if (status != fc.PermissionStatus.granted &&
        status != fc.PermissionStatus.limited) {
      return ToolOutcome.error(
        'Нет доступа к контактам: пользователь не дал разрешение',
        code: 'permission_denied',
      );
    }

    final contacts = await _ensureContacts();
    final matches = ContactMatcher.match(query, contacts);
    if (matches.isEmpty) {
      return ToolOutcome.success(
        'contact_not_found',
        {'contacts': [], 'note': 'Контакт «$query» не найден'},
        card: ActionCard('CONTACT', 'Не нашла «$query»', 'в телефонной книге'),
      );
    }

    final list = matches.take(5).map((c) {
      final seen = <String>{};
      final phones = <Map<String, String>>[];
      for (final p in c.phones) {
        final digits = p.number.replaceAll(RegExp(r'[^\d+]'), '');
        if (digits.isEmpty || !seen.add(digits)) continue;
        phones.add({
          'number': p.number,
          'type': p.label.customLabel ?? p.label.label.name
        });
      }
      return {'name': c.displayName ?? '', 'phones': phones};
    }).toList();

    return ToolOutcome.success(
      'contacts_found',
      {'contacts': list},
      card: ActionCard(
        'CONTACT',
        list.length == 1
            ? list.first['name'] as String
            : 'Нашла ${list.length} контакта',
        list.map((c) => c['name']).join(', '),
      ),
    );
  }

  // ---------------------------------------------------------------- связь

  Future<ToolOutcome> _makeCall(String phone, String name) async {
    final resolved = await _resolveByName(phone, name);
    if (resolved == null) {
      return ToolOutcome.error(
        'Для «$name» есть несколько контактов, а номер $phone им не принадлежит. Вызови find_contact для «$name» и уточни у пользователя.',
        code: 'ambiguous_contact',
      );
    }
    phone = resolved.$1;
    name = resolved.$2;

    if (!_looksLikePhone(phone)) {
      return ToolOutcome.error('Некорректный номер: «$phone»',
          code: 'invalid_phone');
    }
    if (isEmergencyPhone(phone)) {
      return ToolOutcome.error(
        'Автоматический звонок на экстренный номер запрещён',
        code: 'emergency_call_blocked',
      );
    }

    final who = name.isNotEmpty ? name : phone;
    final dialUri = Uri(scheme: 'tel', path: _cleanPhone(phone));
    final permission = await _phonePermission();
    if (!permission.isGranted) {
      return ToolOutcome.success(
        'dialer_ready',
        {
          'contact': who,
          'phone': phone,
          'note':
              'После твоего ответа откроется номеронабиратель. Пользователю останется нажать кнопку звонка.',
        },
        card: ActionCard('CALL', 'Номеронабиратель: $who', phone),
        deferred: () => _launch(dialUri),
      );
    }

    return ToolOutcome.success(
      'call_ready',
      {
        'contact': who,
        'phone': phone,
        'note': 'Звонок $who начнётся сразу после твоего ответа'
      },
      card: ActionCard('CALL', 'Звонок: $who', phone),
      deferred: () async {
        try {
          await _directCall(phone);
        } catch (_) {
          await _launch(dialUri);
        }
      },
    );
  }

  Future<ToolOutcome> _sendSms(String phone, String text, String name) async {
    final resolved = await _resolveByName(phone, name);
    if (resolved != null) {
      phone = resolved.$1;
      name = resolved.$2;
    }
    if (!_looksLikePhone(phone)) {
      return ToolOutcome.error('Некорректный номер: «$phone»',
          code: 'invalid_phone');
    }
    if (text.isEmpty) {
      return ToolOutcome.error('Пустой текст сообщения', code: 'empty_message');
    }
    final who = name.isNotEmpty ? name : phone;
    final uri = Uri.parse(
        'sms:${_cleanPhone(phone)}?body=${Uri.encodeComponent(text)}');
    return ToolOutcome.success(
      'sms_composer_ready',
      {
        'contact': who,
        'phone': phone,
        'note':
            'После твоего ответа откроется SMS с этим текстом, пользователю останется нажать «Отправить»'
      },
      card: ActionCard('SMS', 'SMS → $who', '«$text»'),
      deferred: () => _launch(uri),
    );
  }

  Future<ToolOutcome> _sendWhatsApp(
      String phone, String text, String name) async {
    final resolved = await _resolveByName(phone, name);
    if (resolved == null) {
      return ToolOutcome.error(
        'Для «$name» есть несколько контактов, а номер $phone им не принадлежит. Уточни получателя через find_contact.',
        code: 'ambiguous_contact',
      );
    }
    phone = resolved.$1;
    name = resolved.$2;
    var digits = phone.replaceAll(RegExp(r'\D'), '');
    // Местный формат 8XXXXXXXXXX → международный 7XXXXXXXXXX
    if (digits.length == 11 && digits.startsWith('8')) {
      digits = '7${digits.substring(1)}';
    }
    if (digits.length < 10) {
      return ToolOutcome.error('Некорректный номер для WhatsApp: «$phone»',
          code: 'invalid_phone');
    }
    if (text.isEmpty) {
      return ToolOutcome.error('Пустой текст сообщения', code: 'empty_message');
    }
    final who = name.isNotEmpty ? name : phone;

    final confirmed =
        actions.consumeConfirmedWhatsApp(phone: digits, text: text);
    if (confirmed != null) {
      final uri =
          Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
      return ToolOutcome.success(
        'whatsapp_composer_ready',
        {
          'actionId': confirmed.id,
          'contact': who,
          'phone': phone,
          'note':
              'После твоего ответа откроется чат WhatsApp с этим текстом. Не говори, что сообщение отправлено: пользователю останется нажать «Отправить».',
        },
        card: ActionCard('WHATSAPP', 'WhatsApp → $who', '«$text»'),
        deferred: () => _launch(uri),
      );
    }

    final pending =
        actions.prepareWhatsApp(phone: digits, name: who, text: text);
    return ToolOutcome.success(
      'confirmation_required',
      {
        'actionId': pending.id,
        'contact': who,
        'phone': phone,
        'text': text,
        'expiresAt': pending.expiresAt.toIso8601String(),
        'note':
            'Сообщение ещё не отправлено и чат не открыт. Зачитай получателя и текст, спроси «отправляю?». Повтори send_whatsapp с теми же аргументами только после явного подтверждения пользователя.',
      },
      card: ActionCard('WHATSAPP', 'Подтверди WhatsApp → $who', '«$text»'),
    );
  }

  // ---------------------------------------------------------------- карты

  Future<ToolOutcome> _getLocation() async {
    final pos = await refreshPosition(timeLimit: const Duration(seconds: 8));
    if (pos == null) {
      return ToolOutcome.error(
        'Не удалось определить местоположение (GPS выключен или нет разрешения)',
        code: 'location_unavailable',
      );
    }
    String? address;
    try {
      final marks = await Geocoding(locale: const Locale('ru', 'RU'))
          .placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (marks.isNotEmpty) {
        final m = marks.first;
        address = [m.locality, m.subLocality, m.thoroughfare, m.subThoroughfare]
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .toSet()
            .join(', ');
        if (address.isEmpty) address = null;
      }
    } catch (_) {}
    lastAddress = address;
    return ToolOutcome.success(
      'location_ready',
      {
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy_m': pos.accuracy.round(),
        if (address != null) 'address': address,
      },
      card: ActionCard('LOCATION', address ?? 'Местоположение',
          '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}'),
    );
  }

  Future<ToolOutcome> _navigateTo(String destination,
      {double? lat, double? lng}) async {
    final hasCoords = lat != null && lng != null;
    if (destination.isEmpty && !hasCoords) {
      return ToolOutcome.error('Не указано, куда ехать',
          code: 'invalid_destination');
    }
    final label = destination.isNotEmpty
        ? destination
        : '${lat!.toStringAsFixed(4)}, ${lng!.toStringAsFixed(4)}';
    final canAutoStart = autoStart2Gis && hasCoords;
    final automationEnabled =
        canAutoStart && await androidAutomation.isDgisAutomationEnabled();
    final autoStart = !canAutoStart
        ? 'disabled'
        : automationEnabled
            ? 'armed'
            : 'accessibility_required';
    final note = switch (autoStart) {
      'armed' =>
        'После твоего ответа откроется 2ГИС с маршрутом до «$label». Служба попробует один раз нажать «В путь»; если кнопка не появится, потребуется ручное нажатие.',
      'accessibility_required' =>
        'После твоего ответа откроется 2ГИС с маршрутом до «$label». Автонажатие недоступно, пока не включена служба специальных возможностей Бьянки.',
      _ => 'После твоего ответа откроется 2ГИС с маршрутом до «$label»',
    };

    return ToolOutcome.success(
      'navigation_ready',
      {
        'app': '2ГИС',
        'destination': label,
        if (hasCoords) 'coords': {'lat': lat, 'lng': lng},
        'autoStart': autoStart,
        'note': note,
      },
      card: ActionCard(
        'NAVIGATION',
        '2ГИС → $label',
        hasCoords
            ? '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}'
            : 'Построение маршрута',
      ),
      deferred: () async {
        final armed =
            canAutoStart && await androidAutomation.armDgisAutoStart();
        await _open2GisRoute(destination, lat: lat, lng: lng, autoStart: armed);
      },
    );
  }

  Future<ToolOutcome> _searchNearby(String query,
      {bool openMap = false}) async {
    if (query.isEmpty) {
      return ToolOutcome.error('Не указано, что искать', code: 'invalid_query');
    }
    final pos = lastPosition ??
        await refreshPosition(timeLimit: const Duration(seconds: 6));
    if (pos == null) {
      return ToolOutcome.success(
        'map_search_ready',
        {
          'query': query,
          'places': const [],
          'open_2gis_after_reply': true,
          'note':
              'Координаты GPS недоступны, поэтому после твоего ответа откроется поиск «$query» прямо в 2ГИС',
        },
        card: ActionCard('NAVIGATION', 'Поиск в 2ГИС', query),
        deferred: () => _open2GisSearch(query, null),
      );
    }

    final places =
        await NearbySearch.find(query, lat: pos.latitude, lng: pos.longitude);
    if (places.isEmpty) {
      return ToolOutcome.success(
        'map_search_ready',
        {
          'query': query,
          'places': const [],
          'open_2gis_after_reply': true,
          'note':
              'Точный список рядом не найден, поэтому после твоего ответа сразу откроется поиск «$query» в приложении 2ГИС',
        },
        card: ActionCard('NAVIGATION', 'Поиск в 2ГИС', query),
        deferred: () => _open2GisSearch(query, pos),
      );
    }

    final preview = places
        .take(3)
        .map((p) => '${p['name']} (${p['distance_m']} м)')
        .join(' · ');

    return ToolOutcome.success(
      'nearby_results',
      {
        'query': query,
        'places': places,
        'note': openMap
            ? 'После твоего ответа также откроется 2ГИС с поиском «$query»'
            : 'Назови пользователю 2–3 ближайших места с расстоянием и спроси, куда построить маршрут в 2ГИС (через navigate_to с lat и lng)',
      },
      card: ActionCard('NAVIGATION', 'Рядом: $query', preview),
      deferred: openMap ? () => _open2GisSearch(query, pos) : null,
    );
  }

  Future<void> _open2GisRoute(String destination,
      {double? lat, double? lng, bool autoStart = false}) async {
    final pos = lastPosition;
    // 1. Пробуем открыть маршрут в приложении 2ГИС по координатам (в 2ГИС порядок: долгота,широта)
    if (lat != null && lng != null) {
      final to = '$lng,$lat';
      final routeUri = pos != null
          ? Uri.parse(
              'dgis://2gis.ru/routeSearch/rsType/car/from/${pos.longitude},${pos.latitude}/to/$to')
          : Uri.parse('dgis://2gis.ru/routeSearch/rsType/car/to/$to');
      if (await _launch(routeUri)) return;
    }
    if (autoStart) await androidAutomation.cancelDgisAutoStart();
    // 2. Поиск по названию/адресу в приложении 2ГИС
    if (destination.isNotEmpty) {
      final q = Uri.encodeComponent(destination);
      if (await _launch(Uri.parse('dgis://2gis.ru/search/$q'))) return;
    }
    // 3. Запасной вариант — системный навигатор или веб-версия 2ГИС
    final target = (lat != null && lng != null)
        ? '$lat,$lng'
        : Uri.encodeComponent(destination);
    if (await _launch(Uri.parse('google.navigation:q=$target'))) return;
    await _launch(Uri.parse('https://2gis.kz/search/$target'));
  }

  Future<void> _open2GisSearch(String query, Position? pos) async {
    final q = Uri.encodeComponent(query);
    if (await _launch(Uri.parse('dgis://2gis.ru/search/$q'))) return;
    final center = pos != null ? '${pos.latitude},${pos.longitude}' : '0,0';
    if (await _launch(Uri.parse('geo:$center?q=$q'))) return;
    await _launch(Uri.parse('https://2gis.kz/search/$q'));
  }

  // ---------------------------------------------------------------- часы

  Future<ToolOutcome> _setAlarm(int? hour, int? minute, String label) async {
    if (!Platform.isAndroid) {
      return ToolOutcome.error('Будильник доступен только на Android',
          code: 'unsupported_platform');
    }
    if (hour == null ||
        hour < 0 ||
        hour > 23 ||
        minute == null ||
        minute < 0 ||
        minute > 59) {
      return ToolOutcome.error('Некорректное время будильника',
          code: 'invalid_alarm');
    }
    await AndroidIntent(
      action: 'android.intent.action.SET_ALARM',
      arguments: {
        'android.intent.extra.alarm.HOUR': hour,
        'android.intent.extra.alarm.MINUTES': minute,
        'android.intent.extra.alarm.SKIP_UI': true,
        if (label.isNotEmpty) 'android.intent.extra.alarm.MESSAGE': label,
      },
    ).launch();
    final time =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    return ToolOutcome.success(
      'alarm_set',
      {'alarm': time},
      card: ActionCard('ALARM', 'Будильник на $time', label),
    );
  }

  Future<ToolOutcome> _setTimer(int? seconds, String label) async {
    if (!Platform.isAndroid) {
      return ToolOutcome.error('Таймер доступен только на Android',
          code: 'unsupported_platform');
    }
    if (seconds == null || seconds < 1 || seconds > 86400) {
      return ToolOutcome.error('Некорректная длительность таймера',
          code: 'invalid_timer');
    }
    await AndroidIntent(
      action: 'android.intent.action.SET_TIMER',
      arguments: {
        'android.intent.extra.alarm.LENGTH': seconds,
        'android.intent.extra.alarm.SKIP_UI': true,
        if (label.isNotEmpty) 'android.intent.extra.alarm.MESSAGE': label,
      },
    ).launch();
    return ToolOutcome.success(
      'timer_set',
      {'timer_seconds': seconds},
      card: ActionCard('TIMER', 'Таймер: ${_formatDuration(seconds)}', label),
    );
  }

  // ---------------------------------------------------------------- утилиты

  Future<bool> _launch(Uri uri) => _launcher(uri);

  static Future<bool> _defaultLaunch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _defaultDirectCall(String phone) async {
    final started = await FlutterPhoneDirectCaller.callNumber(phone);
    if (started != true) throw StateError('Direct call was not started');
  }

  static Future<PermissionStatus> _requestPhonePermission() async {
    var status = await Permission.phone.status;
    if (!status.isGranted) status = await Permission.phone.request();
    return status;
  }

  static bool isEmergencyPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return const {'101', '102', '103', '104', '108', '112', '911', '999', '000'}
        .contains(digits);
  }

  static String _str(Object? v) => v == null ? '' : v.toString().trim();

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v?.toString().trim() ?? '');
  }

  static double? _double(Object? v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString().trim() ?? '');
  }

  static String _cleanPhone(String phone) =>
      phone.replaceAll(RegExp(r'[^\d+]'), '');

  static bool _looksLikePhone(String phone) =>
      _cleanPhone(phone).replaceAll('+', '').length >= 3;

  static String _formatDuration(int s) {
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return [if (h > 0) '$h ч', if (m > 0) '$m мин', if (sec > 0) '$sec с']
        .join(' ');
  }
}

/// Нечёткий поиск контактов с учётом русских падежей и уменьшительно-ласкательных форм:
/// «мамуле» → «Мамуля❤️», «мамочке» → «Мамуля❤️» / «Мама», «Сергею» → «Сергей».
class ContactMatcher {
  static const _endings = [
    'ому',
    'ему',
    'ой',
    'ей',
    'ою',
    'ею',
    'ам',
    'ям',
    'ах',
    'ях',
    'ов',
    'ев',
    'ом',
    'ем',
    'у',
    'ю',
    'е',
    'а',
    'я',
    'ы',
    'и',
    'й',
    'ь',
    'о',
  ];

  // Ласкательные суффиксы (от длинных к коротким), чтобы «мамуля», «мамочка» и «мама» давали общий корень «мам».
  static const _diminutives = [
    'улечка',
    'улечке',
    'улечку',
    'улечкой',
    'очка',
    'очке',
    'очку',
    'очкой',
    'ечка',
    'ечке',
    'ечку',
    'ечкой',
    'онька',
    'оньке',
    'оньку',
    'енька',
    'еньке',
    'еньку',
    'ушка',
    'ушке',
    'ушку',
    'юшка',
    'юшке',
    'юшку',
    'уля',
    'уле',
    'улю',
    'улей',
    'уль',
    'уся',
    'усе',
    'усю',
    'усик',
    'ик',
    'ика',
    'ику',
    'ок',
    'ек',
    'ка',
    'ке',
    'ку',
    'кой',
  ];

  // Служебные слова, которые пользователь может произнести при поиске («позвони мамуля сердечко»).
  static const _fillerWords = {
    'контакт',
    'контакты',
    'контакте',
    'номер',
    'телефон',
    'сердечко',
    'сердце',
    'смайлик',
  };

  static String normalize(String s) => s
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Основа слова без падежного окончания («мамуле» → «мамул», «маме» → «мам»).
  static String stem(String word) {
    for (final e in _endings) {
      if (word.endsWith(e) && word.length - e.length >= 2) {
        return word.substring(0, word.length - e.length);
      }
    }
    return word;
  }

  /// Корень без уменьшительно-ласкательных суффиксов («мамуля», «мамочка», «мама» → «мам»).
  static String stemRoot(String word) {
    for (final d in _diminutives) {
      if (word.endsWith(d) && word.length - d.length >= 3) {
        return word.substring(0, word.length - d.length);
      }
    }
    return stem(word);
  }

  /// Возвращает подходящие контакты, отсортированные по точности совпадения.
  static List<T> matchNames<T>(
      String query, List<T> items, String Function(T) nameOf) {
    final q = normalize(query);
    if (q.isEmpty) return [];
    var qWords = q.split(' ');
    final filtered = qWords.where((w) => !_fillerWords.contains(w)).toList();
    if (filtered.isNotEmpty) qWords = filtered;

    final qJoined = qWords.join(' ');
    final qStems = qWords.map(stem).toList();
    final qRoots = qWords.map(stemRoot).toList();

    final scored = <(T, int)>[];
    for (final item in items) {
      final name = normalize(nameOf(item));
      if (name.isEmpty) continue;
      final words = name.split(' ');
      final wStems = words.map(stem).toList();
      final wRoots = words.map(stemRoot).toList();

      int score = 0;
      if (name == qJoined) {
        score = 100;
      } else if (wStems.length == qStems.length &&
          qStems.every(wStems.contains)) {
        // Точное совпадение всех слов в другом падеже («мамуле» → «Мамуля❤️»)
        score = 95;
      } else if (qWords.every(words.contains)) {
        score = 85;
      } else if (qStems.every(wStems.contains)) {
        score = 80;
      } else if (wRoots.length == qRoots.length &&
          qRoots.every(wRoots.contains)) {
        // Однословный контакт с тем же корнем («мамочке» / «маме» → «Мамуля❤️»)
        score = 78;
      } else if (qRoots.every(wRoots.contains)) {
        // Многословный контакт с тем же корнем («мамочке» → «Асылгул Мама Акежа»)
        score = 72;
      } else if (qStems.every((s) => words.any((w) => w.startsWith(s)))) {
        score = 55;
      } else if (qRoots.any(wRoots.contains)) {
        score = 45;
      } else if (name.contains(qJoined)) {
        score = 40;
      }
      if (score > 0) scored.add((item, score));
    }
    if (scored.isEmpty) return [];
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final best = scored.first.$2;
    // Оставляем близкие по качеству совпадения (например, и «Мамуля❤️», и «Асылгул Мама Акежа» для «мама»),
    // но отсекаем далёкие, если есть точное попадание («мамуле» → только «Мамуля❤️»).
    return scored.where((e) => e.$2 >= best - 15).map((e) => e.$1).toList();
  }

  static List<fc.Contact> match(String query, List<fc.Contact> contacts) =>
      matchNames(query, contacts.where((c) => c.phones.isNotEmpty).toList(),
          (c) => c.displayName ?? '');
}

/// Поиск реальных мест поблизости без API-ключей через OpenStreetMap (Nominatim + Overpass fallback).
class NearbySearch {
  static const _userAgent = 'BiancaVoiceAssistant/2.0 (Android; Almaty)';

  static Future<List<Map<String, dynamic>>> find(
    String query, {
    required double lat,
    required double lng,
    int radius = 3000,
    int limit = 5,
    http.Client? client,
  }) async {
    final httpClient = client ?? http.Client();
    try {
      // 1. Быстрый поиск через Nominatim viewbox (~0.8 сек)
      for (final scale in [1.0, 2.0]) {
        try {
          final url = buildNominatimUrl(query, lat, lng,
              radiusMeters: (radius * scale).round());
          final res = await httpClient.get(Uri.parse(url), headers: {
            'User-Agent': _userAgent
          }).timeout(const Duration(seconds: 5));
          if (res.statusCode == 200) {
            final decoded = jsonDecode(utf8.decode(res.bodyBytes));
            if (decoded is List) {
              final places = parseNominatim(decoded, lat, lng, limit: limit);
              if (places.isNotEmpty) return places;
            }
          }
        } catch (_) {}
      }

      // 2. Резервный поиск через Overpass (по bounding box)
      final ql = buildOverpassQuery(query, lat, lng, radius: radius);
      try {
        final res = await httpClient
            .post(
              Uri.parse('https://overpass-api.de/api/interpreter'),
              headers: {
                'User-Agent': _userAgent,
                'Content-Type':
                    'application/x-www-form-urlencoded; charset=utf-8',
              },
              body: 'data=${Uri.encodeQueryComponent(ql)}',
            )
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final data =
              jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
          return parseOverpass(data, lat, lng, limit: limit);
        }
      } catch (_) {}

      return const [];
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Переводит русский запрос категории в специальный тег Nominatim, либо оставляет текст как есть.
  static String nominatimCategory(String query) {
    final q = query.toLowerCase().replaceAll('ё', 'е').trim();
    bool any(List<String> keys) => keys.any(q.contains);

    if (any([
      'кофе',
      'кофейн',
      'кафе',
      'coffee',
      'латте',
      'капучино',
      'эспрессо',
      'пекарн',
      'кондитер'
    ])) {
      return 'cafe';
    }
    if (any([
      'ресторан',
      'поесть',
      'покушать',
      'еда',
      'обед',
      'ужин',
      'завтрак',
      'столов',
      'фастфуд',
      'бургер',
      'пицц',
      'суши',
      'шашлык',
      'лагман',
      'плов',
      'донер',
      'шаурм'
    ])) {
      return 'restaurant';
    }
    if (any(['заправк', 'азс', 'бензин', 'топлив', 'газ'])) return 'fuel';
    if (any(['аптек', 'лекарств'])) return 'pharmacy';
    if (any(['супермаркет', 'магазин', 'продукт', 'маркет'])) {
      return 'supermarket';
    }
    if (any(['банкомат', 'наличн', 'atm'])) return 'atm';
    if (any(['банк'])) return 'bank';
    if (any(['мойк', 'автомойк'])) return 'car wash';
    if (any(['шиномонтаж', 'сто', 'автосервис', 'ремонт авто'])) {
      return 'car repair';
    }
    if (any(['парковк', 'стоянк', 'паркинг'])) return 'parking';
    if (any(['стоматолог'])) return 'dentist';
    if (any(['больниц', 'клиник', 'поликлиник', 'врач', 'медцентр'])) {
      return 'clinic';
    }
    if (any(['отель', 'гостиниц', 'хостел'])) return 'hotel';
    if (any(['парк', 'сквер'])) return 'park';
    if (any(['торговый центр', 'трц', 'молл', 'тц'])) return 'mall';
    return q;
  }

  static String buildNominatimUrl(String query, double lat, double lng,
      {int radiusMeters = 3000}) {
    final term = nominatimCategory(query);
    final dLat = radiusMeters / 111000.0;
    final dLng =
        radiusMeters / (111000.0 * math.cos(_deg2rad(lat)).clamp(0.2, 1.0));
    final west = (lng - dLng).toStringAsFixed(5);
    final north = (lat + dLat).toStringAsFixed(5);
    final east = (lng + dLng).toStringAsFixed(5);
    final south = (lat - dLat).toStringAsFixed(5);
    return 'https://nominatim.openstreetmap.org/search'
        '?format=jsonv2&addressdetails=1'
        '&q=${Uri.encodeQueryComponent(term)}'
        '&viewbox=$west,$north,$east,$south&bounded=1'
        '&limit=20&accept-language=ru';
  }

  static List<Map<String, dynamic>> parseNominatim(
    List<dynamic> items,
    double userLat,
    double userLng, {
    int limit = 5,
  }) {
    final results = <Map<String, dynamic>>[];

    for (final raw in items.whereType<Map>()) {
      final name = (raw['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;

      final elLat = double.tryParse(raw['lat']?.toString() ?? '');
      final elLng = double.tryParse(raw['lon']?.toString() ?? '');
      if (elLat == null || elLng == null) continue;

      final addr = (raw['address'] is Map)
          ? Map<String, dynamic>.from(raw['address'] as Map)
          : const <String, dynamic>{};
      final street = (addr['road'] ??
              addr['pedestrian'] ??
              addr['neighbourhood'] ??
              addr['suburb'] ??
              '')
          .toString()
          .trim();
      final house = (addr['house_number'] ?? '').toString().trim();
      final address = [
        if (street.isNotEmpty) street,
        if (house.isNotEmpty) house
      ].join(', ');

      final distM = distanceMeters(userLat, userLng, elLat, elLng).round();
      results.add({
        'name': name,
        if (address.isNotEmpty) 'address': address,
        'distance_m': distM,
        'lat': double.parse(elLat.toStringAsFixed(6)),
        'lng': double.parse(elLng.toStringAsFixed(6)),
      });
    }

    return _dedupeAndSort(results, limit);
  }

  /// Собирает Overpass QL запрос по квадрату координат (bbox).
  static String buildOverpassQuery(String query, double lat, double lng,
      {int radius = 2500}) {
    final q = query.toLowerCase().replaceAll('ё', 'е').trim();
    final dLat = radius / 111000.0;
    final dLng = radius / (111000.0 * math.cos(_deg2rad(lat)).clamp(0.2, 1.0));
    final bbox =
        '${(lat - dLat).toStringAsFixed(6)},${(lng - dLng).toStringAsFixed(6)},'
        '${(lat + dLat).toStringAsFixed(6)},${(lng + dLng).toStringAsFixed(6)}';
    final clauses = <String>[];

    bool any(List<String> keys) => keys.any(q.contains);

    if (any([
      'кофе',
      'кофейн',
      'кафе',
      'coffee',
      'латте',
      'капучино',
      'эспрессо',
      'пекарн',
      'кондитер'
    ])) {
      clauses.add('nwr["amenity"="cafe"]($bbox);');
      clauses.add('nwr["shop"="coffee"]($bbox);');
    } else if (any([
      'ресторан',
      'поесть',
      'покушать',
      'еда',
      'обед',
      'ужин',
      'завтрак',
      'столов',
      'фастфуд',
      'бургер',
      'пицц',
      'суши',
      'шашлык',
      'лагман',
      'плов',
      'донер',
      'шаурм'
    ])) {
      clauses.add('nwr["amenity"="restaurant"]($bbox);');
      clauses.add('nwr["amenity"="fast_food"]($bbox);');
    } else if (any(
        ['заправк', 'азс', 'бензин', 'топлив', 'газ', 'электрозаправ'])) {
      clauses.add('nwr["amenity"="fuel"]($bbox);');
    } else if (any(['аптек', 'лекарств'])) {
      clauses.add('nwr["amenity"="pharmacy"]($bbox);');
    } else if (any([
      'магазин',
      'супермаркет',
      'продукт',
      'маркет',
      'магнум',
      'magnum',
      'small',
      'смол'
    ])) {
      clauses.add('nwr["shop"="supermarket"]($bbox);');
      clauses.add('nwr["shop"="convenience"]($bbox);');
    } else if (any([
      'банкомат',
      'банк',
      'наличн',
      'деньги',
      'atm',
      'каспи',
      'kaspi',
      'халык',
      'halyk'
    ])) {
      clauses.add('nwr["amenity"="atm"]($bbox);');
      clauses.add('nwr["amenity"="bank"]($bbox);');
    } else if (any([
      'мойк',
      'автомойк',
      'шиномонтаж',
      'сто',
      'автосервис',
      'ремонт авто'
    ])) {
      clauses.add('nwr["amenity"="car_wash"]($bbox);');
      clauses.add('nwr["shop"="car_repair"]($bbox);');
    } else if (any(['парковк', 'стоянк', 'паркинг'])) {
      clauses.add('nwr["amenity"="parking"]($bbox);');
    } else if (any([
      'больниц',
      'клиник',
      'поликлиник',
      'стоматолог',
      'врач',
      'медцентр'
    ])) {
      clauses.add('nwr["amenity"="clinic"]($bbox);');
      clauses.add('nwr["amenity"="dentist"]($bbox);');
    } else if (any(['отель', 'гостиниц', 'хостел'])) {
      clauses.add('nwr["tourism"="hotel"]($bbox);');
    } else if (any(['парк', 'сквер'])) {
      clauses.add('nwr["leisure"="park"]($bbox);');
    } else if (any(['торговый центр', 'трц', 'молл', 'тц'])) {
      clauses.add('nwr["shop"="mall"]($bbox);');
    }

    if (clauses.isEmpty) {
      final escaped = q.replaceAll(RegExp(r'[.*+?^${}()|[\]\\"]'), ' ').trim();
      if (escaped.isNotEmpty) {
        clauses.add('nwr["name"~"$escaped",i]($bbox);');
      }
    }

    return '[out:json][timeout:5];(${clauses.join()});out center tags 40;';
  }

  /// Разбирает ответ Overpass, считает расстояние в метрах и сортирует от ближайших к дальним.
  static List<Map<String, dynamic>> parseOverpass(
    Map<String, dynamic> data,
    double userLat,
    double userLng, {
    int limit = 5,
  }) {
    final elements = (data['elements'] as List? ?? const []).whereType<Map>();
    final results = <Map<String, dynamic>>[];

    for (final el in elements) {
      final tags = (el['tags'] is Map)
          ? Map<String, dynamic>.from(el['tags'] as Map)
          : const <String, dynamic>{};
      final name =
          (tags['name:ru'] ?? tags['name'] ?? tags['brand'] ?? tags['operator'])
                  ?.toString()
                  .trim() ??
              '';
      if (name.isEmpty) continue;

      final center = el['center'] is Map ? el['center'] as Map : null;
      final elLat = (el['lat'] as num?)?.toDouble() ??
          (center?['lat'] as num?)?.toDouble();
      final elLng = (el['lon'] as num?)?.toDouble() ??
          (center?['lon'] as num?)?.toDouble();
      if (elLat == null || elLng == null) continue;

      final distM = distanceMeters(userLat, userLng, elLat, elLng).round();
      final street = tags['addr:street']?.toString().trim();
      final house = tags['addr:housenumber']?.toString().trim();
      final fullAddr = tags['addr:full']?.toString().trim();
      final address = [
        if (street != null && street.isNotEmpty) street,
        if (house != null && house.isNotEmpty) house
      ].join(', ');
      final finalAddress = address.isNotEmpty ? address : (fullAddr ?? '');

      results.add({
        'name': name,
        if (finalAddress.isNotEmpty) 'address': finalAddress,
        'distance_m': distM,
        'lat': double.parse(elLat.toStringAsFixed(6)),
        'lng': double.parse(elLng.toStringAsFixed(6)),
      });
    }

    return _dedupeAndSort(results, limit);
  }

  static List<Map<String, dynamic>> _dedupeAndSort(
      List<Map<String, dynamic>> results, int limit) {
    results.sort(
        (a, b) => (a['distance_m'] as int).compareTo(b['distance_m'] as int));
    final deduped = <Map<String, dynamic>>[];
    for (final item in results) {
      final normName = (item['name'] as String).toLowerCase();
      final duplicate = deduped.any((d) =>
          (d['name'] as String).toLowerCase() == normName &&
          ((item['distance_m'] as int) - (d['distance_m'] as int)).abs() < 80);
      if (!duplicate) {
        deduped.add(item);
        if (deduped.length >= limit) break;
      }
    }
    return deduped;
  }

  /// Расстояние между двумя координатами по формуле гаверсинусов (в метрах).
  static double distanceMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _deg2rad(double deg) => deg * (math.pi / 180.0);
}
