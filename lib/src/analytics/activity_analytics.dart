import 'dart:math' as math;

import '../models/date_range.dart';
import '../models/health_data_type.dart';
import '../models/samples.dart';
import '../models/statistics.dart';
import 'health_statistics.dart';

/// Daily goals used by the activity score. Defaults match HealthSyncKit.
class ActivityGoals {
  const ActivityGoals({
    this.steps = 10000,
    this.activeCalories = 500,
    this.exerciseMinutes = 30,
    this.distanceMeters = 5000,
  });

  final double steps;
  final double activeCalories;
  final double exerciseMinutes;
  final double distanceMeters;
}

/// One day of activity.
class ActivitySummary {
  const ActivitySummary({
    required this.date,
    this.steps = 0,
    this.activeCalories = 0,
    this.distance = 0,
    this.exerciseMinutes = 0,
    this.standMinutes = 0,
    this.goals = const ActivityGoals(),
  });

  final DateTime date;
  final double steps;

  /// kcal
  final double activeCalories;

  /// metres
  final double distance;
  final double exerciseMinutes;
  final double standMinutes;
  final ActivityGoals goals;

  int get activityScore => ActivityAnalytics.calculateScore(this);

  @override
  String toString() =>
      'ActivitySummary($date: ${steps.round()} steps, score $activityScore)';
}

/// Acute:chronic workload status.
enum TrainingLoadStatus {
  insufficientData,
  undertraining,
  optimal,
  high,
  veryHigh
}

/// Acute (7-day) vs chronic (28-day) training load.
class TrainingLoad {
  const TrainingLoad({
    required this.acute,
    required this.chronic,
    required this.ratio,
    required this.status,
  });

  /// Average daily load over the last 7 days.
  final double acute;

  /// Average daily load over the last 28 days.
  final double chronic;

  /// acute ÷ chronic, or `null` without enough history.
  final double? ratio;
  final TrainingLoadStatus status;
}

/// Activity metrics. All functions are pure; pass `now` to make them
/// deterministic in tests.
abstract final class ActivityAnalytics {
  /// A day's summary from raw samples of several types. Overlapping sources
  /// are handled with [dedup] (see [DedupStrategy]).
  static ActivitySummary dailySummary(
    Iterable<QuantitySample> samples,
    DateTime day, {
    ActivityGoals goals = const ActivityGoals(),
    DedupStrategy dedup = DedupStrategy.maxSource,
  }) {
    final range = DateRange.day(day);
    double total(HealthDataType t) =>
        HealthStatistics.dailyValues(samples, t, range, dedup: dedup)
            .first
            .value ??
        0;
    return ActivitySummary(
      date: startOfDay(day),
      steps: total(HealthDataType.steps),
      activeCalories: total(HealthDataType.activeEnergyBurned),
      distance: total(HealthDataType.distanceWalkingRunning),
      exerciseMinutes: total(HealthDataType.exerciseTime),
      standMinutes: total(HealthDataType.standTime),
      goals: goals,
    );
  }

  /// Activity score, 0–100:
  /// steps 40 pts · active calories 30 · exercise minutes 20 · distance 10,
  /// each scaled linearly up to its goal.
  static int calculateScore(ActivitySummary s) {
    final g = s.goals;
    double part(double value, double goal, double points) =>
        goal <= 0 ? 0 : math.min(points, value / goal * points);
    final total = part(s.steps, g.steps, 40) +
        part(s.activeCalories, g.activeCalories, 30) +
        part(s.exerciseMinutes, g.exerciseMinutes, 20) +
        part(s.distance, g.distanceMeters, 10);
    return total.round().clamp(0, 100);
  }

  /// Progress towards a goal, 0–1.
  static double goalProgress(double current, double goal) =>
      goal <= 0 ? 0 : math.min(1.0, current / goal);

  /// Average of the days that have data.
  static double averageDaily(List<DailyValue> series) => HealthStatistics.mean([
        for (final d in series)
          if (d.value != null) d.value!
      ]);

  /// Current streak of consecutive days meeting [goal], ending today.
  ///
  /// If today hasn't reached the goal *yet*, it doesn't break the streak:
  /// counting starts from yesterday (set [todayInProgress] to `false` to
  /// require today too). HealthSyncKit's version reset to 0 every morning.
  static int streak(
    List<DailyValue> series,
    double goal, {
    DateTime? now,
    bool todayInProgress = true,
  }) {
    final byDay = {for (final d in series) startOfDay(d.date): d.value};
    var day = startOfDay(now ?? DateTime.now());
    if (todayInProgress && (byDay[day] ?? 0) < goal) day = addDays(day, -1);
    var count = 0;
    while ((byDay[day] ?? 0) >= goal) {
      count++;
      day = addDays(day, -1);
    }
    return count;
  }

  /// Longest run of consecutive days meeting [goal] anywhere in [series].
  static int longestStreak(List<DailyValue> series, double goal) {
    final hits = {
      for (final d in series)
        if ((d.value ?? 0) >= goal) startOfDay(d.date),
    };
    var best = 0;
    for (final day in hits) {
      if (hits.contains(addDays(day, -1))) continue; // not a run start
      var len = 1;
      while (hits.contains(addDays(day, len))) {
        len++;
      }
      best = math.max(best, len);
    }
    return best;
  }

  /// Acute:chronic workload ratio from workouts.
  ///
  /// Load per workout = minutes × intensity, where intensity comes from the
  /// average heart rate as a fraction of [maxHeartRate] when known, else 0.6.
  /// Ratios of 0.8–1.3 are commonly treated as the "sweet spot"; above 1.5 as
  /// a spike. A heuristic for wellness apps, not medical advice.
  static TrainingLoad trainingLoad(
    List<Workout> workouts, {
    DateTime? now,
    double maxHeartRate = 190,
  }) {
    final today = startOfDay(now ?? DateTime.now());
    final tomorrow = addDays(today, 1);
    double loadSince(int days) {
      final from = addDays(today, -(days - 1));
      var total = 0.0;
      for (final w in workouts) {
        if (w.start.isBefore(from) || !w.start.isBefore(tomorrow)) continue;
        final hr = w.averageHeartRate;
        final intensity =
            hr == null ? 0.6 : (hr / maxHeartRate).clamp(0.3, 1.0);
        total += w.minutes * intensity;
      }
      return total / days;
    }

    final hasHistory =
        workouts.any((w) => w.start.isBefore(addDays(today, -21)));
    final acute = loadSince(7);
    final chronic = loadSince(28);
    if (!hasHistory || chronic == 0) {
      return TrainingLoad(
          acute: acute,
          chronic: chronic,
          ratio: null,
          status: TrainingLoadStatus.insufficientData);
    }
    final ratio = acute / chronic;
    final status = ratio < 0.8
        ? TrainingLoadStatus.undertraining
        : ratio <= 1.3
            ? TrainingLoadStatus.optimal
            : ratio <= 1.5
                ? TrainingLoadStatus.high
                : TrainingLoadStatus.veryHigh;
    return TrainingLoad(
        acute: acute, chronic: chronic, ratio: ratio, status: status);
  }
}
