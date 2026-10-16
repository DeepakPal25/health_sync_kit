import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

/// Performance smoke test on a year of synthetic data. Fails if any call takes
/// longer than [budgetMs] (generous to tolerate slow CI; the plan's flag is
/// 500 ms, which is printed for visibility).
const budgetMs = 2000;
const flagMs = 500;

void main() {
  final now = DateTime(2026, 11, 18, 10);
  late HealthSyncClient client;

  setUpAll(() {
    final sw = Stopwatch()..start();
    final source = MockHealthSource.synthetic(days: 365, now: now);
    client = HealthSyncClient(source: source, clock: () => now);
    // ignore: avoid_print
    print('synthetic(days: 365) built in ${sw.elapsedMilliseconds} ms');
  });

  Future<T> timed<T>(String label, Future<T> Function() f) async {
    await f(); // warm-up (JIT)
    final sw = Stopwatch()..start();
    final r = await f();
    final ms = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('$label: $ms ms${ms > flagMs ? '  ⚠ over $flagMs ms' : ''}');
    expect(ms, lessThan(budgetMs), reason: label);
    return r;
  }

  test('readiness()', () async {
    final r = await timed('readiness()', client.readiness);
    expect(r.hasScore, isTrue);
  });

  test('sleepNights(lastDays(90))', () async {
    final n = await timed('sleepNights(lastDays(90))',
        () => client.sleepNights(DateRange.lastDays(90, now: now)));
    expect(n.length, inInclusiveRange(88, 92));
    final sw = Stopwatch()..start();
    for (final x in n) {
      x.isNap; // recomputes the summary each call
      x.summary.sleepScore;
    }
    // ignore: avoid_print
    print('90× isNap + summary: ${sw.elapsedMilliseconds} ms');
  });

  test('streak()', () async {
    final s = await timed('streak()', () => client.streak(goal: 1000));
    expect(s, greaterThan(30));
  });

  test('dailySteps(365) and trainingLoad()', () async {
    final d = await timed('dailySteps(lastDays(365))',
        () => client.dailySteps(DateRange.lastDays(365, now: now)));
    expect(d, hasLength(366));
    await timed('trainingLoad()', client.trainingLoad);
  });
}
