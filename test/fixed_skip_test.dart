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

  test('a from-to range on several days closes every slot inside it', () {
    // Sunday + Wednesday 16:00-20:00, until 6/12/2026.
    final b = <String, dynamic>{'id': 's', 'stadiumId': 's1', 'days': [0, 3], 'startTime': '16:00', 'endTime': '20:00',
      'until': '2026-12-06', 'active': true};
    expect(recurringBlockForSlot([b], 's1', '29/11', '16:00 - 17:00'), isTrue);
    expect(recurringBlockForSlot([b], 's1', '29/11', '19:00 - 20:00'), isTrue);
    expect(recurringBlockForSlot([b], 's1', '29/11', '20:00 - 21:00'), isFalse);
    expect(recurringBlockForSlot([b], 's1', '2/12', '18:00 - 20:00'), isTrue);  // Wednesday
    expect(recurringBlockForSlot([b], 's1', '1/12', '18:00 - 19:00'), isFalse); // Tuesday
    expect(recurringBlockForSlot([b], 's1', '9/12', '18:00 - 19:00'), isFalse); // after until
    final dates = nextFixedDates(b, count: 10, now: DateTime(2026, 11, 22, 10)).map(fixedDateKey).toList();
    expect(dates, ['22/11', '25/11', '29/11', '2/12', '6/12']);
  });

  test('clash check sees overlapping hours on a shared day', () {
    final b = <String, dynamic>{'days': [1], 'startTime': '12:00', 'endTime': '14:00', 'active': true};
    expect(fixedClash([b], [1, 4], 13 * 60, 15 * 60), isNotNull);
    expect(fixedClash([b], [1], 14 * 60, 15 * 60), isNull);
    expect(fixedClash([b], [2], 12 * 60, 14 * 60), isNull);
    // an older one-slot block
    expect(fixedClash([{'dayOfWeek': 1, 'time': '23:00 - 00:00'}], [1], 23 * 60 + 30, 24 * 60), isNotNull);
  });
}
