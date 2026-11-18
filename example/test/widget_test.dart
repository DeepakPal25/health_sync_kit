// Smoke test for the example dashboard in "Demo data" mode
// (MockHealthSource.synthetic), covering the Step 7 checks without a device.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_sync_kit_example/main.dart';

/// Pumps until the dashboard list replaces the loading spinner.
Future<Duration> _pumpUntilLoaded(WidgetTester tester) async {
  final sw = Stopwatch()..start();
  for (var i = 0; i < 200 && find.byType(ListView).evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 10));
  }
  sw.stop();
  return sw.elapsed;
}

/// True when a `_kv` row with label [k] shows value [v].
bool _hasKv(String k, String v) => find
    .byWidgetPredicate((w) =>
        w is Row &&
        w.children.length == 2 &&
        (w.children[0] as Expanded?)?.child is Text &&
        ((w.children[0] as Expanded).child as Text).data == k &&
        (w.children[1] as Text?)?.data == v)
    .evaluate()
    .isNotEmpty;

void main() {
  testWidgets('demo dashboard loads with all cards', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const HealthDemoApp());
    final elapsed = await _pumpUntilLoaded(tester);

    expect(find.byType(ListView), findsOneWidget, reason: 'dashboard loaded');
    expect(elapsed, lessThan(const Duration(seconds: 2)));

    expect(find.text('Readiness'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Sleep'), findsOneWidget);
    expect(find.text('No sleep recorded last night.'), findsNothing);
    expect(_hasKv('Source', 'Watch'), isTrue, reason: 'sleep Source: Watch');

    expect(find.text('Training load'), findsOneWidget);
    expect(find.text('insufficientData'), findsNothing);
  });

  testWidgets('pull-to-refresh reloads the dashboard', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const HealthDemoApp());
    await _pumpUntilLoaded(tester);

    final state =
        tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator));
    final refresh = state.show();
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => refresh);
    await tester.pump();

    expect(find.text('Readiness'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
