import 'dart:math' as math;

import '../models/date_range.dart';
import '../models/health_data_type.dart';
import '../models/samples.dart';
import '../models/statistics.dart';

/// Convenience accessors on sample lists.
extension QuantitySampleList on Iterable<QuantitySample> {
  /// The sample values, in order.
  List<double> get values => [for (final s in this) s.value];

  /// Only the samples of [type].
  Iterable<QuantitySample> ofType(HealthDataType type) =>
      where((s) => s.type == type);
}

/// How to combine overlapping sources (iPhone + Apple Watch, phone + band)
/// when summing raw cumulative samples.
enum DedupStrategy {
  /// Sum everything. Overlapping sources double-count.
  none,

  /// Per day, keep the single source with the largest total. A robust
  /// heuristic when the platform's de-duplicated statistics aren't available.
  maxSource,
}

/// A value that deviates strongly from its recent baseline.
class Anomaly {
  const Anomaly({
    required this.date,
    required this.value,
    required this.baselineMean,
    required this.zScore,
  });

  final DateTime date;
  final double value;
  final double baselineMean;

  /// Standard deviations from the rolling baseline (sign = direction).
  final double zScore;

  bool get isHigh => zScore > 0;

  @override
  String toString() => 'Anomaly($date: $value, z=${zScore.toStringAsFixed(2)})';
}

/// Summary of a personal baseline.
class Baseline {
  const Baseline(
      {required this.mean,
      required this.standardDeviation,
      required this.count});

  final double mean;
  final double standardDeviation;
  final int count;

  /// z-score of [value] against this baseline. Uses a floor of 1% of the mean
  /// for the deviation so a perfectly flat baseline doesn't divide by zero.
  double zScore(double value) {
    final sd = math.max(standardDeviation, mean.abs() * 0.01);
    return sd == 0 ? 0 : (value - mean) / sd;
  }
}

/// Statistical computations on health values. All functions are pure.
abstract final class HealthStatistics {
  static double mean(Iterable<double> values) {
    if (values.isEmpty) return 0;
    return sum(values) / values.length;
  }

  static double sum(Iterable<double> values) =>
      values.fold(0.0, (a, b) => a + b);

  static double median(Iterable<double> values) => percentile(values, 50);

  /// The [p]th percentile (0–100) using linear interpolation.
  static double percentile(Iterable<double> values, double p) {
    if (values.isEmpty) return 0;
    final sorted = values.toList()..sort();
    if (sorted.length == 1) return sorted.first;
    final rank = (p.clamp(0, 100) / 100) * (sorted.length - 1);
    final lo = rank.floor();
    final hi = rank.ceil();
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo);
  }

  /// Standard deviation. Population by default (matches HealthSyncKit); pass
  /// `sample: true` for the n-1 estimator.
  static double standardDeviation(Iterable<double> values,
      {bool sample = false}) {
    final n = values.length;
    if (n < 2) return 0;
    final m = mean(values);
    final squares = values.fold(0.0, (a, v) => a + (v - m) * (v - m));
    return math.sqrt(squares / (sample ? n - 1 : n));
  }

  static double? minimum(Iterable<double> values) =>
      values.isEmpty ? null : values.reduce(math.min);

  static double? maximum(Iterable<double> values) =>
      values.isEmpty ? null : values.reduce(math.max);

  /// Simple moving average over [window] values.
  static List<double> movingAverage(List<double> values, int window) {
    if (window <= 0 || values.length < window) return const [];
    final out = <double>[];
    var running = sum(values.take(window));
    out.add(running / window);
    for (var i = window; i < values.length; i++) {
      running += values[i] - values[i - window];
      out.add(running / window);
    }
    return out;
  }

  /// Exponential moving average with smoothing factor [alpha] in (0, 1].
  static List<double> exponentialMovingAverage(
      List<double> values, double alpha) {
    if (values.isEmpty) return const [];
    final out = <double>[values.first];
    for (var i = 1; i < values.length; i++) {
      out.add(alpha * values[i] + (1 - alpha) * out.last);
    }
    return out;
  }

  /// Percentage change from [oldValue] to [newValue], or `null` when
  /// [oldValue] is 0 (the change is undefined).
  static double? percentChange(double oldValue, double newValue) {
    if (oldValue == 0) return null;
    return (newValue - oldValue) / oldValue.abs() * 100;
  }

  /// Least-squares slope per *sample index* (HealthSyncKit-compatible).
  /// For irregularly spaced data prefer [trendPerDay].
  static double trend(List<double> values) {
    if (values.length < 2) return 0;
    return _slope(
        [for (var i = 0; i < values.length; i++) i.toDouble()], values);
  }

  /// Least-squares slope in *units per day*, using the real dates, so gaps in
  /// the data don't distort the trend. Days without a value are ignored.
  static double trendPerDay(List<DailyValue> series) {
    final points = [
      for (final d in series)
        if (d.value != null) d,
    ];
    if (points.length < 2) return 0;
    // Measure in wall-clock time so a 23 h / 25 h DST day still counts as 1.
    DateTime wall(DateTime t) =>
        DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
    final origin = wall(points.first.date);
    final xs = [
      for (final p in points)
        wall(p.date).difference(origin).inSeconds / Duration.secondsPerDay,
    ];
    return _slope(xs, [for (final p in points) p.value!]);
  }

  static double _slope(List<double> xs, List<double> ys) {
    final n = xs.length.toDouble();
    var sx = 0.0, sy = 0.0, sxy = 0.0, sx2 = 0.0;
    for (var i = 0; i < xs.length; i++) {
      sx += xs[i];
      sy += ys[i];
      sxy += xs[i] * ys[i];
      sx2 += xs[i] * xs[i];
    }
    final denom = n * sx2 - sx * sx;
    return denom == 0 ? 0 : (n * sxy - sx * sy) / denom;
  }

  /// A personal baseline from the most recent [window] values.
  static Baseline baseline(List<double> values, {int window = 30}) {
    final recent = values.length > window
        ? values.sublist(values.length - window)
        : values;
    return Baseline(
      mean: mean(recent),
      standardDeviation: standardDeviation(recent, sample: true),
      count: recent.length,
    );
  }

  /// Flags days whose value is more than [threshold] standard deviations from
  /// the rolling baseline of the preceding [window] days (needs at least
  /// [minBaseline] prior values).
  static List<Anomaly> anomalies(
    List<DailyValue> series, {
    int window = 14,
    double threshold = 2.0,
    int minBaseline = 7,
  }) {
    final out = <Anomaly>[];
    final history = <double>[];
    for (final day in series) {
      final v = day.value;
      if (v == null) continue;
      if (history.length >= minBaseline) {
        final b = baseline(history, window: window);
        final z = b.zScore(v);
        if (z.abs() >= threshold) {
          out.add(Anomaly(
              date: day.date, value: v, baselineMean: b.mean, zScore: z));
        }
      }
      history.add(v);
    }
    return out;
  }

  // ------------------------------------------------------------- Grouping

  static Map<DateTime, List<QuantitySample>> groupByDay(
          Iterable<QuantitySample> samples) =>
      _group(samples, (t) => startOfDay(t));

  /// Groups by ISO week (weeks start on Monday).
  static Map<DateTime, List<QuantitySample>> groupByWeek(
          Iterable<QuantitySample> samples) =>
      _group(samples, (t) {
        final d = startOfDay(t);
        return addDays(d, -(d.weekday - DateTime.monday));
      });

  static Map<DateTime, List<QuantitySample>> groupByMonth(
          Iterable<QuantitySample> samples) =>
      _group(samples, (t) => DateTime(t.year, t.month));

  static Map<DateTime, List<QuantitySample>> _group(
      Iterable<QuantitySample> samples, DateTime Function(DateTime) key) {
    final out = <DateTime, List<QuantitySample>>{};
    for (final s in samples) {
      out.putIfAbsent(key(s.start), () => []).add(s);
    }
    return out;
  }

  /// Daily values computed from raw samples of a single [type], one entry per
  /// day in [range] (null for days without data).
  ///
  /// Cumulative types are summed (with [dedup] applied); discrete types are
  /// averaged. Prefer the platform's de-duplicated
  /// `HealthSyncClient.daily()` when you can.
  static List<DailyValue> dailyValues(
    Iterable<QuantitySample> samples,
    HealthDataType type,
    DateRange range, {
    DedupStrategy dedup = DedupStrategy.maxSource,
  }) {
    final byDay = groupByDay(samples.ofType(type));
    return [
      for (final day in range.splitByDay())
        DailyValue(
          startOfDay(day.start),
          _combine(byDay[startOfDay(day.start)], type, dedup),
        ),
    ];
  }

  static double? _combine(
      List<QuantitySample>? day, HealthDataType type, DedupStrategy dedup) {
    if (day == null || day.isEmpty) return null;
    if (!type.isCumulative) return mean(day.values);
    if (dedup == DedupStrategy.none) return sum(day.values);
    final bySource = <String, double>{};
    for (final s in day) {
      final key = s.sourceId ?? s.sourceName ?? '';
      bySource[key] = (bySource[key] ?? 0) + s.value;
    }
    return bySource.values.reduce(math.max);
  }
}
