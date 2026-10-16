import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

/// B3: client paths that the other suites don't reach — client-side
/// fallbacks, unsupported types and change-feed pagination.
void main() {
  final now = DateTime(2026, 11, 18, 10);
  final today = DateTime(2026, 11, 18);
  final yesterday = DateTime(2026, 11, 17);

  late MockHealthSource source;
  late HealthSyncClient client;

  setUp(() {
    source = MockHealthSource();
    client = HealthSyncClient(source: source, clock: () => now);
  });

  group('daily() fallback without native statistics', () {
    // Yesterday: 60 @08:00, 80 @12:00, 70 @18:00. Today: no samples.
    setUp(() {
      source.supportsStatistics = false;
      for (final (h, v) in [(8, 60.0), (12, 80.0), (18, 70.0)]) {
        source.addQuantity(HealthDataType.heartRate, v,
            start: yesterday.add(Duration(hours: h)));
      }
    });
    final range = DateRange(yesterday, today.add(const Duration(days: 1)));

    Future<List<double?>> values(StatisticsOption o) async => [
          for (final d
              in await client.daily(HealthDataType.heartRate, range, option: o))
            d.value
        ];

    test('minimum = min(60, 80, 70) = 60', () async {
      expect(await values(StatisticsOption.minimum), [60, null]);
    });
    test('maximum = max(60, 80, 70) = 80', () async {
      expect(await values(StatisticsOption.maximum), [80, null]);
    });
    test('mostRecent = the 18:00 sample = 70', () async {
      expect(await values(StatisticsOption.mostRecent), [70, null]);
    });
    test('buckets are local midnights, one per day', () async {
      final days = await client.daily(HealthDataType.heartRate, range,
          option: StatisticsOption.maximum);
      expect([for (final d in days) d.date], [yesterday, today]);
    });
  });

  group('heartRateVariability()', () {
    final range = DateRange.day(today);

    test('falls back to RMSSD when SDNN has no samples', () async {
      source.addQuantity(HealthDataType.heartRateVariabilityRMSSD, 42,
          start: today.add(const Duration(hours: 3)));
      final hrv = await client.heartRateVariability(range);
      expect(hrv.single.type, HealthDataType.heartRateVariabilityRMSSD);
      expect(hrv.single.value, 42);
    });

    test('skips SDNN when the platform lacks it (Android)', () async {
      source.supported.remove(HealthDataType.heartRateVariabilitySDNN);
      source.addQuantity(HealthDataType.heartRateVariabilityRMSSD, 38,
          start: today.add(const Duration(hours: 3)));
      final hrv = await client.heartRateVariability(range);
      expect(hrv.single.type, HealthDataType.heartRateVariabilityRMSSD);
    });

    test('is empty when neither measure has data', () async {
      source.supported.remove(HealthDataType.heartRateVariabilityRMSSD);
      expect(await client.heartRateVariability(range), isEmpty);
    });
  });

  test('activitySummary counts unsupported types as 0', () async {
    source.supported
      ..remove(HealthDataType.standTime)
      ..remove(HealthDataType.exerciseTime);
    source.addQuantity(HealthDataType.steps, 1234,
        start: today.add(const Duration(hours: 9)));
    final s = await client.activitySummary(today);
    expect(s.steps, 1234);
    expect(s.standMinutes, 0);
    expect(s.exerciseMinutes, 0);
  });

  test('readiness uses RMSSD when SDNN is unsupported', () async {
    source.supported.remove(HealthDataType.heartRateVariabilitySDNN);
    // 10 history days alternating 40/50 → mean 45; today 55 (above baseline).
    final history = <double>[];
    for (var i = 1; i <= 10; i++) {
      final v = i.isEven ? 40.0 : 50.0;
      history.add(v);
      source.addQuantity(HealthDataType.heartRateVariabilityRMSSD, v,
          start:
              today.subtract(Duration(days: i)).add(const Duration(hours: 4)));
    }
    source.addQuantity(HealthDataType.heartRateVariabilityRMSSD, 55,
        start: today.add(const Duration(hours: 4)));

    final r = await client.readiness();
    final expected = HealthStatistics.baseline(history).zScore(55);
    expect(expected, greaterThan(0));
    expect(r.hrvZScore, closeTo(expected, 1e-9));
    expect(r.hrvPoints, isNotNull);
  });

  group('changes() pagination', () {
    test('loops over every page and returns the final anchor', () async {
      final first = await client.changes(HealthDataType.weight);
      final ids = <String>[
        for (var i = 0; i < 5; i++)
          source
              .addQuantity(HealthDataType.weight, 70.0 + i,
                  start: today.add(Duration(minutes: i)))
              .id,
      ];
      source.deleteQuantity(ids[0]);
      source.pageSize = 2; // 6 changes → pages of 2, 2, 2

      final before = source.queryCount;
      final all =
          await client.changes(HealthDataType.weight, anchor: first.anchor);
      expect(source.queryCount - before, 3);
      expect(all.hasMore, isFalse);
      expect([for (final s in all.added) s.value], [70, 71, 72, 73, 74]);
      expect(all.deletedIds, [ids[0]]);

      // The returned anchor is the newest one: nothing more to fetch.
      final next =
          await client.changes(HealthDataType.weight, anchor: all.anchor);
      expect(next.added, isEmpty);
      expect(next.deletedIds, isEmpty);
    });

    test('mock source pages report hasMore and a resumable anchor', () async {
      final start = await source.changes(HealthDataType.steps);
      for (var i = 0; i < 3; i++) {
        source.addQuantity(HealthDataType.steps, 10.0 * i, start: today);
      }
      source.pageSize = 2;
      final p1 =
          await source.changes(HealthDataType.steps, anchor: start.anchor);
      expect(p1.hasMore, isTrue);
      expect(p1.added, hasLength(2));
      final p2 = await source.changes(HealthDataType.steps, anchor: p1.anchor);
      expect(p2.hasMore, isFalse);
      expect([for (final s in p2.added) s.value], [20]);
    });
  });

  test('convenience readers query their own type', () async {
    final range = DateRange.day(today);
    final t = today.add(const Duration(hours: 6));
    final readers =
        <HealthDataType, Future<List<QuantitySample>> Function(DateRange)>{
      HealthDataType.steps: client.steps,
      HealthDataType.activeEnergyBurned: client.activeEnergy,
      HealthDataType.distanceWalkingRunning: client.distance,
      HealthDataType.flightsClimbed: client.flightsClimbed,
      HealthDataType.heartRate: client.heartRate,
      HealthDataType.restingHeartRate: client.restingHeartRate,
      HealthDataType.oxygenSaturation: client.oxygenSaturation,
      HealthDataType.respiratoryRate: client.respiratoryRate,
      HealthDataType.weight: client.weight,
      HealthDataType.bodyFatPercentage: client.bodyFatPercentage,
    };
    for (final type in readers.keys) {
      source.addQuantity(type, 1, start: t);
    }
    for (final MapEntry(key: type, value: read) in readers.entries) {
      expect((await read(range)).single.type, type, reason: type.name);
    }
  });

  test('availability and openHealthSettings delegate to the source', () async {
    expect(await client.availability(), HealthAvailability.available);
    source.availabilityValue = HealthAvailability.updateRequired;
    expect(await client.availability(), HealthAvailability.updateRequired);
    await client.openHealthSettings(); // no throw
  });
}
