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

  test('authorization through the mock', () async {
    final result = await client.requestAuthorization({HealthDataType.steps});
    expect(result.allGranted, isTrue);

    source.grantAll = false;
    final denied = await client.requestAuthorization({HealthDataType.weight});
    expect(denied.denied, [HealthDataType.weight]);
    await expectLater(client.weight(DateRange.today(now: now)),
        throwsA(isA<AuthorizationDenied>()));
  });

  test('unavailable store', () async {
    source.availabilityValue = HealthAvailability.notInstalled;
    await expectLater(client.requestAuthorization({HealthDataType.steps}),
        throwsA(const HealthDataNotAvailable(reason: 'notInstalled')));
  });

  test('daily steps are de-duplicated across phone + watch', () async {
    final t = today.subtract(const Duration(hours: 10));
    source.addQuantity(HealthDataType.steps, 5000,
        start: t, sourceName: 'iPhone');
    source.addQuantity(HealthDataType.steps, 5200,
        start: t, sourceName: 'Watch');
    final daily = await client.dailySteps(DateRange.lastDays(1, now: now));
    expect(daily.first.value, 5200);
    expect(daily.last.value, isNull); // today, no data yet
  });

  test(
      'statistics falls back to raw samples when the platform cannot aggregate',
      () async {
    source.supportsStatistics = false;
    for (final v in [60.0, 70.0, 80.0]) {
      source.addQuantity(HealthDataType.heartRate, v,
          start: today.add(Duration(hours: v ~/ 10)));
    }
    final avg = await client.statistics(
        HealthDataType.heartRate, DateRange.today(now: now),
        option: StatisticsOption.average);
    expect(avg.value, 70);
    expect(avg.deduplicated, isFalse);
    final latest = await client.statistics(
        HealthDataType.heartRate, DateRange.today(now: now),
        option: StatisticsOption.mostRecent);
    expect(latest.value, 80);
  });

  test('blood pressure readings are paired', () async {
    final t = today.add(const Duration(hours: 8));
    source.addQuantity(HealthDataType.bloodPressureSystolic, 120, start: t);
    source.addQuantity(HealthDataType.bloodPressureDiastolic, 80, start: t);
    source.addQuantity(HealthDataType.bloodPressureSystolic, 130,
        start: t.add(const Duration(hours: 1))); // unpaired
    final bp = await client.bloodPressure(DateRange.today(now: now));
    expect(bp, hasLength(1));
    expect(bp.single.systolic, 120);
    expect(bp.single.diastolic, 80);
  });

  test('lastNight finds a night that started before midnight', () async {
    final bed = DateTime(2026, 11, 17, 23);
    source.addSleep(SleepStage.core,
        start: bed, end: bed.add(const Duration(hours: 3)));
    source.addSleep(SleepStage.deep,
        start: bed.add(const Duration(hours: 3)),
        end: bed.add(const Duration(hours: 4, minutes: 30)));
    source.addSleep(SleepStage.rem,
        start: bed.add(const Duration(hours: 4, minutes: 30)),
        end: bed.add(const Duration(hours: 7, minutes: 30)));
    final night = await client.lastNight();
    expect(night, isNotNull);
    expect(night!.date, today);
    expect(night.summary.totalSleep, closeTo(7.5, 1e-9));

    final summary = await client.sleepSummary(DateRange.today(now: now));
    expect(summary.totalSleep, closeTo(7.5, 1e-9));
  });

  test('streak via client', () async {
    for (var d = 1; d <= 4; d++) {
      source.addQuantity(HealthDataType.steps, 11000,
          start: addDays(today, -d).add(const Duration(hours: 12)));
    }
    expect(await client.streak(), 4);
  });

  test('incremental sync reports additions and deletions', () async {
    final first = await client.changes(HealthDataType.weight);
    expect(first.added, isEmpty);

    final a = source.addQuantity(HealthDataType.weight, 74.2, start: now);
    source.addQuantity(HealthDataType.steps, 100, start: now); // other type
    final second =
        await client.changes(HealthDataType.weight, anchor: first.anchor);
    expect(second.added.single.id, a.id);

    source.deleteQuantity(a.id);
    final third =
        await client.changes(HealthDataType.weight, anchor: second.anchor);
    expect(third.added, isEmpty);
    expect(third.deletedIds, [a.id]);

    await expectLater(client.changes(HealthDataType.weight, anchor: 'garbage'),
        throwsA(isA<SyncAnchorExpired>()));
  });

  test('writing a sample makes it readable', () async {
    await client.writeQuantity(HealthDataType.dietaryWater, 250);
    final water = await client.quantity(HealthDataType.dietaryWater,
        DateRange.today(now: now.add(const Duration(seconds: 1))));
    expect(water.single.value, 250);
  });

  test('nextError is surfaced once', () async {
    source.nextError = const QueryFailed('boom');
    await expectLater(client.steps(DateRange.today(now: now)),
        throwsA(const QueryFailed('boom')));
    expect(await client.steps(DateRange.today(now: now)), isEmpty);
  });

  group('synthetic data end-to-end', () {
    late HealthSyncClient demo;
    setUp(() {
      demo = HealthSyncClient(
          source: MockHealthSource.synthetic(days: 35, now: now),
          clock: () => now);
    });

    test('activity, sleep, readiness, load and anomalies all produce values',
        () async {
      final activity = await demo.activitySummary(addDays(today, -1));
      expect(activity.steps, greaterThan(1000));
      expect(activity.activityScore, inInclusiveRange(1, 100));

      final night = await demo.lastNight();
      expect(night, isNotNull);
      expect(night!.summary.totalSleep, inInclusiveRange(5, 10));
      expect(night.summary.hasStages, isTrue);
      expect(night.sourceName, 'Watch'); // staged watch beats unstaged phone

      final nights = await demo.sleepNights(DateRange.lastDays(14, now: now));
      expect(nights.length, inInclusiveRange(13, 15));
      expect(
          SleepAnalytics.bedtimeConsistency(nights), inInclusiveRange(0, 100));

      final readiness = await demo.readiness();
      expect(readiness.hasScore, isTrue);
      expect(readiness.hrvPoints, isNotNull);

      final load = await demo.trainingLoad();
      expect(load.status, isNot(TrainingLoadStatus.insufficientData));

      final rhr = await demo.daily(
          HealthDataType.restingHeartRate, DateRange.lastDays(30, now: now));
      expect(rhr.where((d) => d.value != null).length, greaterThan(25));
    });

    test('is deterministic for a seed', () async {
      final a = MockHealthSource.synthetic(seed: 7, now: now);
      final b = MockHealthSource.synthetic(seed: 7, now: now);
      final r = DateRange.lastWeek(now: now);
      expect((await a.quantity(HealthDataType.weight, r)).values,
          (await b.quantity(HealthDataType.weight, r)).values);
    });
  });
}
