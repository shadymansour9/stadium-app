import 'package:flutter_test/flutter_test.dart';
import 'package:stadium_app/main.dart';

void main() {
  // Sunday 22/11/2026, 18:30. Block: every Sunday (0) 20:00 - 21:00.
  final now = DateTime(2026, 11, 22, 18, 30);
  final block = <String, dynamic>{'id': 'b1', 'stadiumId': 's1', 'dayOfWeek': 0, 'time': '20:00 - 21:00', 'active': true};

  test('next dates include today while the slot is ahead', () {
    final d = nextFixedDates(block, count: 3, now: now).map(fixedDateKey).toList();
    expect(d, ['22/11', '29/11', '6/12']);
    final later = nextFixedDates(block, count: 2, now: DateTime(2026, 11, 22, 20, 30)).map(fixedDateKey).toList();
    expect(later, ['29/11', '6/12']);
  });

  test('a freed date is free only that week', () {
    final b = {...block, 'skipDates': ['29/11']};
    expect(recurringBlockForSlot([b], 's1', '29/11', '20:00 - 21:00'), isFalse);
    expect(recurringBlockForSlot([b], 's1', '6/12', '20:00 - 21:00'), isTrue);
    expect(freedFixedForSlot([b], 's1', '29/11', '20:00 - 21:00')?['id'], 'b1');
    expect(freedFixedForSlot([b], 's1', '6/12', '20:00 - 21:00'), isNull);
  });
}
