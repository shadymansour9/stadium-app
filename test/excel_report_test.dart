import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stadium_app/excel_report.dart';

void main() {
  final now = DateTime(2026, 11, 22, 12);
  final bookings = <Map<String, dynamic>>[
    {'bookingCode': '6837', 'date': '23/11', 'time': '20:00 - 22:00', 'stadiumName': 'shadystadium', 'userName': 'שאדי מנסור',
     'phone': '0528577112', 'players': ['a', 'b', 'c'], 'price': '₪200/2h', 'payMethod': 'paybox', 'paymentStatus': 'partial', 'paidAmount': 150},
    {'bookingCode': '1200', 'date': '22/11', 'time': '18:00 - 20:00', 'stadiumName': 'shadystadium', 'userName': 'רשא מנסור',
     'phone': '0500000000', 'players': ['x'], 'price': '₪200/2h', 'payMethod': 'cash', 'paymentStatus': 'paid', 'paidAmount': 200},
    {'bookingCode': '4411', 'date': '22/11', 'time': '08:00 - 10:00', 'stadiumName': 'shadystadium', 'userName': 'דני',
     'phone': '', 'players': [], 'price': '₪200/2h', 'payMethod': 'cash', 'paymentStatus': 'unpaid', 'isManual': true},
    {'bookingCode': '9999', 'date': '1/1', 'time': '10:00 - 12:00', 'stadiumName': 'shadystadium', 'userName': 'ישן',
     'price': '₪300/2hr'}, // older booking: no payment tracking; January → next year
  ];

  test('payment helpers', () {
    expect(bookingPayState(bookings[0]), 'partial');
    expect(bookingMissingAmount(bookings[0]), 50);
    expect(bookingPayState(bookings[1]), 'paid');
    expect(bookingPayState(bookings[2]), 'unpaid');
    expect(bookingMissingAmount(bookings[2]), 200);
    expect(bookingPayState(bookings[3]), 'none');
    expect(bookingMissingAmount(bookings[3]), 0);
    expect(bookingPaidAmount({'price': '₪200', 'paymentStatus': 'paid'}), 200); // old "paid" mark
  });

  test('report has title, totals, rows in date order and a day sheet', () {
    final bytes = buildBookingsReport(bookings, hebrew: true, now: now)!;
    final dir = Directory('build/test_reports')..createSync(recursive: true);
    File('${dir.path}/report_he.xlsx').writeAsBytesSync(bytes);
    File('${dir.path}/report_en.xlsx').writeAsBytesSync(buildBookingsReport(bookings, hebrew: false, now: now)!);

    final x = Excel.decodeBytes(bytes);
    final s = x['הזמנות'];
    String v(int c, int r) => s.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).value.toString();
    expect(v(0, 0), contains('דוח הזמנות'));
    expect(v(0, 2), contains('חסר לגבות ₪250'));
    expect(v(1, 4), 'קוד הזמנה');
    // sorted: 22/11 08:00, 22/11 18:00, 23/11, then 1/1/2027
    expect(v(1, 5), '4411');
    expect(v(1, 6), '1200');
    expect(v(1, 7), '6837');
    expect(v(1, 8), '9999');
    expect(v(2, 8), '01/01/2027');
    expect(v(4, 5), '\u200E08:00 - 10:00');
    expect(v(13, 7), 'שולם חלקית');
    expect(v(11, 7), '50');
    expect(v(9, 9), '900'); // total price
    expect(x.tables.keys, contains('סיכום לפי יום'));
  });
}
