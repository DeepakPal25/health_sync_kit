import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

void main() {
  final now = DateTime(2026, 11, 18, 10);
  final today = DateTime(2026, 11, 18);
  late MockHealthSource source;
  late HealthSyncClient client;

  setUp(() {
    source = MockHealthSource();
    client = HealthSyncClient(source: source, clock: () => now);
  });

  group('empty data — every client method', () {
    final week = DateRange.lastDays(7, now: now);

    test('raw reads return empty lists', () async {
      for (final t in HealthDataType.values.where((t) => t.isQuantity)) {
        expect(await client.quantity(t, week), isEmpty, reason: t.name);
      }
      expect(await client.steps(week), isEmpty);
      expect(await client.heartRateVariability(week), isEmpty);
      expect(await client.bloodPressure(week), isEmpty);
      expect(await client.workouts(week), isEmpty);
      expect(await client.sleep(week), isEmpty);
    });

    test('statistics are null for every option, native and fallback', () async {
      for (final native in [true, false]) {
        source.supportsStatistics = native;
        for (final o in StatisticsOption.values) {
          final r =
              await client.statistics(HealthDataType.steps, week, option: o);
          expect(r.value, isNull, reason: '$o native=$native');
        }
      }
    });

    test('daily series have one null entry per day', () async {
      for (final native in [true, false]) {
        source.supportsStatistics = native;
        final d = await client.dailySteps(week);
        expect(d, hasLength(8)); // 7 full days + today so far
        expect(d.every((v) => v.value == null), isTrue);
        final hr = await client.daily(HealthDataType.heartRate, week);
        expect(hr.every((v) => v.value == null), isTrue);
      }
    });

    test('sleep analytics are empty, not errors', () async {
      expect(await client.sleepNights(week), isEmpty);
      expect(await client.lastNight(), isNull);
      final s = await client.sleepSummary(week);
      expect(s.totalSleep, 0);
      expect(SleepAnalytics.bedtimeConsistency(const []), isA<double>());
      expect(SleepAnalytics.averageSleep(const []), 0);
    });

    test('activity, streak, readiness, load, anomalies, changes', () async {
      final a = await client.activitySummary(today);
      expect(a.steps, 0);
      expect(a.activityScore, inInclusiveRange(0, 100));
      expect(await client.streak(), 0);
      final r = await client.readiness();
      expect(r.hasScore, isFalse);
      expect((await client.trainingLoad()).status,
          TrainingLoadStatus.insufficientData);
      expect(await client.anomalies(HealthDataType.restingHeartRate, week),
          isEmpty);
      final c = await client.changes(HealthDataType.steps);
      expect(c.added, isEmpty);
      expect(c.deletedIds, isEmpty);
    });
  });

  group('a single sample', () {
    test('quantity, statistics and daily', () async {
      source.addQuantity(HealthDataType.heartRate, 72,
          start: today.add(const Duration(hours: 8)));
      final r = DateRange.today(now: now);
      for (final native in [true, false]) {
        source.supportsStatistics = native;
        for (final o in StatisticsOption.values) {
          expect(
              (await client.statistics(HealthDataType.heartRate, r, option: o))
                  .value,
              72,
              reason: '$o native=$native');
        }
      }
      expect(
          (await client.daily(HealthDataType.heartRate, r)).single.value, 72);
      expect(HealthStatistics.standardDeviation([72]), 0);
      expect(HealthStatistics.trend([72]), 0);
      expect(HealthStatistics.trendPerDay([DailyValue(today, 72)]), 0);
      expect(HealthStatistics.median([72]), 72);
      expect(HealthStatistics.percentile([72], 90), 72);
    });

    test('one sleep sample is one night', () async {
      source.addSleep(SleepStage.asleep,
          start: DateTime(2026, 11, 17, 23), end: DateTime(2026, 11, 18, 6));
      final night = await client.lastNight();
      expect(night!.summary.totalSleep, 7);
      expect(
          SleepAnalytics.bedtimeConsistency([night]), inInclusiveRange(0, 100));
    });

    test('one workout gives insufficient training-load data or a status',
        () async {
      source.addWorkout(WorkoutActivityType.running,
          start: today.subtract(const Duration(hours: 10)),
          end: today.subtract(const Duration(hours: 9)));
      final load = await client.trainingLoad();
      expect(load.status, isA<TrainingLoadStatus>());
    });
  });

  group('midnight boundaries', () {
    test('a sample at exactly 00:00:00 belongs to the new day', () async {
      source.addQuantity(HealthDataType.steps, 500, start: today);
      source.addQuantity(HealthDataType.steps, 300,
          start: today.subtract(const Duration(milliseconds: 1)));
      final d = await client.dailySteps(DateRange.lastDays(1, now: now));
      expect(d.map((v) => v.date), [addDays(today, -1), today]);
      expect(d.map((v) => v.value), [300, 500]);
      expect(
          HealthStatistics.groupByDay(
                  await client.steps(DateRange.lastDays(1, now: now)))[today]!
              .single
              .value,
          500);
      expect(DateRange.day(today).contains(today), isTrue);
      expect(DateRange.day(addDays(today, -1)).contains(today), isFalse);
    });

    test('a night ending at exactly 00:00 is dated that day', () {
      final n = SleepAnalytics.nights([
        SleepSample(
            id: 'x',
            stage: SleepStage.asleep,
            start: DateTime(2026, 11, 17, 17),
            end: today,
            sourceName: 'W'),
      ]);
      expect(n.single.date, today);
    });
  });

  group('start == end ranges', () {
    final r = DateRange(now, now);

    test('are allowed and empty', () async {
      expect(r.splitByDay(), isEmpty);
      expect(r.contains(now), isFalse);
      source.addQuantity(HealthDataType.steps, 10, start: now);
      expect(await client.steps(r), isEmpty);
      expect(await client.dailySteps(r), isEmpty);
      expect((await client.statistics(HealthDataType.steps, r)).value, isNull);
      expect(await client.sleepNights(r), isEmpty);
      expect(await client.workouts(r), isEmpty);
      expect(await client.sleepSummary(r), isA<SleepSummary>());
    });
  });
}
