import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

QuantitySample q(double v, DateTime t,
        {HealthDataType type = HealthDataType.steps, String source = 'A'}) =>
    QuantitySample(
        id: '$source-$t-$v',
        type: type,
        value: v,
        start: t,
        end: t,
        sourceName: source,
        sourceId: source);

void main() {
  group('basic statistics', () {
    final v = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];

    test('mean / median / sum / min / max', () {
      expect(HealthStatistics.mean(v), 5);
      expect(HealthStatistics.median(v), 4.5);
      expect(HealthStatistics.sum(v), 40);
      expect(HealthStatistics.minimum(v), 2);
      expect(HealthStatistics.maximum(v), 9);
      expect(HealthStatistics.mean(const []), 0);
      expect(HealthStatistics.minimum(const []), isNull);
    });

    test('standard deviation, population and sample', () {
      expect(HealthStatistics.standardDeviation(v), 2);
      expect(HealthStatistics.standardDeviation(v, sample: true),
          closeTo(2.138, 0.001));
      expect(HealthStatistics.standardDeviation([1]), 0);
    });

    test('percentile interpolates', () {
      expect(HealthStatistics.percentile([1, 2, 3, 4, 5], 25), 2);
      expect(HealthStatistics.percentile([10, 20], 50), 15);
    });

    test('moving averages', () {
      expect(HealthStatistics.movingAverage([1, 2, 3, 4, 5], 3), [2, 3, 4]);
      expect(HealthStatistics.movingAverage([1, 2], 3), isEmpty);
      expect(
          HealthStatistics.exponentialMovingAverage([10, 20], 0.5), [10, 15]);
    });

    test('percentChange is undefined from zero', () {
      expect(HealthStatistics.percentChange(8000, 10200), closeTo(27.5, 1e-9));
      expect(HealthStatistics.percentChange(0, 5), isNull);
    });

    test('trend by index and by real days', () {
      expect(HealthStatistics.trend([1, 2, 3, 4]), closeTo(1, 1e-9));
      final d0 = DateTime(2026, 1, 1);
      // Values grow 10/day, but with a gap: index-based trend would say 10/sample.
      final series = [
        DailyValue(d0, 100),
        DailyValue(addDays(d0, 1), 110),
        DailyValue(addDays(d0, 5), 150),
        DailyValue(addDays(d0, 6), null),
      ];
      expect(HealthStatistics.trendPerDay(series), closeTo(10, 1e-6));
    });
  });

  group('daily values & de-duplication', () {
    final day = DateTime(2026, 3, 10);
    final range = DateRange.day(day);
    final samples = [
      q(4000, day.add(const Duration(hours: 9)), source: 'iPhone'),
      q(3000, day.add(const Duration(hours: 15)), source: 'iPhone'),
      q(6500, day.add(const Duration(hours: 9)), source: 'Watch'),
    ];

    test('maxSource avoids phone + watch double counting', () {
      final values =
          HealthStatistics.dailyValues(samples, HealthDataType.steps, range);
      expect(values.single.value, 7000);
    });

    test('none sums everything', () {
      final values = HealthStatistics.dailyValues(
          samples, HealthDataType.steps, range,
          dedup: DedupStrategy.none);
      expect(values.single.value, 13500);
    });

    test('discrete types are averaged', () {
      final hr = [
        q(60, day.add(const Duration(hours: 1)),
            type: HealthDataType.heartRate),
        q(80, day.add(const Duration(hours: 2)),
            type: HealthDataType.heartRate),
      ];
      expect(
          HealthStatistics.dailyValues(hr, HealthDataType.heartRate, range)
              .single
              .value,
          70);
    });

    test('days without data are null', () {
      final week = DateRange(day, addDays(day, 3));
      final values =
          HealthStatistics.dailyValues(samples, HealthDataType.steps, week);
      expect(values.map((d) => d.value), [7000, null, null]);
    });
  });

  group('baseline & anomalies', () {
    test('z-score against a baseline', () {
      final b = HealthStatistics.baseline([50, 52, 48, 50, 51, 49, 50]);
      expect(b.mean, 50);
      expect(b.zScore(50), 0);
      expect(b.zScore(60), greaterThan(5));
    });

    test('flags a spike after enough history', () {
      final d0 = DateTime(2026, 1, 1);
      final series = [
        for (var i = 0; i < 14; i++) DailyValue(addDays(d0, i), 58.0 + (i % 3)),
        DailyValue(addDays(d0, 14), 75),
      ];
      final anomalies = HealthStatistics.anomalies(series);
      expect(anomalies.single.date, addDays(d0, 14));
      expect(anomalies.single.isHigh, isTrue);
    });
  });

  group('DateRange', () {
    final now = DateTime(2026, 11, 18, 14, 30); // a Wednesday

    test('factories', () {
      expect(DateRange.today(now: now).start, DateTime(2026, 11, 18));
      expect(DateRange.yesterday(now: now),
          DateRange(DateTime(2026, 11, 17), DateTime(2026, 11, 18)));
      expect(DateRange.thisWeek(now: now).start, DateTime(2026, 11, 16));
      expect(DateRange.thisMonth(now: now).start, DateTime(2026, 11, 1));
      expect(DateRange.lastWeek(now: now).start, DateTime(2026, 11, 11));
    });

    test('rejects inverted ranges', () {
      expect(() => DateRange(now, DateTime(2020)),
          throwsA(isA<InvalidDateRange>()));
    });

    test('splitByDay', () {
      final r = DateRange(DateTime(2026, 1, 1, 18), DateTime(2026, 1, 3, 6));
      expect(r.splitByDay().map((d) => d.start), [
        DateTime(2026, 1, 1, 18),
        DateTime(2026, 1, 2),
        DateTime(2026, 1, 3),
      ]);
    });
  });
}
