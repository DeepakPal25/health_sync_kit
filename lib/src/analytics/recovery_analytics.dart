import 'dart:math' as math;

import 'health_statistics.dart';
import 'sleep_analytics.dart';

/// A daily readiness / recovery estimate.
///
/// Wellness guidance only, not a medical device or diagnosis.
class ReadinessScore {
  const ReadinessScore({
    required this.score,
    required this.hrvPoints,
    required this.restingHeartRatePoints,
    required this.sleepPoints,
    required this.hrvZScore,
    required this.restingHeartRateZScore,
  });

  /// 0–100, or `null` when no component had enough data.
  final int? score;

  /// Component contributions before rescaling (max 40 / 30 / 30), `null` when
  /// that input was missing or its baseline too short.
  final double? hrvPoints;
  final double? restingHeartRatePoints;
  final double? sleepPoints;

  /// Today's HRV vs. its personal baseline (positive = higher = better).
  final double? hrvZScore;

  /// Today's resting HR vs. baseline (positive = *lower* than usual = better).
  final double? restingHeartRateZScore;

  bool get hasScore => score != null;

  String get label => switch (score) {
        null => 'Not enough data',
        >= 85 => 'Optimal',
        >= 70 => 'Good',
        >= 50 => 'Fair',
        _ => 'Pay attention',
      };
}

/// Recovery metrics based on personal baselines.
abstract final class RecoveryAnalytics {
  /// Minimum baseline length for HRV / resting-HR components.
  static const int minBaselineDays = 7;

  /// Combines HRV and resting heart rate (each compared to the user's own
  /// rolling baseline) with last night's sleep score.
  ///
  /// - HRV (40 pts): 20 at baseline, ±10 per standard deviation
  /// - Resting HR (30 pts): 15 at baseline, ±7.5 per SD, lower is better
  /// - Sleep (30 pts): sleep score × 0.3
  ///
  /// Missing components are left out and the rest rescaled to 100.
  /// Baselines should be daily values *before* today (e.g. last 30 days).
  static ReadinessScore readiness({
    double? hrvToday,
    List<double> hrvBaseline = const [],
    double? restingHeartRateToday,
    List<double> restingHeartRateBaseline = const [],
    SleepSummary? lastNight,
  }) {
    double? hrvPts, rhrPts, sleepPts, hrvZ, rhrZ;

    if (hrvToday != null && hrvBaseline.length >= minBaselineDays) {
      hrvZ = HealthStatistics.baseline(hrvBaseline).zScore(hrvToday);
      hrvPts = (20 + hrvZ * 10).clamp(0, 40).toDouble();
    }
    if (restingHeartRateToday != null &&
        restingHeartRateBaseline.length >= minBaselineDays) {
      rhrZ = -HealthStatistics.baseline(restingHeartRateBaseline)
          .zScore(restingHeartRateToday);
      rhrPts = (15 + rhrZ * 7.5).clamp(0, 30).toDouble();
    }
    if (lastNight != null && lastNight.totalSleep > 0) {
      sleepPts = lastNight.sleepScore * 0.3;
    }

    var earned = 0.0, possible = 0.0;
    if (hrvPts != null) {
      earned += hrvPts;
      possible += 40;
    }
    if (rhrPts != null) {
      earned += rhrPts;
      possible += 30;
    }
    if (sleepPts != null) {
      earned += sleepPts;
      possible += 30;
    }

    return ReadinessScore(
      score: possible == 0
          ? null
          : math.min(100, (earned / possible * 100).round()),
      hrvPoints: hrvPts,
      restingHeartRatePoints: rhrPts,
      sleepPoints: sleepPts,
      hrvZScore: hrvZ,
      restingHeartRateZScore: rhrZ,
    );
  }
}
