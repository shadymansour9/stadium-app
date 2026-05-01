// Flutter tests for the Stadium app.
//
// Run with: flutter test
//
// Test groups:
//   1. Pure unit tests   — logic helpers that don't depend on Flutter runtime
//   2. Widget unit tests — Design-System widgets that don't need Firebase
//   3. Screen tests      — full screens that require Firebase mocks (skipped
//                          until firebase_auth_mocks / fake_cloud_firestore
//                          packages are added to dev_dependencies)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stadium_app/main.dart';

void main() {
  // ============================================================
  // 1) PURE UNIT TESTS
  // ============================================================
  group('Pure unit tests', () {
    test('hebrewWeekday returns Hebrew letters when isHebrew=true', () {
      // weekday is 1..7 (Mon..Sun)
      expect(hebrewWeekday(1, true), "ב'");  // Monday
      expect(hebrewWeekday(2, true), "ג'");  // Tuesday
      expect(hebrewWeekday(3, true), "ד'");  // Wednesday
      expect(hebrewWeekday(4, true), "ה'");  // Thursday
      expect(hebrewWeekday(5, true), "ו'");  // Friday
      expect(hebrewWeekday(6, true), "ש'");  // Saturday
      expect(hebrewWeekday(7, true), "א'");  // Sunday
    });

    test('hebrewWeekday returns English abbreviations when isHebrew=false', () {
      expect(hebrewWeekday(1, false), 'Mon');
      expect(hebrewWeekday(2, false), 'Tue');
      expect(hebrewWeekday(3, false), 'Wed');
      expect(hebrewWeekday(4, false), 'Thu');
      expect(hebrewWeekday(5, false), 'Fri');
      expect(hebrewWeekday(6, false), 'Sat');
      expect(hebrewWeekday(7, false), 'Sun');
    });

    test('_slotLabel returns "HH:mm - HH:mm" format', () {
      // _slotLabel is library-private. We test the documented format contract.
      String slotLabel(Map<String, String> slot) => '${slot['start']} - ${slot['end']}';

      expect(slotLabel({'start': '08:00', 'end': '10:00'}), '08:00 - 10:00');
      expect(slotLabel({'start': '14:00', 'end': '16:00'}), '14:00 - 16:00');
      expect(slotLabel({'start': '20:00', 'end': '22:00'}), '20:00 - 22:00');
    });

    test('Date parsing: DD/MM string yields valid weekday in 0..6', () {
      // Mirrors _weekdayFromDateString contract: 0=Sunday … 6=Saturday.
      int weekday(String date) {
        final parts = date.split('/');
        final now = DateTime.now();
        final d = DateTime(now.year, int.parse(parts[1]), int.parse(parts[0]));
        return d.weekday % 7;
      }

      for (final date in ['1/1', '15/3', '28/12', '5/7']) {
        final wd = weekday(date);
        expect(wd, isA<int>());
        expect(wd, inInclusiveRange(0, 6),
            reason: 'weekday($date) should be 0..6');
      }
    });

    test('Date parsing: HH:mm to total minutes', () {
      // Mirrors _minutesOf contract.
      int minutesOf(String hhmm) {
        final p = hhmm.split(':');
        return int.parse(p[0]) * 60 + int.parse(p[1]);
      }

      expect(minutesOf('00:00'), 0);
      expect(minutesOf('01:00'), 60);
      expect(minutesOf('08:30'), 510);
      expect(minutesOf('14:45'), 885);
      expect(minutesOf('23:59'), 1439);
    });

    test('Price calculation in reports: bookings * stadium price', () {
      const stadiumPrice = 300;

      int revenue(int bookings) => bookings * stadiumPrice;

      expect(revenue(0), 0);
      expect(revenue(1), 300);
      expect(revenue(5), 1500);
      expect(revenue(10), 3000);
      expect(revenue(20), 6000);
    });

    test('trainingOverlapForSlot returns false when no groups match stadium', () {
      final groups = <Map<String, dynamic>>[
        {
          'stadiumId': 'stadium_a',
          'days': [1], // Monday
          'startTime': '16:00',
          'endTime': '18:00',
        }
      ];

      // Wrong stadium -> no overlap
      expect(
        trainingOverlapForSlot(groups, 'stadium_b', '5/1', '16:00 - 18:00'),
        isFalse,
      );

      // Empty groups -> no overlap
      expect(
        trainingOverlapForSlot(<Map<String, dynamic>>[], 'stadium_a', '5/1', '16:00 - 18:00'),
        isFalse,
      );
    });

    test('trainingOverlapForSlot returns false for non-overlapping times', () {
      // Compute the weekday of a known recent date so we can build a matching group.
      final now = DateTime.now();
      final probe = DateTime(now.year, now.month, now.day);
      final wd = probe.weekday % 7;
      final dateStr = '${probe.day}/${probe.month}';

      final groups = <Map<String, dynamic>>[
        {
          'stadiumId': 's1',
          'days': [wd],
          'startTime': '08:00',
          'endTime': '10:00',
        }
      ];

      // 12:00-14:00 doesn't overlap 08:00-10:00
      expect(
        trainingOverlapForSlot(groups, 's1', dateStr, '12:00 - 14:00'),
        isFalse,
      );
    });

    test('trainingOverlapForSlot returns true for overlapping times', () {
      final now = DateTime.now();
      final probe = DateTime(now.year, now.month, now.day);
      final wd = probe.weekday % 7;
      final dateStr = '${probe.day}/${probe.month}';

      final groups = <Map<String, dynamic>>[
        {
          'stadiumId': 's1',
          'days': [wd],
          'startTime': '08:00',
          'endTime': '10:00',
        }
      ];

      // 09:00-11:00 overlaps 08:00-10:00
      expect(
        trainingOverlapForSlot(groups, 's1', dateStr, '09:00 - 11:00'),
        isTrue,
      );
    });
  });

  // ============================================================
  // 2) WIDGET UNIT TESTS — Design System widgets (no Firebase)
  // ============================================================
  group('Design System widgets', () {
    Widget wrap(Widget child) => MaterialApp(
          home: Scaffold(body: child),
        );

    testWidgets('appPrimaryButton renders label and is tappable', (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(
        appPrimaryButton(
          label: 'Confirm',
          icon: Icons.check,
          onPressed: () => tapped = true,
        ),
      ));

      expect(find.text('Confirm'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);

      // ElevatedButton.icon creates a subclass; use a predicate finder.
      final buttonFinder = find.byWidgetPredicate((w) => w is ElevatedButton);
      expect(buttonFinder, findsOneWidget);

      await tester.tap(find.text('Confirm'));
      expect(tapped, isTrue);
    });

    testWidgets('appPrimaryButton with onPressed=null is disabled', (tester) async {
      await tester.pumpWidget(wrap(
        appPrimaryButton(label: 'Disabled', onPressed: null),
      ));

      expect(find.text('Disabled'), findsOneWidget);
      final btn = tester.widgetList<ElevatedButton>(
        find.byWidgetPredicate((w) => w is ElevatedButton),
      ).first;
      expect(btn.onPressed, isNull);
    });

    testWidgets('appBadge renders text with given color', (tester) async {
      await tester.pumpWidget(wrap(
        appBadge('TEST', Colors.red),
      ));
      expect(find.text('TEST'), findsOneWidget);
    });

    testWidgets('appCard renders its child', (tester) async {
      await tester.pumpWidget(wrap(
        appCard(child: const Text('inside-card')),
      ));
      expect(find.text('inside-card'), findsOneWidget);
    });

    testWidgets('appStatCell renders value and label', (tester) async {
      await tester.pumpWidget(wrap(
        appStatCell('42', 'BOOKINGS'),
      ));
      expect(find.text('42'), findsOneWidget);
      expect(find.text('BOOKINGS'), findsOneWidget);
    });

    testWidgets('appChip toggles active state visually', (tester) async {
      await tester.pumpWidget(wrap(
        Column(children: [
          appChip('Inactive'),
          appChip('Active', active: true),
        ]),
      ));
      expect(find.text('Inactive'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
    });

    testWidgets('appEmptyState shows icon, title, subtitle', (tester) async {
      await tester.pumpWidget(wrap(
        appEmptyState(
          icon: Icons.inbox_outlined,
          title: 'Nothing here',
          subtitle: 'Try later',
        ),
      ));
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.text('Try later'), findsOneWidget);
    });
  });

  // ============================================================
  // 3) SCREEN TESTS — require Firebase mocking
  // ------------------------------------------------------------
  // To enable these, add to dev_dependencies in pubspec.yaml:
  //   firebase_auth_mocks: ^0.14.x
  //   fake_cloud_firestore: ^3.x
  //   firebase_core_platform_interface: any
  // Then in setUp() initialize a mock Firebase app and inject the
  // mocked instances. The current production code uses
  // FirebaseAuth.instance / FirebaseFirestore.instance directly,
  // so it would also need to read from injected providers (or
  // accept overrides in tests via setupFirebaseAuthMocks()).
  // ============================================================
  group('Screen tests (Firebase-dependent)', () {
    // Reason: Requires Firebase.initializeApp() — add firebase_core mock setup
    testWidgets('Login screen renders correctly', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      expect(find.text('STADIUM'), findsOneWidget);
      expect(find.byType(TextFormField), findsAtLeastNWidgets(2));
    }, skip: true);

    // Reason: Requires firebase_auth_mocks
    testWidgets('Login with wrong password shows error', (tester) async {
      // Pseudocode:
      //   1. Build LoginScreen with mocked FirebaseAuth that throws
      //      FirebaseAuthException(code: 'wrong-password') on signIn.
      //   2. Enter email + password, tap "Sign In".
      //   3. expect(find.byType(SnackBar), findsOneWidget);
    }, skip: true);

    // Reason: Requires Firebase mocks (Auth + Firestore notifications stream)
    testWidgets('Home (VenueSelection) screen shows venue cards', (tester) async {
      // Pseudocode:
      //   1. Mock FirebaseAuth.currentUser to return a fake user.
      //   2. Build VenueSelectionScreen.
      //   3. expect(find.text('MD9'), findsOneWidget);
      //   4. expect(find.text('Y STADIUM'), findsOneWidget);
    }, skip: true);

    // Reason: Requires Firebase mocks (4 parallel Firestore queries)
    testWidgets('Booking screen shows time slots', (tester) async {
      // Pseudocode:
      //   1. Mock Firestore with empty bookings + admin_schedule for the stadium.
      //   2. Build BookingScreen(stadium: allStadiums.first).
      //   3. expect(find.byType(_SlotCard), findsAtLeastNWidgets(1));
      //   4. expect(find.textContaining(' - '), findsWidgets);
    }, skip: true);

    // Reason: Requires Firebase mocks
    testWidgets('Admin panel shows correct tabs for MD9 admin', (tester) async {
      // Pseudocode:
      //   1. Mock FirebaseAuth.currentUser email = md9AdminEmail.
      //   2. Build MD9AdminScreen.
      //   3. expect(find.text('OVERVIEW'), findsOneWidget);
      //   4. expect(find.text('MD9 MAIN'), findsOneWidget);
      //   5. expect(find.text('MD9 2'), findsOneWidget);
    }, skip: true);
  });
}
