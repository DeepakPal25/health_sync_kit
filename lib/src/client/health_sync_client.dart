import 'dart:math' as math;

import '../analytics/activity_analytics.dart';
import '../analytics/health_statistics.dart';
import '../analytics/recovery_analytics.dart';
import '../analytics/sleep_analytics.dart';
import '../models/authorization.dart';
import '../models/date_range.dart';
import '../models/health_data_type.dart';
import '../models/health_error.dart';
import '../models/samples.dart';
import '../models/statistics.dart';
import '../source/health_source.dart';
import '../source/live_health_source.dart';

/// The main entry point: a typed, cross-platform API over HealthKit and
/// Health Connect, plus the analytics layer.
///
/// ```dart
/// final health = HealthSyncClient();
/// if (!(await health.availability()).isAvailable) return;
/// await health.requestAuthorization({HealthDataType.steps, HealthDataType.sleep});
///
/// final steps = await health.dailySteps(DateRange.lastWeek());
/// final night = await health.lastNight();
/// print('Sleep score ${night?.summary.sleepScore}');
/// ```
///
/// Pass a `MockHealthSource` to run the whole thing without a device.
class HealthSyncClient {
  HealthSyncClient({HealthSource? source, DateTime Function()? clock})
      : source = source ?? const LiveHealthSource(),
        _clock = clock ?? DateTime.now;

  final HealthSource source;
  final DateTime Function() _clock;

  DateTime get _now => _clock();

  // ------------------------------------------------------ Availability & auth

  Future<HealthAvailability> availability() => source.availability();

  /// The data types this platform has at all. For example, HRV is
  /// `heartRateVariabilitySDNN` on iOS and `heartRateVariabilityRMSSD` on
  /// Android; check here instead of hard-coding the platform.
  Future<Set<HealthDataType>> supportedTypes() => source.supportedTypes();

  /// Requests access. Throws [HealthDataNotAvailable] when there is no store.
  ///
  /// Types the platform doesn't have are not sent to the platform; they come
  /// back as [AuthorizationStatus.unsupported] (not as denied), so you can
  /// request both HRV measures on every platform.
  Future<AuthorizationResult> requestAuthorization(
    Set<HealthDataType> read, {
    Set<HealthDataType> write = const {},
  }) async {
    final a = await source.availability();
    if (!a.isAvailable) throw HealthDataNotAvailable(reason: a.name);
    final supported = await source.supportedTypes();
    final r = read.where(supported.contains).toSet();
    final w = write.where(supported.contains).toSet();
    final unsupported = {...read, ...write}.difference({...r, ...w});
    final native = r.isEmpty && w.isEmpty
        ? const AuthorizationResult({})
        : await source.requestAuthorization(r, write: w);
    return AuthorizationResult({
      ...native.statuses,
      for (final t in unsupported) t: AuthorizationStatus.unsupported,
    });
  }

  Future<AuthorizationStatus> authorizationStatus(HealthDataType type) =>
      source.authorizationStatus(type);

  Future<void> openHealthSettings() => source.openSettings();

  // ------------------------------------------------------------ Raw samples

  Future<List<QuantitySample>> quantity(HealthDataType type, DateRange range) =>
      source.quantity(type, range);

  Future<List<QuantitySample>> steps(DateRange r) =>
      quantity(HealthDataType.steps, r);
  Future<List<QuantitySample>> activeEnergy(DateRange r) =>
      quantity(HealthDataType.activeEnergyBurned, r);
  Future<List<QuantitySample>> distance(DateRange r) =>
      quantity(HealthDataType.distanceWalkingRunning, r);
  Future<List<QuantitySample>> flightsClimbed(DateRange r) =>
      quantity(HealthDataType.flightsClimbed, r);
  Future<List<QuantitySample>> heartRate(DateRange r) =>
      quantity(HealthDataType.heartRate, r);
  Future<List<QuantitySample>> restingHeartRate(DateRange r) =>
      quantity(HealthDataType.restingHeartRate, r);
  Future<List<QuantitySample>> oxygenSaturation(DateRange r) =>
      quantity(HealthDataType.oxygenSaturation, r);
  Future<List<QuantitySample>> respiratoryRate(DateRange r) =>
      quantity(HealthDataType.respiratoryRate, r);
  Future<List<QuantitySample>> weight(DateRange r) =>
      quantity(HealthDataType.weight, r);
  Future<List<QuantitySample>> bodyFatPercentage(DateRange r) =>
      quantity(HealthDataType.bodyFatPercentage, r);

  /// HRV, whichever measure this platform records: SDNN on iOS (Apple Watch),
  /// RMSSD on Android. Check `sample.type` before comparing across devices.
  Future<List<QuantitySample>> heartRateVariability(DateRange r) async {
    for (final type in const [
      HealthDataType.heartRateVariabilitySDNN,
      HealthDataType.heartRateVariabilityRMSSD,
    ]) {
      try {
        final samples = await quantity(type, r);
        if (samples.isNotEmpty) return samples;
      } on UnsupportedDataType {
        continue;
      }
    }
    return const [];
  }

  /// Systolic/diastolic readings paired by timestamp (HealthSyncKit returned
  /// two unrelated lists).
  Future<List<BloodPressureReading>> bloodPressure(DateRange r) async {
    final results = await Future.wait([
      quantity(HealthDataType.bloodPressureSystolic, r),
      quantity(HealthDataType.bloodPressureDiastolic, r),
    ]);
    final diastolicByTime = {
      for (final d in results[1]) d.start.millisecondsSinceEpoch: d,
    };
    return [
      for (final s in results[0])
        if (diastolicByTime[s.start.millisecondsSinceEpoch] case final d?)
          BloodPressureReading(
            time: s.start,
            systolic: s.value,
            diastolic: d.value,
            sourceName: s.sourceName,
          ),
    ];
  }

  Future<List<Workout>> workouts(DateRange r) => source.workouts(r);

  Future<List<SleepSample>> sleep(DateRange r) => source.sleep(r);

  // ------------------------------------------------------------- Statistics

  /// One aggregate over [range]. Uses the platform's de-duplicated
  /// statistics when available, otherwise computes from raw samples
  /// (`deduplicated: false`).
  Future<StatisticsResult> statistics(
    HealthDataType type,
    DateRange range, {
    StatisticsOption option = StatisticsOption.sum,
  }) async {
    final native = await source.statistics(type, range, option);
    if (native != null) return native;
    final samples = await source.quantity(type, range);
    final values = samples.values;
    final double? value = values.isEmpty
        ? null
        : switch (option) {
            StatisticsOption.sum => HealthStatistics.sum([
                for (final d
                    in HealthStatistics.dailyValues(samples, type, range))
                  d.value ?? 0,
              ]),
            StatisticsOption.average => HealthStatistics.mean(values),
            StatisticsOption.minimum => values.reduce(math.min),
            StatisticsOption.maximum => values.reduce(math.max),
            StatisticsOption.mostRecent => samples.last.value,
          };
    return StatisticsResult(
      type: type,
      option: option,
      value: value,
      start: range.start,
      end: range.end,
      deduplicated: false,
    );
  }

  /// One value per local day in [range]: summed for cumulative types,
  /// averaged for discrete ones (override with [option]). De-duplicated by
  /// the platform when it can; otherwise computed from raw samples.
  Future<List<DailyValue>> daily(
    HealthDataType type,
    DateRange range, {
    StatisticsOption? option,
  }) async {
    final opt = option ??
        (type.isCumulative ? StatisticsOption.sum : StatisticsOption.average);
    final native = await source.dailyStatistics(type, range, opt);
    if (native != null) return native;
    final samples = await source.quantity(type, range);
    if (opt == StatisticsOption.sum || opt == StatisticsOption.average) {
      return HealthStatistics.dailyValues(samples, type, range);
    }
    final byDay = HealthStatistics.groupByDay(samples);
    return [
      for (final day in range.splitByDay())
        DailyValue(
            startOfDay(day.start),
            switch (byDay[startOfDay(day.start)]) {
              null => null,
              final s => switch (opt) {
                  StatisticsOption.minimum => s.values.reduce(math.min),
                  StatisticsOption.maximum => s.values.reduce(math.max),
                  _ => s.last.value,
                },
            }),
    ];
  }

  Future<List<DailyValue>> dailySteps(DateRange range) =>
      daily(HealthDataType.steps, range);

  // ------------------------------------------------------------ Analytics

  /// Sleep sessions whose wake-up falls in [range], de-duplicated per source.
  /// The query starts 18 h earlier so nights that began before
  /// `range.start` are complete.
  Future<List<SleepNight>> sleepNights(
    DateRange range, {
    List<String> sourcePriority = const [],
  }) async {
    final widened =
        DateRange(range.start.subtract(const Duration(hours: 18)), range.end);
    final samples = await source.sleep(widened);
    return SleepAnalytics.nights(samples, sourcePriority: sourcePriority)
        .where((n) => range.contains(n.end))
        .toList();
  }

  /// The most recent main sleep (naps excluded) ending in the last 24 h.
  Future<SleepNight?> lastNight() async {
    final now = _now;
    final nights = await sleepNights(
        DateRange(now.subtract(const Duration(hours: 24)), now));
    final main = nights.where((n) => !n.isNap).toList();
    return main.isEmpty ? null : main.last;
  }

  /// HealthSyncKit-compatible: a single summary for [range].
  Future<SleepSummary> sleepSummary(DateRange range) async {
    final nights = await sleepNights(range);
    final main = nights.where((n) => !n.isNap).toList()
      ..sort((a, b) => b.timeInBed.compareTo(a.timeInBed));
    return main.isEmpty ? SleepSummary.empty(range.start) : main.first.summary;
  }

  /// Activity for one local day, from de-duplicated daily totals.
  Future<ActivitySummary> activitySummary(
    DateTime day, {
    ActivityGoals goals = const ActivityGoals(),
  }) async {
    final range = DateRange.day(day);
    Future<double> total(HealthDataType t) async {
      try {
        final d = await daily(t, range);
        return d.isEmpty ? 0 : d.first.value ?? 0;
      } on UnsupportedDataType {
        return 0;
      }
    }

    final values = await Future.wait([
      total(HealthDataType.steps),
      total(HealthDataType.activeEnergyBurned),
      total(HealthDataType.distanceWalkingRunning),
      total(HealthDataType.exerciseTime),
      total(HealthDataType.standTime),
    ]);
    return ActivitySummary(
      date: startOfDay(day),
      steps: values[0],
      activeCalories: values[1],
      distance: values[2],
      exerciseMinutes: values[3],
      standMinutes: values[4],
      goals: goals,
    );
  }

  /// Current streak of days reaching [goal] for [type] (default: 10k steps).
  Future<int> streak({
    HealthDataType type = HealthDataType.steps,
    double goal = 10000,
    int lookbackDays = 365,
  }) async {
    final series =
        await daily(type, DateRange.lastDays(lookbackDays, now: _now));
    return ActivityAnalytics.streak(series, goal, now: _now);
  }

  /// Today's readiness from HRV and resting-HR baselines (previous 30 days)
  /// and last night's sleep.
  Future<ReadinessScore> readiness({int baselineDays = 30}) async {
    final now = _now;
    final today = startOfDay(now);
    final range = DateRange(addDays(today, -baselineDays), now);

    Future<List<DailyValue>> series(HealthDataType t) async {
      try {
        return await daily(t, range);
      } on UnsupportedDataType {
        return const [];
      }
    }

    final results = await Future.wait([
      series(HealthDataType.heartRateVariabilitySDNN),
      series(HealthDataType.heartRateVariabilityRMSSD),
      series(HealthDataType.restingHeartRate),
    ]);
    final hrv =
        results[0].any((d) => d.value != null) ? results[0] : results[1];
    final rhr = results[2];

    (double?, List<double>) split(List<DailyValue> s) {
      double? todayValue;
      final history = <double>[];
      for (final d in s) {
        final v = d.value;
        if (v == null) continue;
        if (d.date == today) {
          todayValue = v;
        } else {
          history.add(v);
        }
      }
      return (todayValue, history);
    }

    final (hrvToday, hrvHistory) = split(hrv);
    final (rhrToday, rhrHistory) = split(rhr);
    final night = await lastNight();

    return RecoveryAnalytics.readiness(
      hrvToday: hrvToday,
      hrvBaseline: hrvHistory,
      restingHeartRateToday: rhrToday,
      restingHeartRateBaseline: rhrHistory,
      lastNight: night?.summary,
    );
  }

  /// Days in [range] where [type] deviated strongly from its rolling baseline.
  Future<List<Anomaly>> anomalies(
    HealthDataType type,
    DateRange range, {
    double threshold = 2.0,
  }) async =>
      HealthStatistics.anomalies(await daily(type, range),
          threshold: threshold);

  /// Training load from the last 28 days of workouts.
  Future<TrainingLoad> trainingLoad({double maxHeartRate = 190}) async {
    final now = _now;
    final w = await workouts(DateRange(addDays(startOfDay(now), -27), now));
    return ActivityAnalytics.trainingLoad(w,
        now: now, maxHeartRate: maxHeartRate);
  }

  // ------------------------------------------------------- Sync & writing

  /// Incremental sync: what changed for [type] since [anchor]. Start with no
  /// anchor, persist the returned one, and pass it next time. Loops while
  /// the platform reports more pages.
  Future<HealthChanges> changes(HealthDataType type, {String? anchor}) async {
    var page = await source.changes(type, anchor: anchor);
    if (!page.hasMore) return page;
    final added = [...page.added];
    final deleted = [...page.deletedIds];
    while (page.hasMore) {
      page = await source.changes(type, anchor: page.anchor);
      added.addAll(page.added);
      deleted.addAll(page.deletedIds);
    }
    return HealthChanges(
        type: type, added: added, deletedIds: deleted, anchor: page.anchor);
  }

  Future<void> writeQuantity(
    HealthDataType type,
    double value, {
    DateTime? start,
    DateTime? end,
  }) =>
      source.writeQuantity(type, value, start: start ?? _now, end: end);
}
