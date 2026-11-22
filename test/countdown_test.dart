import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stadium_app/main.dart';

Future<String> _textFor(WidgetTester tester, Duration fromNow, {int minutes = 120}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: GameCountdown(
    start: DateTime.now().add(fromNow), durationMinutes: minutes))));
  final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').toList();
  await tester.pumpWidget(const SizedBox()); // stop the timer
  return texts.join(' ');
}

void main() {
  testWidgets('hours, minutes and seconds under a day', (tester) async {
    final t = await _textFor(tester, const Duration(hours: 2, minutes: 14, seconds: 5, milliseconds: 500));
    expect(t, matches(RegExp(r'2:14:0[45]'))); // a second may pass while building
  });
  testWidgets('days when further off', (tester) async {
    expect(await _textFor(tester, const Duration(days: 3, hours: 2)), anyOf(contains('3'), contains('4')));
  });
  testWidgets('playing now during the game, nothing after it', (tester) async {
    expect(await _textFor(tester, const Duration(minutes: -10)), isNotEmpty);
    expect(await _textFor(tester, const Duration(hours: -5)), isEmpty);
  });
}
