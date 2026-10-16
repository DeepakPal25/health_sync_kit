// Run in a DST time zone, e.g.:
//   TZ=Europe/London flutter test test/dst_test.dart
//   TZ=America/New_York flutter test test/dst_test.dart
// In a zone without DST (e.g. UTC) every test is skipped.
import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

/// The local calendar days in [year] on which the UTC offset changes,
/// i.e. [spring forward, fall back] (northern hemisphere ordering not assumed).
List<DateTime> dstDays(int year) {
  final out = <DateTime>[];
  for (var d = DateTime(year); d.year == year; d = addDays(d, 1)) {
    if (d.timeZoneOffset != addDays(d, 1).timeZoneOffset) out.add(d);
  }
  return out;
}

void main() {
  final days = dstDays(2026);
  final skip = days.length == 2
      ? false
      : 'Local time zone (${DateTime.now().timeZoneName}) has no DST; '
          'run with TZ=Europe/London or TZ=America/New_York';
  // The day whose offset grows is "spring forward" (23 h long).
  DateTime springDay() =>
      days.firstWhere((d) => addDays(d, 1).timeZoneOffset > d.timeZoneOffset);
  DateTime fallDay() =>
      days.firstWhere((d) => addDays(d, 1).timeZoneOffset < d.timeZoneOffset);

  SleepSample asleep(DateTime start, DateTime end, String id) => SleepSample(
      id: id,
      stage: SleepStage.asleep,
      start: start,
      end: end,
      sourceName: 'Watch',
      sourceId: 'Watch');

  group('DST', () {
    test('spring forward: 23:00 → 07:00 is one 7 h night', () {
      final day = springDay();
      final bed = DateTime(day.year, day.month, day.day - 1, 23);
      final wake = DateTime(day.year, day.month, day.day, 7);
      final nights = SleepAnalytics.nights([asleep(bed, wake, 'a')]);
      expect(nights, hasLength(1));
      expect(nights.single.date, day);
      expect(nights.single.summary.totalSleep, closeTo(7, 1e-9),
          reason: 'real elapsed hours, not wall-clock 8');
    }, skip: skip);

    test('fall back: 23:00 → 07:00 is one 9 h night', () {
      final day = fallDay();
      final bed = DateTime(day.year, day.month, day.day - 1, 23);
      final wake = DateTime(day.year, day.month, day.day, 7);
      final nights = SleepAnalytics.nights([
        // Split in two samples across the repeated hour.
        asleep(bed, DateTime(day.year, day.month, day.day, 1), 'a'),
        asleep(DateTime(day.year, day.month, day.day, 1), wake, 'b'),
      ]);
      expect(nights, hasLength(1));
      expect(nights.single.date, day);
      expect(nights.single.summary.totalSleep, closeTo(9, 1e-9));
    }, skip: skip);

    test('splitByDay yields calendar days of 23 h and 25 h', () {
      for (final (day, hours) in [(springDay(), 23), (fallDay(), 25)]) {
        final r = DateRange(addDays(day, -1), addDays(day, 2));
        final parts = r.splitByDay();
        expect(parts.map((p) => p.start),
            [addDays(day, -1), day, addDays(day, 1)]);
        for (final p in parts) {
          expect(p.start.hour, 0);
          expect(p.start.minute, 0);
        }
        expect(parts[1].end.difference(parts[1].start).inHours, hours);
      }
    }, skip: skip);

    test('daily steps bucket into the right calendar day', () async {
      final day = springDay();
      final source = MockHealthSource();
      final now = DateTime(day.year, day.month, day.day + 2, 12);
      final client = HealthSyncClient(source: source, clock: () => now);
      for (var d = -1; d <= 1; d++) {
        final base = addDays(day, d);
        source.addQuantity(HealthDataType.steps, 1000, start: base); // 00:00
        source.addQuantity(HealthDataType.steps, 2000,
            start: DateTime(base.year, base.month, base.day, 23, 59));
      }
      final daily =
          await client.dailySteps(DateRange(addDays(day, -1), addDays(day, 2)));
      expect(
          daily.map((d) => d.date), [addDays(day, -1), day, addDays(day, 1)]);
      expect(daily.map((d) => d.value), [3000, 3000, 3000]);
    }, skip: skip);

    test('trendPerDay counts a DST day as exactly one day', () {
      final day = springDay();
      final series = [
        DailyValue(addDays(day, -1), 100),
        DailyValue(day, 110),
        DailyValue(addDays(day, 1), 120),
      ];
      expect(HealthStatistics.trendPerDay(series), closeTo(10, 1e-9));
    }, skip: skip);
  });
}
