import 'dart:math' as math;

import '../analytics/health_statistics.dart';
import '../models/authorization.dart';
import '../models/date_range.dart';
import '../models/health_data_type.dart';
import '../models/health_error.dart';
import '../models/samples.dart';
import '../models/statistics.dart';
import 'health_source.dart';

/// An in-memory [HealthSource] for tests, previews and demos.
///
/// Seed it with samples (or [MockHealthSource.synthetic] for realistic
/// generated data), control availability and permissions, and inject
/// failures. Statistics are computed from the stored samples with
/// [DedupStrategy.maxSource], like a platform that merges sources.
class MockHealthSource implements HealthSource {
  MockHealthSource({
    this.availabilityValue = HealthAvailability.available,
    this.grantAll = true,
  });

  /// A source pre-filled with [days] of plausible, deterministic data:
  /// steps, energy, distance, exercise, heart rate, resting HR, HRV, weight,
  /// SpO2, sleep with stages, and a few workouts.
  factory MockHealthSource.synthetic({
    int days = 30,
    int seed = 42,
    DateTime? now,
  }) {
    final source = MockHealthSource();
    SyntheticHealthData(seed: seed)
        .fill(source, days: days, now: now ?? DateTime.now());
    return source;
  }

  HealthAvailability availabilityValue;

  /// Whether permission requests are granted.
  bool grantAll;

  final List<QuantitySample> _quantities = [];
  final List<SleepSample> _sleep = [];
  final List<Workout> _workouts = [];
  final Map<HealthDataType, AuthorizationStatus> _status = {};
  final List<_Change> _log = [];
  int _version = 0;
  int _idCounter = 0;

  /// The next query throws this error, then it's cleared.
  HealthError? nextError;

  /// Number of queries served (for asserting caching etc.).
  int queryCount = 0;

  /// Simulates a platform that can't aggregate (forces client fallback).
  bool supportsStatistics = true;

  /// When set, [changes] returns at most this many changes per call with
  /// `hasMore: true`, like Health Connect's paged change feed.
  int? pageSize;

  /// The types this simulated platform has. Defaults to all of them; remove
  /// e.g. `heartRateVariabilitySDNN` to behave like Android. Queries for a
  /// type outside this set throw [UnsupportedDataType].
  Set<HealthDataType> supported = {...HealthDataType.values};

  // ------------------------------------------------------------ Seeding

  String _id() => 'mock-${_idCounter++}';

  QuantitySample addQuantity(
    HealthDataType type,
    double value, {
    required DateTime start,
    DateTime? end,
    String sourceName = 'Mock',
    String? sourceId,
  }) {
    final s = QuantitySample(
      id: _id(),
      type: type,
      value: value,
      start: start,
      end: end ?? start,
      sourceName: sourceName,
      sourceId: sourceId ?? sourceName,
    );
    _quantities.add(s);
    _log.add(_Change(++_version, s, null));
    return s;
  }

  SleepSample addSleep(
    SleepStage stage, {
    required DateTime start,
    required DateTime end,
    String sourceName = 'Mock',
    String? sourceId,
  }) {
    final s = SleepSample(
      id: _id(),
      stage: stage,
      start: start,
      end: end,
      sourceName: sourceName,
      sourceId: sourceId ?? sourceName,
    );
    _sleep.add(s);
    return s;
  }

  Workout addWorkout(
    WorkoutActivityType type, {
    required DateTime start,
    required DateTime end,
    double? energyBurned,
    double? distance,
    double? averageHeartRate,
  }) {
    final w = Workout(
      id: _id(),
      activityType: type,
      start: start,
      end: end,
      energyBurned: energyBurned,
      distance: distance,
      averageHeartRate: averageHeartRate,
      sourceName: 'Mock',
      totalsAttribution:
          energyBurned != null || distance != null || averageHeartRate != null
              ? WorkoutTotalsAttribution.sameApp
              : WorkoutTotalsAttribution.none,
    );
    _workouts.add(w);
    return w;
  }

  /// Deletes a quantity sample (shows up in [changes] as a deletion).
  void deleteQuantity(String id) {
    final index = _quantities.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final removed = _quantities.removeAt(index);
    _log.add(_Change(++_version, null, removed));
  }

  void setStatus(HealthDataType type, AuthorizationStatus status) =>
      _status[type] = status;

  // ------------------------------------------------------------- Helpers

  void _guard(HealthDataType? type) {
    queryCount++;
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
    if (!availabilityValue.isAvailable) {
      throw HealthDataNotAvailable(reason: availabilityValue.name);
    }
    if (type != null && !supported.contains(type)) {
      throw UnsupportedDataType(type);
    }
    if (type != null && _status[type] == AuthorizationStatus.denied) {
      throw AuthorizationDenied([type]);
    }
  }

  bool _inRange(DateTime t, DateRange r) => r.contains(t);

  // --------------------------------------------------------- HealthSource

  @override
  Future<HealthAvailability> availability() async => availabilityValue;

  @override
  Future<Set<HealthDataType>> supportedTypes() async => {...supported};

  @override
  Future<AuthorizationResult> requestAuthorization(
    Set<HealthDataType> read, {
    Set<HealthDataType> write = const {},
  }) async {
    if (!availabilityValue.isAvailable) {
      throw HealthDataNotAvailable(reason: availabilityValue.name);
    }
    final granted =
        grantAll ? AuthorizationStatus.authorized : AuthorizationStatus.denied;
    final out = <HealthDataType, AuthorizationStatus>{};
    for (final t in {...read, ...write}) {
      out[t] = _status[t] =
          supported.contains(t) ? granted : AuthorizationStatus.unsupported;
    }
    return AuthorizationResult(out);
  }

  @override
  Future<AuthorizationStatus> authorizationStatus(HealthDataType type) async =>
      !supported.contains(type)
          ? AuthorizationStatus.unsupported
          : _status[type] ?? AuthorizationStatus.notDetermined;

  @override
  Future<List<QuantitySample>> quantity(
      HealthDataType type, DateRange range) async {
    if (!type.isQuantity) throw UnsupportedDataType(type);
    _guard(type);
    return _quantities
        .where((s) => s.type == type && _inRange(s.start, range))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<List<SleepSample>> sleep(DateRange range) async {
    _guard(HealthDataType.sleep);
    // Like HealthKit's predicate: anything overlapping the range.
    return _sleep
        .where((s) => s.end.isAfter(range.start) && s.start.isBefore(range.end))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<List<Workout>> workouts(DateRange range) async {
    _guard(HealthDataType.workouts);
    return _workouts.where((w) => _inRange(w.start, range)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<StatisticsResult?> statistics(
      HealthDataType type, DateRange range, StatisticsOption option) async {
    if (!supportsStatistics) return null;
    final samples = await quantity(type, range);
    if (samples.isEmpty) return null;
    final values = samples.values;
    final value = switch (option) {
      StatisticsOption.sum => HealthStatistics.sum([
          for (final d in HealthStatistics.dailyValues(samples, type, range))
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
        end: range.end);
  }

  @override
  Future<List<DailyValue>?> dailyStatistics(
      HealthDataType type, DateRange range, StatisticsOption option) async {
    if (!supportsStatistics) return null;
    final samples = await quantity(type, range);
    final out = <DailyValue>[];
    for (final day in range.splitByDay()) {
      final daySamples = samples.where((s) => day.contains(s.start)).toList();
      double? v;
      if (daySamples.isNotEmpty) {
        final values = daySamples.values;
        v = switch (option) {
          StatisticsOption.sum => HealthStatistics.dailyValues(
                  daySamples, type, DateRange.day(day.start))
              .first
              .value,
          StatisticsOption.average => HealthStatistics.mean(values),
          StatisticsOption.minimum => values.reduce(math.min),
          StatisticsOption.maximum => values.reduce(math.max),
          StatisticsOption.mostRecent => daySamples.last.value,
        };
      }
      out.add(DailyValue(startOfDay(day.start), v));
    }
    return out;
  }

  @override
  Future<HealthChanges> changes(HealthDataType type, {String? anchor}) async {
    _guard(type);
    final current = _version.toString();
    if (anchor == null) {
      return HealthChanges(
          type: type, added: const [], deletedIds: const [], anchor: current);
    }
    final since = int.tryParse(anchor);
    if (since == null || since > _version) throw const SyncAnchorExpired();
    final added = <QuantitySample>[];
    final deleted = <String>[];
    final pending = [
      for (final c in _log)
        if (c.version > since &&
            (c.added?.type == type || c.deleted?.type == type))
          c,
    ];
    final limit = pageSize;
    final page = limit == null || pending.length <= limit
        ? pending
        : pending.sublist(0, limit);
    for (final c in page) {
      final a = c.added;
      final d = c.deleted;
      if (a != null) added.add(a);
      if (d != null) {
        added.removeWhere((s) => s.id == d.id);
        deleted.add(d.id);
      }
    }
    final hasMore = page.length < pending.length;
    return HealthChanges(
      type: type,
      added: added,
      deletedIds: deleted,
      anchor: hasMore ? page.last.version.toString() : current,
      hasMore: hasMore,
    );
  }

  @override
  Future<void> writeQuantity(
    HealthDataType type,
    double value, {
    required DateTime start,
    DateTime? end,
  }) async {
    _guard(type);
    addQuantity(type, value, start: start, end: end, sourceName: 'This app');
  }

  @override
  Future<void> openSettings() async {}
}

class _Change {
  _Change(this.version, this.added, this.deleted);
  final int version;
  final QuantitySample? added;
  final QuantitySample? deleted;
}

/// Generates realistic, deterministic health data for demos and tests.
class SyntheticHealthData {
  SyntheticHealthData({int seed = 42}) : _r = math.Random(seed);

  final math.Random _r;

  double _noise(double sd) {
    // Box-Muller
    final u1 = math.max(_r.nextDouble(), 1e-9);
    final u2 = _r.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * sd;
  }

  void fill(MockHealthSource source,
      {required int days, required DateTime now}) {
    final today = startOfDay(now);
    var weight = 74.0;
    for (var i = days; i >= 0; i--) {
      final day = addDays(today, -i);
      final weekend = day.weekday >= DateTime.saturday;
      final isToday = i == 0;

      // Steps in hourly chunks from two "sources" (phone + watch overlap).
      final dailySteps =
          math.max(1500.0, (weekend ? 6500 : 9000) + _noise(2500));
      final lastHour = isToday ? math.min(now.hour, 21) : 21;
      for (var h = 7; h <= lastHour; h++) {
        final chunk = dailySteps / 15;
        final t = day.add(Duration(hours: h));
        source.addQuantity(HealthDataType.steps, chunk.roundToDouble(),
            start: t,
            end: t.add(const Duration(hours: 1)),
            sourceName: 'iPhone');
        source.addQuantity(HealthDataType.steps, (chunk * 0.97).roundToDouble(),
            start: t,
            end: t.add(const Duration(hours: 1)),
            sourceName: 'Watch');
      }
      final noon = day.add(const Duration(hours: 12));
      source.addQuantity(HealthDataType.activeEnergyBurned,
          math.max(80.0, dailySteps * 0.045 + _noise(60)),
          start: noon, sourceName: 'Watch');
      source.addQuantity(
          HealthDataType.distanceWalkingRunning, dailySteps * 0.75,
          start: noon, sourceName: 'Watch');
      source.addQuantity(HealthDataType.exerciseTime,
          math.max(0, 28 + _noise(15)).roundToDouble(),
          start: noon, sourceName: 'Watch');

      // Vitals
      final morning = day.add(const Duration(hours: 7));
      source.addQuantity(HealthDataType.restingHeartRate, 58 + _noise(2.5),
          start: morning, sourceName: 'Watch');
      source.addQuantity(HealthDataType.heartRateVariabilitySDNN,
          math.max(15.0, 48 + _noise(8)),
          start: morning, sourceName: 'Watch');
      source.addQuantity(
          HealthDataType.oxygenSaturation, 96.5 + _noise(1).clamp(-2, 2),
          start: morning, sourceName: 'Watch');
      for (var h = 8; h <= 20; h += 2) {
        source.addQuantity(HealthDataType.heartRate, 72 + _noise(9),
            start: day.add(Duration(hours: h)), sourceName: 'Watch');
      }
      weight += _noise(0.15) - 0.01;
      source.addQuantity(
          HealthDataType.weight, double.parse(weight.toStringAsFixed(1)),
          start: morning, sourceName: 'Scale');

      // Sleep: bedtime around 23:15 (later at weekends), stages in cycles.
      if (!isToday || now.hour >= 8) {
        final bed = addDays(day, -1).add(Duration(
            minutes: 23 * 60 + 15 + (weekend ? 60 : 0) + _noise(25).round()));
        _night(source, bed, hours: 7.3 + _noise(0.6));
      }

      // Workouts 3x/week
      if (day.weekday == DateTime.monday ||
          day.weekday == DateTime.wednesday ||
          day.weekday == DateTime.saturday) {
        final start = day.add(const Duration(hours: 18));
        final minutes = 35 + _r.nextInt(25);
        source.addWorkout(
          day.weekday == DateTime.saturday
              ? WorkoutActivityType.cycling
              : WorkoutActivityType.running,
          start: start,
          end: start.add(Duration(minutes: minutes)),
          energyBurned: minutes * 10.5,
          distance: minutes * 160.0,
          averageHeartRate: 145 + _noise(8),
        );
      }
    }
  }

  void _night(MockHealthSource source, DateTime bed, {required double hours}) {
    final end = bed.add(Duration(minutes: (hours * 60).round()));
    source.addSleep(SleepStage.inBed,
        start: bed.subtract(const Duration(minutes: 10)),
        end: end,
        sourceName: 'iPhone');
    var t = bed;
    var cycle = 0;
    while (t.isBefore(end)) {
      // 90-minute cycles: core → deep (more early) → core → REM (more late)
      final deepMin = math.max(5, 30 - cycle * 7);
      final remMin = math.min(35, 12 + cycle * 6);
      for (final (stage, minutes) in [
        (SleepStage.core, 25),
        (SleepStage.deep, deepMin),
        (SleepStage.core, 20),
        (SleepStage.rem, remMin),
        (SleepStage.awake, cycle.isEven ? 3 : 0),
      ]) {
        if (minutes == 0 || !t.isBefore(end)) continue;
        var stop = t.add(Duration(minutes: minutes));
        if (stop.isAfter(end)) stop = end;
        source.addSleep(stage, start: t, end: stop, sourceName: 'Watch');
        t = stop;
      }
      cycle++;
    }
  }
}
