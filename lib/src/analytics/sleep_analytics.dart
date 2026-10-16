import 'dart:math' as math;

import '../models/date_range.dart';
import '../models/samples.dart';
import 'health_statistics.dart';

/// One sleep session (a night or a nap), already de-duplicated to a single
/// source.
///
/// Not `const`: [summary] is computed once, on first access, and cached.
class SleepNight {
  SleepNight({
    required this.date,
    required this.start,
    required this.end,
    required this.samples,
    this.sourceName,
  });

  /// The day the session is attributed to: the local date of waking up.
  /// A night from 23:30 Mon to 07:00 Tue belongs to Tuesday.
  final DateTime date;

  /// First sample start (bedtime).
  final DateTime start;

  /// Last sample end (wake time).
  final DateTime end;

  /// The samples of the chosen source.
  final List<SleepSample> samples;
  final String? sourceName;

  /// Time in bed, bedtime → wake.
  Duration get timeInBed => end.difference(start);

  /// Midpoint of the session; used for chronotype / social-jetlag maths.
  DateTime get midpoint => start.add(timeInBed ~/ 2);

  /// Metrics for this session. Computed on first access, then cached, so
  /// [isNap] and the nightly averages don't re-walk [samples].
  late final SleepSummary summary = SleepAnalytics.summarize(this);

  /// Short daytime sessions are naps and are excluded from nightly averages.
  bool get isNap =>
      summary.totalSleep < 3 && start.hour >= 9 && start.hour < 20;
}

/// Aggregated metrics for one sleep session.
class SleepSummary {
  const SleepSummary({
    required this.date,
    required this.totalSleep,
    required this.deepSleep,
    required this.remSleep,
    required this.coreSleep,
    required this.awake,
    required this.timeInBed,
    required this.sleepEfficiency,
    required this.sleepScore,
    required this.hasStages,
    this.bedtime,
    this.wakeTime,
  });

  static SleepSummary empty(DateTime date) => SleepSummary(
        date: date,
        totalSleep: 0,
        deepSleep: 0,
        remSleep: 0,
        coreSleep: 0,
        awake: 0,
        timeInBed: 0,
        sleepEfficiency: 0,
        sleepScore: 0,
        hasStages: false,
      );

  final DateTime date;

  /// Hours asleep (any stage). Never includes "in bed" or awake time.
  final double totalSleep;
  final double deepSleep;
  final double remSleep;

  /// Light/core plus unstaged "asleep" hours.
  final double coreSleep;
  final double awake;

  /// Hours from bedtime to wake time.
  final double timeInBed;

  /// Asleep ÷ time in bed, 0–100.
  final double sleepEfficiency;

  /// 0–100. See [SleepAnalytics.calculateScore].
  final int sleepScore;

  /// Whether the source recorded stages (deep/REM/core). Unstaged sources get
  /// no stage points, so their score is capped at 50.
  final bool hasStages;
  final DateTime? bedtime;
  final DateTime? wakeTime;

  @override
  String toString() => 'SleepSummary($date: ${totalSleep.toStringAsFixed(1)}h, '
      'score $sleepScore)';
}

/// Sleep metrics and scores from raw [SleepSample]s.
abstract final class SleepAnalytics {
  // ------------------------------------------------------------- Sessions

  /// Groups samples into sessions and keeps one source per session.
  ///
  /// - Samples less than [maxGap] apart belong to the same session, so a
  ///   night that crosses midnight stays one night.
  /// - When several sources recorded the same session (iPhone *and* Apple
  ///   Watch, phone *and* band), the source with the most staged sleep wins,
  ///   then the one with the most total sleep. Pass [sourcePriority] (source
  ///   ids or names, best first) to override.
  static List<SleepNight> nights(
    Iterable<SleepSample> samples, {
    Duration maxGap = const Duration(hours: 2),
    List<String> sourcePriority = const [],
  }) {
    final sorted = samples.toList()..sort((a, b) => a.start.compareTo(b.start));
    final clusters = <List<SleepSample>>[];
    DateTime? clusterEnd;
    for (final s in sorted) {
      if (clusterEnd == null || s.start.difference(clusterEnd) > maxGap) {
        clusters.add([s]);
        clusterEnd = s.end;
      } else {
        clusters.last.add(s);
        if (s.end.isAfter(clusterEnd)) clusterEnd = s.end;
      }
    }

    final nights = <SleepNight>[];
    for (final cluster in clusters) {
      final bySource = <String, List<SleepSample>>{};
      for (final s in cluster) {
        bySource.putIfAbsent(_sourceKey(s), () => []).add(s);
      }
      final chosen = _pickSource(bySource, sourcePriority);
      if (!chosen.any((s) => s.stage.isAsleep)) continue; // in-bed only
      var start = chosen.first.start;
      var end = chosen.first.end;
      for (final s in chosen) {
        if (s.start.isBefore(start)) start = s.start;
        if (s.end.isAfter(end)) end = s.end;
      }
      nights.add(SleepNight(
        date: startOfDay(end),
        start: start,
        end: end,
        samples: chosen,
        sourceName: chosen.first.sourceName,
      ));
    }
    return nights;
  }

  static String _sourceKey(SleepSample s) => s.sourceId ?? s.sourceName ?? '';

  static List<SleepSample> _pickSource(
      Map<String, List<SleepSample>> bySource, List<String> priority) {
    if (bySource.length == 1) return bySource.values.first;
    for (final p in priority) {
      for (final e in bySource.entries) {
        if (e.key == p || e.value.first.sourceName == p) return e.value;
      }
    }
    List<SleepSample>? best;
    var bestStaged = -1.0, bestTotal = -1.0;
    for (final candidate in bySource.values) {
      final staged = _union(candidate.where((s) =>
          s.stage == SleepStage.deep ||
          s.stage == SleepStage.rem ||
          s.stage == SleepStage.core));
      final total = _union(candidate.where((s) => s.stage.isAsleep));
      if (staged > bestStaged || (staged == bestStaged && total > bestTotal)) {
        best = candidate;
        bestStaged = staged;
        bestTotal = total;
      }
    }
    return best!;
  }

  /// Total hours covered by [samples], counting overlaps once.
  static double _union(Iterable<SleepSample> samples) {
    final sorted = samples.toList()..sort((a, b) => a.start.compareTo(b.start));
    var totalMs = 0;
    DateTime? curStart, curEnd;
    for (final s in sorted) {
      if (curEnd == null || s.start.isAfter(curEnd)) {
        if (curStart != null) {
          totalMs += curEnd!.difference(curStart).inMilliseconds;
        }
        curStart = s.start;
        curEnd = s.end;
      } else if (s.end.isAfter(curEnd)) {
        curEnd = s.end;
      }
    }
    if (curStart != null) {
      totalMs += curEnd!.difference(curStart).inMilliseconds;
    }
    return totalMs / 3600000;
  }

  // -------------------------------------------------------------- Summary

  /// Summarises one session.
  static SleepSummary summarize(SleepNight night) {
    final s = night.samples;
    final asleep = _union(s.where((x) => x.stage.isAsleep));
    final deep = _union(s.where((x) => x.stage == SleepStage.deep));
    final rem = _union(s.where((x) => x.stage == SleepStage.rem));
    final core = _union(s.where(
        (x) => x.stage == SleepStage.core || x.stage == SleepStage.asleep));
    final awake = _union(s.where((x) => x.stage == SleepStage.awake));
    final inBed = night.timeInBed.inMilliseconds / 3600000;
    final efficiency = inBed > 0 ? math.min(100.0, asleep / inBed * 100) : 0.0;
    final hasStages = deep > 0 || rem > 0;
    return SleepSummary(
      date: night.date,
      totalSleep: asleep,
      deepSleep: deep,
      remSleep: rem,
      coreSleep: core,
      awake: awake,
      timeInBed: inBed,
      sleepEfficiency: efficiency,
      sleepScore: calculateScore(
        totalSleep: asleep,
        deepSleep: deep,
        remSleep: rem,
        efficiency: efficiency,
      ),
      hasStages: hasStages,
      bedtime: night.start,
      wakeTime: night.end,
    );
  }

  /// Summary of the main (longest, non-nap) session in [samples], or an
  /// empty summary when there is none. Mirrors HealthSyncKit's
  /// `SleepAnalytics.summary(from:)`, minus its double counting.
  static SleepSummary summary(Iterable<SleepSample> samples, {DateTime? date}) {
    final all = nights(samples);
    final main = all.where((n) => !n.isNap).toList();
    final pool = main.isNotEmpty ? main : all;
    if (pool.isEmpty) return SleepSummary.empty(date ?? DateTime.now());
    pool.sort((a, b) => b.timeInBed.compareTo(a.timeInBed));
    return pool.first.summary;
  }

  /// Scores sleep 0–100 (same formula as HealthSyncKit):
  /// - Duration (0–40): 7–9 h optimal
  /// - Deep (0–25): 20% of sleep earns full points
  /// - REM (0–25): 20% of sleep earns full points
  /// - Efficiency (0–10): 100% earns full points
  static int calculateScore({
    required double totalSleep,
    required double deepSleep,
    required double remSleep,
    required double efficiency,
  }) {
    final double duration;
    if (totalSleep >= 7 && totalSleep <= 9) {
      duration = 40;
    } else if (totalSleep >= 6 && totalSleep < 7) {
      duration = 30;
    } else if (totalSleep > 9 && totalSleep < 10) {
      duration = 30;
    } else if (totalSleep >= 5 && totalSleep < 6) {
      duration = 20;
    } else if (totalSleep >= 10) {
      duration = 20;
    } else {
      duration = math.max(0.0, totalSleep / 5 * 20);
    }
    final deepRatio = totalSleep > 0 ? deepSleep / totalSleep * 100 : 0.0;
    final remRatio = totalSleep > 0 ? remSleep / totalSleep * 100 : 0.0;
    final deepScore = math.min(25.0, deepRatio * 1.25);
    final remScore = math.min(25.0, remRatio * 1.25);
    final effScore = math.min(10.0, efficiency / 10);
    return (duration + deepScore + remScore + effScore).round().clamp(0, 100);
  }

  // ---------------------------------------------------- Multi-night metrics

  /// Average hours asleep per night (naps excluded).
  static double averageSleep(List<SleepNight> nights) {
    final main = nights.where((n) => !n.isNap).toList();
    return HealthStatistics.mean([for (final n in main) n.summary.totalSleep]);
  }

  /// Bedtime consistency, 0–100 (100 = same bedtime every night).
  ///
  /// Uses circular statistics so 23:30 and 00:30 are one hour apart, not
  /// 23. A circular standard deviation of 90 minutes or more scores 0.
  static double bedtimeConsistency(List<SleepNight> nights) => _consistency([
        for (final n in nights)
          if (!n.isNap) n.start
      ]);

  /// Wake-time consistency, 0–100.
  static double wakeConsistency(List<SleepNight> nights) => _consistency([
        for (final n in nights)
          if (!n.isNap) n.end
      ]);

  static double _consistency(List<DateTime> times) {
    if (times.length < 2) return 0;
    final sd = circularStdMinutes(times);
    return math.max(0.0, 100 - sd / 90 * 100);
  }

  /// Circular standard deviation of clock times, in minutes.
  static double circularStdMinutes(List<DateTime> times) {
    var sinSum = 0.0, cosSum = 0.0;
    for (final t in times) {
      final a = _angle(t);
      sinSum += math.sin(a);
      cosSum += math.cos(a);
    }
    final r = math.sqrt(sinSum * sinSum + cosSum * cosSum) / times.length;
    if (r >= 1) return 0;
    final sdRadians = math.sqrt(-2 * math.log(r));
    return sdRadians / (2 * math.pi) * 1440;
  }

  /// Circular mean clock time, in minutes after midnight (0–1439).
  static double circularMeanMinutes(List<DateTime> times) {
    var sinSum = 0.0, cosSum = 0.0;
    for (final t in times) {
      final a = _angle(t);
      sinSum += math.sin(a);
      cosSum += math.cos(a);
    }
    var a = math.atan2(sinSum, cosSum);
    if (a < 0) a += 2 * math.pi;
    return a / (2 * math.pi) * 1440;
  }

  static double _angle(DateTime t) =>
      (t.hour * 60 + t.minute + t.second / 60) / 1440 * 2 * math.pi;

  /// Accumulated sleep debt in hours over the last [days] nights: the sum of
  /// shortfalls against [need]. Surplus nights don't pay debt back.
  static double sleepDebt(
    List<SleepNight> nights, {
    double need = 8,
    int days = 7,
  }) {
    final main = nights.where((n) => !n.isNap).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final recent = main.length > days ? main.sublist(main.length - days) : main;
    return recent.fold(
        0.0, (debt, n) => debt + math.max(0, need - n.summary.totalSleep));
  }

  /// Social jetlag in hours: the shift in mid-sleep between free days
  /// (waking on Saturday/Sunday) and work days. Over ~1 h is commonly
  /// associated with feeling "jet-lagged" on Mondays. `null` if either group
  /// is empty.
  static double? socialJetlag(List<SleepNight> nights) {
    final free = <DateTime>[];
    final work = <DateTime>[];
    for (final n in nights.where((n) => !n.isNap)) {
      final weekend = n.date.weekday == DateTime.saturday ||
          n.date.weekday == DateTime.sunday;
      (weekend ? free : work).add(n.midpoint);
    }
    if (free.isEmpty || work.isEmpty) return null;
    var diff = (circularMeanMinutes(free) - circularMeanMinutes(work)).abs();
    if (diff > 720) diff = 1440 - diff;
    return diff / 60;
  }
}
