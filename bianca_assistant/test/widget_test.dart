import 'package:bianca_assistant/services/device_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ContactMatcher', () {
    const contacts = [
      'Асылгул Мама Акежа',
      'Мамуля❤️',
      'Максим',
      'Сергей Петров',
      'Сергей Работа',
      'Аня',
      'Анна Иванова',
      'Папа',
    ];

    List<String> find(String q) => ContactMatcher.matchNames(q, contacts, (c) => c);

    test('«мамуле» и «Мамуля сердечко» находят именно Мамуля❤️', () {
      expect(find('мамуле'), ['Мамуля❤️']);
      expect(find('Мамуля сердечко'), ['Мамуля❤️']);
    });

    test('«мамочке» и «маме» находят обеих мам (Мамуля❤️ в списке)', () {
      expect(find('мамочке'), ['Мамуля❤️', 'Асылгул Мама Акежа']);
      expect(find('маме'), containsAll(['Мамуля❤️', 'Асылгул Мама Акежа']));
    });

    test('падежи: папе', () {
      expect(find('папе'), ['Папа']);
    });

    test('несколько Сергеев — возвращает всех', () {
      expect(find('Сергею'), containsAll(['Сергей Петров', 'Сергей Работа']));
    });

    test('уточнение по фамилии', () {
      expect(find('Петрову'), ['Сергей Петров']);
    });

    test('Ане → Аня, а не Анна', () {
      expect(find('Ане'), ['Аня']);
    });

    test('ничего не найдено', () {
      expect(find('Борис'), isEmpty);
    });

    test('ё и регистр не мешают', () {
      expect(ContactMatcher.matchNames('артём', ['Артем Ф'], (c) => c), ['Артем Ф']);
    });
  });

  group('NearbySearch', () {
    test('nominatimCategory и buildOverpassQuery распознают кофейню и заправку', () {
      expect(NearbySearch.nominatimCategory('кофейня'), 'cafe');
      expect(NearbySearch.nominatimCategory('заправка'), 'fuel');

      final coffeeQl = NearbySearch.buildOverpassQuery('кофейня', 43.2245, 76.8007);
      expect(coffeeQl, contains('["amenity"="cafe"]'));

      final fuelQl = NearbySearch.buildOverpassQuery('заправка', 43.2245, 76.8007);
      expect(fuelQl, contains('fuel'));
    });

    test('parseNominatim считает расстояние и извлекает адрес', () {
      final items = [
        {
          'name': 'Нур Рай',
          'lat': '43.2213492',
          'lon': '76.8174911',
          'address': {'road': 'улица Байзак батыра', 'suburb': 'Шугыла'},
        },
        {
          'name': 'Ближняя кофейня',
          'lat': '43.2250',
          'lon': '76.8010',
          'address': {'road': 'ул. Жандосова', 'house_number': '58'},
        },
      ];
      final places = NearbySearch.parseNominatim(items, 43.2245, 76.8007);
      expect(places.first['name'], 'Ближняя кофейня');
      expect(places.first['address'], 'ул. Жандосова, 58');
      expect((places.first['distance_m'] as int) < (places.last['distance_m'] as int), isTrue);
    });

    test('parseOverpass сортирует по расстоянию и убирает дубликаты рядом', () {
      final raw = {
        'elements': [
          {
            'type': 'node',
            'lat': 43.2290,
            'lon': 76.8050,
            'tags': {'name': 'Дальняя кофейня', 'addr:street': 'ул. Сатпаева', 'addr:housenumber': '90'},
          },
          {
            'type': 'node',
            'lat': 43.2250,
            'lon': 76.8010,
            'tags': {'name': 'Coffee Boom', 'addr:street': 'ул. Жандосова', 'addr:housenumber': '58'},
          },
          {
            'type': 'way',
            'center': {'lat': 43.2251, 'lon': 76.8011},
            'tags': {'name': 'Coffee Boom'},
          },
        ],
      };

      final places = NearbySearch.parseOverpass(raw, 43.2245, 76.8007);
      expect(places.length, 2);
      expect(places.first['name'], 'Coffee Boom');
      expect(places.first['address'], 'ул. Жандосова, 58');
      expect((places.first['distance_m'] as int) < (places.last['distance_m'] as int), isTrue);
    });
  });
}
