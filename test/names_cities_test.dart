import 'package:flutter_test/flutter_test.dart';

import 'package:stadium_app/israel_cities.dart';
import 'package:stadium_app/main.dart';

void main() {
  group('cleanPersonName', () {
    test('a name typed twice is kept once', () {
      expect(cleanPersonName('שפיק נזאר שפיק שחאדה שפיק נזאר שפיק שחאדה'), 'שפיק נזאר שפיק שחאדה');
      expect(cleanPersonName('Dana Dana'), 'Dana');
    });
    test('extra spaces are removed, real names stay', () {
      expect(cleanPersonName('  Dana   Levi '), 'Dana Levi');
      expect(cleanPersonName('Levi Levi Cohen'), 'Levi Levi Cohen');
      expect(cleanPersonName('Dana'), 'Dana');
    });
  });

  group('exactCity', () {
    test('Hebrew or English name from the list', () {
      expect(exactCity('נצרת'), ('נצרת', 'Nazareth'));
      expect(exactCity('  nazareth '), ('נצרת', 'Nazareth'));
    });
    test('free text is not a city', () {
      expect(exactCity('kika nazareth'), isNull);
      expect(exactCity(''), isNull);
    });
  });
}
