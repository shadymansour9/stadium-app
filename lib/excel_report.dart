import 'package:excel/excel.dart';

// ==================== PAYMENTS (shared by the app and the report) ====================

/// A booking's price, from its text ("₪200/2h" -> 200).
int reportAmount(Map<String, dynamic> b) =>
    int.tryParse((b['price']?.toString() ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

/// Whether this booking tracks payment (bookings from before payments don't).
bool bookingTracksPayment(Map<String, dynamic> b) =>
    b['payMethod'] != null || b['paymentStatus'] != null || b['paidAmount'] != null;

/// What the court admin recorded as received. Older "paid" marks without an
/// amount count as the full price.
int bookingPaidAmount(Map<String, dynamic> b) =>
    (b['paidAmount'] as num?)?.round() ?? (b['paymentStatus'] == 'paid' ? reportAmount(b) : 0);

/// Still owed (0 when paid in full or not tracked).
int bookingMissingAmount(Map<String, dynamic> b) {
  if (!bookingTracksPayment(b)) return 0;
  final m = reportAmount(b) - bookingPaidAmount(b);
  return m > 0 ? m : 0;
}

/// 'paid', 'partial', 'unpaid', or 'none' when payment isn't tracked.
String bookingPayState(Map<String, dynamic> b) {
  if (!bookingTracksPayment(b)) return 'none';
  final paid = bookingPaidAmount(b);
  if (paid >= reportAmount(b) && (paid > 0 || b['paymentStatus'] == 'paid')) return 'paid';
  return paid > 0 ? 'partial' : 'unpaid';
}

/// Start of a booking ("d/m" + "HH:MM - HH:MM"); January seen in December is next year.
DateTime? reportBookingStart(Map<String, dynamic> b, DateTime now) {
  try {
    final d = (b['date'] as String).split('/');
    final t = (b['time'] as String).split('-').first.trim().split(':');
    var start = DateTime(now.year, int.parse(d[1]), int.parse(d[0]), int.parse(t[0]), int.parse(t[1]));
    if (start.isBefore(now.subtract(const Duration(days: 180)))) {
      start = DateTime(now.year + 1, start.month, start.day, start.hour, start.minute);
    }
    return start;
  } catch (_) {
    return null;
  }
}

// ==================== EXCEL REPORT ====================

/// A court's bookings as a tidy Excel file: a title, the period, totals,
/// coloured headers, one row per booking (code, date, booker, phone, price,
/// paid, still owed, payment status) and a second sheet summing each day.
List<int>? buildBookingsReport(List<Map<String, dynamic>> bookings, {required bool hebrew, DateTime? now}) {
  String t(String he, String en) => hebrew ? he : en;
  final at = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  String dmy(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
  const heDays = ['שני', 'שלישי', 'רביעי', 'חמישי', 'שישי', 'שבת', 'ראשון'];
  const enDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String dayName(DateTime d) => hebrew ? heDays[d.weekday - 1] : enDays[d.weekday - 1];

  final rows = [
    for (final b in bookings) (b: b, start: reportBookingStart(b, at)),
  ]..sort((x, y) {
      if (x.start == null && y.start == null) return 0;
      if (x.start == null) return 1;
      if (y.start == null) return -1;
      return x.start!.compareTo(y.start!);
    });

  final ex = Excel.createExcel();
  final sheetName = t('הזמנות', 'Bookings');
  ex.rename(ex.getDefaultSheet() ?? 'Sheet1', sheetName);
  final sheet = ex[sheetName];
  sheet.isRTL = hebrew;

  // ---- colours ----
  final dark = ExcelColor.fromHexString('FF0B5D33');
  final green = ExcelColor.fromHexString('FF13A150');
  final white = ExcelColor.fromHexString('FFFFFFFF');
  final zebra = ExcelColor.fromHexString('FFF2F7F4');
  final grey = ExcelColor.fromHexString('FF5B6270');
  final thin = Border(borderStyle: BorderStyle.Thin, borderColorHex: ExcelColor.fromHexString('FFD5DBD8'));

  CellStyle cell({bool bold = false, ExcelColor? bg, ExcelColor? fg, int size = 11, HorizontalAlign align = HorizontalAlign.Center}) => CellStyle(
    bold: bold,
    fontSize: size,
    fontColorHex: fg ?? ExcelColor.fromHexString('FF1B1D21'),
    backgroundColorHex: bg ?? ExcelColor.none,
    horizontalAlign: align,
    verticalAlign: VerticalAlign.Center,
    leftBorder: thin, rightBorder: thin, topBorder: thin, bottomBorder: thin,
  );

  final headers = [
    '#', t('קוד הזמנה', 'Code'), t('תאריך', 'Date'), t('יום', 'Day'), t('שעה', 'Time'), t('מגרש', 'Court'),
    t('שם המזמין', 'Booked by'), t('טלפון', 'Phone'), t('שחקנים', 'Players'), t('מחיר ₪', 'Price ₪'),
    t('שולם ₪', 'Paid ₪'), t('חסר ₪', 'Owed ₪'), t('אמצעי תשלום', 'Pay method'), t('סטטוס תשלום', 'Payment'),
    t('מקור', 'Source'),
  ];
  const widths = [5.0, 11.0, 12.0, 9.0, 15.0, 18.0, 22.0, 14.0, 9.0, 10.0, 10.0, 10.0, 14.0, 14.0, 12.0];
  for (var c = 0; c < widths.length; c++) {
    sheet.setColumnWidth(c, widths[c]);
  }
  final last = headers.length - 1;

  // ---- totals ----
  var total = 0, paid = 0, owed = 0, players = 0;
  for (final r in rows) {
    total += reportAmount(r.b);
    paid += bookingPaidAmount(r.b);
    owed += bookingMissingAmount(r.b);
    players += ((r.b['players'] as List?) ?? const []).length;
  }
  final courts = {for (final r in rows) (r.b['stadiumName'] ?? '').toString()}..remove('');
  final dated = rows.where((r) => r.start != null).toList();
  final period = dated.isEmpty ? '' : '${dmy(dated.first.start!)} – ${dmy(dated.last.start!)}';

  void merged(int row, String text, CellStyle style, {double height = 22}) {
    sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row), CellIndex.indexByColumnRow(columnIndex: last, rowIndex: row),
        customValue: TextCellValue(text));
    for (var c = 0; c <= last; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = style;
    }
    sheet.setRowHeight(row, height);
  }

  final titleStyle = CellStyle(bold: true, fontSize: 16, fontColorHex: white, backgroundColorHex: dark,
      horizontalAlign: HorizontalAlign.Center, verticalAlign: VerticalAlign.Center);
  final subStyle = CellStyle(fontSize: 11, fontColorHex: grey, horizontalAlign: HorizontalAlign.Center, verticalAlign: VerticalAlign.Center);
  final sumStyle = CellStyle(bold: true, fontSize: 12, fontColorHex: dark, backgroundColorHex: ExcelColor.fromHexString('FFE3F3EA'),
      horizontalAlign: HorizontalAlign.Center, verticalAlign: VerticalAlign.Center);

  merged(0, '${t('דוח הזמנות', 'Bookings report')}${courts.isEmpty ? '' : ' · ${courts.join(', ')}'}', titleStyle, height: 30);
  merged(1, [if (period.isNotEmpty) period, '${t('הופק', 'Created')} ${dmy(at)} ${two(at.hour)}:${two(at.minute)}'].join('   ·   '), subStyle);
  merged(2, [
    '${rows.length} ${t('הזמנות', 'bookings')}',
    '${t('סה״כ', 'Total')} ₪$total',
    '${t('שולם', 'Paid')} ₪$paid',
    '${t('חסר לגבות', 'Owed')} ₪$owed',
  ].join('   ·   '), sumStyle, height: 24);

  // ---- header row ----
  const headerRow = 4;
  final headerStyle = cell(bold: true, bg: green, fg: white, size: 12);
  for (var c = 0; c <= last; c++) {
    final ci = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: headerRow));
    ci.value = TextCellValue(headers[c]);
    ci.cellStyle = headerStyle;
  }
  sheet.setRowHeight(headerRow, 24);

  // ---- bookings ----
  final stateText = {
    'paid': t('שולם', 'Paid'), 'partial': t('שולם חלקית', 'Part paid'),
    'unpaid': t('לא שולם', 'Unpaid'), 'none': '—',
  };
  final stateColors = {
    'paid': (ExcelColor.fromHexString('FFD3F2DE'), ExcelColor.fromHexString('FF0A7D2C')),
    'partial': (ExcelColor.fromHexString('FFFFEBCC'), ExcelColor.fromHexString('FFA35A00')),
    'unpaid': (ExcelColor.fromHexString('FFFADADA'), ExcelColor.fromHexString('FFB3261E')),
  };
  for (var i = 0; i < rows.length; i++) {
    final b = rows[i].b;
    final s = rows[i].start;
    final row = headerRow + 1 + i;
    final bg = i.isOdd ? zebra : null;
    final state = bookingPayState(b);
    final method = b['payMethod'] == 'paybox' ? 'PayBox' : b['payMethod'] == 'cash' ? t('מזומן', 'Cash') : '—';
    final values = <CellValue>[
      IntCellValue(i + 1),
      TextCellValue((b['bookingCode'] ?? '').toString()),
      TextCellValue(s == null ? (b['date'] ?? '').toString() : dmy(s)),
      TextCellValue(s == null ? (b['day'] ?? '').toString() : dayName(s)),
      // A left-to-right mark keeps "08:00 - 10:00" in order inside a right-to-left sheet.
      TextCellValue('\u200E${(b['time'] ?? '').toString()}'),
      TextCellValue((b['stadiumName'] ?? '').toString()),
      TextCellValue((b['userName'] ?? '').toString()),
      TextCellValue((b['phone'] ?? '').toString()),
      IntCellValue(((b['players'] as List?) ?? const []).length),
      IntCellValue(reportAmount(b)),
      IntCellValue(bookingPaidAmount(b)),
      IntCellValue(bookingMissingAmount(b)),
      TextCellValue(method),
      TextCellValue(stateText[state]!),
      TextCellValue(b['isManual'] == true ? t('נרשם ע״י המגרש', 'Added by court') : t('אפליקציה', 'App')),
    ];
    for (var c = 0; c <= last; c++) {
      final ci = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
      ci.value = values[c];
      if (c == 13 && stateColors[state] != null) {
        ci.cellStyle = cell(bold: true, bg: stateColors[state]!.$1, fg: stateColors[state]!.$2);
      } else if (c == 11 && bookingMissingAmount(b) > 0) {
        ci.cellStyle = cell(bold: true, bg: bg, fg: ExcelColor.fromHexString('FFB3261E'));
      } else if (c == 9 || c == 10) {
        ci.cellStyle = cell(bold: true, bg: bg, fg: ExcelColor.fromHexString('FF0A7D2C'));
      } else {
        ci.cellStyle = cell(bg: bg, align: c == 6 ? HorizontalAlign.Right : HorizontalAlign.Center);
      }
    }
  }

  // ---- total row ----
  final totalRow = headerRow + 1 + rows.length;
  final totalStyle = cell(bold: true, bg: dark, fg: white, size: 12);
  final totals = <int, CellValue>{
    0: TextCellValue(t('סה״כ', 'Total')),
    8: IntCellValue(players), 9: IntCellValue(total), 10: IntCellValue(paid), 11: IntCellValue(owed),
  };
  for (var c = 0; c <= last; c++) {
    final ci = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: totalRow));
    ci.value = totals[c] ?? TextCellValue('');
    ci.cellStyle = totalStyle;
  }
  sheet.setRowHeight(totalRow, 24);

  // ---- second sheet: one line per day ----
  final daySheet = ex[t('סיכום לפי יום', 'By day')];
  daySheet.isRTL = hebrew;
  final dayHeaders = [t('תאריך', 'Date'), t('יום', 'Day'), t('הזמנות', 'Bookings'), t('שחקנים', 'Players'),
    t('סה״כ ₪', 'Total ₪'), t('שולם ₪', 'Paid ₪'), t('חסר ₪', 'Owed ₪')];
  const dayWidths = [12.0, 9.0, 10.0, 10.0, 11.0, 11.0, 11.0];
  for (var c = 0; c < dayWidths.length; c++) {
    daySheet.setColumnWidth(c, dayWidths[c]);
  }
  for (var c = 0; c < dayHeaders.length; c++) {
    final ci = daySheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
    ci.value = TextCellValue(dayHeaders[c]);
    ci.cellStyle = headerStyle;
  }
  final byDay = <DateTime, List<Map<String, dynamic>>>{};
  for (final r in dated) {
    byDay.putIfAbsent(DateTime(r.start!.year, r.start!.month, r.start!.day), () => []).add(r.b);
  }
  var dr = 1;
  for (final e in byDay.entries) {
    final list = e.value;
    final vals = <CellValue>[
      TextCellValue(dmy(e.key)), TextCellValue(dayName(e.key)), IntCellValue(list.length),
      IntCellValue(list.fold<int>(0, (s, b) => s + ((b['players'] as List?) ?? const []).length)),
      IntCellValue(list.fold<int>(0, (s, b) => s + reportAmount(b))),
      IntCellValue(list.fold<int>(0, (s, b) => s + bookingPaidAmount(b))),
      IntCellValue(list.fold<int>(0, (s, b) => s + bookingMissingAmount(b))),
    ];
    for (var c = 0; c < vals.length; c++) {
      final ci = daySheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: dr));
      ci.value = vals[c];
      ci.cellStyle = cell(bg: dr.isEven ? zebra : null, bold: c >= 4,
          fg: c == 6 && (vals[c] as IntCellValue).value > 0 ? ExcelColor.fromHexString('FFB3261E') : null);
    }
    dr++;
  }
  final dayTotals = <CellValue>[TextCellValue(t('סה״כ', 'Total')), TextCellValue(''), IntCellValue(rows.length),
    IntCellValue(players), IntCellValue(total), IntCellValue(paid), IntCellValue(owed)];
  for (var c = 0; c < dayTotals.length; c++) {
    final ci = daySheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: dr));
    ci.value = dayTotals[c];
    ci.cellStyle = totalStyle;
  }

  ex.setDefaultSheet(sheetName);
  final bytes = ex.save();
  if (bytes == null || !hebrew) return bytes;
  // The excel package writes right-to-left only for sheets already in the
  // file, so the saved workbook is opened once more to set it.
  final again = Excel.decodeBytes(bytes);
  for (final name in again.tables.keys) {
    again[name].isRTL = true;
  }
  return again.save();
}
