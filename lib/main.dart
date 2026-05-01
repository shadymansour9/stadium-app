import 'dart:async';
import 'dart:convert' show base64Decode, base64Encode;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'export_stub.dart' if (dart.library.html) 'export_web.dart';

// ==================== LANGUAGE ====================
bool isHebrew = true;
String tr(String he, String en) => isHebrew ? he : en;

// ==================== CONFIG ====================
const String superAdminEmail    = 'admin@gmail.com';
const String md9AdminEmail      = 'admin.md9@gmail.com';
const String yStadiumAdminEmail = 'admin.ystadium@gmail.com';

const List<Map<String, dynamic>> allStadiums = [
  {'id': 'md9_main',  'name': 'MD9 MAIN',  'type': 'Football', 'price': 300, 'location': 'נצרת', 'admin': md9AdminEmail},
  {'id': 'md9_2',     'name': 'MD9 2',     'type': 'Football', 'price': 300, 'location': 'נצרת', 'admin': md9AdminEmail},
  {'id': 'y_stadium', 'name': 'Y STADIUM', 'type': 'Football', 'price': 300, 'location': 'נצרת', 'admin': yStadiumAdminEmail},
];

final List<Map<String, dynamic>> venues = [
  {
    'id': 'md9', 'name': 'MD9', 'nameEn': 'MD9',
    'region': 'נצרת', 'regionEn': 'Nazareth',
    'description': 'מרכז כדורגל מקצועי בנצרת', 'descriptionEn': 'Professional football center in Nazareth',
    'color': 'green', 'stadiumIds': ['md9_main', 'md9_2'], 'hasTraining': true,
  },
  {
    'id': 'y_stadium', 'name': 'Y STADIUM', 'nameEn': 'Y STADIUM',
    'region': 'נצרת', 'regionEn': 'Nazareth',
    'description': 'אצטדיון כדורגל מקצועי בנצרת', 'descriptionEn': 'Professional football stadium in Nazareth',
    'color': 'blue', 'stadiumIds': ['y_stadium'], 'hasTraining': false,
  },
];

Map<String, dynamic>? venueForStadium(String stadiumId) {
  for (final v in venues) {
    if ((v['stadiumIds'] as List).contains(stadiumId)) return v;
  }
  return null;
}

Map<String, dynamic>? venueById(String id) {
  try { return venues.firstWhere((v) => v['id'] == id); } catch (_) { return null; }
}

Color _colorForVenue(String? color) {
  switch (color) {
    case 'blue':   return Colors.blue;
    case 'purple': return Colors.purple;
    case 'orange': return Colors.orange;
    default:       return accentGreen;
  }
}

int _weekdayFromDateString(String date) {
  final parts = date.split('/');
  final now = DateTime.now();
  final d = DateTime(now.year, int.parse(parts[1]), int.parse(parts[0]));
  return d.weekday % 7; // 0=Sun … 6=Sat
}

int _minutesOf(String hhmm) {
  final p = hhmm.split(':');
  return int.parse(p[0]) * 60 + int.parse(p[1]);
}

bool trainingOverlapForSlot(List<Map<String, dynamic>> groups, String stadiumId, String dateStr, String slotLabel) {
  final wd = _weekdayFromDateString(dateStr);
  final parts = slotLabel.split(' - ');
  if (parts.length < 2) return false;
  final sMin = _minutesOf(parts[0].trim());
  final eMin = _minutesOf(parts[1].trim());
  for (final g in groups) {
    if ((g['stadiumId'] ?? '') != stadiumId) continue;
    final days = (g['days'] as List? ?? []);
    if (!days.contains(wd)) continue;
    final gStart = _minutesOf(g['startTime'] as String? ?? '00:00');
    final gEnd   = _minutesOf(g['endTime']   as String? ?? '00:00');
    if (sMin < gEnd && eMin > gStart) return true;
  }
  return false;
}

String? trainingNameForSlot(List<Map<String, dynamic>> groups, String stadiumId, String dateStr, String slotLabel) {
  final wd = _weekdayFromDateString(dateStr);
  final parts = slotLabel.split(' - ');
  if (parts.length < 2) return null;
  final sMin = _minutesOf(parts[0].trim());
  final eMin = _minutesOf(parts[1].trim());
  for (final g in groups) {
    if ((g['stadiumId'] ?? '') != stadiumId) continue;
    final days = (g['days'] as List? ?? []);
    if (!days.contains(wd)) continue;
    final gStart = _minutesOf(g['startTime'] as String? ?? '00:00');
    final gEnd   = _minutesOf(g['endTime']   as String? ?? '00:00');
    if (sMin < gEnd && eMin > gStart) return g['name'] as String? ?? tr('אימון', 'Training');
  }
  return null;
}

// ----- Recurring weekly blocks (admin-defined fixed reservations) -----
// Convention used in this app:
//   - dayOfWeek 0=Sun … 6=Sat (matches _weekdayFromDateString output).
//   - time field can be either a slot label "HH:mm - HH:mm" (exact match)
//     or "startTime"/"endTime" pair for time-range overlap checking.

bool recurringBlockForSlot(List<Map<String, dynamic>> blocks, String stadiumId, String dateStr, String slotLabel) {
  final wd = _weekdayFromDateString(dateStr);
  for (final b in blocks) {
    if ((b['active'] ?? true) != true) continue;
    if ((b['stadiumId'] ?? '') != stadiumId) continue;
    if ((b['dayOfWeek'] as int?) != wd) continue;
    if ((b['time'] as String?) == slotLabel) return true;
  }
  return false;
}

String? recurringReasonForSlot(List<Map<String, dynamic>> blocks, String stadiumId, String dateStr, String slotLabel) {
  final wd = _weekdayFromDateString(dateStr);
  for (final b in blocks) {
    if ((b['active'] ?? true) != true) continue;
    if ((b['stadiumId'] ?? '') != stadiumId) continue;
    if ((b['dayOfWeek'] as int?) != wd) continue;
    if ((b['time'] as String?) == slotLabel) {
      return (b['reason'] as String?) ?? tr('קבוע', 'FIXED');
    }
  }
  return null;
}

String? recurringIdForSlot(List<Map<String, dynamic>> blocks, String stadiumId, String dateStr, String slotLabel) {
  final wd = _weekdayFromDateString(dateStr);
  for (final b in blocks) {
    if ((b['active'] ?? true) != true) continue;
    if ((b['stadiumId'] ?? '') != stadiumId) continue;
    if ((b['dayOfWeek'] as int?) != wd) continue;
    if ((b['time'] as String?) == slotLabel) return b['id'] as String?;
  }
  return null;
}

// Default booking types (used if none defined in Firestore)
final List<Map<String, dynamic>> defaultBookingTypes = [
  {'name': 'כדורגל',      'nameEn': 'Football',   'icon': 'soccer',      'price': 300, 'color': 'green'},
  {'name': 'יום הולדת',   'nameEn': 'Birthday',   'icon': 'cake',        'price': 500, 'color': 'pink'},
  {'name': 'אירוע',       'nameEn': 'Event',      'icon': 'celebration', 'price': 600, 'color': 'purple'},
  {'name': 'אימון קבוצתי','nameEn': 'Training',   'icon': 'groups',      'price': 400, 'color': 'blue'},
];

final List<String> trainingDayNames   = ['ראשון','שני','שלישי','רביעי','חמישי','שישי','שבת'];
final List<String> trainingDayNamesEn = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];

IconData _iconForType(String? icon) {
  switch (icon) {
    case 'cake':        return Icons.cake;
    case 'celebration': return Icons.celebration;
    case 'groups':      return Icons.groups;
    case 'party':       return Icons.emoji_events;
    default:            return Icons.sports_soccer;
  }
}

Color _colorForType(String? color) {
  switch (color) {
    case 'pink':   return Colors.pink;
    case 'purple': return Colors.purple;
    case 'blue':   return Colors.blue;
    case 'orange': return Colors.orange;
    default:       return accentGreen;
  }
}
final List<Map<String, String>> defaultSlots = [
  {'start': '08:00', 'end': '10:00'},
  {'start': '10:00', 'end': '12:00'},
  {'start': '12:00', 'end': '14:00'},
  {'start': '14:00', 'end': '16:00'},
  {'start': '16:00', 'end': '18:00'},
  {'start': '18:00', 'end': '20:00'},
  {'start': '20:00', 'end': '22:00'},
  {'start': '22:00', 'end': '00:00'},
];

final List<String> allStartTimes = [
  '08:00','08:30','09:00','09:30','10:00','10:30','11:00','11:30',
  '12:00','12:30','13:00','13:30','14:00','14:30','15:00','15:30',
  '16:00','16:30','17:00','17:30','18:00','18:30','19:00','19:30',
  '20:00','20:30','21:00','21:30','22:00','22:30','23:00','23:30',
];

String _addTwoHours(String start) {
  final parts = start.split(':');
  int h = int.parse(parts[0]) + 2;
  if (h >= 24) h -= 24;
  return '${h.toString().padLeft(2,'0')}:${parts[1]}';
}

String _slotLabel(Map<String, String> slot) => '${slot['start']} - ${slot['end']}';

// ==================== NAVIGATION HELPERS ====================
/// Push a screen with a fast (200ms) fade transition.
/// Drop-in replacement for `navigateTo(context, page)`.
Future<T?> navigateTo<T>(BuildContext context, Widget page) {
  return Navigator.push<T>(
    context,
    PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    ),
  );
}

// ==================== AUTH HELPERS ====================
Future<void> _signOut([BuildContext? context]) async {
  await FirebaseAuth.instance.signOut();
  // After login uses pushReplacement to admin/venue screens, the auth-gate
  // StreamBuilder is no longer in the widget tree, so it can't route us back
  // to LoginScreen on signOut. Navigate explicitly when a context is provided.
  if (context != null && context.mounted) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }
}

// ====================================================
// DESIGN SYSTEM - STADIUM v1.0
// ====================================================

// Colors
const Color bgColor         = Color(0xFF000000);
const Color bgSecondary     = Color(0xFF0F0F0F);
const Color cardColor       = Color(0xFF1A1A1A);
const Color borderColor     = Color(0xFF2A2A2A);
const Color borderActive    = Color(0xFF3A3A3A);

const Color accentGreen     = Color(0xFF00C853);
const Color accentGreenSoft = Color(0x3300C853);

const Color textPrimary     = Color(0xFFFFFFFF);
const Color textSecondary   = Color(0xFF9E9E9E);
const Color textTertiary    = Color(0xFF616161);

const Color colorError      = Color(0xFFF44336);
const Color colorWarning    = Color(0xFFFF9800);
const Color colorInfo       = Color(0xFF2196F3);

// Spacing
const double spaceMicro = 4;
const double spaceXs    = 8;
const double spaceSm    = 12;
const double spaceMd    = 16;
const double spaceLg    = 24;
const double spaceXl    = 32;

// Border Radius
const double radiusXs   = 6;
const double radiusSm   = 8;
const double radiusMd   = 10;
const double radiusLg   = 12;
const double radiusXl   = 14;

// ====================================================
// HELPER WIDGETS - DESIGN SYSTEM
// ====================================================

String hebrewWeekday(int weekday, bool isHebrew) {
  if (isHebrew) {
    const days = ['ב\'', 'ג\'', 'ד\'', 'ה\'', 'ו\'', 'ש\'', 'א\''];
    return days[weekday - 1];
  } else {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[weekday - 1];
  }
}

Widget appPrimaryButton({
  required String label,
  required VoidCallback? onPressed,
  IconData? icon,
}) {
  return SizedBox(
    width: double.infinity,
    height: 52,
    child: ElevatedButton.icon(
      onPressed: onPressed,
      icon: icon != null ? Icon(icon, size: 20) : const SizedBox.shrink(),
      label: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: accentGreen,
        foregroundColor: bgColor,
        disabledBackgroundColor: borderColor,
        disabledForegroundColor: textTertiary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLg)),
        elevation: 0,
      ),
    ),
  );
}

Widget appToolButton({
  required IconData icon,
  required String label,
  VoidCallback? onTap,
}) {
  final enabled = onTap != null;
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(radiusLg),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(radiusLg),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: enabled ? accentGreen : textTertiary, size: 22),
          const SizedBox(height: spaceXs),
          Text(
            label,
            style: TextStyle(
              color: enabled ? textPrimary : textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}

Widget appStatCell(String value, String label, {Color? valueColor}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value,
        style: TextStyle(
          color: valueColor ?? accentGreen,
          fontSize: 28,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: spaceMicro),
      Text(
        label,
        style: const TextStyle(
          color: textSecondary,
          fontSize: 10,
          letterSpacing: 2,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

Widget appCard({required Widget child, EdgeInsets? padding}) {
  return Container(
    padding: padding ?? const EdgeInsets.all(spaceMd),
    decoration: BoxDecoration(
      color: cardColor,
      borderRadius: BorderRadius.circular(radiusXl),
      border: Border.all(color: borderColor),
    ),
    child: child,
  );
}

Widget appBadge(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(radiusXs),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1,
      ),
    ),
  );
}

// ====================================================
// SECONDARY BUTTON (outlined green)
// ====================================================
Widget appSecondaryButton({
  required String label,
  required VoidCallback? onPressed,
  IconData? icon,
}) {
  return SizedBox(
    width: double.infinity,
    height: 48,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon != null ? Icon(icon, size: 18, color: accentGreen) : const SizedBox.shrink(),
      label: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.5, color: accentGreen),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: accentGreen, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLg)),
        backgroundColor: cardColor,
      ),
    ),
  );
}

// ====================================================
// TERTIARY BUTTON (subtle, gray border)
// ====================================================
Widget appTertiaryButton({
  required String label,
  required VoidCallback? onPressed,
  IconData? icon,
}) {
  return SizedBox(
    width: double.infinity,
    height: 44,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon != null ? Icon(icon, size: 16, color: textSecondary) : const SizedBox.shrink(),
      label: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: textPrimary),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: borderColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
        backgroundColor: bgSecondary,
      ),
    ),
  );
}

// ====================================================
// INPUT FIELD (text input with icon)
// ====================================================
Widget appTextField({
  required TextEditingController controller,
  required String label,
  String? hint,
  IconData? icon,
  bool obscure = false,
  TextInputType keyboardType = TextInputType.text,
  String? Function(String?)? validator,
  VoidCallback? onTap,
  bool readOnly = false,
}) {
  return TextFormField(
    controller: controller,
    obscureText: obscure,
    keyboardType: keyboardType,
    validator: validator,
    onTap: onTap,
    readOnly: readOnly,
    style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon != null ? Icon(icon, color: textSecondary, size: 20) : null,
      labelStyle: const TextStyle(color: textSecondary, fontSize: 13),
      hintStyle: const TextStyle(color: textTertiary, fontSize: 13),
      filled: true,
      fillColor: cardColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: accentGreen, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: colorError),
      ),
    ),
  );
}

// ====================================================
// SCREEN HEADER (page title with back button)
// ====================================================
Widget appScreenHeader(BuildContext context, String title, {String? subtitle, List<Widget>? actions}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: spaceMd, vertical: spaceMd),
    decoration: const BoxDecoration(
      color: bgColor,
      border: Border(bottom: BorderSide(color: borderColor)),
    ),
    child: Row(children: [
      IconButton(
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.arrow_back, color: textPrimary, size: 22),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
      const SizedBox(width: spaceSm),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w800)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ],
        ),
      ),
      if (actions != null) ...actions,
    ]),
  );
}

// ====================================================
// SECTION TITLE (section header with optional action)
// ====================================================
Widget appSectionTitle(String title, {String? action, VoidCallback? onActionTap}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: spaceXs, vertical: spaceSm),
    child: Row(children: [
      Expanded(
        child: Text(title, style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
      ),
      if (action != null)
        TextButton(
          onPressed: onActionTap,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(50, 24)),
          child: Text(action, style: const TextStyle(color: accentGreen, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
    ]),
  );
}

// ====================================================
// EMPTY STATE (when nothing to show)
// ====================================================
Widget appEmptyState({required IconData icon, required String title, String? subtitle, Widget? action}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(spaceXl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(36),
              border: Border.all(color: borderColor),
            ),
            child: Icon(icon, color: textSecondary, size: 32),
          ),
          const SizedBox(height: spaceMd),
          Text(title, style: const TextStyle(color: textPrimary, fontSize: 16, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          if (subtitle != null) ...[
            const SizedBox(height: spaceXs),
            Text(subtitle, style: const TextStyle(color: textSecondary, fontSize: 13), textAlign: TextAlign.center),
          ],
          if (action != null) ...[
            const SizedBox(height: spaceLg),
            action,
          ],
        ],
      ),
    ),
  );
}

// ====================================================
// LIST TILE (list item, professional style)
// ====================================================
Widget appListTile({
  required IconData icon,
  required String title,
  String? subtitle,
  Widget? trailing,
  VoidCallback? onTap,
  Color? iconColor,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(radiusLg),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: spaceMd, vertical: spaceSm + 2),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(radiusLg),
        border: Border.all(color: borderColor),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: (iconColor ?? accentGreen).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor ?? accentGreen, size: 20),
        ),
        const SizedBox(width: spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing,
      ]),
    ),
  );
}

// ====================================================
// CHIP (small filter/tag chip)
// ====================================================
Widget appChip(String label, {bool active = false, VoidCallback? onTap, IconData? icon}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(radiusXs),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: active ? accentGreen : cardColor,
        borderRadius: BorderRadius.circular(radiusXs),
        border: Border.all(color: active ? accentGreen : borderColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: active ? bgColor : textSecondary),
          const SizedBox(width: 5),
        ],
        Text(
          label,
          style: TextStyle(
            color: active ? bgColor : textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ]),
    ),
  );
}

// ====================================================
// LOADING STATE
// ====================================================
Widget appLoading({String? message}) {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: accentGreen, strokeWidth: 2.5),
        if (message != null) ...[
          const SizedBox(height: spaceMd),
          Text(message, style: const TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ],
    ),
  );
}

// ==================== EXCEL EXPORT ====================
Future<void> exportToCSV(BuildContext context, List<Map<String,dynamic>> bookings, String filename) async {
  final ex = Excel.createExcel();
  final sheet = ex['הזמנות'];
  ex.delete('Sheet1');

  // ----- Column widths (per Excel "characters" unit) -----
  // Set BEFORE writing rows so the file's columnInfo block is consistent.
  sheet.setColumnWidth(0, 20); // Name
  sheet.setColumnWidth(1, 15); // Phone
  sheet.setColumnWidth(2, 15); // Stadium
  sheet.setColumnWidth(3, 8);  // Day
  sheet.setColumnWidth(4, 12); // Date
  sheet.setColumnWidth(5, 15); // Time
  sheet.setColumnWidth(6, 10); // Price
  sheet.setColumnWidth(7, 8);  // Code
  sheet.setColumnWidth(8, 8);  // Count
  sheet.setColumnWidth(9, 30); // Players

  // ----- Header styles (excel ^4.0.6 wants hex WITHOUT a leading '#') -----
  final headerStyle = CellStyle(
    bold: true,
    fontSize: 12,
    fontColorHex: ExcelColor.fromHexString('FFFFFF'),
    backgroundColorHex: ExcelColor.fromHexString('00C853'),
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );

  final headers = [
    tr('שם מארגן',     'Organizer'),
    tr('טלפון',        'Phone'),
    tr('מגרש',         'Stadium'),
    tr('יום',          'Day'),
    tr('תאריך',        'Date'),
    tr('שעה',          'Time'),
    tr('מחיר',         'Price'),
    tr('קוד',          'Code'),
    tr('שחקנים',       'Count'),
    tr('שמות שחקנים', 'Players'),
  ];
  sheet.appendRow(headers.map((h) => TextCellValue(h)).toList());
  for (var c = 0; c < headers.length; c++) {
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).cellStyle = headerStyle;
  }

  // ----- Helpers -----
  int parsePriceInt(String? raw) =>
      int.tryParse((raw ?? '').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  DateTime? parseDate(Map<String, dynamic> b) {
    try {
      final d = (b['date'] as String).split('/');
      final t = (b['time'] as String? ?? '').split(' - ').first.trim().split(':');
      final now = DateTime.now();
      return DateTime(now.year, int.parse(d[1]), int.parse(d[0]),
        int.parse(t[0]), t.length > 1 ? int.parse(t[1]) : 0);
    } catch (_) { return null; }
  }

  final sorted = [...bookings];
  sorted.sort((a, b) {
    final da = parseDate(a);
    final db = parseDate(b);
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return da.compareTo(db);
  });

  // ----- Data styles -----
  final dataStyle = CellStyle(
    fontSize: 11,
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );
  final priceStyle = CellStyle(
    fontSize: 11,
    bold: true,
    fontColorHex: ExcelColor.fromHexString('0A7D2C'),
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );

  int totalRevenue = 0;
  int totalPlayers = 0;
  for (var i = 0; i < sorted.length; i++) {
    final b = sorted[i];
    final players = (b['players'] as List?) ?? [];
    final price = parsePriceInt(b['price'] as String?);
    totalRevenue += price;
    totalPlayers += players.length;

    sheet.appendRow(<CellValue>[
      TextCellValue((b['userName']    ?? '').toString()),
      TextCellValue((b['phone']       ?? '').toString()),
      TextCellValue((b['stadiumName'] ?? '').toString()),
      TextCellValue((b['day']         ?? '').toString()),
      TextCellValue((b['date']        ?? '').toString()),
      TextCellValue((b['time']        ?? '').toString()),
      IntCellValue(price),
      TextCellValue((b['bookingCode'] ?? '').toString()),
      IntCellValue(players.length),
      TextCellValue(players.join(', ')),
    ]);
    final rowIdx = i + 1;
    for (var c = 0; c < headers.length; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIdx)).cellStyle =
          c == 6 ? priceStyle : dataStyle;
    }
  }

  // ----- Empty separator + total row -----
  if (sorted.isNotEmpty) {
    final totalRowIdx = sorted.length + 2;
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: totalRowIdx))
      .value = TextCellValue(tr('סה"כ', 'TOTAL'));
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: totalRowIdx))
      .value = IntCellValue(totalRevenue);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: totalRowIdx))
      .value = IntCellValue(totalPlayers);

    final totalStyle = CellStyle(
      bold: true,
      fontSize: 12,
      fontColorHex: ExcelColor.fromHexString('FFFFFF'),
      backgroundColorHex: ExcelColor.fromHexString('1A1A1A'),
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );
    for (var c = 0; c < headers.length; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: totalRowIdx)).cellStyle = totalStyle;
    }
  }

  // ----- Save -----
  final bytes = ex.save();
  if (bytes == null) return;
  final path = await saveExcelFile(bytes, '$filename.xlsx');
  if (context.mounted) {
    final ok = path.isNotEmpty;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? tr('הקובץ הורד! 📊  ${sorted.length} ${tr('הזמנות', 'bookings')} • ₪$totalRevenue',
                'File downloaded! 📊  ${sorted.length} bookings • ₪$totalRevenue')
          : tr('שגיאה בשמירה', 'Save failed')),
      backgroundColor: ok ? accentGreen : Colors.red,
      duration: const Duration(seconds: 3),
    ));
  }
}

// ==================== FETCH PHONE ====================
Future<String> _fetchPhone(String? userId) async {
  if (userId == null) return '';
  try {
    final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    return doc.data()?['phone'] ?? '';
  } catch(_) { return ''; }
}

// ==================== BOOKING DETAILS DIALOG ====================
void showBookingDetails(BuildContext context, Map<String,dynamic> b, {bool isAdmin = false, String? docId}) async {
  String phone = await _fetchPhone(b['userId'] as String?);
  final players = (b['players'] as List?)??[];
  if (!context.mounted) return;

  showDialog(context: context, builder: (_) => AlertDialog(
    backgroundColor: cardColor,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: Row(children: [
      const Icon(Icons.sports_soccer, color: accentGreen, size: 20), const SizedBox(width: 8),
      Text(tr('פרטי הזמנה','Booking Details'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
    ]),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      _detailRow(Icons.sports_soccer_outlined, tr('מגרש','Stadium'), b['stadiumName']??''),
      if ((b['bookingType'] as String?)?.isNotEmpty == true)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Icon(_iconForType(b['bookingTypeIcon'] as String?), color: _colorForType(b['bookingTypeColor'] as String?), size: 16),
            const SizedBox(width: 8),
            Text('${tr('סוג','Type')}: ', style: const TextStyle(color: textSecondary, fontSize: 13)),
            Expanded(child: Text(isHebrew ? (b['bookingType'] ?? '') : (b['bookingTypeEn'] ?? b['bookingType'] ?? ''), style: TextStyle(color: _colorForType(b['bookingTypeColor'] as String?), fontSize: 13, fontWeight: FontWeight.bold))),
          ]),
        ),
      _detailRow(Icons.calendar_today_outlined, tr('תאריך','Date'), '${b['day']??''} ${b['date']??''}'),
      _detailRow(Icons.access_time_outlined, tr('שעה','Time'), b['time']??''),
      _detailRow(Icons.attach_money, tr('מחיר','Price'), b['price']??''),
      _detailRow(Icons.person_outline, tr('מארגן','Organizer'), b['userName']??''),
      if (phone.isNotEmpty) GestureDetector(
        onTap: () => Clipboard.setData(ClipboardData(text: phone)),
        child: _detailRow(Icons.phone_outlined, tr('טלפון','Phone'), '$phone 📋'),
      ),
      _detailRow(Icons.tag, tr('קוד','Code'), b['bookingCode']??''),
      const SizedBox(height: 12),
      const Divider(color: borderColor), const SizedBox(height: 8),
      Text(tr('שחקנים (${players.length}/18)','Players (${players.length}/18)'),
        style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: players.map((p) =>
        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
          child: Text(p.toString(), style: const TextStyle(color: accentGreen, fontSize: 12)))).toList()),
    ])),
    actions: [
      if (isAdmin && docId != null && () {
        try {
          final parts = (b['date'] as String).split('/');
          final h = int.parse((b['time'] as String).split(':')[0]);
          return DateTime(DateTime.now().year, int.parse(parts[1]), int.parse(parts[0]), h).isAfter(DateTime.now());
        } catch(_) { return false; }
      }())
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
              backgroundColor: cardColor,
              title: Text(tr('ביטול הזמנה?','Cancel Booking?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
              content: Text(tr('האם לבטל את ההזמנה הזו?','Cancel this booking?'), style: const TextStyle(color: textSecondary)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('לא','No'), style: const TextStyle(color: textSecondary))),
                TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('בטל','Cancel'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
              ],
            ));
            if (ok == true) await FirebaseFirestore.instance.collection('bookings').doc(docId).delete();
          },
          child: Text(tr('בטל הזמנה','Cancel Booking'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('סגור','Close'), style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold))),
    ],
  ));
}

Widget _detailRow(IconData icon, String label, String value) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(icon, color: accentGreen, size: 16), const SizedBox(width: 8),
    Flexible(
      child: Text('$label: ', style: const TextStyle(color: textSecondary, fontSize: 13), overflow: TextOverflow.ellipsis),
    ),
    Expanded(
      child: Text(value, style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis, maxLines: 2),
    ),
  ]),
);

// ==================== MANUAL BOOKING DIALOG ====================
void showManualBookingDialog(BuildContext context, String stadiumName, String stadiumId, int price) async {
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final now = DateTime.now();
  final names = isHebrew ? ['אח','ב','ג','ד','ה','ו','ש'] : ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
  final days = List.generate(14, (i) {
    final d = now.add(Duration(days: i));
    return {'name': names[d.weekday%7], 'date': '${d.day}/${d.month}'};
  });
  String selectedDate = days[0]['date']!;
  String selectedTime = '${defaultSlots[0]['start']} - ${defaultSlots[0]['end']}';
  bool saving = false;

  // Load booking types
  List<Map<String, dynamic>> bookingTypes = [];
  Map<String, dynamic>? selectedType;
  try {
    final tSnap = await FirebaseFirestore.instance.collection('booking_types').where('stadiumId', isEqualTo: stadiumId).get();
    if (tSnap.docs.isNotEmpty) {
      bookingTypes = tSnap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
    } else {
      bookingTypes = defaultBookingTypes.map((t) => {...t, 'price': price}).toList();
    }
    if (bookingTypes.isNotEmpty) selectedType = bookingTypes.first;
  } catch (_) {
    bookingTypes = defaultBookingTypes.map((t) => {...t, 'price': price}).toList();
    if (bookingTypes.isNotEmpty) selectedType = bookingTypes.first;
  }

  await showDialog(context: context, builder: (_) => StatefulBuilder(
    builder: (ctx, setS) => Dialog(
      backgroundColor: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.add_circle_outline, color: accentGreen, size: 20), const SizedBox(width: 8),
            Text(tr('הזמנה ידנית','Manual Booking'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          const SizedBox(height: 4),
          Text(stadiumName, style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 16),
          _dialogTf(nameCtrl, tr('שם לקוח','Customer Name'), Icons.person_outline),
          const SizedBox(height: 12),
          _dialogTf(phoneCtrl, tr('מספר טלפון','Phone Number'), Icons.phone_outlined, type: TextInputType.phone),
          const SizedBox(height: 12),
          Text(tr('תאריך','Date'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          // Wrap instead of ListView to avoid layout crash
          Wrap(spacing: 6, runSpacing: 6, children: days.map((d) {
            final isSel = selectedDate == d['date'];
            return GestureDetector(
              onTap: () => setS(() => selectedDate = d['date']!),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(color: isSel ? accentGreen : bgColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: isSel ? accentGreen : borderColor)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(d['name']!, style: TextStyle(color: isSel ? bgColor : textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                  Text(d['date']!, style: TextStyle(color: isSel ? bgColor : textSecondary, fontSize: 10)),
                ]),
              ),
            );
          }).toList()),
          const SizedBox(height: 12),
          Text(tr('שעה','Time'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          DropdownButton<String>(
            value: selectedTime, isExpanded: true, dropdownColor: cardColor,
            items: defaultSlots.map((s) {
              final label = '${s['start']} - ${s['end']}';
              return DropdownMenuItem(value: label, child: Text(label, style: const TextStyle(color: textPrimary)));
            }).toList(),
            onChanged: (v) => setS(() => selectedTime = v!),
          ),
          const SizedBox(height: 12),
          Text(tr('סוג הזמנה','Booking Type'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: bookingTypes.map((t) {
            final isSel = selectedType == t || (selectedType?['name'] == t['name'] && selectedType?['icon'] == t['icon']);
            final col = _colorForType(t['color'] as String?);
            return GestureDetector(
              onTap: () => setS(() => selectedType = t),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: isSel ? col.withValues(alpha: 0.15) : bgColor, borderRadius: BorderRadius.circular(20), border: Border.all(color: isSel ? col : borderColor)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_iconForType(t['icon'] as String?), color: col, size: 14),
                  const SizedBox(width: 5),
                  Text(isHebrew ? (t['name'] ?? '') : (t['nameEn'] ?? t['name'] ?? ''), style: TextStyle(color: isSel ? col : textSecondary, fontSize: 12, fontWeight: isSel ? FontWeight.bold : FontWeight.normal)),
                ]),
              ),
            );
          }).toList()),
          const SizedBox(height: 10),
          Container(width: double.infinity, padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
            child: Text('₪${selectedType?['price'] ?? price}/2hr', textAlign: TextAlign.center, style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold))),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('ביטול','Cancel'), style: const TextStyle(color: textSecondary)),
            )),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton(
              onPressed: saving ? null : () async {
                if (nameCtrl.text.trim().isEmpty) return;
                setS(() => saving = true);
                final code = (1000 + DateTime.now().millisecondsSinceEpoch % 9000).toString();
                final dayName = days.firstWhere((d) => d['date'] == selectedDate)['name'] ?? '';
                final typePrice = selectedType?['price'] ?? price;
                await FirebaseFirestore.instance.collection('bookings').add({
                  'userId': 'manual', 'userName': nameCtrl.text.trim(),
                  'phone': phoneCtrl.text.trim(),
                  'stadiumName': stadiumName, 'stadiumId': stadiumId,
                  'day': dayName, 'date': selectedDate, 'time': selectedTime,
                  'price': '₪$typePrice/2hr', 'bookingCode': code,
                  'players': [nameCtrl.text.trim()],
                  'createdAt': DateTime.now().toIso8601String(), 'isManual': true,
                  if (selectedType != null) ...{
                    'bookingType':      selectedType!['name']   ?? '',
                    'bookingTypeEn':    selectedType!['nameEn'] ?? '',
                    'bookingTypeIcon':  selectedType!['icon']   ?? '',
                    'bookingTypeColor': selectedType!['color']  ?? '',
                  },
                });
                setS(() => saving = false);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(tr('ההזמנה נוספה! קוד: $code', 'Booking added! Code: $code')),
                    backgroundColor: accentGreen, duration: const Duration(seconds: 4),
                  ));
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor),
              child: saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: bgColor, strokeWidth: 2))
                : Text(tr('הוסף','ADD'), style: const TextStyle(fontWeight: FontWeight.w900)),
            )),
          ]),
        ]),
      ),
    ),
  ));
}

Widget _dialogTf(TextEditingController c, String hint, IconData icon, {TextInputType? type}) => TextField(
  controller: c, keyboardType: type, style: const TextStyle(color: textPrimary),
  decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: textSecondary), prefixIcon: Icon(icon, color: textSecondary, size: 18), filled: true, fillColor: bgColor,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accentGreen, width: 1.5))));

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Offline persistence — must be set before any Firestore call.
  // Reads are served from local cache when offline, and writes are queued
  // until connectivity is restored. CACHE_SIZE_UNLIMITED keeps everything
  // we've ever read on disk for instant subsequent loads.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  // FCM (push notifications) — only on native platforms. On web it requires
  // a `firebase-messaging-sw.js` service worker in the `web/` folder, which
  // isn't set up here, so we skip it to avoid the noisy MIME-type error.
  if (!kIsWeb) {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token != null) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          await FirebaseFirestore.instance.collection('users').doc(uid).set({'fcmToken': token}, SetOptions(merge: true));
        }
      }
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        // No-op: rely on Firestore notifications collection for in-app display.
      });
    } catch (_) {
      // Silent: FCM is optional; failures don't block the app.
    }
  }
  runApp(const StadiumApp());
}

class StadiumApp extends StatefulWidget {
  const StadiumApp({super.key});
  static _StadiumAppState? of(BuildContext context) => context.findAncestorStateOfType<_StadiumAppState>();
  @override State<StadiumApp> createState() => _StadiumAppState();
}
class _StadiumAppState extends State<StadiumApp> {
  void toggleLanguage() => setState(() => isHebrew = !isHebrew);
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'STADIUM', debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: bgColor,
      colorScheme: const ColorScheme.dark(primary: accentGreen, surface: cardColor),
      // 'Heebo' supports both Hebrew and Latin glyphs; loaded from Google
      // Fonts in web/index.html. On native platforms it falls back to the
      // system font (which is fine for Hebrew on Android/iOS).
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Heebo'),
      primaryTextTheme: ThemeData.dark().primaryTextTheme.apply(fontFamily: 'Heebo'),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    ),
    home: const SplashScreen(),
  );
}

/// Toggles the global `isHebrew` flag and forces the current route to
/// rebuild so all `tr()` calls re-evaluate immediately.
///
/// `setState` on `_StadiumAppState` rebuilds the MaterialApp, but the
/// Navigator's already-pushed routes (e.g. admin screens reached via
/// pushAndRemoveUntil) keep their existing State objects — their build
/// methods don't re-run unless we explicitly mark them dirty.
void toggleAppLanguage(BuildContext context) {
  // Flip the global `isHebrew` on the app state.
  StadiumApp.of(context)?.toggleLanguage();

  // markNeedsBuild on ancestors alone is not enough: any `const` child
  // (e.g. `TabBarView(children: const [MD9OverviewTab(), ...])`) is
  // identity-equal across rebuilds, so Flutter skips its build pass and
  // cached `tr()` strings stay stale until the user navigates.
  //
  // To make the toggle visible immediately, re-push the current route with
  // a fresh `MaterialPageRoute` using the same `builder`. The framework
  // tears down the old route's State + widgets and constructs new ones,
  // so every `tr()` re-evaluates with the new language.
  final navigator = Navigator.of(context);
  final route = ModalRoute.of(context);
  if (route is MaterialPageRoute) {
    navigator.pushReplacement(MaterialPageRoute(
      builder: route.builder,
      maintainState: route.maintainState,
      fullscreenDialog: route.fullscreenDialog,
    ));
    return;
  }

  // Fallback for non-MaterialPageRoute (e.g. PageRouteBuilder created via
  // `navigateTo`): still mark ancestors dirty so the AppBar at minimum
  // refreshes. The `const` body issue may remain for these screens.
  (context as Element).visitAncestorElements((el) {
    el.markNeedsBuild();
    return true;
  });
}

Widget _langButton(BuildContext context) => TextButton(
  onPressed: () => toggleAppLanguage(context),
  child: Text(isHebrew ? 'EN' : 'עב', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 13)),
);

// ==================== SPLASH ====================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final AnimationController _spacingController;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _spacingAnim;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _spacingController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeIn);
    _spacingAnim = Tween<double>(begin: 2, end: 10).animate(
      CurvedAnimation(parent: _spacingController, curve: Curves.easeOutCubic),
    );
    _fadeController.forward();
    _spacingController.forward();

    Future.delayed(const Duration(milliseconds: 2500), _goNext);
  }

  void _goNext() {
    if (!mounted) return;
    final user = FirebaseAuth.instance.currentUser;
    Widget next;
    if (user == null) {
      next = const LoginScreen();
    } else {
      final email = user.email ?? '';
      if (email == superAdminEmail) {
        next = const SuperAdminScreen();
      } else if (email == md9AdminEmail) {
        next = const MD9AdminScreen();
      } else if (email == yStadiumAdminEmail) {
        next = const SingleAdminScreen(stadiumId: 'y_stadium');
      } else {
        next = const VenueSelectionScreen();
      }
    }
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => next,
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _spacingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.sports_soccer, color: accentGreen, size: 80),
              const SizedBox(height: 24),
              AnimatedBuilder(
                animation: _spacingAnim,
                builder: (_, __) => Text(
                  'STADIUM',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    letterSpacing: _spacingAnim.value,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('הזמן את המשחק שלך', 'BOOK YOUR GAME'),
                style: const TextStyle(color: accentGreen, fontSize: 12, letterSpacing: 4),
              ),
              const SizedBox(height: 40),
              const SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(color: accentGreen, strokeWidth: 2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== LOGIN ====================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _obscurePass = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await _signOut();
      try {
        await FirebaseFirestore.instance.clearPersistence();
      } catch (_) {
        // clearPersistence throws if Firestore is still running; safe to ignore.
      }
      final email = _emailCtrl.text.trim();
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: _passCtrl.text,
      );
      if (!mounted) return;
      Widget next;
      if (email == superAdminEmail) {
        next = const SuperAdminScreen();
      } else if (email == md9AdminEmail) {
        next = const MD9AdminScreen();
      } else if (email == yStadiumAdminEmail) {
        next = const SingleAdminScreen(stadiumId: 'y_stadium');
      } else {
        next = const VenueSelectionScreen();
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => next),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Login failed'), backgroundColor: colorError),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    bool sending = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(spaceLg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        color: accentGreen.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(Icons.lock_reset_rounded, color: accentGreen, size: 32),
                    ),
                  ),
                  const SizedBox(height: spaceMd),
                  Text(
                    tr('שיחזור סיסמה', 'Reset Password'),
                    style: const TextStyle(
                      color: textPrimary, fontSize: 20, fontWeight: FontWeight.w900,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('הזן את האימייל שלך ונשלח לך קישור איפוס',
                       'Enter your email and we\'ll send you a reset link'),
                    style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: spaceXs),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: colorWarning.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(radiusSm),
                      border: Border.all(color: colorWarning.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: colorWarning, size: 14),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            tr('לא רואה? בדוק בספאם 📬', 'Not in inbox? Check SPAM 📬'),
                            style: const TextStyle(color: colorWarning, fontSize: 10, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: spaceLg),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      labelText: tr('אימייל', 'Email'),
                      prefixIcon: const Icon(Icons.email_outlined, color: textSecondary, size: 20),
                      labelStyle: const TextStyle(color: textSecondary, fontSize: 13),
                      filled: true,
                      fillColor: bgSecondary,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(radiusMd),
                        borderSide: const BorderSide(color: borderColor),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(radiusMd),
                        borderSide: const BorderSide(color: borderColor),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(radiusMd),
                        borderSide: const BorderSide(color: accentGreen, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: spaceLg),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: borderColor),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                        ),
                        child: Text(
                          tr('ביטול', 'Cancel'),
                          style: const TextStyle(color: textSecondary, fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: spaceSm),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: sending ? null : () async {
                          final email = emailCtrl.text.trim();
                          if (email.isEmpty) return;
                          setS(() => sending = true);
                          try {
                            await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(tr('✉️ נשלח אימייל איפוס ל-$email • בדוק גם בספאם',
                                                    '✉️ Reset email sent to $email • Check SPAM too')),
                                  backgroundColor: accentGreen,
                                  duration: const Duration(seconds: 5),
                                ),
                              );
                            }
                          } on FirebaseAuthException catch (e) {
                            setS(() => sending = false);
                            String msg = tr('שגיאה - בדוק את האימייל', 'Error - check email');
                            if (e.code == 'user-not-found') {
                              msg = tr('משתמש לא נמצא', 'User not found');
                            } else if (e.code == 'invalid-email') {
                              msg = tr('אימייל לא תקין', 'Invalid email');
                            }
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text(msg), backgroundColor: colorError),
                              );
                            }
                          }
                        },
                        icon: sending
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: bgColor))
                            : const Icon(Icons.send_rounded, size: 18),
                        label: Text(
                          sending ? tr('שולח...', 'Sending...') : tr('שלח קישור', 'Send Link'),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentGreen,
                          foregroundColor: bgColor,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? spaceMd : spaceXl,
              vertical: spaceLg,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 72, height: 72,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [accentGreen, accentGreen.withValues(alpha: 0.7)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: accentGreen.withValues(alpha: 0.3),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.stadium_rounded, color: bgColor, size: 36),
                      ),
                    ),
                    const SizedBox(height: spaceLg),
                    const Text(
                      'STADIUM',
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: spaceXs),
                    Text(
                      tr('ניהול מגרשים מקצועי', 'Professional venue management'),
                      style: const TextStyle(
                        color: textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: spaceXl),

                    Container(
                      padding: const EdgeInsets.all(spaceLg),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(radiusXl),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            tr('כניסה לחשבון', 'Sign In'),
                            style: const TextStyle(
                              color: textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tr('הזן את פרטיך כדי להמשיך', 'Enter your credentials to continue'),
                            style: const TextStyle(
                              color: textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: spaceLg),
                          appTextField(
                            controller: _emailCtrl,
                            label: tr('אימייל', 'Email'),
                            icon: Icons.email_outlined,
                            keyboardType: TextInputType.emailAddress,
                            validator: (v) => (v == null || v.isEmpty) ? tr('שדה חובה', 'Required') : null,
                          ),
                          const SizedBox(height: spaceMd),
                          TextFormField(
                            controller: _passCtrl,
                            obscureText: _obscurePass,
                            style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                            validator: (v) => (v == null || v.isEmpty) ? tr('שדה חובה', 'Required') : null,
                            decoration: InputDecoration(
                              labelText: tr('סיסמה', 'Password'),
                              prefixIcon: const Icon(Icons.lock_outline, color: textSecondary, size: 20),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _obscurePass = !_obscurePass),
                                icon: Icon(
                                  _obscurePass ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  color: textSecondary, size: 20,
                                ),
                              ),
                              labelStyle: const TextStyle(color: textSecondary, fontSize: 13),
                              filled: true,
                              fillColor: bgSecondary,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: borderColor),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: borderColor),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: accentGreen, width: 2),
                              ),
                            ),
                          ),
                          const SizedBox(height: spaceLg),
                          appPrimaryButton(
                            label: _loading ? tr('מתחבר...', 'Signing in...') : tr('התחבר', 'Sign In'),
                            icon: _loading ? null : Icons.login,
                            onPressed: _loading ? null : _login,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: spaceMd),

                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(
                        onPressed: () => _showForgotPasswordDialog(),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          minimumSize: const Size(50, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          tr('שכחתי סיסמה?', 'Forgot password?'),
                          style: const TextStyle(
                            color: accentGreen,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: spaceXs),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          tr('אין לך חשבון? ', "Don't have an account? "),
                          style: const TextStyle(color: textSecondary, fontSize: 13),
                        ),
                        InkWell(
                          onTap: () {
                            navigateTo(context, const RegisterScreen(),);
                          },
                          child: Text(
                            tr('הירשם', 'Register'),
                            style: const TextStyle(
                              color: accentGreen,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: spaceLg),

                    Center(
                      child: InkWell(
                        onTap: () => toggleAppLanguage(context),
                        borderRadius: BorderRadius.circular(radiusSm),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: cardColor,
                            borderRadius: BorderRadius.circular(radiusSm),
                            border: Border.all(color: borderColor),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.language, color: textSecondary, size: 14),
                              const SizedBox(width: 6),
                              Text(
                                isHebrew ? 'English' : 'עברית',
                                style: const TextStyle(
                                  color: textPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== REGISTER ====================
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _pass2Ctrl = TextEditingController();
  final _dobCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _obscurePass = true;
  bool _obscurePass2 = true;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _pass2Ctrl.dispose();
    _dobCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(1920),
      lastDate: DateTime(now.year - 5),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: accentGreen, surface: cardColor, onPrimary: bgColor),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _dobCtrl.text = '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      });
    }
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      await cred.user?.updateDisplayName(_nameCtrl.text.trim());
      await FirebaseFirestore.instance.collection('users').doc(cred.user!.uid).set({
        'name': _nameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
        'email': _emailCtrl.text.trim(),
        'dob': _dobCtrl.text.trim(),
        'city': _cityCtrl.text.trim(),
        'emailVerified': false,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await cred.user?.sendEmailVerification();
      await cred.user?.reload();

      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => Dialog(
            backgroundColor: cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding: const EdgeInsets.all(spaceLg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        color: accentGreen.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.mark_email_read_rounded, color: accentGreen, size: 40),
                    ),
                    const SizedBox(height: spaceMd),
                    Text(
                      tr('✅ נרשמת בהצלחה!', '✅ Successfully registered!'),
                      style: const TextStyle(
                        color: textPrimary, fontSize: 20, fontWeight: FontWeight.w900,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: spaceXs),
                    Text(
                      tr('שלחנו אימייל אימות ל-${_emailCtrl.text.trim()}\nאנא בדוק את תיבת הדואר שלך',
                         'We sent a verification email to ${_emailCtrl.text.trim()}\nPlease check your inbox'),
                      style: const TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: spaceSm),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: colorWarning.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(radiusSm),
                        border: Border.all(color: colorWarning.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: colorWarning, size: 16),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              tr('לא רואה? בדוק בתיקיית הספאם 📬',
                                 "Don't see it? Check your SPAM folder 📬"),
                              style: const TextStyle(color: colorWarning, fontSize: 11, fontWeight: FontWeight.w700),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: spaceLg),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          // Close the dialog and navigate to the main player
                          // screen in one shot. We use the parent State's
                          // context (not the dialog's `ctx`) for navigation
                          // so the new route replaces RegisterScreen, not
                          // the dialog route.
                          Navigator.pop(ctx);
                          if (mounted) {
                            Navigator.of(context).pushAndRemoveUntil(
                              MaterialPageRoute(builder: (_) => const VenueSelectionScreen()),
                              (route) => false,
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentGreen,
                          foregroundColor: bgColor,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                          elevation: 0,
                        ),
                        child: Text(
                          tr('המשך', 'Continue'),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String msg = e.message ?? 'Registration failed';
        if (e.code == 'email-already-in-use') {
          msg = tr('האימייל כבר רשום במערכת', 'Email already registered');
        } else if (e.code == 'weak-password') {
          msg = tr('סיסמה חלשה - מינימום 6 תווים', 'Weak password - min 6 chars');
        } else if (e.code == 'invalid-email') {
          msg = tr('אימייל לא תקין', 'Invalid email');
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: colorError),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? spaceMd : spaceXl,
              vertical: spaceLg,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: InkWell(
                        onTap: () => Navigator.pop(context),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: cardColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: borderColor),
                          ),
                          child: Icon(
                            isHebrew ? Icons.arrow_forward : Icons.arrow_back,
                            color: textPrimary, size: 18,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: spaceLg),
                    Center(
                      child: Container(
                        width: 64, height: 64,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [accentGreen, accentGreen.withValues(alpha: 0.7)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(Icons.person_add_alt_1_rounded, color: bgColor, size: 32),
                      ),
                    ),
                    const SizedBox(height: spaceMd),
                    Text(
                      tr('יצירת חשבון', 'Create Account'),
                      style: const TextStyle(
                        color: textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('הצטרף ל-STADIUM וקבל גישה למתחמים', 'Join STADIUM and access venues'),
                      style: const TextStyle(
                        color: textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: spaceLg),
                    Container(
                      padding: const EdgeInsets.all(spaceLg),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(radiusXl),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          appTextField(
                            controller: _nameCtrl,
                            label: tr('שם מלא', 'Full Name'),
                            icon: Icons.person_outline,
                            validator: (v) => (v == null || v.isEmpty) ? tr('שדה חובה', 'Required') : null,
                          ),
                          const SizedBox(height: spaceMd),
                          appTextField(
                            controller: _phoneCtrl,
                            label: tr('טלפון', 'Phone'),
                            icon: Icons.phone_outlined,
                            keyboardType: TextInputType.phone,
                            validator: (v) => (v == null || v.isEmpty) ? tr('שדה חובה', 'Required') : null,
                          ),
                          const SizedBox(height: spaceMd),
                          appTextField(
                            controller: _dobCtrl,
                            label: tr('תאריך לידה', 'Date of Birth'),
                            icon: Icons.cake_outlined,
                            readOnly: true,
                            onTap: _pickDob,
                            validator: (v) => (v == null || v.isEmpty) ? tr('שדה חובה', 'Required') : null,
                          ),
                          const SizedBox(height: spaceMd),
                          appTextField(
                            controller: _cityCtrl,
                            label: tr('עיר', 'City'),
                            icon: Icons.location_city_outlined,
                          ),
                          const SizedBox(height: spaceMd),
                          appTextField(
                            controller: _emailCtrl,
                            label: tr('אימייל', 'Email'),
                            icon: Icons.email_outlined,
                            keyboardType: TextInputType.emailAddress,
                            validator: (v) => (v == null || v.isEmpty) ? tr('שדה חובה', 'Required') : null,
                          ),
                          const SizedBox(height: spaceMd),
                          TextFormField(
                            controller: _passCtrl,
                            obscureText: _obscurePass,
                            style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                            validator: (v) {
                              if (v == null || v.isEmpty) return tr('שדה חובה', 'Required');
                              if (v.length < 6) return tr('מינימום 6 תווים', 'Min 6 characters');
                              return null;
                            },
                            decoration: InputDecoration(
                              labelText: tr('סיסמה', 'Password'),
                              prefixIcon: const Icon(Icons.lock_outline, color: textSecondary, size: 20),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _obscurePass = !_obscurePass),
                                icon: Icon(
                                  _obscurePass ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  color: textSecondary, size: 20,
                                ),
                              ),
                              labelStyle: const TextStyle(color: textSecondary, fontSize: 13),
                              filled: true,
                              fillColor: bgSecondary,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: borderColor),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: borderColor),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: accentGreen, width: 2),
                              ),
                            ),
                          ),
                          const SizedBox(height: spaceMd),
                          TextFormField(
                            controller: _pass2Ctrl,
                            obscureText: _obscurePass2,
                            style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                            validator: (v) {
                              if (v == null || v.isEmpty) return tr('שדה חובה', 'Required');
                              if (v != _passCtrl.text) return tr('הסיסמאות לא תואמות', 'Passwords do not match');
                              return null;
                            },
                            decoration: InputDecoration(
                              labelText: tr('אימות סיסמה', 'Confirm Password'),
                              prefixIcon: const Icon(Icons.lock_outline, color: textSecondary, size: 20),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _obscurePass2 = !_obscurePass2),
                                icon: Icon(
                                  _obscurePass2 ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  color: textSecondary, size: 20,
                                ),
                              ),
                              labelStyle: const TextStyle(color: textSecondary, fontSize: 13),
                              filled: true,
                              fillColor: bgSecondary,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: borderColor),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: borderColor),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: accentGreen, width: 2),
                              ),
                              errorBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(radiusMd),
                                borderSide: const BorderSide(color: colorError),
                              ),
                            ),
                          ),
                          const SizedBox(height: spaceLg),
                          appPrimaryButton(
                            label: _loading ? tr('יוצר חשבון...', 'Creating...') : tr('צור חשבון', 'Create Account'),
                            icon: _loading ? null : Icons.person_add_alt_1,
                            onPressed: _loading ? null : _register,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== SUPER ADMIN ====================
class SuperAdminScreen extends StatefulWidget {
  const SuperAdminScreen({super.key});
  @override State<SuperAdminScreen> createState() => _SuperAdminScreenState();
}
class _SuperAdminScreenState extends State<SuperAdminScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  String _search = '';
  @override void initState() { super.initState(); _tab = TabController(length: 3, vsync: this); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: AdminAppBar(
      title: Row(children: [
        const Icon(Icons.shield_outlined, color: Colors.amber, size: 20),
        const SizedBox(width: 8),
        Text(tr('סופר אדמין', 'SUPER ADMIN'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, letterSpacing: 2)),
      ]),
      bottom: TabBar(controller: _tab, indicatorColor: accentGreen, labelColor: accentGreen, unselectedLabelColor: textSecondary,
        tabs: [Tab(text: tr('סקירה','Overview')), Tab(text: tr('הזמנות','Bookings')), Tab(text: tr('דוחות','Reports'))]),
    ),
    body: TabBarView(controller: _tab, children: [
      _buildOverview(),
      _buildAllBookings(),
      _buildReports(),
    ]),
  );

  Widget _buildOverview() => StreamBuilder(
    stream: FirebaseFirestore.instance.collection('bookings').snapshots(),
    builder: (context, snap) {
      if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
      final docs = snap.data!.docs;
      final allBookings = docs.map((d) => d.data()).toList();
      int totalP = 0; Map<String, int> sCount = {}, sRev = {};
      for (final d in docs) {
        final b = d.data();
        totalP += ((b['players'] as List?) ?? []).length;
        final s = b['stadiumName'] as String? ?? '';
        sCount[s] = (sCount[s] ?? 0) + 1;
        final pr = int.tryParse((b['price'] as String? ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        sRev[s] = (sRev[s] ?? 0) + pr;
      }
      return ListView(padding: const EdgeInsets.all(16), children: [
        _secTitle(tr('סקירה כללית', 'OVERVIEW')), const SizedBox(height: 12),
        Row(children: [Expanded(child: _statCard(tr('הזמנות', 'BOOKINGS'), '${docs.length}', Icons.calendar_month, accentGreen)), const SizedBox(width: 12), Expanded(child: _statCard(tr('שחקנים', 'PLAYERS'), '$totalP', Icons.people_outline, Colors.blue))]),
        const SizedBox(height: 12),
        Row(children: [Expanded(child: _statCard(tr('מגרשים', 'STADIUMS'), '${allStadiums.length}', Icons.sports_soccer, Colors.orange)), const SizedBox(width: 12), Expanded(child: _statCard(tr('הכנסות', 'REVENUE'), '₪${sRev.values.fold(0, (a, b) => a + b)}', Icons.attach_money, Colors.amber))]),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: () => exportToCSV(context, allBookings, 'all_bookings'),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text(tr('ייצוא כל ההזמנות לExcel', 'Export All to Excel')),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 12)),
        )),
        const SizedBox(height: 24), _secTitle(tr('ביצועי מגרשים', 'STADIUMS')), const SizedBox(height: 12),
        ...allStadiums.map((s) => _perfCard(s['name'], sCount[s['name']] ?? 0, sRev[s['name']] ?? 0)),
      ]);
    },
  );

  Widget _buildAllBookings() => StreamBuilder(
    stream: FirebaseFirestore.instance.collection('bookings').snapshots(),
    builder: (context, snap) {
      if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
      var docs = snap.data!.docs;
      if (_search.isNotEmpty) {
        docs = docs.where((d) {
          final b = d.data();
          return (b['userName'] as String? ?? '').toLowerCase().contains(_search.toLowerCase()) ||
                 (b['date'] as String? ?? '').contains(_search) ||
                 (b['stadiumName'] as String? ?? '').toLowerCase().contains(_search.toLowerCase()) ||
                 (b['bookingCode'] as String? ?? '').contains(_search);
        }).toList();
      }
      return Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: TextField(
          onChanged: (v) => setState(() => _search = v),
          style: const TextStyle(color: textPrimary),
          decoration: InputDecoration(
            hintText: tr('חפש לפי שם, תאריך, מגרש...', 'Search by name, date, stadium...'),
            hintStyle: const TextStyle(color: textSecondary, fontSize: 13),
            prefixIcon: const Icon(Icons.search, color: textSecondary, size: 20),
            filled: true, fillColor: cardColor,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: accentGreen, width: 1.5)),
          ),
        )),
        Expanded(child: ListView.builder(padding: const EdgeInsets.fromLTRB(12,0,12,12), itemCount: docs.length, itemBuilder: (_, i) {
          final doc = docs[i]; final b = doc.data();
          return _adminBookCard(b, docId: doc.id, context: context);
        })),
      ]);
    },
  );

  Widget _buildReports() {
    DateTime fromDate = DateTime.now().subtract(const Duration(days: 30));
    DateTime toDate = DateTime.now();
    String period = 'month';

    return StatefulBuilder(builder: (ctx, setSS) => StreamBuilder(
      stream: FirebaseFirestore.instance.collection('bookings').snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
        final docs = snap.data!.docs;
        final now = DateTime.now();

        // חישוב טווח לפי בחירה
        DateTime rangeStart, rangeEnd;
        if (period == 'day') {
          rangeStart = DateTime(now.year, now.month, now.day);
          rangeEnd = now;
        } else if (period == 'week') {
          rangeStart = now.subtract(Duration(days: now.weekday - 1));
          rangeEnd = now;
        } else if (period == 'month') {
          rangeStart = DateTime(now.year, now.month, 1);
          rangeEnd = now;
        } else {
          rangeStart = fromDate;
          rangeEnd = toDate;
        }

        // סינון לפי טווח
        final filtered = docs.where((d) {
          try {
            final b = d.data();
            final parts = (b['date'] as String).split('/');
            final date = DateTime(now.year, int.parse(parts[1]), int.parse(parts[0]));
            return !date.isBefore(DateTime(rangeStart.year, rangeStart.month, rangeStart.day)) &&
                   !date.isAfter(DateTime(rangeEnd.year, rangeEnd.month, rangeEnd.day));
          } catch(_) { return false; }
        }).toList();

        final rev = filtered.fold(0, (s, d) => s + (int.tryParse((d.data()['price'] as String? ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0));
        final players = filtered.fold(0, (s, d) => s + ((d.data()['players'] as List?)?.length ?? 0));

        String periodLabel() {
          if (period == 'day') return tr('היום','Today');
          if (period == 'week') return tr('השבוע','This Week');
          if (period == 'month') return tr('החודש','This Month');
          return '${fromDate.day}/${fromDate.month} — ${toDate.day}/${toDate.month}';
        }

        return ListView(padding: const EdgeInsets.all(16), children: [
          // בחירת תקופה
          _secTitle(tr('בחר תקופה','SELECT PERIOD')), const SizedBox(height: 12),
          Row(children: [
            _periodBtn(tr('יום','Day'), 'day', period, () => setSS(() => period = 'day')),
            const SizedBox(width: 8),
            _periodBtn(tr('שבוע','Week'), 'week', period, () => setSS(() => period = 'week')),
            const SizedBox(width: 8),
            _periodBtn(tr('חודש','Month'), 'month', period, () => setSS(() => period = 'month')),
            const SizedBox(width: 8),
            _periodBtn(tr('מותאם','Custom'), 'custom', period, () => setSS(() => period = 'custom')),
          ]),
          const SizedBox(height: 12),
          // בחירת תאריכים מותאמת
          if (period == 'custom') ...[
            Row(children: [
              Expanded(child: GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: context, initialDate: fromDate, firstDate: DateTime(2024), lastDate: DateTime.now(),
                    builder: (_, child) => Theme(data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: accentGreen, surface: cardColor)), child: child!));
                  if (picked != null) setSS(() => fromDate = picked);
                },
                child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: accentGreen.withValues(alpha: 0.4))),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.calendar_today_outlined, color: accentGreen, size: 16), const SizedBox(width: 6),
                    Text('${fromDate.day}/${fromDate.month}/${fromDate.year}', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
                  ])),
              )),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('→', style: TextStyle(color: textSecondary, fontSize: 18))),
              Expanded(child: GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: context, initialDate: toDate, firstDate: DateTime(2024), lastDate: DateTime.now().add(const Duration(days: 1)),
                    builder: (_, child) => Theme(data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: accentGreen, surface: cardColor)), child: child!));
                  if (picked != null) setSS(() => toDate = picked);
                },
                child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: accentGreen.withValues(alpha: 0.4))),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.calendar_today_outlined, color: accentGreen, size: 16), const SizedBox(width: 6),
                    Text('${toDate.day}/${toDate.month}/${toDate.year}', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
                  ])),
              )),
            ]),
            const SizedBox(height: 12),
          ],
          // תוצאות
          Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12), border: Border.all(color: accentGreen.withValues(alpha: 0.2))),
            child: Row(children: [const Icon(Icons.bar_chart, color: accentGreen, size: 18), const SizedBox(width: 8), Text('${tr('דוח','Report')}: ${periodLabel()}', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold))])),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _statCard(tr('הזמנות','BOOKINGS'), '${filtered.length}', Icons.calendar_month, accentGreen)),
            const SizedBox(width: 8),
            Expanded(child: _statCard(tr('שחקנים','PLAYERS'), '$players', Icons.people_outline, Colors.blue)),
            const SizedBox(width: 8),
            Expanded(child: _statCard(tr('הכנסות','REVENUE'), '₪$rev', Icons.attach_money, Colors.amber)),
          ]),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: filtered.isEmpty ? null : () => exportToCSV(context, filtered.map((d) => d.data()).toList(), 'report_${period}_${rangeStart.day}-${rangeStart.month}'),
            icon: const Icon(Icons.download_outlined, size: 16),
            label: Text(tr('ייצוא דוח לExcel','Export Report to Excel')),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 12)),
          )),
          const SizedBox(height: 24),
          // פילוח לפי מגרש
          _secTitle(tr('פילוח לפי מגרש','BY STADIUM')), const SizedBox(height: 12),
          ...allStadiums.map((s) {
            final sBookings = filtered.where((d) => d.data()['stadiumName'] == s['name']).toList();
            final sRev = sBookings.fold(0, (sum, d) => sum + (int.tryParse((d.data()['price'] as String? ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0));
            return Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: borderColor)),
              child: Row(children: [
                const Icon(Icons.sports_soccer, color: accentGreen, size: 20), const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s['name'], style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
                  Text('${sBookings.length} ${tr('הזמנות','bookings')}', style: const TextStyle(color: textSecondary, fontSize: 12)),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('₪$sRev', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 16)),
                  if (sBookings.isNotEmpty) TextButton(
                    onPressed: () => exportToCSV(context, sBookings.map((d) => d.data()).toList(), '${s['id']}_report'),
                    child: Text(tr('ייצוא','Export'), style: const TextStyle(color: accentGreen, fontSize: 11)),
                  ),
                ]),
              ]));
          }),
          const SizedBox(height: 24),
          // רשימת הזמנות
          if (filtered.isNotEmpty) ...[
            _secTitle(tr('הזמנות בתקופה','BOOKINGS IN PERIOD')), const SizedBox(height: 12),
            ...filtered.map((d) => _adminBookCard(d.data(), docId: d.id, context: context)),
          ],
        ]);
      },
    ));
  }

  Widget _perfCard(String name, int b, int r) => Container(
    margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
    child: Row(children: [Container(width: 44, height: 44, decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.sports_soccer, color: accentGreen, size: 22)), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 14)), Text('$b ${tr('הזמנות', 'bookings')}', style: const TextStyle(color: textSecondary, fontSize: 12))])),
      Text('₪$r', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 16))]),
  );
}

// ==================== ADMIN BOOK CARD (with cancel + phone) ====================
Widget _adminBookCard(Map<String,dynamic> b, {required String docId, required BuildContext context}) {
  final players = (b['players'] as List?)??[];
  final phone = b['phone'] as String? ?? '';
  final isManual = b['isManual'] == true;
  return GestureDetector(
    onTap: () => showBookingDetails(context, b, isAdmin: true, docId: docId),
    child: Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: isManual ? Colors.purple.withValues(alpha: 0.4) : borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_iconForType(b['bookingTypeIcon'] as String?), color: _colorForType(b['bookingTypeColor'] as String?), size: 16),
          const SizedBox(width: 6),
          Expanded(child: Text(b['stadiumName']??'', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 14), overflow: TextOverflow.ellipsis)),
          if (isManual) Container(margin: const EdgeInsets.only(right: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.purple.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)), child: const Text('MANUAL', style: TextStyle(color: Colors.purple, fontSize: 9, fontWeight: FontWeight.bold))),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.amber.withValues(alpha: 0.3))), child: Text(b['bookingCode']??'', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 12))),
          const SizedBox(width: 6),
          const Icon(Icons.info_outline, color: Colors.blue, size: 16),
        ]),
        const SizedBox(height: 6),
        Text('${b['userName']??''} • ${b['day']} ${b['date']} • ${b['time']}', style: const TextStyle(color: textSecondary, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (phone.isNotEmpty) Row(children: [
          const Icon(Icons.phone_outlined, color: accentGreen, size: 12),
          const SizedBox(width: 4),
          Expanded(child: Text(phone, style: const TextStyle(color: accentGreen, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 4),
        Text('${players.length}/18 ${tr('שחקנים','players')}', style: const TextStyle(color: textSecondary, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
      ])),
  );
}

// ==================== MD9 ADMIN ====================
class MD9AdminScreen extends StatefulWidget {
  const MD9AdminScreen({super.key});
  @override State<MD9AdminScreen> createState() => _MD9AdminScreenState();
}
class _MD9AdminScreenState extends State<MD9AdminScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  @override void initState() { super.initState(); _tab = TabController(length: 3, vsync: this); }
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: AdminAppBar(
      title: Row(children: [
        const Icon(Icons.shield_outlined, color: Colors.amber, size: 20),
        const SizedBox(width: 8),
        Text(tr('אדמין MD9', 'MD9 ADMIN'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, letterSpacing: 2)),
      ]),
      bottom: TabBar(controller: _tab, indicatorColor: accentGreen, labelColor: accentGreen, unselectedLabelColor: textSecondary,
        tabs: [Tab(text: tr('סקירה', 'DASHBOARD')), const Tab(text: 'MD9 MAIN'), const Tab(text: 'MD9 2')]),
    ),
    body: TabBarView(controller: _tab, children: const [
      MD9OverviewTab(),
      AdminStadiumTab(stadiumName: 'MD9 MAIN', stadiumId: 'md9_main', price: 300),
      AdminStadiumTab(stadiumName: 'MD9 2',    stadiumId: 'md9_2',    price: 300),
    ]),
  );
}

class MD9OverviewTab extends StatelessWidget {
  const MD9OverviewTab({super.key});

  static int _priceOf(Map<String, dynamic> b) =>
      int.tryParse((b['price'] as String? ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  static DateTime? _parseBookingDateTime(Map<String, dynamic> b, DateTime now) {
    try {
      final dateParts = (b['date'] as String).split('/');
      final timeStr = (b['time'] as String? ?? '').split(' - ').first.trim();
      final hh = int.parse(timeStr.split(':')[0]);
      final mm = int.parse(timeStr.split(':')[1]);
      return DateTime(now.year, int.parse(dateParts[1]), int.parse(dateParts[0]), hh, mm);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: FirebaseFirestore.instance.collection('bookings').where('stadiumName', whereIn: ['MD9 MAIN', 'MD9 2']).snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));

        final now = DateTime.now();
        final todayStr = '${now.day}/${now.month}';
        final weekAgo = now.subtract(const Duration(days: 7));

        final docs = snap.data!.docs;
        final allBookings = docs.map((d) => d.data()).toList();

        // ---- Today aggregates (cross-stadium) ----
        int todayBookings = 0, todayPlayers = 0, todayRevenue = 0;
        // Per-stadium today
        final perStadium = <String, Map<String, int>>{
          'MD9 MAIN': {'b': 0, 'p': 0, 'r': 0},
          'MD9 2':    {'b': 0, 'p': 0, 'r': 0},
        };
        // ---- Week aggregates ----
        int weekBookings = 0, weekRevenue = 0;
        // ---- Upcoming bookings (next 24h) ----
        final upcoming = <Map<String, dynamic>>[];

        for (final b in allBookings) {
          final stadium = b['stadiumName'] as String? ?? '';
          final players = ((b['players'] as List?) ?? []).length;
          final price = _priceOf(b);
          final bd = _parseBookingDateTime(b, now);

          if (b['date'] == todayStr) {
            todayBookings++;
            todayPlayers += players;
            todayRevenue += price;
            final ps = perStadium[stadium];
            if (ps != null) {
              ps['b'] = ps['b']! + 1;
              ps['p'] = ps['p']! + players;
              ps['r'] = ps['r']! + price;
            }
          }

          if (bd != null && bd.isAfter(weekAgo) && bd.isBefore(now.add(const Duration(days: 1)))) {
            weekBookings++;
            weekRevenue += price;
          }

          if (bd != null && bd.isAfter(now) && bd.isBefore(now.add(const Duration(hours: 24)))) {
            upcoming.add(b);
          }
        }

        upcoming.sort((a, b) {
          final da = _parseBookingDateTime(a, now);
          final db = _parseBookingDateTime(b, now);
          if (da == null || db == null) return 0;
          return da.compareTo(db);
        });

        // Estimated capacity for occupancy: 2 stadiums × 8 default slots = 16
        const capacityToday = 16;
        final occupancyPct = capacityToday == 0 ? 0 : ((todayBookings / capacityToday) * 100).round();

        return ListView(padding: const EdgeInsets.all(16), children: [
          // ===== HERO: Today's headline =====
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accentGreen.withValues(alpha: 0.18), accentGreen.withValues(alpha: 0.04)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(radiusXl),
              border: Border.all(color: accentGreen.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: accentGreen.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.dashboard_rounded, color: accentGreen, size: 26),
              ),
              const SizedBox(width: spaceMd),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    tr('סקירה כללית', 'OVERVIEW'),
                    style: const TextStyle(color: accentGreen, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 2),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${tr('היום', 'Today')} • $todayStr',
                    style: const TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: spaceMd),

          // ===== KPIs grid (2x2) =====
          Row(children: [
            Expanded(child: _kpi(tr('הזמנות היום', 'BOOKINGS'), '$todayBookings', Icons.calendar_today_rounded, accentGreen)),
            const SizedBox(width: spaceSm),
            Expanded(child: _kpi(tr('הכנסות היום', 'REVENUE'), '₪$todayRevenue', Icons.payments_rounded, Colors.amber)),
          ]),
          const SizedBox(height: spaceSm),
          Row(children: [
            Expanded(child: _kpi(tr('שחקנים', 'PLAYERS'), '$todayPlayers', Icons.people_rounded, Colors.blue)),
            const SizedBox(width: spaceSm),
            Expanded(child: _kpi(tr('תפוסה', 'OCCUPANCY'), '$occupancyPct%', Icons.donut_large_rounded, Colors.purple)),
          ]),

          const SizedBox(height: spaceLg),

          // ===== Per-stadium snapshot =====
          _secTitle(tr('פעילות לפי מגרש — היום', 'BY STADIUM — TODAY')),
          const SizedBox(height: spaceSm),
          _stadiumCard('MD9 MAIN', perStadium['MD9 MAIN']!),
          const SizedBox(height: spaceXs),
          _stadiumCard('MD9 2', perStadium['MD9 2']!),

          const SizedBox(height: spaceLg),

          // ===== Week summary =====
          _secTitle(tr('שבוע אחרון', 'LAST 7 DAYS')),
          const SizedBox(height: spaceSm),
          Container(
            padding: const EdgeInsets.all(spaceMd),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(radiusLg),
              border: Border.all(color: borderColor),
            ),
            child: IntrinsicHeight(
              child: Row(children: [
                Expanded(child: appStatCell('$weekBookings', tr('הזמנות', 'BOOKINGS'))),
                Container(width: 1, color: borderColor),
                Expanded(child: appStatCell('₪$weekRevenue', tr('הכנסות', 'REVENUE'))),
                Container(width: 1, color: borderColor),
                Expanded(child: appStatCell(
                  weekBookings == 0 ? '₪0' : '₪${(weekRevenue / weekBookings).round()}',
                  tr('ממוצע', 'AVG'),
                )),
              ]),
            ),
          ),

          const SizedBox(height: spaceLg),

          // ===== Upcoming bookings (next 24h) =====
          Row(children: [
            _secTitle(tr('הזמנות קרובות (24 שעות)', 'UPCOMING (NEXT 24H)')),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accentGreen.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(radiusXs),
              ),
              child: Text('${upcoming.length}', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: spaceSm),
          if (upcoming.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(radiusLg),
                border: Border.all(color: borderColor),
              ),
              child: Row(children: [
                const Icon(Icons.event_busy_outlined, color: textSecondary, size: 24),
                const SizedBox(width: spaceSm),
                Expanded(child: Text(tr('אין הזמנות ב-24 השעות הקרובות', 'No bookings in the next 24 hours'), style: const TextStyle(color: textSecondary, fontSize: 13))),
              ]),
            )
          else
            ...upcoming.take(8).map((b) => _upcomingTile(b, now)),

          const SizedBox(height: spaceLg),

          // ===== Venue customization =====
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => navigateTo(context, const VenueImageScreen(venueId: 'md9', venueName: 'MD9')),
              icon: const Icon(Icons.image_outlined, size: 18, color: Colors.purple),
              label: Text(
                tr('תמונת רקע למתחם MD9', 'MD9 Venue Background Image'),
                style: const TextStyle(color: Colors.purple, fontSize: 13, fontWeight: FontWeight.w800),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.purple.withValues(alpha: 0.4)),
                backgroundColor: cardColor,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
              ),
            ),
          ),
          const SizedBox(height: spaceSm),

          // ===== Export action =====
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => exportToCSV(context, allBookings, 'md9_bookings'),
              icon: const Icon(Icons.download_outlined, size: 18, color: accentGreen),
              label: Text(
                tr('ייצוא כל הזמנות MD9', 'Export All MD9 Bookings'),
                style: const TextStyle(color: accentGreen, fontSize: 13, fontWeight: FontWeight.w800),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: accentGreen.withValues(alpha: 0.4)),
                backgroundColor: cardColor,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
              ),
            ),
          ),
        ]);
      },
    );
  }

  Widget _kpi(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(spaceMd),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(radiusLg),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: color, size: 18),
            ),
            const Spacer(),
          ]),
          const SizedBox(height: spaceSm),
          Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w900), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: textSecondary, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _stadiumCard(String name, Map<String, int> stats) {
    final b = stats['b']!;
    final p = stats['p']!;
    final r = stats['r']!;
    return Container(
      padding: const EdgeInsets.all(spaceMd),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(radiusLg),
        border: Border.all(color: borderColor),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.sports_soccer_rounded, color: accentGreen, size: 22),
        ),
        const SizedBox(width: spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1)),
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.calendar_today_outlined, color: textSecondary, size: 12),
                const SizedBox(width: 4),
                Text('$b', style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Icon(Icons.people_outline, color: textSecondary, size: 12),
                const SizedBox(width: 4),
                Text('$p', style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ],
          ),
        ),
        Text('₪$r', style: const TextStyle(color: accentGreen, fontSize: 16, fontWeight: FontWeight.w900)),
      ]),
    );
  }

  Widget _upcomingTile(Map<String, dynamic> b, DateTime now) {
    final stadium = b['stadiumName'] as String? ?? '';
    final time    = b['time']        as String? ?? '';
    final user    = b['userName']    as String? ?? '';
    final phone   = b['phone']       as String? ?? '';
    final dt      = _parseBookingDateTime(b, now);
    final isToday = dt != null && dt.year == now.year && dt.month == now.month && dt.day == now.day;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: spaceSm + 2, vertical: spaceSm),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(radiusMd),
        border: Border.all(color: borderColor),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isToday ? accentGreen.withValues(alpha: 0.15) : Colors.blue.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(radiusXs),
          ),
          child: Text(
            isToday ? tr('היום', 'TODAY') : tr('מחר', 'TOMORROW'),
            style: TextStyle(
              color: isToday ? accentGreen : Colors.blue,
              fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(width: spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$stadium • $time',
                style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w800),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
              if (user.isNotEmpty || phone.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  [user, phone].where((s) => s.isNotEmpty).join(' • '),
                  style: const TextStyle(color: textSecondary, fontSize: 11),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ]),
    );
  }
}

// ==================== ADMIN STADIUM TAB ====================
class AdminStadiumTab extends StatefulWidget {
  final String stadiumName, stadiumId;
  final int price;
  const AdminStadiumTab({super.key, required this.stadiumName, required this.stadiumId, required this.price});
  @override State<AdminStadiumTab> createState() => _AdminStadiumTabState();
}
class _AdminStadiumTabState extends State<AdminStadiumTab> with SingleTickerProviderStateMixin {
  int _selDay = 0;
  String _search = '';
  late List<Map<String, String>> _days;
  DateTime _reportFrom = DateTime.now().subtract(const Duration(days: 30));
  DateTime _reportTo = DateTime.now();
  late Stream<QuerySnapshot<Map<String, dynamic>>> _bookingsStream;
  late TabController _tabController;
  int _tabIndex = 0;

  @override void initState() {
    super.initState();
    _buildDays();
    _bookingsStream = FirebaseFirestore.instance.collection('bookings').where('stadiumName', isEqualTo: widget.stadiumName).snapshots();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() { if (!_tabController.indexIsChanging) setState(() => _tabIndex = _tabController.index); });
  }

  @override void dispose() { _tabController.dispose(); super.dispose(); }

  void _buildDays() {
    final now = DateTime.now();
    _days = List.generate(14, (i) {
      final d = now.add(Duration(days: i));
      return {'name': hebrewWeekday(d.weekday, isHebrew), 'date': '${d.day}/${d.month}', 'full': '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}' };
    });
  }

  String get _docId => '${widget.stadiumId}_${_days[_selDay]['full']}';

  List<Map<String, String>> _getDaySlots(Map<String, dynamic>? schedData) {
    if (schedData != null && schedData['slots'] != null) {
      final raw = schedData['slots'] as List;
      return raw.map((s) => {'start': s['start'] as String, 'end': s['end'] as String}).toList();
    }
    return List.from(defaultSlots);
  }

  // Converts "HH:mm" to minutes since midnight for comparison
  int _toMinutes(String t) {
    if (t == '00:00') return 24 * 60;
    final p = t.split(':');
    return int.parse(p[0]) * 60 + int.parse(p[1]);
  }

  Future<void> _editSlot(Map<String, String> slot, int index, Set<String> bookedLabels, List<Map<String,String>> currentSlots) async {
    final label = _slotLabel(slot);
    if (bookedLabels.contains(label)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('לא ניתן לערוך שעה תפוסה', 'Cannot edit a booked slot')),
        backgroundColor: Colors.red));
      return;
    }

    String selStart = slot['start']!;
    String selEnd   = slot['end']!;

    // Boundaries from adjacent slots
    final prevEnd  = index > 0 ? currentSlots[index - 1]['end']! : '00:00';
    final nextStart = index < currentSlots.length - 1 ? currentSlots[index + 1]['start']! : '00:00';
    final prevMins  = index > 0 ? _toMinutes(prevEnd) : 0;
    final nextMins  = index < currentSlots.length - 1 ? _toMinutes(nextStart) : 24 * 60;

    await showDialog(context: context, builder: (_) => StatefulBuilder(
      builder: (ctx, setS) {
        final startMins = _toMinutes(selStart);
        final endMins   = _toMinutes(selEnd);
        final overlap   = startMins >= endMins || startMins < prevMins || endMins > nextMins;
        final errorMsg  = overlap
            ? (startMins >= endMins
                ? tr('שעת סיום חייבת להיות אחרי ההתחלה', 'End must be after start')
                : startMins < prevMins
                    ? tr('חפיפה עם המשבצת הקודמת', 'Overlaps with previous slot')
                    : tr('חפיפה עם המשבצת הבאה', 'Overlaps with next slot'))
            : '';

        return AlertDialog(
          backgroundColor: cardColor,
          title: Text(tr('עריכת משבצת', 'Edit Slot'),
              style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            // Previous slot boundary hint
            if (index > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  tr('המשבצת הקודמת מסתיימת ב-$prevEnd', 'Previous slot ends at $prevEnd'),
                  style: const TextStyle(color: textSecondary, fontSize: 11)),
              ),

            // Start time
            Text(tr('שעת התחלה', 'Start time'),
                style: const TextStyle(color: textSecondary, fontSize: 12, letterSpacing: 1)),
            const SizedBox(height: 6),
            DropdownButton<String>(
              value: selStart, dropdownColor: cardColor, isExpanded: true,
              items: allStartTimes.map((t) => DropdownMenuItem(
                value: t,
                child: Text(t, style: const TextStyle(color: textPrimary)))).toList(),
              onChanged: (v) => setS(() {
                selStart = v!;
                selEnd = _addTwoHours(selStart);
              }),
            ),
            const SizedBox(height: 12),

            // End time
            Text(tr('שעת סיום', 'End time'),
                style: const TextStyle(color: textSecondary, fontSize: 12, letterSpacing: 1)),
            const SizedBox(height: 6),
            DropdownButton<String>(
              value: allStartTimes.contains(selEnd) ? selEnd : allStartTimes.last,
              dropdownColor: cardColor, isExpanded: true,
              items: allStartTimes.map((t) => DropdownMenuItem(
                value: t,
                child: Text(t, style: const TextStyle(color: textPrimary)))).toList(),
              onChanged: (v) => setS(() => selEnd = v!),
            ),

            // Next slot boundary hint
            if (index < currentSlots.length - 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr('המשבצת הבאה מתחילה ב-$nextStart', 'Next slot starts at $nextStart'),
                  style: const TextStyle(color: textSecondary, fontSize: 11)),
              ),

            // Overlap error
            if (errorMsg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 14),
                    const SizedBox(width: 6),
                    Expanded(child: Text(errorMsg,
                        style: const TextStyle(color: Colors.red, fontSize: 12))),
                  ]),
                ),
              ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('ביטול', 'Cancel'),
                  style: const TextStyle(color: textSecondary))),
            ElevatedButton(
              onPressed: overlap ? null : () async {
                final newSlots = List<Map<String,String>>.from(currentSlots);
                newSlots[index] = {'start': selStart, 'end': selEnd};
                await FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).set(
                  {'slots': newSlots.map((s) => {'start': s['start'], 'end': s['end']}).toList()},
                  SetOptions(merge: true));
                if (ctx.mounted) Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: overlap ? Colors.grey[800] : accentGreen,
                foregroundColor: bgColor),
              child: Text(tr('שמור', 'SAVE'),
                  style: const TextStyle(fontWeight: FontWeight.w900))),
          ],
        );
      },
    ));
  }

  Future<void> _toggleBlock(Map<String,String> slot, bool isBlocked, Set<String> bookedLabels) async {
    final label = _slotLabel(slot);
    if (bookedLabels.contains(label)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('לא ניתן לחסום שעה תפוסה', 'Cannot block a booked slot')), backgroundColor: Colors.red));
      return;
    }
    final ref = FirebaseFirestore.instance.collection('admin_schedule').doc(_docId);
    if (isBlocked) {
      await ref.set({'blocked': FieldValue.arrayRemove([label])}, SetOptions(merge: true));
    } else {
      await ref.set({'blocked': FieldValue.arrayUnion([label])}, SetOptions(merge: true));
    }
  }

  Future<void> _resetDay() async => FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).delete();

  Future<void> _showRecurringBlockDialog() async {
    int? dayOfWeek;            // 0=Sun … 6=Sat (matches _weekdayFromDateString)
    String? selectedTime;      // "HH:mm - HH:mm"
    final reasonCtrl = TextEditingController();
    int weeks = 12;            // 4 / 8 / 12 / -1 (unlimited)
    bool saving = false;

    final dayNames = isHebrew
        ? ['ראשון','שני','שלישי','רביעי','חמישי','שישי','שבת']
        : ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(spaceLg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        color: Colors.purple.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(Icons.event_repeat_outlined, color: Colors.purple, size: 32),
                    ),
                  ),
                  const SizedBox(height: spaceMd),
                  Text(
                    tr('הזמנה קבועה שבועית', 'Weekly Recurring Block'),
                    style: const TextStyle(color: textPrimary, fontSize: 20, fontWeight: FontWeight.w900),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: spaceLg),
                  // Day of week
                  Text(tr('יום בשבוע', 'Day of Week'), style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int>(
                    value: dayOfWeek,
                    dropdownColor: cardColor,
                    style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: bgSecondary,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: accentGreen, width: 2)),
                    ),
                    items: List.generate(7, (i) => DropdownMenuItem(value: i, child: Text(dayNames[i]))),
                    onChanged: (v) => setS(() => dayOfWeek = v),
                  ),
                  const SizedBox(height: spaceMd),
                  // Time slot
                  Text(tr('שעה', 'Time'), style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: selectedTime,
                    dropdownColor: cardColor,
                    style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: bgSecondary,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: accentGreen, width: 2)),
                    ),
                    items: defaultSlots.map((s) {
                      final label = '${s['start']} - ${s['end']}';
                      return DropdownMenuItem(value: label, child: Text(label));
                    }).toList(),
                    onChanged: (v) => setS(() => selectedTime = v),
                  ),
                  const SizedBox(height: spaceMd),
                  // Reason
                  Text(tr('סיבה / שם לקוח', 'Reason / Customer'), style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonCtrl,
                    style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      hintText: tr('לדוגמה: קבוצת בית ספר', 'e.g. School team'),
                      hintStyle: const TextStyle(color: textTertiary, fontSize: 13),
                      filled: true,
                      fillColor: bgSecondary,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: accentGreen, width: 2)),
                    ),
                  ),
                  const SizedBox(height: spaceMd),
                  // Weeks
                  Text(tr('כמה שבועות', 'How many weeks'), style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final w in [4, 8, 12, -1])
                        ChoiceChip(
                          label: Text(w == -1 ? tr('ללא הגבלה', 'Unlimited') : '$w ${tr('שבועות', 'weeks')}'),
                          selected: weeks == w,
                          onSelected: (_) => setS(() => weeks = w),
                          backgroundColor: bgSecondary,
                          selectedColor: accentGreen.withValues(alpha: 0.2),
                          labelStyle: TextStyle(
                            color: weeks == w ? accentGreen : textSecondary,
                            fontWeight: weeks == w ? FontWeight.w800 : FontWeight.w500,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(radiusSm),
                            side: BorderSide(color: weeks == w ? accentGreen : borderColor),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: spaceLg),
                  // Buttons
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: borderColor),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                        ),
                        child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary, fontSize: 14, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: spaceSm),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: saving ? null : () async {
                          if (dayOfWeek == null || selectedTime == null) {
                            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text(tr('בחר יום ושעה', 'Pick day and time')),
                              backgroundColor: colorError,
                            ));
                            return;
                          }
                          setS(() => saving = true);
                          try {
                            await FirebaseFirestore.instance.collection('recurring_blocks').add({
                              'stadiumId':  widget.stadiumId,
                              'stadiumName': widget.stadiumName,
                              'dayOfWeek':  dayOfWeek,
                              'dayName':    dayNames[dayOfWeek!],
                              'time':       selectedTime,
                              'reason':     reasonCtrl.text.trim(),
                              'weeks':      weeks,
                              'createdAt':  DateTime.now().toIso8601String(),
                              'active':     true,
                            });
                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(tr('הזמנה קבועה נוספה ✓', 'Recurring block added ✓')),
                                backgroundColor: accentGreen,
                                duration: const Duration(seconds: 3),
                              ));
                            }
                          } catch (e) {
                            setS(() => saving = false);
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                content: Text(tr('שגיאה בשמירה', 'Error saving')),
                                backgroundColor: colorError,
                              ));
                            }
                          }
                        },
                        icon: saving
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: bgColor))
                            : const Icon(Icons.save_outlined, size: 18),
                        label: Text(
                          saving ? tr('שומר...', 'Saving...') : tr('שמור', 'Save'),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentGreen,
                          foregroundColor: bgColor,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _cancelRecurringBlock(String docId, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cardColor,
        title: Text(tr('ביטול הזמנה קבועה?', 'Cancel Recurring Block?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
        content: Text(tr('זה יסיר את ה"$label" מכל השבועות הבאים.', 'This removes "$label" from all upcoming weeks.'), style: const TextStyle(color: textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('השאר', 'KEEP'), style: const TextStyle(color: textSecondary))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('בטל', 'CANCEL'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FirebaseFirestore.instance.collection('recurring_blocks').doc(docId).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('ההזמנה הקבועה בוטלה ✓', 'Recurring block cancelled ✓')),
          backgroundColor: accentGreen,
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('שגיאה בביטול', 'Error cancelling')),
          backgroundColor: colorError,
        ));
      }
    }
  }

  Widget _buildBookingsList({required bool upcoming}) {
    // Cap to 200 most-recent bookings per stadium. Older ones live in
    // exports/reports tab. Keeps reads + memory bounded as data grows.
    return StreamBuilder(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .where('stadiumName', isEqualTo: widget.stadiumName)
          .limit(200)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
        final now = DateTime.now();
        var docs = snap.data!.docs.where((d) {
          final b = d.data();
          try {
            final parts = (b['date'] as String).split('/');
            final h = int.parse((b['time'] as String).split(':')[0]);
            final bookingDate = DateTime(now.year, int.parse(parts[1]), int.parse(parts[0]), h);
            return upcoming ? bookingDate.isAfter(now) : bookingDate.isBefore(now);
          } catch(_) { return upcoming; }
        }).toList()
          ..sort((a, b) {
            try {
              final pa = (a.data()['date'] as String).split('/');
              final pb = (b.data()['date'] as String).split('/');
              final ha = int.parse((a.data()['time'] as String).split(':')[0]);
              final hb = int.parse((b.data()['time'] as String).split(':')[0]);
              final da = DateTime(DateTime.now().year, int.parse(pa[1]), int.parse(pa[0]), ha);
              final db = DateTime(DateTime.now().year, int.parse(pb[1]), int.parse(pb[0]), hb);
              return upcoming ? da.compareTo(db) : db.compareTo(da);
            } catch(_) { return 0; }
          });

        // Search filter
        if (_search.isNotEmpty) {
          docs = docs.where((d) {
            final b = d.data();
            return (b['userName'] as String? ?? '').toLowerCase().contains(_search.toLowerCase()) ||
                   (b['date'] as String? ?? '').contains(_search) ||
                   (b['phone'] as String? ?? '').contains(_search);
          }).toList();
        }

        if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(upcoming ? Icons.calendar_today_outlined : Icons.history, color: const Color(0xFF333333), size: 48),
          const SizedBox(height: 12),
          Text(upcoming ? tr('אין הזמנות עתידיות','No upcoming bookings') : tr('אין היסטוריה','No history'), style: const TextStyle(color: textSecondary)),
        ]));

        final allBookings = docs.map((d) => d.data()).toList();
        return ListView(padding: const EdgeInsets.all(12), children: [
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () => exportToCSV(context, allBookings, '${widget.stadiumId}_${upcoming ? 'upcoming' : 'history'}'),
            icon: const Icon(Icons.download_outlined, size: 16),
            label: Text(upcoming ? tr('ייצוא עתידיות','Export Upcoming') : tr('ייצוא היסטוריה','Export History')),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          )),
          const SizedBox(height: 12),
          ...docs.map((d) => _adminBookCard(d.data(), docId: d.id, context: context)),
        ]);
      },
    );
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filterByRange(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, DateTime from, DateTime to) {
    return docs.where((d) {
      try {
        final parts = (d.data()['date'] as String).split('/');
        final date = DateTime(DateTime.now().year, int.parse(parts[1]), int.parse(parts[0]));
        return !date.isBefore(DateTime(from.year, from.month, from.day)) &&
               !date.isAfter(DateTime(to.year, to.month, to.day));
      } catch (_) { return false; }
    }).toList();
  }

  Widget _periodRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required String exportName,
  }) {
    final rev = docs.fold(0, (s, d) => s + (int.tryParse((d.data()['price'] as String? ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: cardColor, border: Border.all(color: borderColor)),
      child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(width: 3, color: color),
        Expanded(child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(title, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(
          '${docs.length} ${tr('הזמנות', 'bookings')}  ·  ₪$rev  ·  $subtitle',
          style: TextStyle(color: docs.isEmpty ? textSecondary : color.withValues(alpha: 0.8), fontSize: 11),
        ),
        trailing: docs.isEmpty
          ? const Icon(Icons.download_outlined, color: borderColor, size: 22)
          : IconButton(
              icon: Icon(Icons.download_outlined, color: color, size: 22),
              tooltip: tr('ייצוא', 'Export'),
              onPressed: () => exportToCSV(context, docs.map((d) => d.data()).toList(), exportName),
            ),
        )),
      ])),
    ));
  }

  Widget _chip(String value, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
      Text(label, style: const TextStyle(color: textSecondary, fontSize: 9)),
    ]),
  );

  Widget _buildStadiumReports() {
    return StreamBuilder(
      stream: _bookingsStream,
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
        final docs = snap.data!.docs;
        final now = DateTime.now();

        final dayDocs   = _filterByRange(docs, DateTime(now.year, now.month, now.day), now);
        final weekStart = now.subtract(Duration(days: now.weekday - 1));
        final weekDocs  = _filterByRange(docs, weekStart, now);
        final monthDocs = _filterByRange(docs, DateTime(now.year, now.month, 1), now);
        final customDocs = _filterByRange(docs, _reportFrom, _reportTo);

        final monthNames   = ['','ינואר','פברואר','מרץ','אפריל','מאי','יוני','יולי','אוגוסט','ספטמבר','אוקטובר','נובמבר','דצמבר'];
        final monthNamesEn = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

        final Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> byMonth = {};
        for (final d in docs) {
          try {
            final parts = (d.data()['date'] as String).split('/');
            final key = '${parts[1]}/${now.year}';
            byMonth.putIfAbsent(key, () => []).add(d);
          } catch (_) {}
        }
        final sortedMonths = byMonth.keys.toList()
          ..sort((a, b) => (int.tryParse(b.split('/')[0]) ?? 0).compareTo(int.tryParse(a.split('/')[0]) ?? 0));

        // Custom date-picker helper
        Widget datePicker(DateTime val, bool isFrom) => GestureDetector(
          onTap: () async {
            final picked = await showDatePicker(
              context: context, initialDate: val,
              firstDate: DateTime(2024),
              lastDate: isFrom ? DateTime.now() : DateTime.now().add(const Duration(days: 1)),
              builder: (_, child) => Theme(data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: accentGreen, surface: cardColor)), child: child!));
            if (picked != null) setState(() { if (isFrom) _reportFrom = picked; else _reportTo = picked; });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: accentGreen.withValues(alpha: 0.35))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.calendar_today_outlined, color: accentGreen, size: 13),
              const SizedBox(width: 5),
              Text('${val.day}/${val.month}/${val.year}', style: const TextStyle(color: accentGreen, fontSize: 12, fontWeight: FontWeight.bold)),
            ]),
          ),
        );

        final customRev = customDocs.fold(0, (s, d) => s + (int.tryParse((d.data()['price'] as String? ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0));
        final customPlayers = customDocs.fold(0, (s, d) => s + ((d.data()['players'] as List?)?.length ?? 0));

        return ListView(padding: const EdgeInsets.all(14), children: [
          // ── header ──
          _secTitle(tr('ייצוא מהיר', 'QUICK EXPORT')), const SizedBox(height: 10),

          _periodRow(icon: Icons.today, color: accentGreen, title: tr('יומי', 'Daily'),
            subtitle: '${now.day}/${now.month}/${now.year}', docs: dayDocs,
            exportName: '${widget.stadiumId}_daily_${now.day}-${now.month}'),

          _periodRow(icon: Icons.date_range, color: Colors.blue, title: tr('שבועי', 'Weekly'),
            subtitle: tr('${weekStart.day}/${weekStart.month} — ${now.day}/${now.month}', '${weekStart.day}/${weekStart.month} — ${now.day}/${now.month}'),
            docs: weekDocs, exportName: '${widget.stadiumId}_weekly_${weekStart.day}-${weekStart.month}'),

          _periodRow(icon: Icons.calendar_month, color: Colors.purple, title: tr('חודשי', 'Monthly'),
            subtitle: tr(monthNames[now.month], monthNamesEn[now.month]) + ' ${now.year}',
            docs: monthDocs, exportName: '${widget.stadiumId}_monthly_${now.month}-${now.year}'),

          const SizedBox(height: 4),

          // ── custom range card ──
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: cardColor, border: Border.all(color: borderColor)),
            child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 3, color: Colors.orange),
              Expanded(child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.tune, color: Colors.orange, size: 18)),
                const SizedBox(width: 10),
                Text(tr('טווח מותאם', 'Custom Range'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                datePicker(_reportFrom, true),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('→', style: TextStyle(color: textSecondary, fontSize: 16))),
                datePicker(_reportTo, false),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                _chip('${customDocs.length}', tr('הזמנות', 'bookings'), Colors.orange),
                const SizedBox(width: 6),
                _chip('$customPlayers', tr('שחקנים', 'players'), Colors.blue),
                const SizedBox(width: 6),
                _chip('₪$customRev', tr('הכנסות', 'revenue'), accentGreen),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: customDocs.isEmpty ? null : () => exportToCSV(context, customDocs.map((d) => d.data()).toList(),
                    '${widget.stadiumId}_custom_${_reportFrom.day}-${_reportFrom.month}_${_reportTo.day}-${_reportTo.month}'),
                  icon: const Icon(Icons.download_outlined, size: 14),
                  label: Text(tr('ייצוא', 'Export'), style: const TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: customDocs.isEmpty ? borderColor : Colors.orange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                ),
              ]),
            ]),
          )),
        ])),
      )),
          const SizedBox(height: 12),
          _secTitle(tr('היסטוריה חודשית', 'MONTHLY HISTORY')), const SizedBox(height: 10),

          if (sortedMonths.isEmpty)
            Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(tr('אין נתונים', 'No data'), style: const TextStyle(color: textSecondary)))),

          ...sortedMonths.map((month) {
            final mDocs    = byMonth[month]!;
            final mRev     = mDocs.fold(0, (s, d) => s + (int.tryParse((d.data()['price'] as String? ?? '0').split('/').first.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0));
            final mPlayers = mDocs.fold(0, (s, d) => s + ((d.data()['players'] as List?)?.length ?? 0));
            final mNum     = int.tryParse(month.split('/')[0]) ?? 0;
            final mLabel   = tr(monthNames[mNum], monthNamesEn[mNum]);
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: borderColor)),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                leading: Container(width: 38, height: 38,
                  decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Center(child: Text('$mNum', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 13)))),
                title: Text(mLabel, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text('${mDocs.length} ${tr('הזמנות', 'bookings')}  ·  $mPlayers ${tr('שחקנים', 'players')}',
                  style: const TextStyle(color: textSecondary, fontSize: 11)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('₪$mRev', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.download_outlined, color: accentGreen, size: 20),
                    onPressed: () => exportToCSV(context, mDocs.map((d) => d.data()).toList(), '${widget.stadiumId}_${month.replaceAll('/', '-')}'),
                  ),
                ]),
              ),
            );
          }),
          const SizedBox(height: 16),
        ]);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isReports = _tabIndex == 3;
    return Column(children: [
      if (!isReports) ...[
        // Day selector
        SizedBox(height: 80, child: ListView.builder(
          scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          itemCount: _days.length,
          itemBuilder: (ctx, i) {
            final isSel = _selDay == i;
            return GestureDetector(
              onTap: () => setState(() => _selDay = i),
              child: Container(margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: isSel ? accentGreen : cardColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: isSel ? accentGreen : i==0 ? accentGreen.withValues(alpha: 0.4) : borderColor)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(_days[i]['name']!, style: TextStyle(color: isSel?bgColor:textSecondary, fontWeight: FontWeight.bold, fontSize: 11)),
                  Text(_days[i]['date']!, style: TextStyle(color: isSel?bgColor.withValues(alpha: 0.7):const Color(0xFF555555), fontSize: 10)),
                  if (i==0) Text(tr('היום', 'TODAY'), style: TextStyle(color: isSel?bgColor:accentGreen, fontSize: 8, fontWeight: FontWeight.w900)),
                ]),
              ),
            );
          },
        )),
        // Search bar
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: TextField(
          onChanged: (v) => setState(() => _search = v),
          style: const TextStyle(color: textPrimary, fontSize: 13),
          decoration: InputDecoration(
            hintText: tr('חפש לפי שם, תאריך, טלפון...', 'Search by name, date, phone...'),
            hintStyle: const TextStyle(color: textSecondary, fontSize: 12),
            prefixIcon: const Icon(Icons.search, color: textSecondary, size: 18),
            filled: true, fillColor: cardColor, contentPadding: const EdgeInsets.symmetric(vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accentGreen, width: 1.5)),
          ),
        )),
      ],
      // Tabs
      TabBar(
        controller: _tabController,
        indicatorColor: accentGreen, labelColor: accentGreen, unselectedLabelColor: textSecondary,
        isScrollable: true,
        tabs: [
          Tab(text: tr('לוח זמנים','Schedule')),
          Tab(text: tr('עתידיות 📅','Upcoming 📅')),
          Tab(text: tr('היסטוריה 📖','History 📖')),
          Tab(text: tr('דוחות 📊','Reports 📊')),
        ],
      ),
      Expanded(child: TabBarView(controller: _tabController, children: [
        _buildScheduleView(),
        _buildBookingsList(upcoming: true),
        _buildBookingsList(upcoming: false),
        _buildStadiumReports(),
      ])),
    ]);
  }

  Widget _buildScheduleView() {
    return StreamBuilder(
      stream: FirebaseFirestore.instance.collection('recurring_blocks').where('stadiumId', isEqualTo: widget.stadiumId).snapshots(),
      builder: (ctx, recurSnap) {
        final recurringBlocks = (recurSnap.data?.docs ?? []).map((d) => {'id': d.id, ...d.data()}).toList();
        return StreamBuilder(
      stream: FirebaseFirestore.instance.collection('training_groups').where('stadiumId', isEqualTo: widget.stadiumId).snapshots(),
      builder: (ctx, trainSnap) {
        // ignore: unused_local_variable
        final trainingGroups = (trainSnap.data?.docs ?? []).map((d) => {'id': d.id, ...d.data()}).toList();
        return StreamBuilder(
          stream: FirebaseFirestore.instance.collection('bookings').where('stadiumName', isEqualTo: widget.stadiumName).where('date', isEqualTo: _days[_selDay]['date']).snapshots(),
          builder: (ctx, bookSnap) => StreamBuilder(
            stream: FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).snapshots(),
            builder: (ctx, schedSnap) {
          final bookedDocs = bookSnap.data?.docs ?? [];
          final bookedLabels = bookedDocs.map((d) => d.data()['time'] as String).toSet();
          final schedData = schedSnap.hasData && schedSnap.data!.exists ? schedSnap.data!.data() : null;
          final blockedLabels = schedData != null ? Set<String>.from(schedData['blocked'] ?? []) : <String>{};
          final slots = _getDaySlots(schedData);
          final isToday = _selDay == 0;
          final now = DateTime.now();
          final selectedDate = _days[_selDay]['date']!;
          final dayBookings = bookedDocs
              .where((b) => (b.data()['date'] as String?) == selectedDate)
              .map((d) => d.data())
              .toList();
          final totalBookings = dayBookings.length;
          final totalRevenue = totalBookings * widget.price;

          return ListView(padding: const EdgeInsets.all(spaceSm), children: [
            appCard(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: IntrinsicHeight(
                child: Row(children: [
                  Expanded(child: appStatCell('$totalBookings', tr('הזמנות','BOOKINGS'))),
                  Container(width: 1, color: borderColor),
                  Expanded(child: appStatCell('₪$totalRevenue', tr('הכנסות','REVENUE'))),
                ]),
              ),
            ),
            const SizedBox(height: spaceMd),
            appPrimaryButton(
              label: tr('הוסף הזמנה ידנית','Add Manual Booking'),
              icon: Icons.add_circle_outline,
              onPressed: () => showManualBookingDialog(context, widget.stadiumName, widget.stadiumId, widget.price),
            ),
            const SizedBox(height: spaceMd),
            Row(children: [
              Expanded(child: appToolButton(
                icon: Icons.category_outlined,
                label: tr('סוגים','Types'),
                onTap: () => navigateTo(context, BookingTypesScreen(stadiumId: widget.stadiumId, stadiumName: widget.stadiumName)),
              )),
              const SizedBox(width: spaceXs),
              Expanded(child: appToolButton(
                icon: Icons.image_outlined,
                label: tr('תמונה','Image'),
                onTap: () => navigateTo(context, StadiumImageScreen(stadiumId: widget.stadiumId, stadiumName: widget.stadiumName)),
              )),
              const SizedBox(width: spaceXs),
              Expanded(child: appToolButton(
                icon: Icons.groups_outlined,
                label: tr('קבוצות','Groups'),
                onTap: () => navigateTo(context, TrainingGroupsAdminScreen(stadiumId: widget.stadiumId, stadiumName: widget.stadiumName)),
              )),
              const SizedBox(width: spaceXs),
              Expanded(child: appToolButton(
                icon: Icons.file_download_outlined,
                label: tr('ייצוא','Export'),
                onTap: dayBookings.isEmpty ? null : () => exportToCSV(context, dayBookings, '${widget.stadiumId}_${_days[_selDay]['date']}'),
              )),
            ]),
            const SizedBox(height: spaceSm),
            SizedBox(
              width: double.infinity, height: 46,
              child: OutlinedButton.icon(
                onPressed: () => _showRecurringBlockDialog(),
                icon: const Icon(Icons.event_repeat_outlined, size: 18, color: Colors.purple),
                label: Text(
                  tr('הזמנה קבועה שבועית', 'Weekly Recurring Block'),
                  style: const TextStyle(color: Colors.purple, fontSize: 13, fontWeight: FontWeight.w800),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.purple.withValues(alpha: 0.4)),
                  backgroundColor: Colors.purple.withValues(alpha: 0.06),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              _secTitle('${tr('לוח זמנים', 'SCHEDULE')} — ${_days[_selDay]['date']}'), const Spacer(),
              if (schedData != null && schedData['slots'] != null)
                TextButton(onPressed: _resetDay, child: Text(tr('איפוס', 'RESET'), style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.w900))),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              _dot(accentGreen, tr('פנוי','Free')), const SizedBox(width: 12),
              _dot(Colors.orange, tr('תפוס','Booked')), const SizedBox(width: 12),
              _dot(Colors.red, tr('חסום','Blocked')), const SizedBox(width: 12),
              _dot(Colors.purple, tr('קבוע','Fixed')),
            ]),
            const SizedBox(height: 12),
            ...slots.map((slot) {
              final label = _slotLabel(slot);
              final isBooked  = bookedLabels.contains(label);
              final isBlocked = blockedLabels.contains(label);
              final isFixed   = recurringBlockForSlot(recurringBlocks, widget.stadiumId, _days[_selDay]['date']!, label);
              final fixedReason = isFixed ? recurringReasonForSlot(recurringBlocks, widget.stadiumId, _days[_selDay]['date']!, label) : null;
              final fixedId   = isFixed ? recurringIdForSlot(recurringBlocks, widget.stadiumId, _days[_selDay]['date']!, label) : null;
              if (isToday) {
                final h = int.parse(slot['start']!.split(':')[0]);
                if (h < now.hour) return const SizedBox.shrink();
              }
              Color bg, border, textClr;
              if (isBooked)        { bg = Colors.orange.withValues(alpha: 0.1); border = Colors.orange.withValues(alpha: 0.5); textClr = Colors.orange; }
              else if (isFixed)    { bg = Colors.purple.withValues(alpha: 0.1); border = Colors.purple.withValues(alpha: 0.5); textClr = Colors.purple; }
              else if (isBlocked)  { bg = Colors.red.withValues(alpha: 0.08);   border = Colors.red.withValues(alpha: 0.4);    textClr = Colors.red; }
              else                 { bg = cardColor; border = accentGreen.withValues(alpha: 0.3); textClr = textPrimary; }
              return GestureDetector(
                onLongPress: (isFixed && fixedId != null) ? () => _cancelRecurringBlock(fixedId, label) : null,
                child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: border)),
                child: Row(children: [
                  SizedBox(width: 120, child: Text(label, style: TextStyle(color: textClr, fontWeight: FontWeight.w900, fontSize: 15))),
                  if (isBooked)        _badge(tr('תפוס','BOOKED'), Colors.orange)
                  else if (isFixed)    _badge(fixedReason ?? tr('קבוע', 'FIXED'), Colors.purple)
                  else if (isBlocked)  _badge(tr('חסום','BLOCKED'), Colors.red)
                  else                 _badge(tr('פנוי','FREE'), accentGreen),
                  const Spacer(),
                  if (isFixed) ...[
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      color: Colors.purple,
                      tooltip: tr('בטל הזמנה קבועה', 'Cancel recurring'),
                      onPressed: fixedId != null ? () => _cancelRecurringBlock(fixedId, label) : null,
                    ),
                  ] else if (!isBooked) ...[
                    IconButton(icon: const Icon(Icons.edit_outlined, size: 18), color: textSecondary, onPressed: () => _editSlot(slot, slots.indexOf(slot), bookedLabels, slots)),
                    IconButton(icon: Icon(isBlocked ? Icons.lock_open_outlined : Icons.block_outlined, size: 18), color: isBlocked ? accentGreen : Colors.red, onPressed: () => _toggleBlock(slot, isBlocked, bookedLabels)),
                  ] else ...[
                    Builder(builder: (ctx) {
                      try {
                        final match = bookedDocs.where((d) => d.data()['time'] == label);
                        if (match.isNotEmpty) {
                          final bookingData = match.first.data();
                          final count = ((bookingData['players'] as List?) ?? []).length;
                          final phone = bookingData['phone'] as String? ?? '';
                          return GestureDetector(
                            onTap: () => showBookingDetails(context, bookingData, isAdmin: true, docId: match.first.id),
                            child: Row(children: [
                              if (phone.isNotEmpty) ...[Text(phone, style: const TextStyle(color: accentGreen, fontSize: 11)), const SizedBox(width: 4)],
                              Text('$count/18', style: const TextStyle(color: textSecondary, fontSize: 12)),
                              const SizedBox(width: 4),
                              const Icon(Icons.info_outline, color: accentGreen, size: 16),
                            ]),
                          );
                        }
                        return Text(tr('תפוס','booked'), style: const TextStyle(color: textSecondary, fontSize: 12));
                      } catch (_) { return Text(tr('תפוס','booked'), style: const TextStyle(color: textSecondary, fontSize: 12)); }
                    }),
                  ],
                ]),
              ),
              );
            }),
            const SizedBox(height: 8),
            Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blue.withValues(alpha: 0.2))),
              child: Row(children: [const Icon(Icons.info_outline, color: Colors.blue, size: 14), const SizedBox(width: 8), Expanded(child: Text('✏️ ${tr('ערוך','Edit')}  🚫 ${tr('חסום/בטל','Block')}  ℹ️ ${tr('לחץ לפרטים + ביטול','Tap for details + cancel')}', style: const TextStyle(color: Colors.blue, fontSize: 11)))])),
          ]);
        },
      ),
    );
    },
  );
    },
  );
  }

  Widget _dot(Color c, String l) => Row(children: [Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)), const SizedBox(width: 3), Text(l, style: const TextStyle(color: textSecondary, fontSize: 10))]);
  Widget _badge(String t, Color c) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withValues(alpha: 0.4))), child: Text(t, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w900)));
}

// ==================== SINGLE ADMIN ====================
class SingleAdminScreen extends StatelessWidget {
  final String stadiumId;
  const SingleAdminScreen({super.key, required this.stadiumId});

  @override
  Widget build(BuildContext context) {
    final s = allStadiums.firstWhere((x) => x['id'] == stadiumId);
    // Resolve the parent venue from the stadium so the admin uploads to
    // the correct venue_config doc (e.g. y_stadium → venue 'y_stadium').
    final venue = venueForStadium(s['id'] as String);
    final venueId = (venue?['id'] as String?) ?? (s['id'] as String);
    final venueNameRaw = isHebrew
        ? (venue?['name'] as String?)
        : (venue?['nameEn'] as String?);
    final venueName = venueNameRaw ?? (s['name'] as String);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: bgColor,
        appBar: AdminAppBar(
          title: Row(children: [
            const Icon(Icons.shield_outlined, color: Colors.amber, size: 20),
            const SizedBox(width: 8),
            Text('${s['name']} ${tr('אדמין', 'ADMIN')}', style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900)),
          ]),
          bottom: TabBar(
            indicatorColor: accentGreen,
            labelColor: accentGreen,
            unselectedLabelColor: textSecondary,
            tabs: [
              Tab(text: tr('לוח זמנים', 'Schedule'), icon: const Icon(Icons.calendar_month_outlined, size: 18)),
              Tab(text: tr('תמונת מתחם', 'Venue Image'), icon: const Icon(Icons.image_outlined, size: 18)),
            ],
          ),
        ),
        body: TabBarView(children: [
          AdminStadiumTab(stadiumName: s['name'], stadiumId: s['id'], price: s['price']),
          VenueImageScreen(venueId: venueId, venueName: venueName),
        ]),
      ),
    );
  }
}

// ==================== VENUE SELECTION ====================
class VenueSelectionScreen extends StatefulWidget {
  const VenueSelectionScreen({super.key});

  @override
  State<VenueSelectionScreen> createState() => _VenueSelectionScreenState();
}

class _VenueSelectionScreenState extends State<VenueSelectionScreen> {
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;
    final isTablet = width >= 700 && width < 1100;
    final crossAxisCount = isMobile ? 1 : (isTablet ? 2 : 3);

    // First name only — keeps the greeting tight in the hero header.
    // Falls back to email-prefix or just "Welcome" if neither is set.
    final user = FirebaseAuth.instance.currentUser;
    final fullName = (user?.displayName ?? '').trim();
    final firstName = fullName.isNotEmpty
        ? fullName.split(RegExp(r'\s+')).first
        : (user?.email?.split('@').first ?? '');
    final greeting = firstName.isNotEmpty
        ? tr('ברוך הבא, $firstName! 👋', 'Welcome, $firstName! 👋')
        : tr('ברוך הבא! 👋', 'Welcome! 👋');

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            // ============== HEADER ==============
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? spaceMd : spaceXl,
                vertical: spaceMd,
              ),
              decoration: const BoxDecoration(
                color: bgColor,
                border: Border(bottom: BorderSide(color: borderColor)),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [accentGreen, accentGreen.withValues(alpha: 0.7)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.stadium_rounded, color: bgColor, size: 22),
                            ),
                            const SizedBox(width: spaceSm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'STADIUM',
                                    style: TextStyle(
                                      color: textPrimary,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (!isMobile)
                                    Text(
                                      tr('בחר את המתחם שלך', 'Choose your venue'),
                                      style: const TextStyle(
                                        color: textSecondary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: spaceMd),
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseAuth.instance.currentUser != null
                            ? FirebaseFirestore.instance
                                .collection('notifications')
                                .where('userId', isEqualTo: FirebaseAuth.instance.currentUser!.uid)
                                .where('read', isEqualTo: false)
                                .snapshots()
                            : null,
                        builder: (ctx, snap) {
                          final unreadCount = snap.data?.docs.length ?? 0;
                          return _topIconButton(
                            icon: Icons.notifications_outlined,
                            onTap: () {
                              navigateTo(context, const NotificationsScreen(),);
                            },
                            badge: unreadCount > 0 ? '$unreadCount' : null,
                          );
                        },
                      ),
                      const SizedBox(width: spaceSm),
                      _menuButton(context),
                    ],
                  ),
                ),
              ),
            ),

            // ============== BODY ==============
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? spaceMd : spaceXl,
                  vertical: spaceMd,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Hero Section
                        Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(isMobile ? spaceMd : spaceLg),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                accentGreen.withValues(alpha: 0.15),
                                accentGreen.withValues(alpha: 0.03),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(radiusXl),
                            border: Border.all(color: accentGreen.withValues(alpha: 0.2)),
                          ),
                          child: Row(children: [
                            Container(
                              width: isMobile ? 44 : 56,
                              height: isMobile ? 44 : 56,
                              decoration: BoxDecoration(
                                color: accentGreen.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(Icons.waving_hand_rounded, color: accentGreen, size: isMobile ? 22 : 28),
                            ),
                            SizedBox(width: isMobile ? spaceSm : spaceMd),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    greeting,
                                    style: TextStyle(
                                      color: textPrimary,
                                      fontSize: isMobile ? 14 : 18,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    tr('בחר מתחם להזמנת מגרש או הרשמה לאימון', 'Pick a venue to book a field or join training'),
                                    style: TextStyle(
                                      color: textSecondary,
                                      fontSize: isMobile ? 11.5 : 13.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ]),
                        ),

                        Builder(builder: (ctx) {
                          final user = FirebaseAuth.instance.currentUser;
                          if (user == null || user.emailVerified) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: spaceMd),
                            child: Container(
                              padding: const EdgeInsets.all(spaceMd),
                              decoration: BoxDecoration(
                                color: colorWarning.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(radiusLg),
                                border: Border.all(color: colorWarning.withValues(alpha: 0.3)),
                              ),
                              child: Row(children: [
                                Container(
                                  width: 40, height: 40,
                                  decoration: BoxDecoration(
                                    color: colorWarning.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.mark_email_unread_rounded, color: colorWarning, size: 20),
                                ),
                                const SizedBox(width: spaceSm),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tr('אימייל לא אומת', 'Email not verified'),
                                        style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w800),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        tr('בדוק את תיבת הדואר ואת הספאם 📬', 'Check inbox and SPAM folder 📬'),
                                        style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w500),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    try {
                                      await user.sendEmailVerification();
                                      if (ctx.mounted) {
                                        ScaffoldMessenger.of(ctx).showSnackBar(
                                          SnackBar(
                                            content: Text(tr('✉️ נשלח שוב', '✉️ Resent')),
                                            backgroundColor: accentGreen,
                                          ),
                                        );
                                      }
                                    } catch (_) {}
                                  },
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    backgroundColor: colorWarning.withValues(alpha: 0.15),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
                                  ),
                                  child: Text(
                                    tr('שלח שוב', 'Resend'),
                                    style: const TextStyle(color: colorWarning, fontSize: 11, fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ]),
                            ),
                          );
                        }),

                        const SizedBox(height: spaceLg),

                        appSectionTitle(tr('מתחמים זמינים', 'AVAILABLE VENUES')),

                        const SizedBox(height: spaceXs),

                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            mainAxisSpacing: spaceMd,
                            crossAxisSpacing: spaceMd,
                            childAspectRatio: isMobile ? 1.05 : 0.95,
                          ),
                          itemCount: venues.length,
                          itemBuilder: (ctx, i) {
                            final v = venues[i];
                            return _VenueCard(
                              venue: v,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => VenueHomeScreen(venue: v)),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ============== FOOTER ==============
            Container(
              padding: const EdgeInsets.all(spaceMd),
              child: const Text(
                'STADIUM v1.0  •  © 2026',
                style: TextStyle(color: textTertiary, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1.5),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topIconButton({required IconData icon, required VoidCallback onTap, String? badge}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(icon, color: textPrimary, size: 18),
            if (badge != null)
              Positioned(
                bottom: 4, right: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: accentGreen,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(color: bgColor, fontSize: 7, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _menuButton(BuildContext context) {
    return Container(
      width: 40, height: 40,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: PopupMenuButton<String>(
        tooltip: tr('תפריט', 'Menu'),
        icon: const Icon(Icons.menu, color: textPrimary, size: 18),
        padding: EdgeInsets.zero,
        color: cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: const BorderSide(color: borderColor),
        ),
        offset: const Offset(0, 48),
        itemBuilder: (ctx) => [
          PopupMenuItem<String>(
            value: 'profile',
            child: _menuRow(Icons.person_outline, tr('הפרופיל שלי', 'My Profile'), accentGreen),
          ),
          PopupMenuItem<String>(
            value: 'bookings',
            child: _menuRow(Icons.calendar_month_outlined, tr('ההזמנות שלי', 'My Bookings'), accentGreen),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: 'language',
            child: _menuRow(Icons.language, isHebrew ? 'English' : 'עברית', textPrimary),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: 'logout',
            child: _menuRow(Icons.logout, tr('יציאה', 'Sign Out'), Colors.red),
          ),
        ],
        onSelected: (value) async {
          switch (value) {
            case 'profile':
              navigateTo(context, const ProfileScreen(),);
              break;
            case 'bookings':
              navigateTo(context, const MyBookingsScreen(),);
              break;
            case 'language':
              toggleAppLanguage(context);
              break;
            case 'logout':
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: cardColor,
                  title: Text(
                    tr('יציאה?', 'Sign Out?'),
                    style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                  ),
                  content: Text(
                    tr('האם אתה בטוח שברצונך לצאת?', 'Are you sure you want to sign out?'),
                    style: const TextStyle(color: textSecondary),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary)),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      child: Text(tr('יציאה', 'Sign Out'), style: const TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ],
                ),
              );
              if (ok == true && context.mounted) await _signOut(context);
              break;
          }
        },
      ),
    );
  }

  Widget _menuRow(IconData icon, String label, Color iconColor) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: spaceSm),
        Text(
          label,
          style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ====================================================
// VENUE CARD WIDGET
// ====================================================
class _VenueCard extends StatelessWidget {
  final Map<String, dynamic> venue;
  final VoidCallback onTap;

  const _VenueCard({required this.venue, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final stadiumCount = (venue['stadiumIds'] as List? ?? const []).length;
    final hasTraining = venue['hasTraining'] == true;
    final emoji = venue['emoji'] as String? ?? '🏟️';
    final name = isHebrew ? (venue['name'] as String? ?? '') : (venue['nameEn'] as String? ?? venue['name'] as String? ?? '');
    final region = isHebrew ? (venue['region'] as String? ?? 'נצרת') : (venue['regionEn'] as String? ?? 'Nazareth');
    final description = isHebrew ? (venue['description'] as String? ?? '') : (venue['descriptionEn'] as String? ?? venue['description'] as String? ?? '');

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radiusXl),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radiusXl),
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(radiusXl),
            border: Border.all(color: borderColor),
          ),
          // Listen to venue_config/{venueId}.backgroundImage. When present,
          // show full-card image with overlay + bottom-aligned content.
          // When absent, fall back to the original split layout (green header + body).
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('venue_config')
                .doc(venue['id'] as String)
                .snapshots(),
            builder: (ctx, snap) {
              final bg = snap.hasData && snap.data!.exists
                  ? (snap.data!.data()?['backgroundImage'] as String?)
                  : null;
              final hasImage = bg != null && bg.isNotEmpty;
              return hasImage
                  ? _imageLayout(bg, name, description, region, stadiumCount, hasTraining, emoji)
                  : _defaultLayout(name, description, region, stadiumCount, hasTraining, emoji);
            },
          ),
        ),
      ),
    );
  }

  /// Layout used when the venue has a custom background image — image covers
  /// the whole card, content sits at the bottom over a darker gradient.
  Widget _imageLayout(
    String bg,
    String name,
    String description,
    String region,
    int stadiumCount,
    bool hasTraining,
    String emoji,
  ) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 290),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) Image (lowest layer)
          _buildVenueBackground(bg),
          // 2) Top-to-bottom dark gradient for text readability
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.30),
                  Colors.black.withValues(alpha: 0.75),
                ],
              ),
            ),
          ),
          // 3) Decorative emoji top-right (reduced opacity, doesn't compete)
          Positioned(
            top: 12,
            right: isHebrew ? null : 12,
            left: isHebrew ? 12 : null,
            child: Opacity(
              opacity: 0.45,
              child: Text(emoji, style: const TextStyle(fontSize: 40)),
            ),
          ),
          // 4) Forward-arrow CTA top-leading corner
          Positioned(
            top: 12,
            right: isHebrew ? 12 : null,
            left: isHebrew ? null : 12,
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: accentGreen,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isHebrew ? Icons.arrow_back : Icons.arrow_forward,
                color: bgColor,
                size: 18,
              ),
            ),
          ),
          // 5) Content stack at the bottom
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Padding(
              padding: const EdgeInsets.all(spaceMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                      shadows: [
                        Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 4),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: spaceSm),
                  Row(children: [
                    _metaItemOnImage(Icons.location_on_outlined, region),
                    const SizedBox(width: spaceMd),
                    _metaItemOnImage(Icons.sports_soccer, '$stadiumCount ${isHebrew ? "מגרשים" : "fields"}'),
                  ]),
                  const SizedBox(height: spaceSm),
                  Container(height: 1, color: Colors.white.withValues(alpha: 0.2)),
                  const SizedBox(height: spaceSm),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _featureBadge(Icons.calendar_month, tr('הזמנות', 'Booking'), accentGreen),
                      if (hasTraining)
                        _featureBadge(Icons.school_outlined, tr('אימונים', 'Training'), const Color(0xFF3B82F6)),
                      _featureBadge(Icons.qr_code_2, tr('קוד', 'Code'), const Color(0xFFF59E0B)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Original split layout (green gradient header + dark body) — used when
  /// the venue admin hasn't configured a background image.
  Widget _defaultLayout(
    String name,
    String description,
    String region,
    int stadiumCount,
    bool hasTraining,
    String emoji,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 110,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _defaultVenueGradient(),
              Positioned(
                top: -20, right: -20,
                child: Container(
                  width: 120, height: 120,
                  decoration: BoxDecoration(
                    color: accentGreen.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                bottom: -30, left: -10,
                child: Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    color: accentGreen.withValues(alpha: 0.04),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Center(
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 56),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: accentGreen,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isHebrew ? Icons.arrow_back : Icons.arrow_forward,
                    color: bgColor,
                    size: 18,
                  ),
                ),
              ]),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: spaceSm),
              Row(children: [
                _metaItem(Icons.location_on_outlined, region),
                const SizedBox(width: spaceMd),
                _metaItem(Icons.sports_soccer, '$stadiumCount ${isHebrew ? "מגרשים" : "fields"}'),
              ]),
              const SizedBox(height: spaceSm),
              Container(height: 1, color: borderColor),
              const SizedBox(height: spaceSm),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _featureBadge(Icons.calendar_month, tr('הזמנות', 'Booking'), accentGreen),
                  if (hasTraining)
                    _featureBadge(Icons.school_outlined, tr('אימונים', 'Training'), const Color(0xFF3B82F6)),
                  _featureBadge(Icons.qr_code_2, tr('קוד', 'Code'), const Color(0xFFF59E0B)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Meta-row item recolored for white-on-image readability.
  Widget _metaItemOnImage(IconData icon, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: Colors.white.withValues(alpha: 0.8), size: 14),
      const SizedBox(width: 4),
      Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.8),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ]);
  }

  /// Renders a venue background image. Supports both base64 data URLs
  /// (stored in Firestore on the free tier) and legacy https:// URLs from
  /// Firebase Storage (Blaze plan only). Falls back to gradient on error.
  Widget _buildVenueBackground(String src) {
    if (src.startsWith('data:image')) {
      try {
        final base64Part = src.split(',').last;
        final bytes = base64Decode(base64Part);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          cacheHeight: 220, cacheWidth: 800,
          errorBuilder: (_, __, ___) => _defaultVenueGradient(),
        );
      } catch (_) {
        return _defaultVenueGradient();
      }
    }
    return Image.network(
      src,
      fit: BoxFit.cover,
      cacheHeight: 220, cacheWidth: 800,
      loadingBuilder: (_, child, p) => p == null
          ? child
          : Container(
              color: cardColor,
              child: const Center(
                child: CircularProgressIndicator(color: accentGreen, strokeWidth: 2),
              ),
            ),
      errorBuilder: (_, __, ___) => _defaultVenueGradient(),
    );
  }

  /// Fallback gradient used when no custom venue background is configured
  /// (or when the configured image fails to load).
  Widget _defaultVenueGradient() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accentGreen.withValues(alpha: 0.25),
            accentGreen.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }

  Widget _metaItem(IconData icon, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: textSecondary, size: 14),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _featureBadge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radiusXs),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 11),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
        ),
      ]),
    );
  }
}

// ==================== VENUE HOME ====================
class VenueHomeScreen extends StatefulWidget {
  final Map<String, dynamic> venue;
  const VenueHomeScreen({super.key, required this.venue});

  @override
  State<VenueHomeScreen> createState() => _VenueHomeScreenState();
}

class _VenueHomeScreenState extends State<VenueHomeScreen> {
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;
    final isTablet = width >= 700 && width < 1100;
    final crossAxisCount = isMobile ? 1 : (isTablet ? 2 : 3);

    final venue = widget.venue;
    final hasTraining = venue['hasTraining'] == true;
    final stadiumIds = (venue['stadiumIds'] as List? ?? const []).cast<String>();
    final stadiums = allStadiums.where((s) => stadiumIds.contains(s['id'] as String)).toList();
    final emoji = venue['emoji'] as String? ?? '🏟️';
    final name = isHebrew ? (venue['name'] as String? ?? '') : (venue['nameEn'] as String? ?? venue['name'] as String? ?? '');
    final region = isHebrew ? (venue['region'] as String? ?? 'נצרת') : (venue['regionEn'] as String? ?? 'Nazareth');

    final actions = <Map<String, dynamic>>[
      {
        'icon': Icons.calendar_month_rounded,
        'title': tr('הזמן מגרש', 'Book a Field'),
        'subtitle': tr('בחר תאריך ושעה', 'Pick date & time'),
        'color': accentGreen,
        'onTap': () {
          if (stadiums.length == 1) {
            navigateTo(context, BookingScreen(stadium: stadiums.first),);
          } else {
            navigateTo(context, StadiumSelectionScreen(venue: venue),);
          }
        },
      },
      if (hasTraining)
        {
          'icon': Icons.school_rounded,
          'title': tr('הירשם לאימונים', 'Join Training'),
          'subtitle': tr('קבוצות אימון לילדים', 'Kids training groups'),
          'color': const Color(0xFF3B82F6),
          'onTap': () {
            navigateTo(context, TrainingGroupsListScreen(venueId: venue['id'] as String, venueName: name),);
          },
        },
      {
        'icon': Icons.qr_code_2_rounded,
        'title': tr('קוד גישה', 'Access Code'),
        'subtitle': tr('הזן קוד הזמנה', 'Enter booking code'),
        'color': const Color(0xFFF59E0B),
        'onTap': () {
          navigateTo(context, const JoinByCodeScreen(),);
        },
      },
    ];

    return Scaffold(
      backgroundColor: bgColor,
      appBar: PlayerAppBar(title: name),
      body: SafeArea(
        child: Column(
          children: [
            // BODY
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? spaceMd : spaceXl,
                  vertical: spaceMd,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // VENUE BANNER
                        Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(isMobile ? spaceLg : spaceXl),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                accentGreen.withValues(alpha: 0.25),
                                accentGreen.withValues(alpha: 0.05),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(radiusXl),
                            border: Border.all(color: accentGreen.withValues(alpha: 0.2)),
                          ),
                          child: Stack(
                            children: [
                              Positioned(
                                top: -30, right: -30,
                                child: Container(
                                  width: 140, height: 140,
                                  decoration: BoxDecoration(
                                    color: accentGreen.withValues(alpha: 0.06),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              Row(children: [
                                Container(
                                  width: isMobile ? 60 : 80,
                                  height: isMobile ? 60 : 80,
                                  decoration: BoxDecoration(
                                    color: bgColor.withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Center(
                                    child: Text(emoji, style: TextStyle(fontSize: isMobile ? 36 : 48)),
                                  ),
                                ),
                                SizedBox(width: isMobile ? spaceMd : spaceLg),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tr('ברוך הבא ל-', 'Welcome to'),
                                        style: TextStyle(
                                          color: accentGreen,
                                          fontSize: isMobile ? 12 : 13,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 1,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        name,
                                        style: TextStyle(
                                          color: textPrimary,
                                          fontSize: isMobile ? 22 : 28,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(children: [
                                        const Icon(Icons.location_on, color: textSecondary, size: 13),
                                        const SizedBox(width: 4),
                                        Text(
                                          region,
                                          style: const TextStyle(
                                            color: textSecondary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(width: spaceSm),
                                        const Icon(Icons.sports_soccer, color: textSecondary, size: 13),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${stadiums.length} ${isHebrew ? "מגרשים" : "fields"}',
                                          style: const TextStyle(
                                            color: textSecondary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ]),
                                    ],
                                  ),
                                ),
                              ]),
                            ],
                          ),
                        ),

                        const SizedBox(height: spaceLg),
                        appSectionTitle(tr('מה תרצה לעשות?', 'WHAT WOULD YOU LIKE TO DO?')),
                        const SizedBox(height: spaceXs),

                        // ACTION CARDS GRID
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            mainAxisSpacing: spaceMd,
                            crossAxisSpacing: spaceMd,
                            childAspectRatio: isMobile ? 2.5 : 1.1,
                          ),
                          itemCount: actions.length,
                          itemBuilder: (ctx, i) {
                            final action = actions[i];
                            return _ActionCard(
                              icon: action['icon'] as IconData,
                              title: action['title'] as String,
                              subtitle: action['subtitle'] as String,
                              color: action['color'] as Color,
                              onTap: action['onTap'] as VoidCallback,
                              isMobile: isMobile,
                            );
                          },
                        ),

                        const SizedBox(height: spaceLg),

                        // MY BOOKINGS LINK
                        appSectionTitle(tr('האזור האישי שלי', 'MY ACCOUNT')),
                        const SizedBox(height: spaceXs),
                        appListTile(
                          icon: Icons.person_rounded,
                          title: tr('הפרטים שלי', 'My Details'),
                          subtitle: tr('שם, אימייל, טלפון, תאריך לידה', 'Name, email, phone, date of birth'),
                          iconColor: const Color(0xFFF59E0B),
                          trailing: Icon(
                            isHebrew ? Icons.arrow_back_ios : Icons.arrow_forward_ios,
                            color: textSecondary, size: 14,
                          ),
                          onTap: () {
                            navigateTo(context, const ProfileScreen(),);
                          },
                        ),
                        const SizedBox(height: spaceSm),
                        appListTile(
                          icon: Icons.calendar_month_rounded,
                          title: tr('ההזמנות שלי', 'My Bookings'),
                          subtitle: tr('הזמנות עתידיות, היסטוריה וביטול', 'Upcoming, history & cancel'),
                          iconColor: accentGreen,
                          trailing: Icon(
                            isHebrew ? Icons.arrow_back_ios : Icons.arrow_forward_ios,
                            color: textSecondary, size: 14,
                          ),
                          onTap: () {
                            navigateTo(context, const MyBookingsScreen(),);
                          },
                        ),

                        // MY REGISTRATIONS LINK (if has training)
                        if (hasTraining) ...[
                          const SizedBox(height: spaceSm),
                          appListTile(
                            icon: Icons.list_alt_rounded,
                            title: tr('הרישומים לאימונים שלי', 'My training registrations'),
                            subtitle: tr('סטטוס תשלום, פרטי הקבוצה', 'Payment status, group details'),
                            iconColor: const Color(0xFF3B82F6),
                            trailing: Icon(
                              isHebrew ? Icons.arrow_back_ios : Icons.arrow_forward_ios,
                              color: textSecondary, size: 14,
                            ),
                            onTap: () {
                              navigateTo(context, const MyTrainingRegistrationsScreen(),);
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final bool isMobile;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    required this.isMobile,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radiusXl),
      child: Container(
        padding: EdgeInsets.all(isMobile ? spaceMd : spaceLg),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(radiusXl),
          border: Border.all(color: borderColor),
        ),
        child: isMobile
            ? Row(
                children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const SizedBox(width: spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: textSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    isHebrew ? Icons.arrow_back_ios : Icons.arrow_forward_ios,
                    color: textSecondary, size: 14,
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  const Spacer(),
                  Text(
                    title,
                    style: const TextStyle(
                      color: textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: spaceSm),
                  Row(children: [
                    Text(
                      tr('המשך', 'Continue'),
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      isHebrew ? Icons.arrow_back : Icons.arrow_forward,
                      color: color, size: 14,
                    ),
                  ]),
                ],
              ),
      ),
    );
  }
}

// ==================== VENUE STADIUMS ====================
class StadiumSelectionScreen extends StatelessWidget {
  final Map<String, dynamic> venue;
  const StadiumSelectionScreen({super.key, required this.venue});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;
    final isTablet = width >= 700 && width < 1100;
    final crossAxisCount = isMobile ? 1 : (isTablet ? 2 : 3);
    final vName = isHebrew ? (venue['name'] as String? ?? '') : (venue['nameEn'] as String? ?? venue['name'] as String? ?? '');
    final ids = (venue['stadiumIds'] as List? ?? const []).cast<String>();
    final stadiums = allStadiums.where((s) => ids.contains(s['id'] as String)).toList();

    return Scaffold(
      backgroundColor: bgColor,
      appBar: PlayerAppBar(title: '${tr('בחר מגרש', 'Choose a Field')} — $vName'),
      body: SafeArea(
        child: Column(
          children: [
            // BODY
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? spaceMd : spaceXl,
                  vertical: spaceMd,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: spaceMd,
                        crossAxisSpacing: spaceMd,
                        childAspectRatio: isMobile ? 2.2 : 1.4,
                      ),
                      itemCount: stadiums.length,
                      itemBuilder: (ctx, i) {
                        final s = stadiums[i];
                        return InkWell(
                          onTap: () {
                            navigateTo(context, BookingScreen(stadium: s),);
                          },
                          borderRadius: BorderRadius.circular(radiusXl),
                          child: Container(
                            padding: const EdgeInsets.all(spaceLg),
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(radiusXl),
                              border: Border.all(color: borderColor),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 56, height: 56,
                                  decoration: BoxDecoration(
                                    color: accentGreen.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(Icons.sports_soccer, color: accentGreen, size: 28),
                                ),
                                const SizedBox(height: spaceMd),
                                Text(
                                  s['name'] as String,
                                  style: const TextStyle(
                                    color: textPrimary,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '₪${s['price']} ${isHebrew ? "להזמנה" : "per booking"}',
                                  style: const TextStyle(
                                    color: textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: spaceSm),
                                Row(children: [
                                  Text(
                                    tr('בחר', 'Select'),
                                    style: const TextStyle(
                                      color: accentGreen,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    isHebrew ? Icons.arrow_back : Icons.arrow_forward,
                                    color: accentGreen, size: 14,
                                  ),
                                ]),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== STADIUM CARD ====================
class StadiumCard extends StatelessWidget {
  final Map<String, dynamic> stadium;
  const StadiumCard({super.key, required this.stadium});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => navigateTo(context, BookingScreen(stadium: stadium)),
    child: Container(margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16), border: Border.all(color: borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('stadium_config').doc(stadium['id'] as String).snapshots(),
          builder: (ctx, snap) {
            final bgImage = snap.hasData && snap.data!.exists ? (snap.data!.data()?['backgroundImage'] as String?) : null;
            final hasImage = bgImage != null && bgImage.isNotEmpty;
            Widget defaultBg = Container(
              height: 130,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accentGreen.withValues(alpha: 0.25), const Color(0xFF0D0D0D)]),
              ),
              child: Center(child: Icon(stadium['type'] == 'Tennis' ? Icons.sports_tennis : Icons.sports_soccer, color: accentGreen.withValues(alpha: 0.6), size: 64)),
            );
            Widget imageWidget = hasImage
              ? ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: Image.network(bgImage,
                    height: 130, width: double.infinity, fit: BoxFit.cover,
                    // Decode at the rendered size so we don't keep huge bitmaps
                    // in memory when the source URL points at a 4K photo.
                    cacheHeight: 260, cacheWidth: 1080,
                    loadingBuilder: (_, child, progress) => progress == null ? child
                      : SizedBox(height: 130, child: Container(decoration: const BoxDecoration(borderRadius: BorderRadius.vertical(top: Radius.circular(16)), color: cardColor), child: const Center(child: CircularProgressIndicator(color: accentGreen, strokeWidth: 2)))),
                    errorBuilder: (_, __, ___) => defaultBg,
                  ),
                )
              : defaultBg;
            return SizedBox(
              height: 130,
              child: Stack(children: [
                imageWidget,
                if (hasImage)
                  Positioned.fill(child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                  )),
                Positioned(top: 12, left: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: bgColor.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(8), border: Border.all(color: accentGreen.withValues(alpha: 0.5))), child: Text(stadium['type'], style: const TextStyle(color: accentGreen, fontSize: 11, fontWeight: FontWeight.bold)))),
                Positioned(top: 12, right: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: accentGreen, borderRadius: BorderRadius.circular(8)), child: Text('₪${stadium['price']}/2hr', style: const TextStyle(color: bgColor, fontSize: 11, fontWeight: FontWeight.w900)))),
              ]),
            );
          },
        ),
        Padding(padding: const EdgeInsets.all(14), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stadium['name'], style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: 1)),
            const SizedBox(height: 4),
            Row(children: [const Icon(Icons.location_on_outlined, color: textSecondary, size: 14), const SizedBox(width: 2), Text(stadium['location'], style: const TextStyle(color: textSecondary, fontSize: 13))]),
          ])),
          ElevatedButton(onPressed: () => navigateTo(context, BookingScreen(stadium: stadium)),
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            child: Text(tr('הזמן','BOOK'), style: const TextStyle(fontWeight: FontWeight.w900))),
        ])),
      ])),
  );
}

// ==================== BOOKING SCREEN ====================
class BookingScreen extends StatefulWidget {
  final Map<String, dynamic> stadium;
  const BookingScreen({super.key, required this.stadium});
  @override State<BookingScreen> createState() => _BookingScreenState();
}
class _BookingScreenState extends State<BookingScreen> {
  int _selDay = 0; int? _selSlot; bool _booking = false;
  late List<Map<String, String>> _days;
  Set<String> _bookedSlots = {}, _blockedSlots = {};
  List<Map<String, String>> _slots = List.from(defaultSlots);
  List<Map<String, dynamic>> _bookingTypes = [];
  Map<String, dynamic>? _selectedType;
  List<Map<String, dynamic>> _trainingGroups = [];
  List<Map<String, dynamic>> _recurringBlocks = [];

  @override void initState() { super.initState(); _buildDays(); _loadData(); }

  void _buildDays() {
    final now = DateTime.now();
    _days = List.generate(14, (i) {
      final d = now.add(Duration(days: i));
      return {
        'name': hebrewWeekday(d.weekday, isHebrew),
        'date': '${d.day}/${d.month}',
        'full': '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}',
      };
    });
  }

  String get _docId => '${widget.stadium['id']}_${_days[_selDay]['full']}';

  Future<void> _loadData() async {
    final date = _days[_selDay]['date']!;
    final results = await Future.wait([
      FirebaseFirestore.instance.collection('bookings').where('stadiumName', isEqualTo: widget.stadium['name']).where('date', isEqualTo: date).get(),
      FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).get(),
      FirebaseFirestore.instance.collection('booking_types').where('stadiumId', isEqualTo: widget.stadium['id']).get(),
      FirebaseFirestore.instance.collection('training_groups').where('stadiumId', isEqualTo: widget.stadium['id']).get(),
      FirebaseFirestore.instance.collection('recurring_blocks').where('stadiumId', isEqualTo: widget.stadium['id']).get(),
    ]);
    final bSnap = results[0] as QuerySnapshot<Map<String, dynamic>>;
    final sSnap = results[1] as DocumentSnapshot<Map<String, dynamic>>;
    final tSnap = results[2] as QuerySnapshot<Map<String, dynamic>>;
    final gSnap = results[3] as QuerySnapshot<Map<String, dynamic>>;
    final rSnap = results[4] as QuerySnapshot<Map<String, dynamic>>;
    List<Map<String, dynamic>> types = tSnap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
    if (types.isEmpty) {
      types = defaultBookingTypes.map((t) => {...t, 'price': widget.stadium['price'] ?? t['price']}).toList();
    }
    setState(() {
      _bookedSlots = bSnap.docs.map((d) => d.data()['time'] as String).toSet();
      _trainingGroups = gSnap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      _recurringBlocks = rSnap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      _bookingTypes = types;
      if (_selectedType == null && types.isNotEmpty) _selectedType = types.first;
      if (sSnap.exists) {
        _blockedSlots = Set<String>.from(sSnap.data()?['blocked'] ?? []);
        if (sSnap.data()?['slots'] != null) {
          final raw = sSnap.data()!['slots'] as List;
          _slots = raw.map((s) => {'start': s['start'] as String, 'end': s['end'] as String}).toList();
        } else { _slots = List.from(defaultSlots); }
      } else { _blockedSlots = {}; _slots = List.from(defaultSlots); }
    });
  }

  String _status(String label) {
    if (recurringBlockForSlot(_recurringBlocks, widget.stadium['id'] as String, _days[_selDay]['date']!, label)) return 'fixed';
    if (_blockedSlots.contains(label)) return 'blocked';
    if (_bookedSlots.contains(label))  return 'booked';
    if (trainingOverlapForSlot(_trainingGroups, widget.stadium['id'] as String, _days[_selDay]['date']!, label)) return 'training';
    return 'available';
  }

  String? _trainingNameFor(String label) =>
      trainingNameForSlot(_trainingGroups, widget.stadium['id'] as String, _days[_selDay]['date']!, label);

  String? _recurringReasonFor(String label) =>
      recurringReasonForSlot(_recurringBlocks, widget.stadium['id'] as String, _days[_selDay]['date']!, label);

  List<Map<String,String>> get _visibleSlots {
    final now = DateTime.now();
    return _slots.where((s) {
      if (_selDay != 0) return true;
      final h = int.parse(s['start']!.split(':')[0]);
      return h > now.hour;
    }).toList();
  }

  Future<void> _book() async {
    if (_selSlot == null) return;
    final slot = _visibleSlots[_selSlot!];
    final label = _slotLabel(slot);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(spaceLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: accentGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.event_available_rounded, color: accentGreen, size: 32),
                  ),
                ),
                const SizedBox(height: spaceMd),
                Text(
                  tr('אישור הזמנה', 'Confirm Booking'),
                  style: const TextStyle(color: textPrimary, fontSize: 20, fontWeight: FontWeight.w900),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  tr('בדוק את הפרטים לפני האישור', 'Review details before confirming'),
                  style: const TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: spaceLg),
                Container(
                  padding: const EdgeInsets.all(spaceMd),
                  decoration: BoxDecoration(
                    color: bgSecondary,
                    borderRadius: BorderRadius.circular(radiusLg),
                    border: Border.all(color: borderColor),
                  ),
                  child: Column(children: [
                    _confirmRow(Icons.sports_soccer, tr('מגרש', 'Field'), widget.stadium['name'] as String),
                    const SizedBox(height: 10),
                    _confirmRow(Icons.calendar_today_outlined, tr('תאריך', 'Date'), _days[_selDay]['date']!),
                    const SizedBox(height: 10),
                    _confirmRow(Icons.access_time, tr('שעה', 'Time'), label),
                    if (_selectedType != null) ...[
                      const SizedBox(height: 10),
                      _confirmRow(
                        Icons.category_outlined,
                        tr('סוג', 'Type'),
                        isHebrew
                            ? (_selectedType!['name'] as String? ?? 'כדורגל')
                            : (_selectedType!['nameEn'] as String? ?? 'Football'),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Container(height: 1, color: borderColor),
                    const SizedBox(height: 10),
                    Row(children: [
                      const Icon(Icons.payments_outlined, color: accentGreen, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        tr('מחיר:', 'Price:'),
                        style: const TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Text(
                        '₪${_selectedType?['price'] ?? widget.stadium['price']}',
                        style: const TextStyle(color: accentGreen, fontSize: 18, fontWeight: FontWeight.w900),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: spaceLg),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: borderColor),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                      ),
                      child: Text(
                        tr('ביטול', 'Cancel'),
                        style: const TextStyle(color: textSecondary, fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: spaceSm),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: Text(
                        tr('אשר הזמנה', 'Confirm'),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentGreen,
                        foregroundColor: bgColor,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                        elevation: 0,
                      ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    setState(() { _booking = true; });
    final user = FirebaseAuth.instance.currentUser;
    final myName = user?.displayName ?? user?.email ?? '';
    final date = _days[_selDay]['date']!;

    final existing = await FirebaseFirestore.instance.collection('bookings').where('stadiumName', isEqualTo: widget.stadium['name']).where('date', isEqualTo: date).where('time', isEqualTo: label).get();
    if (existing.docs.isNotEmpty) {
      setState(() { _booking = false; });
      if (context.mounted) _dlg(tr('שעה תפוסה ❌','Slot Taken ❌'), tr('$label כבר תפוס. בחר שעה אחרת.','$label is already booked.'), err: true);
      return;
    }

    final userExisting = await FirebaseFirestore.instance
        .collection('bookings')
        .where('userId', isEqualTo: user?.uid)
        .where('date', isEqualTo: date)
        .where('time', isEqualTo: label)
        .get();
    if (userExisting.docs.isNotEmpty) {
      setState(() { _booking = false; });
      final otherStadium = userExisting.docs.first.data()['stadiumName'];
      if (context.mounted) _dlg(
        tr('כבר הזמנת ❌', 'Already Booked ❌'),
        tr('כבר יש לך הזמנה באותה שעה ב-$otherStadium',
           'You already have a booking at this time at $otherStadium'),
        err: true,
      );
      return;
    }

    final code = (1000 + DateTime.now().millisecondsSinceEpoch % 9000).toString();
    final typePrice = _selectedType?['price'] ?? widget.stadium['price'];
    await FirebaseFirestore.instance.collection('bookings').add({
      'userId': user?.uid, 'userName': myName,
      'stadiumName': widget.stadium['name'], 'stadiumId': widget.stadium['id'],
      'day': _days[_selDay]['name'], 'date': date, 'time': label,
      'price': '₪$typePrice/2hr',
      'bookingCode': code, 'players': [myName],
      'createdAt': DateTime.now().toIso8601String(),
      if (_selectedType != null) ...{
        'bookingType':      _selectedType!['name']   ?? '',
        'bookingTypeEn':    _selectedType!['nameEn'] ?? '',
        'bookingTypeIcon':  _selectedType!['icon']   ?? '',
        'bookingTypeColor': _selectedType!['color']  ?? '',
      },
    });
    await FirebaseFirestore.instance.collection('notifications').add({
      'userId': user?.uid,
      'title': tr('ההזמנה אושרה ✅','Booking Confirmed ✅'),
      'body': tr('ההזמנה שלך ב-${widget.stadium['name']} ב-${_days[_selDay]['name']} $date • $label', 'Your booking at ${widget.stadium['name']} on ${_days[_selDay]['name']} $date • $label'),
      'read': false, 'createdAt': DateTime.now().toIso8601String(),
    });

    await _loadData();
    setState(() { _booking = false; _selSlot = null; });
    if (!mounted) return;
    showDialog(context: context, builder: (dialogContext) => AlertDialog(
      backgroundColor: cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(tr('ההזמנה אושרה! 🎉','Booking Confirmed! 🎉'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
          child: Column(children: [Text(widget.stadium['name'], style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)), Text('${_days[_selDay]['name']} $date • $label', style: const TextStyle(color: textSecondary, fontSize: 13))])),
        const SizedBox(height: 20),
        Text(tr('שלח קוד לחברים','SHARE CODE WITH FRIENDS'), style: const TextStyle(color: textSecondary, fontSize: 11, letterSpacing: 2)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (dialogContext.mounted) ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text(tr('הקוד הועתק! 📋', 'Code copied! 📋')), backgroundColor: accentGreen, duration: const Duration(seconds: 2)));
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(code, style: const TextStyle(color: accentGreen, fontSize: 48, fontWeight: FontWeight.w900, letterSpacing: 12)),
              const SizedBox(width: 12), const Icon(Icons.copy_outlined, color: accentGreen, size: 22),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Text(tr('לחץ על הקוד להעתקה', 'Tap code to copy'), style: const TextStyle(color: textSecondary, fontSize: 11)),
      ]),
      actions: [ElevatedButton(onPressed: () => Navigator.pop(dialogContext), style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: Text(tr('הבנתי','GOT IT'), style: const TextStyle(fontWeight: FontWeight.w900)))],
    ));
  }

  void _dlg(String t, String msg, {bool err = false}) => showDialog(context: context, builder: (_) => AlertDialog(
    backgroundColor: cardColor, title: Text(t, style: TextStyle(color: err?Colors.red:accentGreen, fontWeight: FontWeight.bold)),
    content: Text(msg, style: const TextStyle(color: textSecondary)),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('אישור','OK'), style: const TextStyle(color: accentGreen)))],
  ));

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;
    final visible = _visibleSlots;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: PlayerAppBar(title: widget.stadium['name'] as String),
      body: SafeArea(
        child: Column(
          children: [
            // BODY
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? spaceMd : spaceXl,
                  vertical: spaceMd,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        appSectionTitle(tr('בחר תאריך', 'SELECT DATE')),
                        const SizedBox(height: spaceXs),
                        SizedBox(
                          height: 76,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _days.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 8),
                            itemBuilder: (ctx, i) {
                              final d = _days[i];
                              final selected = i == _selDay;
                              return InkWell(
                                onTap: () { setState(() { _selDay = i; _selSlot = null; }); _loadData(); },
                                borderRadius: BorderRadius.circular(radiusLg),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: 64,
                                  decoration: BoxDecoration(
                                    color: selected ? accentGreen : cardColor,
                                    borderRadius: BorderRadius.circular(radiusLg),
                                    border: Border.all(
                                      color: selected ? accentGreen : borderColor,
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        d['name'] as String,
                                        style: TextStyle(
                                          color: selected ? bgColor : textSecondary,
                                          fontSize: 11, fontWeight: FontWeight.w700,
                                          letterSpacing: 1,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        d['date'] as String,
                                        style: TextStyle(
                                          color: selected ? bgColor : textPrimary,
                                          fontSize: 14, fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        if (_bookingTypes.isNotEmpty) ...[
                          const SizedBox(height: spaceLg),
                          appSectionTitle(tr('סוג הזמנה', 'BOOKING TYPE')),
                          const SizedBox(height: spaceXs),
                          SizedBox(
                            height: 96,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _bookingTypes.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                              itemBuilder: (ctx, i) {
                                final t = _bookingTypes[i];
                                final isSel = _selectedType == t || (_selectedType?['name'] == t['name'] && _selectedType?['icon'] == t['icon']);
                                final col = _colorForType(t['color'] as String?);
                                return InkWell(
                                  onTap: () => setState(() => _selectedType = t),
                                  borderRadius: BorderRadius.circular(radiusLg),
                                  child: Container(
                                    width: 110,
                                    decoration: BoxDecoration(
                                      color: isSel ? col.withValues(alpha: 0.18) : cardColor,
                                      borderRadius: BorderRadius.circular(radiusLg),
                                      border: Border.all(color: isSel ? col : borderColor, width: isSel ? 1.5 : 1),
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(_iconForType(t['icon'] as String?), color: col, size: 24),
                                        const SizedBox(height: 4),
                                        Text(
                                          isHebrew ? (t['name'] ?? '') : (t['nameEn'] ?? t['name'] ?? ''),
                                          style: TextStyle(color: isSel ? col : textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 2),
                                        Text('₪${t['price']}', style: TextStyle(color: isSel ? col : textSecondary, fontSize: 10)),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                        const SizedBox(height: spaceLg),
                        appSectionTitle(tr('בחר שעה', 'SELECT TIME')),
                        const SizedBox(height: spaceXs),
                        Wrap(
                          spacing: 12, runSpacing: 6,
                          children: [
                            _legendDot(tr('פנוי', 'Free'), accentGreen),
                            _legendDot(tr('תפוס', 'Booked'), colorWarning),
                            _legendDot(tr('חסום', 'Closed'), colorError),
                            _legendDot(tr('אימון', 'Training'), const Color(0xFF14B8A6)),
                            _legendDot(tr('קבוע', 'Fixed'), Colors.purple),
                          ],
                        ),
                        const SizedBox(height: spaceMd),
                        if (visible.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: spaceXl),
                            child: Center(
                              child: Column(
                                children: [
                                  const Icon(Icons.schedule, color: textSecondary, size: 48),
                                  const SizedBox(height: 12),
                                  Text(tr('אין שעות פנויות היום', 'No more slots today'), style: const TextStyle(color: textSecondary)),
                                  const SizedBox(height: 8),
                                  TextButton(
                                    onPressed: () { setState(() { _selDay = 1; _selSlot = null; }); _loadData(); },
                                    child: Text(tr('צפה במחר ←', 'View tomorrow →'), style: const TextStyle(color: accentGreen)),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: isMobile ? 2 : 4,
                              mainAxisSpacing: spaceXs,
                              crossAxisSpacing: spaceXs,
                              childAspectRatio: 2.4,
                            ),
                            itemCount: visible.length,
                            itemBuilder: (ctx, i) {
                              final slot = visible[i];
                              final label = _slotLabel(slot);
                              final status = _status(label);
                              return _SlotCard(
                                label: label,
                                status: status,
                                trainingName: status == 'training' ? _trainingNameFor(label) : null,
                                fixedReason: status == 'fixed' ? _recurringReasonFor(label) : null,
                                onTap: (status == 'available' && !_booking)
                                    ? () { setState(() => _selSlot = i); _book(); }
                                    : null,
                              );
                            },
                          ),
                        if (_booking) ...[
                          const SizedBox(height: spaceMd),
                          appLoading(message: tr('מבצע הזמנה...', 'Booking...')),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(String label, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _confirmRow(IconData icon, String label, String value) {
    return Row(children: [
      Icon(icon, color: textSecondary, size: 16),
      const SizedBox(width: 8),
      Text(
        label,
        style: const TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
      ),
      const Spacer(),
      Flexible(
        child: Text(
          value,
          style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w800),
          textAlign: TextAlign.end,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }
}

class _SlotCard extends StatelessWidget {
  final String label;
  final String status;
  final String? trainingName;
  final String? fixedReason;
  final VoidCallback? onTap;

  const _SlotCard({
    required this.label,
    required this.status,
    this.trainingName,
    this.fixedReason,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color bgClr, brdClr, txtClr;
    String badge;

    switch (status) {
      case 'booked':
        bgClr = colorWarning.withValues(alpha: 0.1);
        brdClr = colorWarning.withValues(alpha: 0.3);
        txtClr = colorWarning;
        badge = isHebrew ? 'תפוס' : 'BOOKED';
        break;
      case 'blocked':
        bgClr = colorError.withValues(alpha: 0.1);
        brdClr = colorError.withValues(alpha: 0.3);
        txtClr = colorError;
        badge = isHebrew ? 'סגור' : 'CLOSED';
        break;
      case 'training':
        bgClr = const Color(0xFF14B8A6).withValues(alpha: 0.1);
        brdClr = const Color(0xFF14B8A6).withValues(alpha: 0.3);
        txtClr = const Color(0xFF14B8A6);
        badge = trainingName ?? (isHebrew ? 'אימון' : 'TRAINING');
        break;
      case 'fixed':
        bgClr = Colors.purple.withValues(alpha: 0.12);
        brdClr = Colors.purple.withValues(alpha: 0.4);
        txtClr = Colors.purple;
        badge = fixedReason ?? (isHebrew ? 'קבוע' : 'FIXED');
        break;
      default:
        bgClr = cardColor;
        brdClr = borderColor;
        txtClr = textPrimary;
        badge = isHebrew ? 'פנוי' : 'FREE';
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radiusLg),
      child: Container(
        decoration: BoxDecoration(
          color: bgClr,
          borderRadius: BorderRadius.circular(radiusLg),
          border: Border.all(color: brdClr),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: txtClr, fontSize: 14, fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              badge,
              style: TextStyle(
                color: txtClr, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== ACCESS CODE ====================
class AccessCodeScreen extends StatefulWidget {
  const AccessCodeScreen({super.key});

  @override
  State<AccessCodeScreen> createState() => _AccessCodeScreenState();
}

class _AccessCodeScreenState extends State<AccessCodeScreen> {
  final _codeCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkCode() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) return;
    setState(() => _loading = true);
    try {
      final query = await FirebaseFirestore.instance
          .collection('bookings')
          .where('bookingCode', isEqualTo: code)
          .limit(1)
          .get();
      if (query.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('קוד לא נמצא', 'Code not found')),
              backgroundColor: colorError,
            ),
          );
        }
      } else {
        final data = query.docs.first.data();
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
              title: Text(tr('פרטי הזמנה', 'Booking Details'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow(tr('שם', 'Name'), '${data['userName'] ?? '-'}'),
                  _detailRow(tr('מגרש', 'Field'), '${data['stadiumName'] ?? '-'}'),
                  _detailRow(tr('תאריך', 'Date'), '${data['date'] ?? '-'}'),
                  _detailRow(tr('שעה', 'Time'), '${data['time'] ?? '-'}'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr('סגור', 'Close'), style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text('$label: ', style: const TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
        Expanded(child: Text(value, style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w700))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? spaceMd : spaceXl,
              vertical: spaceLg,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: borderColor),
                        ),
                        child: Icon(
                          isHebrew ? Icons.arrow_forward : Icons.arrow_back,
                          color: textPrimary, size: 18,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: spaceLg),
                  Center(
                    child: Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.qr_code_2_rounded, color: Color(0xFFF59E0B), size: 40),
                    ),
                  ),
                  const SizedBox(height: spaceMd),
                  Text(
                    tr('קוד גישה', 'Access Code'),
                    style: const TextStyle(color: textPrimary, fontSize: 24, fontWeight: FontWeight.w900),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('הזן את הקוד שקיבלת בעת ההזמנה', 'Enter the code you received'),
                    style: const TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: spaceLg),
                  Container(
                    padding: const EdgeInsets.all(spaceLg),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(radiusXl),
                      border: Border.all(color: borderColor),
                    ),
                    child: Column(children: [
                      appTextField(
                        controller: _codeCtrl,
                        label: tr('קוד הזמנה', 'Booking code'),
                        icon: Icons.confirmation_number_outlined,
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: spaceMd),
                      appPrimaryButton(
                        label: _loading ? tr('בודק...', 'Checking...') : tr('בדוק קוד', 'Check Code'),
                        icon: _loading ? null : Icons.search,
                        onPressed: _loading ? null : _checkCode,
                      ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== JOIN BY CODE ====================
class JoinByCodeScreen extends StatefulWidget {
  const JoinByCodeScreen({super.key});
  @override State<JoinByCodeScreen> createState() => _JoinByCodeScreenState();
}
class _JoinByCodeScreenState extends State<JoinByCodeScreen> {
  final _ctrl = TextEditingController();
  bool _loading=false; String _error='',_success='';
  Map<String,dynamic>? _booking; bool _joined=false;
  String get _myName => FirebaseAuth.instance.currentUser?.displayName ?? FirebaseAuth.instance.currentUser?.email ?? '';

  Future<void> _find() async {
    setState(() { _loading=true; _error=''; _booking=null; _success=''; });
    final s = await FirebaseFirestore.instance.collection('bookings').where('bookingCode', isEqualTo: _ctrl.text.trim()).limit(1).get();
    if (s.docs.isEmpty) { setState(() { _error=tr('קוד לא תקין','Invalid code.'); _loading=false; }); return; }
    final data = {'id': s.docs.first.id, ...s.docs.first.data()};
    setState(() { _booking=data; _joined=((data['players'] as List?)??[]).contains(_myName); _loading=false; });
  }

  Future<void> _join() async {
    final p=(_booking!['players'] as List?)??[];
    if (p.length>=18) { setState(() { _error=tr('הקבוצה מלאה (18/18)','Team full (18/18)'); }); return; }
    setState(() { _loading=true; });
    await FirebaseFirestore.instance.collection('bookings').doc(_booking!['id']).update({'players': FieldValue.arrayUnion([_myName])});
    final user = FirebaseAuth.instance.currentUser;
    await FirebaseFirestore.instance.collection('notifications').add({
      'userId': user?.uid,
      'title': tr('הצטרפת למשחק! ⚽','You joined a game! ⚽'),
      'body': tr('הצטרפת ל-${_booking!['stadiumName']} ב-${_booking!['day']} ${_booking!['date']} • ${_booking!['time']}', 'You joined ${_booking!['stadiumName']} on ${_booking!['day']} ${_booking!['date']} • ${_booking!['time']}'),
      'read': false, 'createdAt': DateTime.now().toIso8601String(),
    });
    await FirebaseFirestore.instance.collection('notifications').add({
      'userId': _booking!['userId'],
      'title': tr('שחקן חדש הצטרף! 👥','New player joined! 👥'),
      'body': tr('$_myName הצטרף למשחק שלך ב-${_booking!['stadiumName']}', '$_myName joined your game at ${_booking!['stadiumName']}'),
      'read': false, 'createdAt': DateTime.now().toIso8601String(),
    });
    setState(() { _success=tr('הצטרפת! 🎉',"You're in! 🎉"); _loading=false; _joined=true; });
  }

  Future<void> _leave() async {
    setState(() { _loading=true; });
    await FirebaseFirestore.instance.collection('bookings').doc(_booking!['id']).update({'players': FieldValue.arrayRemove([_myName])});
    setState(() { _success=tr('הוסרת מההזמנה ✓','Removed ✓'); _loading=false; _joined=false; _booking=null; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: bgColor, appBar: PlayerAppBar(title: tr('הצטרף למשחק','JOIN GAME')),
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: Column(children: [
      const Icon(Icons.group_add_outlined, color: accentGreen, size: 56), const SizedBox(height: 16),
      Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.person_outline, color: accentGreen, size: 16), const SizedBox(width: 6), Text('${tr('מצטרף כ','Joining as')}: $_myName', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 13))])),
      const SizedBox(height: 28),
      Text(tr('הכנס קוד הזמנה','ENTER BOOKING CODE'), style: const TextStyle(color: textSecondary, fontSize: 11, letterSpacing: 3)), const SizedBox(height: 12),
      TextField(controller: _ctrl, textAlign: TextAlign.center, style: const TextStyle(color: accentGreen, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 12), keyboardType: TextInputType.number, maxLength: 4,
        decoration: InputDecoration(hintText: '0000', hintStyle: const TextStyle(color: Color(0xFF333333), fontSize: 32, letterSpacing: 12), filled: true, fillColor: cardColor, counterText: '',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: accentGreen, width: 1.5)))),
      const SizedBox(height: 16),
      if (_error.isNotEmpty) _errBox(_error),
      if (_success.isNotEmpty) Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)), child: Text(_success, style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold))),
      if (_booking==null&&_success.isEmpty) ...[
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(onPressed: _loading?null:_find,
          style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: _loading?const SizedBox(width:20,height:20,child:CircularProgressIndicator(color:bgColor,strokeWidth:2)):Text(tr('חפש הזמנה','FIND BOOKING'), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)))),
      ],
      if (_booking!=null) ...[
        const SizedBox(height: 20),
        Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_booking!['stadiumName']??'', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 4),
            Text('${_booking!['day']} ${_booking!['date']} • ${_booking!['time']}', style: const TextStyle(color: textSecondary, fontSize: 13)),
            Text('${tr('מארגן','Organizer')}: ${_booking!['userName']??''}', style: const TextStyle(color: textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            Text('${tr('שחקנים','Players')}: ${(_booking!['players'] as List?)?.length??0}/18', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
          ])),
        const SizedBox(height: 14),
        if (_success.isEmpty) ...[
          if (!_joined) SizedBox(width: double.infinity, height: 52, child: ElevatedButton(onPressed: _loading?null:_join,
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(tr('הצטרף לקבוצה','JOIN TEAM'), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)))),
          if (_joined) ...[
            Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.check_circle_outline, color: accentGreen), const SizedBox(width: 8), Text(tr('אתה בתוך המשחק',"You're in this game"), style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold))])),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, height: 46, child: TextButton(onPressed: _loading?null:_leave,
              style: TextButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.08), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: Colors.red.withValues(alpha: 0.3)))),
              child: Text(tr('עזוב משחק','LEAVE GAME'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w900)))),
          ],
        ],
      ],
    ])))),
  );
}

// ==================== PROFILE ====================
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<List<dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final user = FirebaseAuth.instance.currentUser;
    _future = Future.wait([
      FirebaseFirestore.instance.collection('users').doc(user?.uid).get(),
      FirebaseFirestore.instance.collection('bookings').where('userId', isEqualTo: user?.uid).get(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final init = (user?.displayName ?? user?.email ?? 'P').substring(0, 1).toUpperCase();

    return Scaffold(
      backgroundColor: bgColor,
      appBar: PlayerAppBar(title: tr('פרופיל', 'PROFILE')),
      body: FutureBuilder<List<dynamic>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: accentGreen));
          }
          final userDoc = snap.data?[0] as DocumentSnapshot<Map<String, dynamic>>?;
          final bookingsSnap = snap.data?[1] as QuerySnapshot<Map<String, dynamic>>?;
          final data = userDoc?.data() ?? <String, dynamic>{};
          final total = bookingsSnap?.docs.length ?? 0;

          final name = (data['name'] as String?) ?? user?.displayName ?? '';
          final email = (data['email'] as String?) ?? user?.email ?? '';
          final phone = (data['phone'] as String?) ?? '';
          final dob = (data['dob'] as String?) ?? '';
          final gender = (data['gender'] as String?) ?? '';
          final city = (data['city'] as String?) ?? '';

          return RefreshIndicator(
            color: accentGreen,
            backgroundColor: cardColor,
            onRefresh: () async => setState(_refresh),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // PROFILE CARD
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: borderColor),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 80, height: 80,
                        decoration: BoxDecoration(
                          color: accentGreen.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: accentGreen.withValues(alpha: 0.4), width: 2),
                        ),
                        child: Center(
                          child: Text(
                            init,
                            style: const TextStyle(color: accentGreen, fontSize: 34, fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        name.isNotEmpty ? name : tr('שחקן', 'Player'),
                        style: const TextStyle(color: textPrimary, fontSize: 20, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      if (user?.emailVerified == false)
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: colorWarning.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: colorWarning.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: colorWarning, size: 12),
                              const SizedBox(width: 4),
                              Text(
                                tr('אימייל לא אומת', 'Email not verified'),
                                style: const TextStyle(color: colorWarning, fontSize: 10, fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
                _secTitle(tr('פרטים אישיים', 'PERSONAL DETAILS')),
                const SizedBox(height: 12),
                _infoRow(Icons.email_outlined, tr('אימייל', 'Email'), email),
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _infoRow(Icons.phone_outlined, tr('טלפון', 'Phone'), phone),
                ],
                if (dob.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _infoRow(Icons.cake_outlined, tr('תאריך לידה', 'Date of Birth'), dob),
                ],
                if (gender.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _infoRow(Icons.person_outline, tr('מין', 'Gender'), _genderLabel(gender)),
                ],
                if (city.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _infoRow(Icons.location_city_outlined, tr('עיר', 'City'), city),
                ],

                const SizedBox(height: 20),
                _secTitle(tr('סטטיסטיקות', 'STATS')),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _statCard(tr('הזמנות', 'BOOKINGS'), '$total', Icons.calendar_month, accentGreen),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _statCard(tr('מגרשים', 'STADIUMS'), '${allStadiums.length}', Icons.sports_soccer, Colors.blue),
                    ),
                  ],
                ),

                const SizedBox(height: 24),
                _secTitle(tr('חשבון', 'ACCOUNT')),
                const SizedBox(height: 12),
                _menuItem(Icons.edit_outlined, tr('ערוך פרטים', 'Edit Details'), accentGreen, () async {
                  final changed = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => EditProfileScreen(initial: data)),
                  );
                  if (changed == true && mounted) setState(_refresh);
                }),
                const SizedBox(height: 10),
                _menuItem(Icons.calendar_month_outlined, tr('הלוח זמנים שלי', 'My Schedule'), accentGreen,
                    () => navigateTo(context, const MyBookingsScreen())),
                const SizedBox(height: 10),
                _menuItem(Icons.logout, tr('יציאה', 'Sign Out'), Colors.red, () => _signOut(context)),
              ],
            ),
          );
        },
      ),
    );
  }

  String _genderLabel(String code) {
    switch (code) {
      case 'male':   return tr('זכר', 'Male');
      case 'female': return tr('נקבה', 'Female');
      case 'other':  return tr('אחר', 'Other');
      default:       return code;
    }
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: accentGreen.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accentGreen, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuItem(IconData icon, String label, Color color, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: borderColor)),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 14),
        Text(label, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
        const Spacer(),
        const Icon(Icons.arrow_forward_ios, color: Color(0xFF444444), size: 12),
      ]),
    ),
  );
}

// ==================== EDIT PROFILE ====================
class EditProfileScreen extends StatefulWidget {
  final Map<String, dynamic> initial;
  const EditProfileScreen({super.key, required this.initial});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _dobCtrl;
  late final TextEditingController _cityCtrl;
  String? _gender;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl  = TextEditingController(text: (widget.initial['name'] as String?) ?? '');
    _phoneCtrl = TextEditingController(text: (widget.initial['phone'] as String?) ?? '');
    _dobCtrl   = TextEditingController(text: (widget.initial['dob'] as String?) ?? '');
    _cityCtrl  = TextEditingController(text: (widget.initial['city'] as String?) ?? '');
    _gender    = (widget.initial['gender'] as String?);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _dobCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    DateTime initial = DateTime(now.year - 20, now.month, now.day);
    if (_dobCtrl.text.isNotEmpty) {
      try {
        final p = _dobCtrl.text.split('/');
        if (p.length == 3) {
          initial = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
        }
      } catch (_) {}
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1920),
      lastDate: DateTime(now.year - 5),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: accentGreen, surface: cardColor, onPrimary: bgColor),
          dialogBackgroundColor: cardColor,
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      _dobCtrl.text = '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      final name = _nameCtrl.text.trim();
      await user?.updateDisplayName(name);
      await FirebaseFirestore.instance.collection('users').doc(user!.uid).set({
        'name':  name,
        'phone': _phoneCtrl.text.trim(),
        'dob':   _dobCtrl.text.trim(),
        'gender': _gender ?? '',
        'city':  _cityCtrl.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await user.reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('הפרטים נשמרו ✓', 'Details saved ✓')),
        backgroundColor: accentGreen,
        duration: const Duration(seconds: 2),
      ));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('שגיאה בשמירה', 'Error saving')),
        backgroundColor: colorError,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: PlayerAppBar(title: tr('ערוך פרטים', 'Edit Details')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? spaceMd : spaceXl,
              vertical: spaceLg,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(spaceLg),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(radiusXl),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(children: [
                        appTextField(
                          controller: _nameCtrl,
                          label: tr('שם מלא', 'Full Name'),
                          icon: Icons.person_outline,
                          validator: (v) => (v == null || v.isEmpty) ? tr('שדה חובה', 'Required') : null,
                        ),
                        const SizedBox(height: spaceMd),
                        appTextField(
                          controller: _phoneCtrl,
                          label: tr('טלפון', 'Phone'),
                          icon: Icons.phone_outlined,
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: spaceMd),
                        appTextField(
                          controller: _dobCtrl,
                          label: tr('תאריך לידה (DD/MM/YYYY)', 'Date of Birth (DD/MM/YYYY)'),
                          icon: Icons.cake_outlined,
                          readOnly: true,
                          onTap: _pickDob,
                        ),
                        const SizedBox(height: spaceMd),
                        _genderDropdown(),
                        const SizedBox(height: spaceMd),
                        appTextField(
                          controller: _cityCtrl,
                          label: tr('עיר', 'City'),
                          icon: Icons.location_city_outlined,
                        ),
                        const SizedBox(height: spaceLg),
                        appPrimaryButton(
                          label: _saving ? tr('שומר...', 'Saving...') : tr('שמור', 'Save'),
                          icon: _saving ? null : Icons.save_outlined,
                          onPressed: _saving ? null : _save,
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _genderDropdown() {
    return DropdownButtonFormField<String>(
      value: _gender == null || _gender!.isEmpty ? null : _gender,
      dropdownColor: cardColor,
      style: const TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        labelText: tr('מין', 'Gender'),
        prefixIcon: const Icon(Icons.wc_outlined, color: textSecondary, size: 20),
        labelStyle: const TextStyle(color: textSecondary, fontSize: 13),
        filled: true,
        fillColor: cardColor,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: borderColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMd), borderSide: const BorderSide(color: accentGreen, width: 2)),
      ),
      items: [
        DropdownMenuItem(value: 'male',   child: Text(tr('זכר',  'Male'))),
        DropdownMenuItem(value: 'female', child: Text(tr('נקבה', 'Female'))),
        DropdownMenuItem(value: 'other',  child: Text(tr('אחר',  'Other'))),
      ],
      onChanged: (v) => setState(() => _gender = v),
    );
  }
}

// ==================== MY BOOKINGS ====================
class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});
  @override State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}
class _MyBookingsScreenState extends State<MyBookingsScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  late Future<List<QuerySnapshot>> _future;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _refresh();
  }

  void _refresh() {
    final user = FirebaseAuth.instance.currentUser;
    final myName = user?.displayName ?? user?.email ?? '';
    _future = Future.wait([
      FirebaseFirestore.instance.collection('bookings').where('userId', isEqualTo: user?.uid).get(),
      FirebaseFirestore.instance.collection('bookings').where('players', arrayContains: myName).get(),
    ]);
  }

  Future<void> _cancelBooking(String docId) async {
    try {
      await FirebaseFirestore.instance.collection('bookings').doc(docId).delete();
      if (!mounted) return;
      setState(_refresh);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('ההזמנה בוטלה ✓', 'Booking cancelled ✓')),
        backgroundColor: accentGreen,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('שגיאה בביטול', 'Error cancelling')),
        backgroundColor: colorError,
      ));
    }
  }

  Future<void> _leaveGame(String docId, String myName) async {
    try {
      await FirebaseFirestore.instance.collection('bookings').doc(docId).update({
        'players': FieldValue.arrayRemove([myName]),
      });
      if (!mounted) return;
      setState(_refresh);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('עזבת את המשחק ✓', 'Left the game ✓')),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('שגיאה בעזיבה', 'Error leaving')),
        backgroundColor: colorError,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final myName = user?.displayName ?? user?.email ?? '';
    return Scaffold(backgroundColor: bgColor,
      appBar: PlayerAppBar(
        title: tr('הלוח זמנים שלי','MY SCHEDULE'),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: accentGreen,
          labelColor: accentGreen,
          unselectedLabelColor: textSecondary,
          tabs: [Tab(text: tr('עתידיות 📅','Upcoming 📅')), Tab(text: tr('היסטוריה 📖','History 📖'))],
        ),
      ),
      body: RefreshIndicator(
        color: accentGreen,
        backgroundColor: cardColor,
        onRefresh: () async => setState(_refresh),
        child: FutureBuilder(
          future: _future,
          builder: (ctx, AsyncSnapshot<List<QuerySnapshot>> snap) {
          if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: accentGreen));
          if (!snap.hasData) return Center(child: Text(tr('שגיאה','Error'), style: const TextStyle(color: Colors.red)));
          final Map<String, QueryDocumentSnapshot> map = {};
          for (final d in snap.data![0].docs) map[d.id]=d;
          for (final d in snap.data![1].docs) map[d.id]=d;
          final docs = map.values.toList();
          final now = DateTime.now();
          final upcoming = <QueryDocumentSnapshot>[];
          final past = <QueryDocumentSnapshot>[];
          for (final doc in docs) {
            final b = doc.data() as Map<String,dynamic>;
            try {
              final parts = (b['date'] as String).split('/');
              final h = int.parse((b['time'] as String).split(':')[0]);
              final bookingDate = DateTime(now.year, int.parse(parts[1]), int.parse(parts[0]), h);
              if (bookingDate.isAfter(now)) { upcoming.add(doc); } else { past.add(doc); }
            } catch(_) { upcoming.add(doc); }
          }
          return TabBarView(controller: _tab, children: [
            _buildList(context, upcoming, myName, user, tr('אין הזמנות עתידיות','No upcoming bookings')),
            _buildList(context, past, myName, user, tr('אין היסטוריה','No booking history'), isPast: true),
          ]);
        },
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, List<QueryDocumentSnapshot> docs, String myName, User? user, String emptyMsg, {bool isPast = false}) {
    if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(isPast ? Icons.history : Icons.calendar_today_outlined, color: const Color(0xFF333333), size: 64),
      const SizedBox(height: 16),
      Text(emptyMsg, style: const TextStyle(color: textSecondary, fontSize: 16))]));

    return ListView.builder(padding: const EdgeInsets.all(16), itemCount: docs.length, addAutomaticKeepAlives: false, addRepaintBoundaries: true, itemBuilder: (ctx, i) {
      final doc = docs[i]; final b = doc.data() as Map<String,dynamic>;
      final players = (b['players'] as List?)??[]; final isOrg = b['userId']==user?.uid;
      bool canCancel = !isPast;
      if (!isPast) {
        try { final parts=(b['date'] as String).split('/'); final h=int.parse((b['time'] as String).split(':')[0]); final now=DateTime.now(); canCancel=DateTime(now.year,int.parse(parts[1]),int.parse(parts[0]),h).difference(now).inHours>=3; } catch(_) {}
      }
      return Container(margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isPast ? borderColor : isOrg?accentGreen.withValues(alpha: 0.3):Colors.blue.withValues(alpha: 0.2))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: isPast ? const Color(0xFF111111) : isOrg?accentGreen.withValues(alpha: 0.08):Colors.blue.withValues(alpha: 0.06), borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
            child: Row(children: [
              Icon(isPast ? Icons.history : (isOrg?Icons.star_outline:Icons.sports_soccer), color: isPast ? textSecondary : (isOrg?Colors.amber:Colors.blue), size: 14),
              const SizedBox(width: 6),
              Text(isPast ? tr('הסתיים','COMPLETED') : (isOrg?tr('מארגן','ORGANIZER'):tr('שחקן','PLAYER')),
                style: TextStyle(color: isPast ? textSecondary : (isOrg?Colors.amber:Colors.blue), fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2)),
              const Spacer(),
              if (isOrg) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: Text(b['bookingCode']??'', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, letterSpacing: 3, fontSize: 13))),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => showBookingDetails(context, b),
                child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.blue.withValues(alpha: 0.3))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.info_outline, color: Colors.blue, size: 12), const SizedBox(width: 4), Text(tr('פרטים','Details'), style: const TextStyle(color: Colors.blue, fontSize: 11, fontWeight: FontWeight.bold))])),
              ),
            ])),
          Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b['stadiumName']??'', style: TextStyle(color: isPast ? textSecondary : textPrimary, fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 6),
            Row(children: [const Icon(Icons.calendar_today_outlined,color:textSecondary,size:13),const SizedBox(width:4),Text('${b['day']} ${b['date']}',style:const TextStyle(color:textSecondary,fontSize:12)),const SizedBox(width:12),const Icon(Icons.access_time_outlined,color:textSecondary,size:13),const SizedBox(width:4),Text(b['time']??'',style:const TextStyle(color:textSecondary,fontSize:12))]),
            const SizedBox(height: 4),
            Text(b['price']??'', style: TextStyle(color: isPast ? textSecondary : accentGreen, fontSize: 13, fontWeight: FontWeight.bold)),
            if (players.isNotEmpty) ...[const SizedBox(height:8),Text('${tr('שחקנים','Players')}: ${players.length}/18', style: const TextStyle(color: textSecondary, fontSize: 12))],
            if (!isPast) ...[
              const SizedBox(height: 12),
              if (isOrg) SizedBox(width: double.infinity, child: TextButton(onPressed: canCancel?() async {
                final ok=await showDialog<bool>(context:context,builder:(_)=>AlertDialog(backgroundColor:cardColor,
                  title:Text(tr('ביטול הזמנה?','Cancel Booking?'),style:const TextStyle(color:textPrimary,fontWeight:FontWeight.bold)),
                  content:Text(tr('זה יבטל את ההזמנה לכל השחקנים.','This cancels for all players.'),style:const TextStyle(color:textSecondary)),
                  actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:Text(tr('השאר','KEEP'),style:const TextStyle(color:textSecondary))),TextButton(onPressed:()=>Navigator.pop(context,true),child:Text(tr('בטל','CANCEL'),style:const TextStyle(color:Colors.red,fontWeight:FontWeight.bold)))]));
                if (ok==true) await _cancelBooking(doc.id);
              }:null,
                style:TextButton.styleFrom(backgroundColor:canCancel?Colors.red.withValues(alpha:0.08):const Color(0xFF111111),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(8),side:BorderSide(color:canCancel?Colors.red.withValues(alpha:0.3):borderColor))),
                child:Text(canCancel?tr('בטל הזמנה','CANCEL BOOKING'):tr('לא ניתן לבטל (פחות מ-3 שעות)','CANNOT CANCEL (< 3 HRS)'),style:TextStyle(color:canCancel?Colors.red:const Color(0xFF444444),fontSize:12,fontWeight:FontWeight.w900))))
              else SizedBox(width:double.infinity,child:TextButton(onPressed:canCancel?()async{await _leaveGame(doc.id, myName);}:null,
                style:TextButton.styleFrom(backgroundColor:canCancel?Colors.orange.withValues(alpha:0.08):const Color(0xFF111111),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(8),side:BorderSide(color:canCancel?Colors.orange.withValues(alpha:0.3):borderColor))),
                child:Text(canCancel?tr('עזוב משחק','LEAVE GAME'):tr('לא ניתן לעזוב (פחות מ-3 שעות)','CANNOT LEAVE (< 3 HRS)'),style:TextStyle(color:canCancel?Colors.orange:const Color(0xFF444444),fontSize:12,fontWeight:FontWeight.w900)))),
            ],
          ])),
        ]));
    });
  }
}

// ==================== NOTIFICATIONS ====================
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(backgroundColor: bgColor, appBar: PlayerAppBar(title: tr('התראות','NOTIFICATIONS')),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance.collection('notifications').where('userId', isEqualTo: uid).orderBy('createdAt', descending: true).snapshots(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
          final docs = snap.data!.docs;
          if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.notifications_none, color: Color(0xFF333333), size: 64), const SizedBox(height: 16),
            Text(tr('אין התראות','No notifications'), style: const TextStyle(color: textSecondary, fontSize: 16)),
          ]));
          return ListView.builder(padding: const EdgeInsets.all(16), itemCount: docs.length, addAutomaticKeepAlives: false, addRepaintBoundaries: true, itemBuilder: (ctx, i) {
            final n = docs[i].data(); final isRead = n['read'] == true;
            return GestureDetector(
              onTap: () => FirebaseFirestore.instance.collection('notifications').doc(docs[i].id).update({'read': true}),
              child: Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: isRead ? cardColor : accentGreen.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12), border: Border.all(color: isRead ? borderColor : accentGreen.withValues(alpha: 0.3))),
                child: Row(children: [
                  Container(width: 36, height: 36, decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), shape: BoxShape.circle), child: const Icon(Icons.notifications_outlined, color: accentGreen, size: 18)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n['title'] ?? '', style: TextStyle(color: isRead ? textSecondary : textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(n['body'] ?? '', style: const TextStyle(color: textSecondary, fontSize: 12)),
                  ])),
                  if (!isRead) Container(width: 8, height: 8, decoration: const BoxDecoration(color: accentGreen, shape: BoxShape.circle)),
                ]),
              ),
            );
          });
        },
      ),
    );
  }
}

// ==================== BOOKING TYPES SCREEN ====================
class BookingTypesScreen extends StatefulWidget {
  final String stadiumId;
  final String stadiumName;
  const BookingTypesScreen({super.key, required this.stadiumId, required this.stadiumName});
  @override State<BookingTypesScreen> createState() => _BookingTypesScreenState();
}
class _BookingTypesScreenState extends State<BookingTypesScreen> {
  final _col = FirebaseFirestore.instance.collection('booking_types');
  bool _loading = false;

  Future<void> _loadDefaults() async {
    setState(() => _loading = true);
    final stadium = allStadiums.firstWhere((s) => s['id'] == widget.stadiumId, orElse: () => {'price': 300});
    for (final t in defaultBookingTypes) {
      await _col.add({...t, 'stadiumId': widget.stadiumId, 'price': stadium['price'] ?? t['price']});
    }
    setState(() => _loading = false);
  }

  Future<void> _showTypeDialog({Map<String, dynamic>? type, String? docId}) async {
    final nameCtrl   = TextEditingController(text: type?['name']   ?? '');
    final nameEnCtrl = TextEditingController(text: type?['nameEn'] ?? '');
    final priceCtrl  = TextEditingController(text: '${type?['price'] ?? 300}');
    String selIcon  = type?['icon']  ?? 'soccer';
    String selColor = type?['color'] ?? 'green';
    const icons  = ['soccer', 'cake', 'celebration', 'groups', 'party'];
    const colors = ['green',  'pink', 'purple',      'blue',   'orange'];
    bool saving = false;

    await showDialog(context: context, builder: (_) => StatefulBuilder(
      builder: (ctx, setS) => Dialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(docId == null ? tr('הוסף סוג', 'Add Type') : tr('ערוך סוג', 'Edit Type'),
            style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          _dialogTf(nameCtrl,   tr('שם (עברית)',  'Name (Hebrew)'),  Icons.label_outline),
          const SizedBox(height: 10),
          _dialogTf(nameEnCtrl, tr('שם (אנגלית)', 'Name (English)'), Icons.label_outline),
          const SizedBox(height: 10),
          _dialogTf(priceCtrl,  tr('מחיר', 'Price'), Icons.attach_money, type: TextInputType.number),
          const SizedBox(height: 14),
          Text(tr('אייקון', 'Icon'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: icons.map((ic) {
            final isSel = selIcon == ic;
            return GestureDetector(
              onTap: () => setS(() => selIcon = ic),
              child: Container(padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: isSel ? accentGreen.withValues(alpha: 0.15) : bgColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: isSel ? accentGreen : borderColor)),
                child: Icon(_iconForType(ic), color: isSel ? accentGreen : textSecondary, size: 22)),
            );
          }).toList()),
          const SizedBox(height: 14),
          Text(tr('צבע', 'Color'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: colors.map((c) {
            final isSel = selColor == c;
            final col = _colorForType(c);
            return GestureDetector(
              onTap: () => setS(() => selColor = c),
              child: Container(width: 32, height: 32, decoration: BoxDecoration(color: col, shape: BoxShape.circle, border: isSel ? Border.all(color: Colors.white, width: 3) : null)),
            );
          }).toList()),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary)))),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton(
              onPressed: saving ? null : () async {
                if (nameCtrl.text.trim().isEmpty) return;
                setS(() => saving = true);
                final data = {'name': nameCtrl.text.trim(), 'nameEn': nameEnCtrl.text.trim(), 'price': int.tryParse(priceCtrl.text.trim()) ?? 300, 'icon': selIcon, 'color': selColor, 'stadiumId': widget.stadiumId};
                if (docId == null) { await _col.add(data); } else { await _col.doc(docId).update(data); }
                setS(() => saving = false);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor),
              child: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: bgColor, strokeWidth: 2))
                : Text(tr('שמור', 'SAVE'), style: const TextStyle(fontWeight: FontWeight.w900)),
            )),
          ]),
        ])),
      ),
    ));
  }

  Future<void> _deleteType(String docId) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: cardColor,
      title: Text(tr('מחק סוג?', 'Delete Type?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Text(tr('האם למחוק סוג הזמנה זה?', 'Delete this booking type?'), style: const TextStyle(color: textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),  child: Text(tr('מחק',   'Delete'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
      ],
    ));
    if (ok == true) await _col.doc(docId).delete();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: AppBar(backgroundColor: bgColor, elevation: 0, iconTheme: const IconThemeData(color: textSecondary),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('סוגי הזמנות', 'Booking Types'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 16)),
        Text(widget.stadiumName, style: const TextStyle(color: accentGreen, fontSize: 11)),
      ]),
      actions: [IconButton(icon: const Icon(Icons.add_circle_outline, color: accentGreen), onPressed: () => _showTypeDialog()), _langButton(context)],
    ),
    body: StreamBuilder(
      stream: _col.where('stadiumId', isEqualTo: widget.stadiumId).snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.category_outlined, color: textSecondary, size: 56), const SizedBox(height: 16),
            Text(tr('אין סוגי הזמנות', 'No booking types'), style: const TextStyle(color: textSecondary, fontSize: 15)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _loading ? null : _loadDefaults,
              icon: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: bgColor, strokeWidth: 2)) : const Icon(Icons.download_outlined, size: 18),
              label: Text(tr('טען ברירות מחדל', 'Load Defaults')),
              style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
            ),
          ]));
        }
        return ListView(padding: const EdgeInsets.all(16), children: [
          _secTitle(tr('סוגי הזמנות', 'BOOKING TYPES')), const SizedBox(height: 12),
          ...docs.map((doc) {
            final t = doc.data();
            final col = _colorForType(t['color'] as String?);
            return ClipRRect(borderRadius: BorderRadius.circular(12), child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: cardColor, border: Border.all(color: borderColor)),
              child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(width: 3, color: col),
                Expanded(child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: col.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)), child: Icon(_iconForType(t['icon'] as String?), color: col, size: 20)),
                  title: Text('${t['name'] ?? ''} / ${t['nameEn'] ?? ''}', style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                  subtitle: Text('₪${t['price'] ?? ''}/2hr', style: TextStyle(color: col.withValues(alpha: 0.8), fontSize: 11)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.edit_outlined,   size: 18, color: textSecondary), onPressed: () => _showTypeDialog(type: t, docId: doc.id)),
                    IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),     onPressed: () => _deleteType(doc.id)),
                  ]),
                )),
              ])),
            ));
          }),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _loading ? null : _loadDefaults,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(tr('טען ברירות מחדל', 'Load Defaults')),
            style: OutlinedButton.styleFrom(foregroundColor: textSecondary, side: const BorderSide(color: borderColor), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          ),
        ]);
      },
    ),
  );
}

// ==================== TRAINING REGISTRATIONS (ADMIN) ====================
class TrainingRegistrationsScreen extends StatefulWidget {
  final String groupId, groupName;
  const TrainingRegistrationsScreen({super.key, required this.groupId, required this.groupName});
  @override State<TrainingRegistrationsScreen> createState() => _TrainingRegistrationsScreenState();
}

class _TrainingRegistrationsScreenState extends State<TrainingRegistrationsScreen> {

  Future<void> _confirmPayment(BuildContext ctx, String docId, Map<String, dynamic> r, {bool addMode = false}) async {
    final amountCtrl = TextEditingController(text: '${r['amount'] ?? ''}');
    final noteCtrl   = TextEditingController();
    String method = 'bank';
    bool saving = false;

    await showDialog(
      context: ctx,
      builder: (_) => StatefulBuilder(builder: (dCtx, setS) => Dialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(addMode ? tr('הוסף תשלום', 'Add Payment') : tr('אישור תשלום', 'Confirm Payment'),
            style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(r['childName'] ?? '', style: const TextStyle(color: Colors.teal, fontSize: 13)),
          const SizedBox(height: 16),
          _dialogTf(amountCtrl, tr('סכום (₪)', 'Amount (₪)'), Icons.attach_money, type: TextInputType.number),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: borderColor)),
            child: DropdownButton<String>(
              value: method, isExpanded: true, dropdownColor: cardColor, underline: const SizedBox(),
              items: [
                DropdownMenuItem(value: 'bank', child: Text(tr('העברה בנקאית', 'Bank Transfer'), style: const TextStyle(color: textPrimary))),
                DropdownMenuItem(value: 'visa', child: Text(tr('ויזה / כרטיס', 'Visa / Card'),   style: const TextStyle(color: textPrimary))),
                DropdownMenuItem(value: 'cash', child: Text(tr('מזומן', 'Cash'),                 style: const TextStyle(color: textPrimary))),
              ],
              onChanged: (v) => setS(() => method = v!),
            ),
          ),
          const SizedBox(height: 10),
          _dialogTf(noteCtrl, tr('הערה (אופציונלי)', 'Note (optional)'), Icons.notes_outlined),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary)))),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(
              onPressed: saving ? null : () async {
                setS(() => saving = true);
                final now = DateTime.now().toIso8601String();
                try {
                  final update = <String, dynamic>{
                    'paymentHistory': FieldValue.arrayUnion([{
                      'date': now, 'amount': int.tryParse(amountCtrl.text.trim()) ?? r['amount'],
                      'method': method, 'note': noteCtrl.text.trim(),
                    }]),
                  };
                  if (!addMode) {
                    update['status'] = 'paid'; update['paidAt'] = now; update['paymentMethod'] = method;
                  }
                  await FirebaseFirestore.instance.collection('training_registrations').doc(docId).update(update);
                  if (!addMode && (r['parentUserId'] as String?)?.isNotEmpty == true) {
                    await FirebaseFirestore.instance.collection('notifications').add({
                      'userId': r['parentUserId'],
                      'title':  tr('תשלום התקבל ✅', 'Payment Received ✅'),
                      'body':   tr('הרישום של ${r['childName']} פעיל!', 'Registration for ${r['childName']} is now active!'),
                      'read': false, 'createdAt': now,
                    });
                  }
                  if (dCtx.mounted) Navigator.pop(dCtx);
                } catch (e) {
                  setS(() => saving = false);
                  if (dCtx.mounted) ScaffoldMessenger.of(dCtx).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor),
              child: saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: bgColor, strokeWidth: 2))
                : Text(addMode ? tr('שמור', 'SAVE') : tr('אשר', 'CONFIRM'), style: const TextStyle(fontWeight: FontWeight.w900)),
            )),
          ]),
        ])),
      )),
    );
  }

  Future<void> _cancelReg(BuildContext ctx, String docId, String childName) async {
    final ok = await showDialog<bool>(context: ctx, builder: (_) => AlertDialog(
      backgroundColor: cardColor,
      title: Text(tr('בטל רישום?', 'Cancel Registration?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(childName, style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(tr('הסטטוס ישתנה ל-מבוטל', 'Status will change to cancelled'), style: const TextStyle(color: textSecondary, fontSize: 13)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('חזור', 'Back'), style: const TextStyle(color: textSecondary))),
        TextButton(onPressed: () => Navigator.pop(ctx, true),  child: Text(tr('בטל', 'Cancel'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
      ],
    ));
    if (ok != true) return;
    await FirebaseFirestore.instance.collection('training_registrations').doc(docId).update({'status': 'cancelled'});
    if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('הרישום בוטל', 'Cancelled')), backgroundColor: Colors.red));
  }

  Widget _regCard(BuildContext ctx, dynamic doc) {
    final r      = doc.data() as Map<String, dynamic>;
    final status = r['status'] as String? ?? 'pending';
    final Color  statusColor = status == 'paid' ? Colors.green : status == 'cancelled' ? Colors.red : Colors.orange;
    final String statusLabel = status == 'paid' ? tr('שולם', 'PAID') : status == 'cancelled' ? tr('מבוטל', 'CANCELLED') : tr('ממתין', 'PENDING');
    final payHistory = (r['paymentHistory'] as List? ?? []);
    final initial = (r['childName'] as String? ?? 'x').isNotEmpty ? (r['childName'] as String)[0].toUpperCase() : '?';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.07), borderRadius: const BorderRadius.vertical(top: Radius.circular(14))),
          child: Row(children: [
            Container(width: 34, height: 34, decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
              child: Center(child: Text(initial, style: TextStyle(color: statusColor, fontWeight: FontWeight.w900, fontSize: 16)))),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['childName'] ?? '', style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
              Text('${tr('גיל', 'Age')} ${r['childAge'] ?? ''}', style: const TextStyle(color: textSecondary, fontSize: 11)),
            ])),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6), border: Border.all(color: statusColor.withValues(alpha: 0.4))),
              child: Text(statusLabel, style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1))),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _groupInfoRow(Icons.person_outline, r['parentName'] ?? ''),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: r['parentPhone'] ?? ''));
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('הטלפון הועתק', 'Phone copied')), duration: const Duration(seconds: 2), backgroundColor: Colors.teal));
            },
            child: Row(children: [
              const Icon(Icons.phone, color: Colors.blue, size: 13), const SizedBox(width: 6),
              Text(r['parentPhone'] ?? '', style: const TextStyle(color: Colors.blue, fontSize: 12, decoration: TextDecoration.underline)),
              const SizedBox(width: 4),
              const Icon(Icons.copy_outlined, color: Colors.blue, size: 11),
            ]),
          ),
          if ((r['registeredAt'] as String? ?? '').length >= 10) ...[
            const SizedBox(height: 4),
            _groupInfoRow(Icons.schedule, (r['registeredAt'] as String).substring(0, 10)),
          ],
          if (payHistory.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withValues(alpha: 0.2))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('היסטוריית תשלומים:', 'Payment History:'), style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ...payHistory.map((ph) {
                  final pm   = ph as Map<String, dynamic>;
                  final date = (pm['date'] as String? ?? '').length >= 10 ? (pm['date'] as String).substring(0, 10) : '';
                  return Padding(padding: const EdgeInsets.only(top: 3),
                    child: Row(children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 11), const SizedBox(width: 4),
                      Text('₪${pm['amount']} • ${pm['method'] ?? ''} • $date', style: const TextStyle(color: textSecondary, fontSize: 11)),
                    ]));
                }),
              ])),
          ],
        ])),
        Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 10), child: Wrap(spacing: 6, runSpacing: 6, children: [
          if (status == 'pending')
            TextButton.icon(
              onPressed: () => _confirmPayment(ctx, doc.id as String, r),
              icon: const Icon(Icons.check_circle_outline, size: 14, color: accentGreen),
              label: Text(tr('אשר תשלום', 'Confirm Payment'), style: const TextStyle(color: accentGreen, fontSize: 11)),
              style: TextButton.styleFrom(backgroundColor: accentGreen.withValues(alpha: 0.08), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            ),
          if (status == 'paid')
            TextButton.icon(
              onPressed: () => _confirmPayment(ctx, doc.id as String, r, addMode: true),
              icon: const Icon(Icons.add_circle_outline, size: 14, color: Colors.blue),
              label: Text(tr('הוסף תשלום', 'Add Payment'), style: const TextStyle(color: Colors.blue, fontSize: 11)),
              style: TextButton.styleFrom(backgroundColor: Colors.blue.withValues(alpha: 0.07), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            ),
          if (status != 'cancelled')
            TextButton.icon(
              onPressed: () => _cancelReg(ctx, doc.id as String, r['childName'] ?? ''),
              icon: const Icon(Icons.remove_circle_outline, size: 14, color: Colors.red),
              label: Text(tr('בטל', 'Cancel'), style: const TextStyle(color: Colors.red, fontSize: 11)),
              style: TextButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.07), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            ),
        ])),
      ]),
    );
  }

  Widget _regList(BuildContext ctx, List<dynamic> docs, String emptyMsg) {
    if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.inbox, color: textSecondary, size: 48), const SizedBox(height: 12),
      Text(emptyMsg, style: const TextStyle(color: textSecondary)),
    ]));
    return ListView(padding: const EdgeInsets.all(14), children: [
      ...docs.map((doc) => _regCard(ctx, doc)),
      const SizedBox(height: 60),
    ]);
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor, elevation: 0,
        iconTheme: const IconThemeData(color: textSecondary),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(tr('נרשמים', 'REGISTRATIONS'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 2)),
          Text(widget.groupName, style: const TextStyle(color: Colors.teal, fontSize: 12)),
        ]),
        actions: [_langButton(context)],
        bottom: const TabBar(
          indicatorColor: accentGreen, labelColor: accentGreen, unselectedLabelColor: textSecondary,
          tabs: [Tab(text: 'ממתינים'), Tab(text: 'פעילים'), Tab(text: 'בוטלו')],
        ),
      ),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance.collection('training_registrations').where('groupId', isEqualTo: widget.groupId).snapshots(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
          final docs      = snap.data!.docs;
          final pending   = docs.where((d) { final s = d.data()['status'] as String?; return s == null || s == 'pending'; }).toList();
          final paid      = docs.where((d) => d.data()['status'] == 'paid').toList();
          final cancelled = docs.where((d) => d.data()['status'] == 'cancelled').toList();
          return TabBarView(children: [
            _regList(ctx, pending,   tr('אין רישומים ממתינים', 'No pending registrations')),
            _regList(ctx, paid,      tr('אין רישומים פעילים',  'No active registrations')),
            _regList(ctx, cancelled, tr('אין רישומים מבוטלים', 'No cancelled registrations')),
          ]);
        },
      ),
    ),
  );
}

// ==================== TRAINING GROUPS ADMIN ====================
class TrainingGroupsAdminScreen extends StatelessWidget {
  final String stadiumId, stadiumName;
  const TrainingGroupsAdminScreen({super.key, required this.stadiumId, required this.stadiumName});

  Future<void> _showGroupDialog(BuildContext context, {Map<String, dynamic>? group, String? docId}) async {
    final nameCtrl     = TextEditingController(text: group?['name']          ?? '');
    final nameEnCtrl   = TextEditingController(text: group?['nameEn']        ?? '');
    final ageCtrl      = TextEditingController(text: group?['ageGroup']      ?? '');
    final coachCtrl    = TextEditingController(text: group?['coach']         ?? '');
    final priceCtrl    = TextEditingController(text: '${group?['price']     ?? ''}');
    final descCtrl     = TextEditingController(text: group?['description']   ?? '');
    final capacityCtrl = TextEditingController(text: '${group?['capacity']  ?? ''}');
    final bankCtrl     = TextEditingController(text: group?['bankDetails']   ?? '');
    final officeCtrl   = TextEditingController(text: group?['officeAddress'] ?? '');

    String priceType      = group?['priceType'] ?? 'monthly';
    Set<int> selectedDays = Set<int>.from((group?['days'] as List? ?? []).map((d) => d as int));
    String startTime      = group?['startTime'] ?? '16:00';
    String endTime        = group?['endTime']   ?? '18:00';
    bool saving = false;

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) => Dialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(docId == null ? tr('הוסף קבוצה', 'Add Group') : tr('ערוך קבוצה', 'Edit Group'),
            style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          _dialogTf(nameCtrl,   tr('שם קבוצה (עברית)',   'Group Name (Hebrew)'),   Icons.groups_outlined),
          const SizedBox(height: 10),
          _dialogTf(nameEnCtrl, tr('שם קבוצה (אנגלית)',  'Group Name (English)'),  Icons.groups_outlined),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _dialogTf(ageCtrl,   tr('גיל (למשל 8-10)', 'Age (e.g. 8-10)'), Icons.cake_outlined)),
            const SizedBox(width: 10),
            Expanded(child: _dialogTf(coachCtrl, tr('מאמן', 'Coach'),               Icons.person_outline)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _dialogTf(priceCtrl,    tr('מחיר', 'Price'),    Icons.attach_money,      type: TextInputType.number)),
            const SizedBox(width: 10),
            Expanded(child: _dialogTf(capacityCtrl, tr('קיבולת', 'Capacity'), Icons.people_outline,  type: TextInputType.number)),
          ]),
          const SizedBox(height: 12),
          Text(tr('סוג תשלום', 'Payment Type'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: GestureDetector(
              onTap: () => setS(() => priceType = 'monthly'),
              child: Container(padding: const EdgeInsets.symmetric(vertical: 10), alignment: Alignment.center,
                decoration: BoxDecoration(color: priceType == 'monthly' ? accentGreen : bgColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: priceType == 'monthly' ? accentGreen : borderColor)),
                child: Text(tr('חודשי', 'Monthly'), style: TextStyle(color: priceType == 'monthly' ? bgColor : textSecondary, fontWeight: FontWeight.bold, fontSize: 12))),
            )),
            const SizedBox(width: 8),
            Expanded(child: GestureDetector(
              onTap: () => setS(() => priceType = 'season'),
              child: Container(padding: const EdgeInsets.symmetric(vertical: 10), alignment: Alignment.center,
                decoration: BoxDecoration(color: priceType == 'season' ? accentGreen : bgColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: priceType == 'season' ? accentGreen : borderColor)),
                child: Text(tr('לעונה', 'Per Season'), style: TextStyle(color: priceType == 'season' ? bgColor : textSecondary, fontWeight: FontWeight.bold, fontSize: 12))),
            )),
          ]),
          const SizedBox(height: 12),
          Text(tr('ימי אימון', 'Training Days'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: List.generate(7, (i) {
            final isSel = selectedDays.contains(i);
            return GestureDetector(
              onTap: () => setS(() { if (isSel) { selectedDays.remove(i); } else { selectedDays.add(i); } }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: isSel ? accentGreen.withValues(alpha: 0.15) : bgColor, borderRadius: BorderRadius.circular(20), border: Border.all(color: isSel ? accentGreen : borderColor)),
                child: Text(isHebrew ? trainingDayNames[i] : trainingDayNamesEn[i],
                  style: TextStyle(color: isSel ? accentGreen : textSecondary, fontSize: 12, fontWeight: isSel ? FontWeight.bold : FontWeight.normal)),
              ),
            );
          })),
          const SizedBox(height: 12),
          Text(tr('שעות אימון', 'Training Hours'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('התחלה', 'Start'), style: const TextStyle(color: textSecondary, fontSize: 11)),
              const SizedBox(height: 4),
              DropdownButton<String>(value: startTime, isExpanded: true, dropdownColor: cardColor,
                items: allStartTimes.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(color: textPrimary, fontSize: 13)))).toList(),
                onChanged: (v) => setS(() => startTime = v!)),
            ])),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('—', style: TextStyle(color: textSecondary, fontSize: 18))),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('סיום', 'End'), style: const TextStyle(color: textSecondary, fontSize: 11)),
              const SizedBox(height: 4),
              DropdownButton<String>(value: endTime, isExpanded: true, dropdownColor: cardColor,
                items: allStartTimes.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(color: textPrimary, fontSize: 13)))).toList(),
                onChanged: (v) => setS(() => endTime = v!)),
            ])),
          ]),
          const SizedBox(height: 10),
          TextField(controller: descCtrl, maxLines: 3, style: const TextStyle(color: textPrimary, fontSize: 13),
            decoration: InputDecoration(hintText: tr('תיאור הקבוצה...', 'Group description...'), hintStyle: const TextStyle(color: textSecondary),
              prefixIcon: const Icon(Icons.description_outlined, color: textSecondary, size: 18),
              filled: true, fillColor: bgColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accentGreen, width: 1.5)))),
          const SizedBox(height: 10),
          TextField(controller: bankCtrl, maxLines: 2, style: const TextStyle(color: textPrimary, fontSize: 13),
            decoration: InputDecoration(hintText: tr('פרטי בנק...', 'Bank details...'), hintStyle: const TextStyle(color: textSecondary),
              prefixIcon: const Icon(Icons.account_balance_outlined, color: textSecondary, size: 18),
              filled: true, fillColor: bgColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accentGreen, width: 1.5)))),
          const SizedBox(height: 10),
          _dialogTf(officeCtrl, tr('כתובת משרד', 'Office Address'), Icons.location_on_outlined),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary)))),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton(
              onPressed: saving ? null : () async {
                if (nameCtrl.text.trim().isEmpty) return;
                setS(() => saving = true);
                final now = DateTime.now().toIso8601String();
                final data = <String, dynamic>{
                  'stadiumId':     stadiumId,
                  'venueId':       venueForStadium(stadiumId)?['id']   ?? '',
                  'venueName':     venueForStadium(stadiumId)?['name'] ?? '',
                  'name':          nameCtrl.text.trim(),
                  'nameEn':        nameEnCtrl.text.trim(),
                  'ageGroup':      ageCtrl.text.trim(),
                  'coach':         coachCtrl.text.trim(),
                  'price':         int.tryParse(priceCtrl.text.trim()) ?? 0,
                  'priceType':     priceType,
                  'days':          (selectedDays.toList()..sort()),
                  'startTime':     startTime,
                  'endTime':       endTime,
                  'capacity':      int.tryParse(capacityCtrl.text.trim()) ?? 0,
                  'description':   descCtrl.text.trim(),
                  'bankDetails':   bankCtrl.text.trim(),
                  'officeAddress': officeCtrl.text.trim(),
                  'updatedAt':     now,
                };
                if (docId == null) {
                  await FirebaseFirestore.instance.collection('training_groups').add({...data, 'createdAt': now});
                } else {
                  await FirebaseFirestore.instance.collection('training_groups').doc(docId).update(data);
                }
                setS(() => saving = false);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor),
              child: saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: bgColor, strokeWidth: 2))
                : Text(tr('שמור', 'SAVE'), style: const TextStyle(fontWeight: FontWeight.w900)),
            )),
          ]),
        ])),
      )),
    );
  }

  Future<void> _deleteGroup(BuildContext context, String docId, String name) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: cardColor,
      title: Text(tr('מחק קבוצה?', 'Delete Group?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(tr('האם למחוק את הקבוצה? כל הרישומים יימחקו גם הם.', 'Delete group? All registrations will be deleted too.'), style: const TextStyle(color: textSecondary)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),  child: Text(tr('מחק',  'Delete'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
      ],
    ));
    if (ok != true) return;
    final regs = await FirebaseFirestore.instance.collection('training_registrations').where('groupId', isEqualTo: docId).get();
    final batch = FirebaseFirestore.instance.batch();
    for (final d in regs.docs) batch.delete(d.reference);
    batch.delete(FirebaseFirestore.instance.collection('training_groups').doc(docId));
    await batch.commit();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: _appBar('${tr('קבוצות אימון', 'TRAINING GROUPS')} — $stadiumName', context),
    floatingActionButton: FloatingActionButton(
      backgroundColor: accentGreen, foregroundColor: bgColor,
      onPressed: () => _showGroupDialog(context),
      child: const Icon(Icons.add),
    ),
    body: StreamBuilder(
      stream: FirebaseFirestore.instance.collection('training_groups').where('stadiumId', isEqualTo: stadiumId).snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
        final docs = snap.data!.docs;
        if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.groups_outlined, color: textSecondary, size: 56), const SizedBox(height: 16),
          Text(tr('אין קבוצות אימון', 'No training groups'), style: const TextStyle(color: textSecondary, fontSize: 15)),
          const SizedBox(height: 6),
          Text(tr('לחץ + להוסיף', 'Tap + to add'), style: const TextStyle(color: textSecondary, fontSize: 12)),
        ]));
        return ListView(padding: const EdgeInsets.all(16), children: [
          _secTitle(tr('קבוצות אימון', 'TRAINING GROUPS')), const SizedBox(height: 12),
          ...docs.map((doc) {
            final g = doc.data();
            final dayList = (g['days'] as List? ?? []).map((d) => isHebrew ? trainingDayNames[d as int] : trainingDayNamesEn[d as int]).join(', ');
            final priceLabel = g['priceType'] == 'season' ? tr('לעונה', '/ season') : tr('/ חודש', '/ month');
            final groupDisplayName = isHebrew ? (g['name'] ?? '') : (g['nameEn'] ?? g['name'] ?? '');
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.08), borderRadius: const BorderRadius.vertical(top: Radius.circular(14))),
                  child: Row(children: [
                    Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.groups, color: Colors.teal, size: 20)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(groupDisplayName, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                      if ((g['ageGroup'] as String? ?? '').isNotEmpty)
                        Text(tr('גיל: ${g['ageGroup']}', 'Age: ${g['ageGroup']}'), style: const TextStyle(color: textSecondary, fontSize: 11)),
                    ])),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('₪${g['price']} $priceLabel', style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold, fontSize: 13)),
                      StreamBuilder(
                        stream: FirebaseFirestore.instance.collection('training_registrations').where('groupId', isEqualTo: doc.id).snapshots(),
                        builder: (_, rs) {
                          final count = rs.data?.docs.length ?? 0;
                          final cap   = g['capacity'] as int? ?? 0;
                          return Text('$count${cap > 0 ? '/$cap' : ''} ${tr('נרשמים', 'reg.')}', style: const TextStyle(color: textSecondary, fontSize: 11));
                        },
                      ),
                    ]),
                  ]),
                ),
                Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (dayList.isNotEmpty) Row(children: [const Icon(Icons.calendar_today_outlined, color: textSecondary, size: 13), const SizedBox(width: 6), Expanded(child: Text(dayList, style: const TextStyle(color: textSecondary, fontSize: 12)))]),
                  if ((g['startTime'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(children: [const Icon(Icons.access_time_outlined, color: textSecondary, size: 13), const SizedBox(width: 6), Text('${g['startTime']} — ${g['endTime']}', style: const TextStyle(color: textSecondary, fontSize: 12))]),
                  ],
                  if ((g['coach'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(children: [const Icon(Icons.person_outline, color: textSecondary, size: 13), const SizedBox(width: 6), Text(g['coach'], style: const TextStyle(color: textSecondary, fontSize: 12))]),
                  ],
                ])),
                Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 10), child: Row(children: [
                  Expanded(child: TextButton.icon(
                    onPressed: () => navigateTo(context, TrainingRegistrationsScreen(groupId: doc.id, groupName: groupDisplayName)),
                    icon: const Icon(Icons.people_outline, size: 15, color: Colors.blue),
                    label: Text(tr('נרשמים', 'Reg.'), style: const TextStyle(color: Colors.blue, fontSize: 11)),
                    style: TextButton.styleFrom(backgroundColor: Colors.blue.withValues(alpha: 0.07), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  )),
                  const SizedBox(width: 6),
                  Expanded(child: TextButton.icon(
                    onPressed: () => _showGroupDialog(context, group: g, docId: doc.id),
                    icon: const Icon(Icons.edit_outlined, size: 15, color: textSecondary),
                    label: Text(tr('ערוך', 'Edit'), style: const TextStyle(color: textSecondary, fontSize: 11)),
                    style: TextButton.styleFrom(backgroundColor: borderColor.withValues(alpha: 0.3), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  )),
                  const SizedBox(width: 6),
                  Expanded(child: TextButton.icon(
                    onPressed: () => _deleteGroup(context, doc.id, groupDisplayName),
                    icon: const Icon(Icons.delete_outline, size: 15, color: Colors.red),
                    label: Text(tr('מחק', 'Delete'), style: const TextStyle(color: Colors.red, fontSize: 11)),
                    style: TextButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.07), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  )),
                ])),
              ]),
            );
          }),
          const SizedBox(height: 80),
        ]);
      },
    ),
  );
}

// ==================== STADIUM IMAGE SCREEN ====================
class StadiumImageScreen extends StatefulWidget {
  final String stadiumId, stadiumName;
  const StadiumImageScreen({super.key, required this.stadiumId, required this.stadiumName});
  @override State<StadiumImageScreen> createState() => _StadiumImageScreenState();
}

class _StadiumImageScreenState extends State<StadiumImageScreen> {
  String? _currentUrl;
  bool _loading = true, _uploading = false;
  double _progress = 0;

  @override void initState() { super.initState(); _loadCurrent(); }

  Future<void> _loadCurrent() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('stadium_config').doc(widget.stadiumId).get();
      if (doc.exists) _currentUrl = doc.data()?['backgroundImage'] as String?;
    } catch (_) {}
    setState(() => _loading = false);
  }

  Future<void> _pickAndUpload() async {
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
      if (picked == null) return;
      setState(() { _uploading = true; _progress = 0; });

      final Uint8List bytes = await picked.readAsBytes();
      final fileName = '${widget.stadiumId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = FirebaseStorage.instance.ref().child('stadium_images').child(fileName);

      final task = ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      task.snapshotEvents.listen((s) {
        if (s.totalBytes > 0) setState(() => _progress = s.bytesTransferred / s.totalBytes);
      });
      await task;
      final url = await ref.getDownloadURL();

      await FirebaseFirestore.instance.collection('stadium_config').doc(widget.stadiumId).set(
        {'backgroundImage': url, 'updatedAt': DateTime.now().toIso8601String()},
        SetOptions(merge: true),
      );

      setState(() { _currentUrl = url; _uploading = false; });
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('התמונה הועלתה! 🎨', 'Image uploaded! 🎨')), backgroundColor: accentGreen)); }
    } catch (e) {
      setState(() => _uploading = false);
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('שגיאה: $e', 'Error: $e')), backgroundColor: Colors.red)); }
    }
  }

  Future<void> _removeImage() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: cardColor,
      title: Text(tr('להסיר תמונה?', 'Remove image?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Text(tr('תחזור לתמונת ברירת המחדל', 'Will restore default image'), style: const TextStyle(color: textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),  child: Text(tr('הסר',  'Remove'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
      ],
    ));
    if (ok == true) {
      await FirebaseFirestore.instance.collection('stadium_config').doc(widget.stadiumId).update({'backgroundImage': FieldValue.delete()});
      setState(() => _currentUrl = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: _appBar('${tr('תמונת רקע', 'IMAGE')} — ${widget.stadiumName}', context),
    body: _loading
      ? const Center(child: CircularProgressIndicator(color: accentGreen))
      : ListView(padding: const EdgeInsets.all(16), children: [
          _secTitle(tr('תצוגה מקדימה', 'PREVIEW')), const SizedBox(height: 10),
          ClipRRect(borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 200, width: double.infinity,
              decoration: BoxDecoration(
                gradient: _currentUrl == null
                  ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [accentGreen.withValues(alpha: 0.25), const Color(0xFF0D0D0D)])
                  : null,
              ),
              child: _currentUrl != null
                ? Image.network(_currentUrl!, fit: BoxFit.cover,
                    cacheHeight: 400, cacheWidth: 1200,
                    loadingBuilder: (_, child, p) => p == null ? child
                      : const Center(child: CircularProgressIndicator(color: accentGreen)),
                    errorBuilder: (_, __, ___) => Center(child: Icon(Icons.broken_image, color: Colors.red.withValues(alpha: 0.6), size: 48)))
                : Center(child: Icon(Icons.sports_soccer, color: accentGreen.withValues(alpha: 0.6), size: 80)),
            )),
          const SizedBox(height: 6),
          if (_currentUrl == null)
            Text(tr('ברירת מחדל (אין תמונה)', 'Default (no image)'), textAlign: TextAlign.center, style: const TextStyle(color: textSecondary, fontSize: 11)),
          const SizedBox(height: 24),
          if (_uploading) ...[
            Container(padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Row(children: [
                  const Icon(Icons.cloud_upload_outlined, color: accentGreen, size: 18), const SizedBox(width: 8),
                  Text(tr('מעלה תמונה...', 'Uploading...'), style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 10),
                ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: _progress, backgroundColor: bgColor, valueColor: const AlwaysStoppedAnimation<Color>(accentGreen), minHeight: 8)),
                const SizedBox(height: 6),
                Text('${(_progress * 100).toInt()}%', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
              ])),
          ] else ...[
            SizedBox(width: double.infinity, height: 54,
              child: ElevatedButton.icon(
                onPressed: _pickAndUpload,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 22),
                label: Text(tr('בחר תמונה מהגלריה', 'CHOOSE IMAGE FROM GALLERY'), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
                style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              )),
            if (_currentUrl != null) ...[
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, height: 48,
                child: TextButton.icon(
                  onPressed: _removeImage,
                  icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                  label: Text(tr('הסר תמונה', 'REMOVE IMAGE'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w900)),
                  style: TextButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.08), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: Colors.red.withValues(alpha: 0.3)))),
                )),
            ],
          ],
          const SizedBox(height: 24),
          Container(padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blue.withValues(alpha: 0.2))),
            child: Row(children: [
              const Icon(Icons.info_outline, color: Colors.blue, size: 16), const SizedBox(width: 8),
              Expanded(child: Text(
                tr('💡 התמונה תוצג במסך הבית של האפליקציה על כרטיס המגרש', '💡 The image will appear on the stadium card in the home screen'),
                style: const TextStyle(color: Colors.blue, fontSize: 12))),
            ])),
        ]),
  );
}

// ==================== VENUE IMAGE (admin upload) ====================
class VenueImageScreen extends StatefulWidget {
  final String venueId, venueName;
  const VenueImageScreen({super.key, required this.venueId, required this.venueName});
  @override State<VenueImageScreen> createState() => _VenueImageScreenState();
}

class _VenueImageScreenState extends State<VenueImageScreen> {
  String? _currentUrl;
  bool _loading = true, _uploading = false;
  double _progress = 0;

  @override void initState() { super.initState(); _loadCurrent(); }

  Future<void> _loadCurrent() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('venue_config').doc(widget.venueId).get();
      if (doc.exists) _currentUrl = doc.data()?['backgroundImage'] as String?;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickAndUpload() async {
    // Save as base64 in Firestore instead of Firebase Storage (Storage
    // requires the Blaze plan since 2024). Firestore is on the free tier.
    // We compress aggressively to stay well under the 1MB document limit.
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,        // small enough for a 110px-tall card header
        imageQuality: 60,     // ~50–80KB JPEG → ~70–110KB base64
      );
      if (picked == null) return;
      setState(() { _uploading = true; _progress = 0.1; });

      final Uint8List bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception(tr('הקובץ ריק או לא ניתן לקריאה', 'File is empty or unreadable'));
      }
      // Hard cap: Firestore docs cap at 1MB. base64 inflates by ~33%, so
      // we limit the raw image to ~700KB to leave headroom for other fields.
      if (bytes.length > 700 * 1024) {
        throw Exception(tr(
          'התמונה גדולה מדי (${(bytes.length / 1024).round()} KB). מקסימום ~700 KB. בחר תמונה קטנה יותר או ירד באיכות.',
          'Image too large (${(bytes.length / 1024).round()} KB). Max ~700 KB. Pick a smaller image.',
        ));
      }

      setState(() => _progress = 0.5);
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';

      setState(() => _progress = 0.8);
      await FirebaseFirestore.instance.collection('venue_config').doc(widget.venueId).set(
        {
          'backgroundImage': dataUrl,
          'updatedAt': DateTime.now().toIso8601String(),
        },
        SetOptions(merge: true),
      );

      if (!mounted) return;
      setState(() { _currentUrl = dataUrl; _uploading = false; _progress = 1; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('התמונה נשמרה! 🎨', 'Image saved! 🎨')),
        backgroundColor: accentGreen,
      ));
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
          'שגיאת Firebase (${e.code}): ${e.message ?? ""}',
          'Firebase error (${e.code}): ${e.message ?? ""}',
        )),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 8),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('שגיאה: $e', 'Error: $e')),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  Future<void> _removeImage() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: cardColor,
      title: Text(tr('להסיר תמונה?', 'Remove image?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Text(tr('תחזור לתמונת ברירת המחדל', 'Will restore default image'), style: const TextStyle(color: textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),  child: Text(tr('הסר',  'Remove'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
      ],
    ));
    if (ok == true) {
      // Storage write requires Blaze plan; we now store as base64 in
      // Firestore, so removal is a single field delete. If a legacy URL
      // (gs://… or https://…firebasestorage…) is present, try to delete
      // the underlying Storage file too — best-effort, won't block.
      final value = _currentUrl;
      try {
        if (value != null && value.isNotEmpty && !value.startsWith('data:')) {
          await FirebaseStorage.instance.refFromURL(value).delete();
        }
      } catch (_) {/* legacy file may be missing or Storage unavailable — ignore */}
      try {
        await FirebaseFirestore.instance.collection('venue_config').doc(widget.venueId).update({'backgroundImage': FieldValue.delete()});
      } catch (_) {/* doc may not exist; that's fine */}
      if (mounted) {
        setState(() => _currentUrl = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('התמונה הוסרה', 'Image removed')), backgroundColor: accentGreen,
        ));
      }
    }
  }

  /// Renders either an `Image.memory` (for base64 data URLs stored in
  /// Firestore — current free-tier path) or `Image.network` (for legacy
  /// Firebase Storage URLs).
  Widget _buildPreview(String src) {
    if (src.startsWith('data:image')) {
      try {
        final base64Part = src.split(',').last;
        final bytes = base64Decode(base64Part);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          cacheHeight: 400, cacheWidth: 1200,
          errorBuilder: (_, __, ___) => Center(
            child: Icon(Icons.broken_image, color: Colors.red.withValues(alpha: 0.6), size: 48),
          ),
        );
      } catch (_) {
        return Center(child: Icon(Icons.broken_image, color: Colors.red.withValues(alpha: 0.6), size: 48));
      }
    }
    return Image.network(
      src,
      fit: BoxFit.cover,
      cacheHeight: 400, cacheWidth: 1200,
      loadingBuilder: (_, child, p) => p == null ? child
          : const Center(child: CircularProgressIndicator(color: accentGreen)),
      errorBuilder: (_, __, ___) => Center(
        child: Icon(Icons.broken_image, color: Colors.red.withValues(alpha: 0.6), size: 48),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: AppBar(
      backgroundColor: bgColor,
      elevation: 0,
      iconTheme: const IconThemeData(color: textSecondary),
      title: Text(
        '${tr('תמונת מתחם', 'VENUE IMAGE')} — ${widget.venueName}',
        style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 16),
      ),
    ),
    body: _loading
      ? const Center(child: CircularProgressIndicator(color: accentGreen))
      : ListView(padding: const EdgeInsets.all(16), children: [
          _secTitle(tr('תצוגה מקדימה', 'PREVIEW')), const SizedBox(height: 10),
          ClipRRect(borderRadius: BorderRadius.circular(radiusXl),
            child: Container(
              height: 200, width: double.infinity,
              decoration: BoxDecoration(
                gradient: _currentUrl == null
                  ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [accentGreen.withValues(alpha: 0.25), const Color(0xFF0D0D0D)])
                  : null,
              ),
              child: _currentUrl != null
                ? _buildPreview(_currentUrl!)
                : const Center(child: Icon(Icons.stadium_rounded, color: accentGreen, size: 80)),
            )),
          const SizedBox(height: 6),
          if (_currentUrl == null)
            Text(tr('ברירת מחדל (אין תמונה)', 'Default (no image)'), textAlign: TextAlign.center, style: const TextStyle(color: textSecondary, fontSize: 11)),
          const SizedBox(height: 24),
          if (_uploading) ...[
            Container(padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Row(children: [
                  const Icon(Icons.cloud_upload_outlined, color: accentGreen, size: 18), const SizedBox(width: 8),
                  Text(tr('מעלה תמונה...', 'Uploading...'), style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 10),
                ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: _progress, backgroundColor: bgColor, valueColor: const AlwaysStoppedAnimation<Color>(accentGreen), minHeight: 8)),
                const SizedBox(height: 6),
                Text('${(_progress * 100).toInt()}%', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
              ])),
          ] else ...[
            SizedBox(width: double.infinity, height: 54,
              child: ElevatedButton.icon(
                onPressed: _pickAndUpload,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 22),
                label: Text(tr('בחר תמונה מהגלריה', 'CHOOSE IMAGE FROM GALLERY'), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
                style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              )),
            if (_currentUrl != null) ...[
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, height: 48,
                child: TextButton.icon(
                  onPressed: _removeImage,
                  icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                  label: Text(tr('הסר תמונה', 'REMOVE IMAGE'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w900)),
                  style: TextButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.08), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: Colors.red.withValues(alpha: 0.3)))),
                )),
            ],
          ],
          const SizedBox(height: 24),
          Container(padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blue.withValues(alpha: 0.2))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, color: Colors.blue, size: 16), const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  tr('💡 התמונה תוצג בכרטיס המתחם במסך הבית', '💡 The image will appear on the venue card in the home screen'),
                  style: const TextStyle(color: Colors.blue, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  tr('מומלץ: יחס 16:9 • מקסימום ~700KB (התמונה נדחסת אוטומטית ל-800px)',
                     'Recommended: 16:9 • max ~700KB (auto-compressed to 800px width)'),
                  style: const TextStyle(color: textSecondary, fontSize: 11),
                ),
              ])),
            ])),
        ]),
  );
}

// ==================== TRAINING GROUPS LIST (USER) ====================
class TrainingGroupsListScreen extends StatefulWidget {
  final String venueId, venueName;
  const TrainingGroupsListScreen({super.key, required this.venueId, required this.venueName});
  @override State<TrainingGroupsListScreen> createState() => _TrainingGroupsListScreenState();
}

class _TrainingGroupsListScreenState extends State<TrainingGroupsListScreen> {
  String _ageFilter = 'all';
  static const List<String> _ageFilters = ['all', '5-7', '8-10', '11-13', '14+'];

  bool _matchesAge(String? ageGroup) {
    if (_ageFilter == 'all') return true;
    if (ageGroup == null || ageGroup.isEmpty) return false;
    return ageGroup.contains(_ageFilter);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: PlayerAppBar(title: '${tr('אימונים', 'TRAINING')} — ${widget.venueName}'),
    body: StreamBuilder(
      stream: FirebaseFirestore.instance.collection('training_groups').where('venueId', isEqualTo: widget.venueId).snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
        final filtered = snap.data!.docs.where((d) => _matchesAge(d.data()['ageGroup'] as String?)).toList();
        return Column(children: [
          SizedBox(height: 52,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              children: _ageFilters.map((f) {
                final isSel = _ageFilter == f;
                final label = f == 'all' ? tr('הכל', 'All') : tr('גיל $f', 'Age $f');
                return GestureDetector(
                  onTap: () => setState(() => _ageFilter = f),
                  child: Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSel ? Colors.teal : cardColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: isSel ? Colors.teal : borderColor),
                    ),
                    child: Text(label, style: TextStyle(color: isSel ? Colors.white : textSecondary, fontSize: 13, fontWeight: isSel ? FontWeight.bold : FontWeight.normal)),
                  ),
                );
              }).toList(),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.groups_outlined, color: textSecondary, size: 56), const SizedBox(height: 12),
                  Text(tr('לא נמצאו קבוצות', 'No groups found'), style: const TextStyle(color: textSecondary, fontSize: 15)),
                ]))
              : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: filtered.map((doc) {
                  final g = doc.data();
                  final groupName  = isHebrew ? (g['name'] ?? '') : (g['nameEn'] ?? g['name'] ?? '');
                  final dayList    = (g['days'] as List? ?? []).map((d) => isHebrew ? trainingDayNames[d as int] : trainingDayNamesEn[d as int]).join(', ');
                  final priceLabel = g['priceType'] == 'season' ? tr('לעונה', '/ season') : tr('/ חודש', '/ month');
                  return GestureDetector(
                    onTap: () => navigateTo(context, TrainingGroupDetailScreen(group: g, groupId: doc.id)),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.08), borderRadius: const BorderRadius.vertical(top: Radius.circular(14))),
                          child: Row(children: [
                            Container(width: 40, height: 40, decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                              child: const Icon(Icons.groups, color: Colors.teal, size: 22)),
                            const SizedBox(width: 10),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(groupName, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                              if ((g['ageGroup'] as String? ?? '').isNotEmpty)
                                Text(tr('גיל: ${g['ageGroup']}', 'Age: ${g['ageGroup']}'), style: const TextStyle(color: textSecondary, fontSize: 11)),
                            ])),
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text('₪${g['price']} $priceLabel', style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold, fontSize: 13)),
                              StreamBuilder(
                                stream: FirebaseFirestore.instance.collection('training_registrations').where('groupId', isEqualTo: doc.id).snapshots(),
                                builder: (_, rs) {
                                  final count = rs.data?.docs.length ?? 0;
                                  final cap   = g['capacity'] as int? ?? 0;
                                  return Text('$count${cap > 0 ? '/$cap' : ''} ${tr('נרשמים', 'reg.')}', style: const TextStyle(color: textSecondary, fontSize: 11));
                                },
                              ),
                            ]),
                          ]),
                        ),
                        Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (dayList.isNotEmpty) _groupInfoRow(Icons.calendar_today_outlined, dayList),
                          if ((g['startTime'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 4), _groupInfoRow(Icons.access_time_outlined, '${g['startTime']} — ${g['endTime']}')],
                          if ((g['coach'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 4), _groupInfoRow(Icons.person_outline, g['coach'])],
                          if ((g['stadiumName'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 4), _groupInfoRow(Icons.place, g['stadiumName'])],
                          const SizedBox(height: 8),
                          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            Text(tr('לפרטים ולהרשמה ←', 'Details & Register →'), style: const TextStyle(color: Colors.teal, fontSize: 12, fontWeight: FontWeight.bold)),
                          ]),
                        ])),
                      ]),
                    ),
                  );
                }).toList()),
          ),
        ]);
      },
    ),
  );
}

// ==================== TRAINING GROUP DETAIL ====================
class TrainingGroupDetailScreen extends StatefulWidget {
  final Map<String, dynamic> group;
  final String groupId;
  const TrainingGroupDetailScreen({super.key, required this.group, required this.groupId});
  @override State<TrainingGroupDetailScreen> createState() => _TrainingGroupDetailScreenState();
}

class _TrainingGroupDetailScreenState extends State<TrainingGroupDetailScreen> {

  Future<void> _register(BuildContext ctx) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final childNameCtrl   = TextEditingController();
    final childAgeCtrl    = TextEditingController();
    final parentNameCtrl  = TextEditingController(text: user.displayName ?? '');
    final parentPhoneCtrl = TextEditingController();
    bool saving = false;

    await showDialog(
      context: ctx,
      builder: (_) => StatefulBuilder(builder: (dCtx, setS) => Dialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('הרשמה לקבוצה', 'Register to Group'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(isHebrew ? (widget.group['name'] ?? '') : (widget.group['nameEn'] ?? widget.group['name'] ?? ''),
            style: const TextStyle(color: Colors.teal, fontSize: 13)),
          const SizedBox(height: 16),
          _dialogTf(childNameCtrl,   tr('שם הילד/ה', 'Child Name'),  Icons.child_care),
          const SizedBox(height: 10),
          _dialogTf(childAgeCtrl,    tr('גיל הילד/ה', 'Child Age'),  Icons.cake_outlined, type: TextInputType.number),
          const SizedBox(height: 10),
          _dialogTf(parentNameCtrl,  tr('שם ההורה',   'Parent Name'), Icons.person_outline),
          const SizedBox(height: 10),
          _dialogTf(parentPhoneCtrl, tr('טלפון',      'Phone'),      Icons.phone,         type: TextInputType.phone),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: TextButton(
              onPressed: () => Navigator.pop(dCtx),
              style: TextButton.styleFrom(foregroundColor: textSecondary),
              child: Text(tr('ביטול', 'Cancel')),
            )),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(
              onPressed: saving ? null : () async {
                if (childNameCtrl.text.trim().isEmpty || parentPhoneCtrl.text.trim().isEmpty) return;
                setS(() => saving = true);
                try {
                  await FirebaseFirestore.instance.collection('training_registrations').add({
                    'groupId':        widget.groupId,
                    'groupName':      widget.group['name'] ?? '',
                    'stadiumId':      widget.group['stadiumId'] ?? '',
                    'stadiumName':    widget.group['stadiumName'] ?? '',
                    'childName':      childNameCtrl.text.trim(),
                    'childAge':       childAgeCtrl.text.trim(),
                    'parentName':     parentNameCtrl.text.trim(),
                    'parentPhone':    parentPhoneCtrl.text.trim(),
                    'parentUserId':   user.uid,
                    'status':         'pending',
                    'amount':         widget.group['price'],
                    'paymentMethod':  null,
                    'registeredAt':   DateTime.now().toIso8601String(),
                    'paidAt':         null,
                    'paymentHistory': [],
                  });
                  await FirebaseFirestore.instance.collection('notifications').add({
                    'userId':    user.uid,
                    'title':     tr('נרשמת בהצלחה!', 'Registration Successful!'),
                    'body':      tr('ההרשמה לקבוצה ${widget.group['name']} התקבלה.', 'Registration for ${widget.group['nameEn'] ?? widget.group['name']} received.'),
                    'read':      false,
                    'createdAt': DateTime.now().toIso8601String(),
                  });
                  if (dCtx.mounted) Navigator.pop(dCtx);
                  if (ctx.mounted) _showSuccessDialog(ctx);
                } catch (e) {
                  setS(() => saving = false);
                  if (dCtx.mounted) ScaffoldMessenger.of(dCtx).showSnackBar(SnackBar(content: Text(tr('שגיאה: $e', 'Error: $e')), backgroundColor: Colors.red));
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
              child: saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text(tr('הירשם', 'REGISTER'), style: const TextStyle(fontWeight: FontWeight.w900)),
            )),
          ]),
        ])),
      )),
    );
  }

  void _showSuccessDialog(BuildContext ctx) {
    final bank = (widget.group['bankDetails'] as String? ?? '').trim();
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: cardColor,
        title: Row(children: [
          const Icon(Icons.check_circle_outline, color: Colors.teal, size: 26), const SizedBox(width: 10),
          Expanded(child: Text(tr('נרשמת בהצלחה!', 'Registered!'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold))),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('ההרשמה התקבלה. הסטטוס יעודכן לאחר האישור.', 'Registration received. Status will be updated after approval.'),
            style: const TextStyle(color: textSecondary, fontSize: 13)),
          if (bank.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.teal.withValues(alpha: 0.2))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('פרטי תשלום:', 'Payment Details:'), style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 6),
                Text(bank, style: const TextStyle(color: textPrimary, fontSize: 13)),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: bank)),
                  icon: const Icon(Icons.copy_outlined, size: 14, color: Colors.teal),
                  label: Text(tr('העתק פרטים', 'Copy Details'), style: const TextStyle(color: Colors.teal, fontSize: 12)),
                  style: TextButton.styleFrom(backgroundColor: Colors.teal.withValues(alpha: 0.08), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                )),
              ])),
          ],
        ]),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
            child: Text(tr('סגור', 'Close'), style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g          = widget.group;
    final groupName  = isHebrew ? (g['name'] ?? '') : (g['nameEn'] ?? g['name'] ?? '');
    final dayList    = (g['days'] as List? ?? []).map((d) => isHebrew ? trainingDayNames[d as int] : trainingDayNamesEn[d as int]).join(', ');
    final priceLabel = g['priceType'] == 'season' ? tr('לעונה', '/ season') : tr('/ חודש', '/ month');
    final user       = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: PlayerAppBar(title: tr('פרטי קבוצה', 'GROUP DETAILS')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Colors.teal.withValues(alpha: 0.25), Colors.teal.withValues(alpha: 0.05)]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            Container(width: 56, height: 56, decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.groups, color: Colors.teal, size: 32)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(groupName, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
              if ((g['ageGroup'] as String? ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(tr('גיל: ${g['ageGroup']}', 'Age: ${g['ageGroup']}'), style: const TextStyle(color: textSecondary, fontSize: 13)),
              ],
              const SizedBox(height: 4),
              Text('₪${g['price']} $priceLabel', style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.w900, fontSize: 16)),
            ])),
          ]),
        ),
        const SizedBox(height: 16),
        Container(padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('פרטי קבוצה', 'Group Info'), style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2)),
            const SizedBox(height: 12),
            if (dayList.isNotEmpty) _groupInfoRow(Icons.calendar_today_outlined, dayList),
            if ((g['startTime'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 8), _groupInfoRow(Icons.access_time_outlined, '${g['startTime']} — ${g['endTime']}')],
            if ((g['coach'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 8), _groupInfoRow(Icons.person_outline, g['coach'])],
            if ((g['stadiumName'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 8), _groupInfoRow(Icons.place, g['stadiumName'])],
            if ((g['officeAddress'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 8), _groupInfoRow(Icons.location_on_outlined, g['officeAddress'])],
          ])),
        const SizedBox(height: 12),
        if ((g['description'] as String? ?? '').isNotEmpty) ...[
          Container(padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('תיאור', 'Description'), style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2)),
              const SizedBox(height: 8),
              Text(g['description'], style: const TextStyle(color: textPrimary, fontSize: 13, height: 1.5)),
            ])),
          const SizedBox(height: 12),
        ],
        StreamBuilder(
          stream: FirebaseFirestore.instance.collection('training_registrations').where('groupId', isEqualTo: widget.groupId).snapshots(),
          builder: (ctx, snap) {
            final count      = snap.data?.docs.length ?? 0;
            final cap        = g['capacity'] as int? ?? 0;
            final full       = cap > 0 && count >= cap;
            final progress   = cap > 0 ? (count / cap).clamp(0.0, 1.0) : 0.0;
            final alreadyReg = snap.data?.docs.any((d) => (d.data()['parentUserId'] as String?) == user?.uid) ?? false;

            return Column(children: [
              Container(padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(tr('מקומות', 'Spots'), style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2)),
                    Text(cap > 0 ? '$count / $cap' : '$count', style: TextStyle(color: full ? Colors.red : Colors.teal, fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                  if (cap > 0) ...[
                    const SizedBox(height: 8),
                    ClipRRect(borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: borderColor,
                        valueColor: AlwaysStoppedAnimation<Color>(full ? Colors.red : Colors.teal),
                        minHeight: 6,
                      )),
                  ],
                ])),
              const SizedBox(height: 16),
              if (alreadyReg)
                Container(width: double.infinity, padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.teal.withValues(alpha: 0.3))),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.check_circle_outline, color: Colors.teal, size: 18), const SizedBox(width: 8),
                    Text(tr('כבר נרשמת לקבוצה זו', 'You are already registered'), style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                  ]))
              else if (full)
                Container(width: double.infinity, padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
                  child: Center(child: Text(tr('הקבוצה מלאה', 'Group is full'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))))
              else
                SizedBox(width: double.infinity, height: 54,
                  child: ElevatedButton.icon(
                    onPressed: () => _register(context),
                    icon: const Icon(Icons.how_to_reg),
                    label: Text(tr('הירשם לקבוצה', 'REGISTER'), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  )),
              const SizedBox(height: 24),
            ]);
          },
        ),
      ]),
    );
  }
}

// ==================== MY TRAINING REGISTRATIONS ====================
class MyTrainingRegistrationsScreen extends StatelessWidget {
  const MyTrainingRegistrationsScreen({super.key});

  Future<void> _showPaymentDetails(BuildContext ctx, String groupId) async {
    final doc = await FirebaseFirestore.instance.collection('training_groups').doc(groupId).get();
    if (!ctx.mounted) return;
    final bank = (doc.data()?['bankDetails'] as String? ?? '').trim();
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: cardColor,
        title: Text(tr('פרטי תשלום', 'Payment Details'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
        content: bank.isEmpty
          ? Text(tr('לא הוזנו פרטי תשלום', 'No payment details provided'), style: const TextStyle(color: textSecondary))
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(bank, style: const TextStyle(color: textPrimary, fontSize: 13, height: 1.5)),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: bank)),
                icon: const Icon(Icons.copy_outlined, size: 14, color: Colors.teal),
                label: Text(tr('העתק', 'Copy'), style: const TextStyle(color: Colors.teal)),
                style: TextButton.styleFrom(backgroundColor: Colors.teal.withValues(alpha: 0.08), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              ),
            ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('סגור', 'Close'), style: const TextStyle(color: textSecondary)))],
      ),
    );
  }

  Future<void> _cancelRegistration(BuildContext ctx, String docId, String groupName) async {
    final ok = await showDialog<bool>(context: ctx, builder: (_) => AlertDialog(
      backgroundColor: cardColor,
      title: Text(tr('בטל רישום?', 'Cancel Registration?'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(groupName, style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(tr('האם אתה בטוח שרצית לבטל את הרישום?', 'Are you sure you want to cancel?'), style: const TextStyle(color: textSecondary)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('חזור', 'Back'), style: const TextStyle(color: textSecondary))),
        TextButton(onPressed: () => Navigator.pop(ctx, true),  child: Text(tr('בטל רישום', 'Cancel'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
      ],
    ));
    if (ok != true) return;
    await FirebaseFirestore.instance.collection('training_registrations').doc(docId).delete();
    if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('הרישום בוטל', 'Registration cancelled')), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return Scaffold(
      backgroundColor: bgColor,
      appBar: PlayerAppBar(title: tr('הרישומים שלי', 'MY REGISTRATIONS')),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance.collection('training_registrations').where('parentUserId', isEqualTo: uid).snapshots(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
          final docs = snap.data!.docs;
          if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.assignment, color: textSecondary, size: 56), const SizedBox(height: 12),
            Text(tr('אין רישומים עדיין', 'No registrations yet'), style: const TextStyle(color: textSecondary, fontSize: 15)),
            const SizedBox(height: 6),
            Text(tr('חפש קבוצת אימון מהמסך הראשי', 'Find a training group from home screen'), style: const TextStyle(color: textSecondary, fontSize: 12)),
          ]));
          return ListView(padding: const EdgeInsets.all(16), children: [
            _secTitle(tr('הרישומים שלי', 'MY REGISTRATIONS')), const SizedBox(height: 12),
            ...docs.map((doc) {
              final r = doc.data();
              final status = r['status'] as String? ?? 'pending';
              final Color statusColor  = status == 'paid' ? Colors.green : status == 'cancelled' ? Colors.red : Colors.orange;
              final String statusLabel = status == 'paid' ? tr('שולם', 'PAID') : status == 'cancelled' ? tr('מבוטל', 'CANCELLED') : tr('ממתין', 'PENDING');
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.06), borderRadius: const BorderRadius.vertical(top: Radius.circular(14))),
                    child: Row(children: [
                      const Icon(Icons.groups, color: Colors.teal, size: 20), const SizedBox(width: 8),
                      Expanded(child: Text(r['groupName'] ?? '', style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 13))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6), border: Border.all(color: statusColor.withValues(alpha: 0.4))),
                        child: Text(statusLabel, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1))),
                    ]),
                  ),
                  Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _groupInfoRow(Icons.child_care, '${r['childName']} • ${tr('גיל', 'Age')} ${r['childAge']}'),
                    const SizedBox(height: 4),
                    _groupInfoRow(Icons.place, r['stadiumName'] ?? ''),
                    const SizedBox(height: 4),
                    _groupInfoRow(Icons.attach_money, '₪${r['amount']}'),
                    if ((r['registeredAt'] as String? ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _groupInfoRow(Icons.schedule, r['registeredAt'].toString().substring(0, 10)),
                    ],
                    if (status == 'paid') ...() {
                      final ph = (r['paymentHistory'] as List? ?? []);
                      if (ph.isEmpty) return <Widget>[];
                      return [
                        const SizedBox(height: 8),
                        Container(padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withValues(alpha: 0.2))),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr('היסטוריית תשלומים:', 'Payment History:'), style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            ...ph.map((p) {
                              final pm   = p as Map<String, dynamic>;
                              final date = (pm['date'] as String? ?? '').length >= 10 ? (pm['date'] as String).substring(0, 10) : '';
                              return Padding(padding: const EdgeInsets.only(top: 3),
                                child: Row(children: [
                                  const Icon(Icons.check_circle, color: Colors.green, size: 11), const SizedBox(width: 4),
                                  Text('₪${pm['amount']} • ${pm['method'] ?? ''} • $date', style: const TextStyle(color: textSecondary, fontSize: 11)),
                                ]));
                            }),
                          ])),
                      ];
                    }(),
                  ])),
                  Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 10), child: Row(children: [
                    Expanded(child: TextButton.icon(
                      onPressed: () => _showPaymentDetails(context, r['groupId'] ?? ''),
                      icon: const Icon(Icons.payment, size: 15, color: Colors.teal),
                      label: Text(tr('פרטי תשלום', 'Payment'), style: const TextStyle(color: Colors.teal, fontSize: 11)),
                      style: TextButton.styleFrom(backgroundColor: Colors.teal.withValues(alpha: 0.07), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    )),
                    if (status != 'cancelled') ...[
                      const SizedBox(width: 6),
                      Expanded(child: TextButton.icon(
                        onPressed: () => _cancelRegistration(context, doc.id, r['groupName'] ?? ''),
                        icon: const Icon(Icons.remove_circle_outline, size: 15, color: Colors.red),
                        label: Text(tr('בטל רישום', 'Cancel'), style: const TextStyle(color: Colors.red, fontSize: 11)),
                        style: TextButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.07), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                      )),
                    ],
                  ])),
                ]),
              );
            }),
          ]);
        },
      ),
    );
  }
}

// ==================== HELPERS ====================
AppBar _appBar(String t, BuildContext context) => AppBar(
  backgroundColor: bgColor, elevation: 0, iconTheme: const IconThemeData(color: textSecondary),
  title: Text(t, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 16)),
  actions: [_langButton(context)],
);

// ==================== PLAYER APP BAR ====================
class PlayerAppBar extends StatefulWidget implements PreferredSizeWidget {
  final String? title;
  final PreferredSizeWidget? bottom;

  const PlayerAppBar({super.key, this.title, this.bottom});

  @override
  Size get preferredSize => Size.fromHeight(
    kToolbarHeight + (bottom?.preferredSize.height ?? 0),
  );

  @override
  State<PlayerAppBar> createState() => _PlayerAppBarState();
}

class _PlayerAppBarState extends State<PlayerAppBar> {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return AppBar(
      backgroundColor: bgColor,
      elevation: 0,
      iconTheme: const IconThemeData(color: textSecondary),
      title: widget.title != null
          ? Text(
              widget.title!,
              style: const TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                fontSize: 16,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      bottom: widget.bottom,
      actions: [
        // Notifications bell with unread badge
        StreamBuilder<QuerySnapshot>(
          stream: user != null
              ? FirebaseFirestore.instance
                  .collection('notifications')
                  .where('userId', isEqualTo: user.uid)
                  .where('read', isEqualTo: false)
                  .snapshots()
              : null,
          builder: (ctx, snap) {
            final count = snap.data?.docs.length ?? 0;
            return Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined, color: textSecondary),
                  tooltip: tr('התראות', 'Notifications'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NotificationsScreen()),
                  ),
                ),
                if (count > 0)
                  Positioned(
                    right: 6, top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      decoration: const BoxDecoration(color: accentGreen, shape: BoxShape.circle),
                      child: Center(
                        child: Text(
                          '$count',
                          style: const TextStyle(color: bgColor, fontSize: 9, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        // Hamburger menu (matches VenueSelectionScreen header)
        PopupMenuButton<String>(
          tooltip: tr('תפריט', 'Menu'),
          icon: const Icon(Icons.menu, color: textSecondary, size: 22),
          color: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusLg),
            side: const BorderSide(color: borderColor),
          ),
          offset: const Offset(0, 48),
          itemBuilder: (ctx) => [
            PopupMenuItem<String>(
              value: 'profile',
              child: _menuRow(Icons.person_outline, tr('הפרופיל שלי', 'My Profile'), accentGreen),
            ),
            PopupMenuItem<String>(
              value: 'bookings',
              child: _menuRow(Icons.calendar_month_outlined, tr('ההזמנות שלי', 'My Bookings'), accentGreen),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'language',
              child: _menuRow(Icons.language, isHebrew ? 'English' : 'עברית', textPrimary),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'logout',
              child: _menuRow(Icons.logout, tr('יציאה', 'Sign Out'), Colors.red),
            ),
          ],
          onSelected: (value) async {
            switch (value) {
              case 'profile':
                navigateTo(context, const ProfileScreen(),);
                break;
              case 'bookings':
                navigateTo(context, const MyBookingsScreen(),);
                break;
              case 'language':
                toggleAppLanguage(context);
                break;
              case 'logout':
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: cardColor,
                    title: Text(
                      tr('יציאה?', 'Sign Out?'),
                      style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                    ),
                    content: Text(
                      tr('האם אתה בטוח שברצונך לצאת?', 'Are you sure you want to sign out?'),
                      style: const TextStyle(color: textSecondary),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary)),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(tr('יציאה', 'Sign Out'), style: const TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) await _signOut(context);
                break;
            }
          },
        ),
      ],
    );
  }

  Widget _menuRow(IconData icon, String label, Color iconColor) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: spaceSm),
        Text(
          label,
          style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ==================== ADMIN APP BAR ====================
/// Admin-flavored AppBar — same hamburger menu style as `PlayerAppBar` but
/// without the notifications bell. Items: My Profile, Language, Sign Out.
class AdminAppBar extends StatefulWidget implements PreferredSizeWidget {
  final Widget? title;
  final PreferredSizeWidget? bottom;

  const AdminAppBar({super.key, this.title, this.bottom});

  @override
  Size get preferredSize => Size.fromHeight(
    kToolbarHeight + (bottom?.preferredSize.height ?? 0),
  );

  @override
  State<AdminAppBar> createState() => _AdminAppBarState();
}

class _AdminAppBarState extends State<AdminAppBar> {
  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: bgColor,
      elevation: 0,
      iconTheme: const IconThemeData(color: textSecondary),
      title: widget.title,
      bottom: widget.bottom,
      actions: [
        PopupMenuButton<String>(
          tooltip: tr('תפריט', 'Menu'),
          icon: const Icon(Icons.menu, color: textSecondary, size: 22),
          color: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusLg),
            side: const BorderSide(color: borderColor),
          ),
          offset: const Offset(0, 48),
          itemBuilder: (ctx) => [
            PopupMenuItem<String>(
              value: 'profile',
              child: _adminMenuRow(Icons.person_outline, tr('הפרופיל שלי', 'My Profile'), accentGreen),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'language',
              child: _adminMenuRow(Icons.language, isHebrew ? 'English' : 'עברית', textPrimary),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'logout',
              child: _adminMenuRow(Icons.logout, tr('יציאה', 'Sign Out'), Colors.red),
            ),
          ],
          onSelected: (value) async {
            switch (value) {
              case 'profile':
                navigateTo(context, const ProfileScreen());
                break;
              case 'language':
                toggleAppLanguage(context);
                break;
              case 'logout':
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: cardColor,
                    title: Text(
                      tr('יציאה?', 'Sign Out?'),
                      style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                    ),
                    content: Text(
                      tr('האם אתה בטוח שברצונך לצאת?', 'Are you sure you want to sign out?'),
                      style: const TextStyle(color: textSecondary),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary)),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(tr('יציאה', 'Sign Out'), style: const TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) await _signOut(context);
                break;
            }
          },
        ),
      ],
    );
  }

  Widget _adminMenuRow(IconData icon, String label, Color iconColor) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: spaceSm),
        Text(
          label,
          style: const TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

Widget _secTitle(String t) => Text(t, style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 3));

Widget _groupInfoRow(IconData icon, String text) => Row(children: [
  Icon(icon, color: textSecondary, size: 13), const SizedBox(width: 6),
  Expanded(child: Text(text, style: const TextStyle(color: textSecondary, fontSize: 12))),
]);

Widget _periodBtn(String label, String value, String current, VoidCallback onTap) {
  final isSel = current == value;
  return Expanded(child: GestureDetector(
    onTap: onTap,
    child: Container(padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(color: isSel ? accentGreen : cardColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: isSel ? accentGreen : borderColor)),
      child: Text(label, textAlign: TextAlign.center, style: TextStyle(color: isSel ? bgColor : textSecondary, fontWeight: FontWeight.bold, fontSize: 12))),
  ));
}

Widget _statCard(String label, String value, IconData icon, Color color) => Container(
  padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.2))),
  child: Row(children: [
    Icon(icon, color: color, size: 22),
    const SizedBox(width: 10),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: textSecondary, fontSize: 10, letterSpacing: 1), maxLines: 1, overflow: TextOverflow.ellipsis),
      Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w900), maxLines: 1, overflow: TextOverflow.ellipsis),
    ])),
  ]));

Widget _bookCard(Map<String,dynamic> b, {BuildContext? context}) {
  final players=(b['players'] as List?)??[];
  return GestureDetector(
    onTap: context != null ? () => showBookingDetails(context, b) : null,
    child: Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(b['stadiumName']??'', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.amber.withValues(alpha: 0.3))), child: Text(b['bookingCode']??'', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 12))),
          if (context != null) ...[const SizedBox(width: 8), const Icon(Icons.info_outline, color: Colors.blue, size: 16)],
        ]),
        const SizedBox(height: 6),
        Text('${b['userName']??''} • ${b['day']} ${b['date']} • ${b['time']}', style: const TextStyle(color: textSecondary, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Text('${players.length}/18 ${tr('שחקנים','players')}${players.isNotEmpty?': ${players.join(', ')}':''}', style: const TextStyle(color: textSecondary, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
      ])),
  );
}

Widget _errBox(String msg) => Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
  child: Row(children: [const Icon(Icons.error_outline, color: Colors.red, size: 16), const SizedBox(width: 8), Expanded(child: Text(msg, style: const TextStyle(color: Colors.red, fontSize: 13)))]));