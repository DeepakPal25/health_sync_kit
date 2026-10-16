import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

void main() {
  final now = DateTime(2026, 11, 18, 10); // Wednesday morning
  final today = DateTime(2026, 11, 18);

  group('activity score', () {
    test('matches HealthSyncKit weights', () {
      final s = ActivitySummary(
          date: today,
          steps: 10000,
          activeCalories: 500,
          exerciseMinutes: 30,
          distance: 5000);
      expect(s.activityScore, 100);
      expect(ActivitySummary(date: today, steps: 5000).activityScore, 20);
      expect(ActivitySummary(date: today, steps: 50000).activityScore, 40);
    });

    test('custom goals', () {
      final s = ActivitySummary(
          date: today, steps: 5000, goals: const ActivityGoals(steps: 5000));
      expect(s.activityScore, 40);
    });

    test('goalProgress is capped at 1', () {
      expect(ActivityAnalytics.goalProgress(15000, 10000), 1);
      expect(ActivityAnalytics.goalProgress(5000, 10000), 0.5);
      expect(ActivityAnalytics.goalProgress(1, 0), 0);
    });
  });

  group('streaks', () {
    List<DailyValue> series(List<double?> values) => [
          for (var i = 0; i < values.length; i++)
            DailyValue(addDays(today, i - values.length + 1), values[i]),
        ];

    test('today in progress does not break the streak', () {
      // ... 12k, 11k, 10k, today 2k so far
      final s = series([3000, 12000, 11000, 10000, 2000]);
      expect(ActivityAnalytics.streak(s, 10000, now: now), 3);
      expect(
          ActivityAnalytics.streak(s, 10000, now: now, todayInProgress: false),
          0);
    });

    test('today counts once reached', () {
      final s = series([12000, 11000, 10500]);
      expect(ActivityAnalytics.streak(s, 10000, now: now), 3);
    });

    test('a missing day breaks the streak', () {
      final s = series([12000, null, 11000, 12000, 0]);
      expect(ActivityAnalytics.streak(s, 10000, now: now), 2);
    });

    test('longest streak anywhere', () {
      final s = series([12000, 12000, 12000, 0, 12000, 12000, 0]);
      expect(ActivityAnalytics.longestStreak(s, 10000), 3);
    });
  });

  group('training load', () {
    Workout w(int daysAgo, int minutes, {double? hr}) {
      final start = addDays(today, -daysAgo).add(const Duration(hours: 18));
      return Workout(
        id: 'w$daysAgo-$minutes',
        activityType: WorkoutActivityType.running,
        start: start,
        end: start.add(Duration(minutes: minutes)),
        averageHeartRate: hr,
      );
    }

    test('insufficient history', () {
      final load = ActivityAnalytics.trainingLoad([w(1, 30)], now: now);
      expect(load.status, TrainingLoadStatus.insufficientData);
      expect(load.ratio, isNull);
    });

    test('steady training is optimal, a spike is flagged', () {
      final steady = [for (var d = 0; d < 28; d += 2) w(d, 40)];
      expect(ActivityAnalytics.trainingLoad(steady, now: now).status,
          TrainingLoadStatus.optimal);

      final spike = [
        for (var d = 8; d < 28; d += 3) w(d, 30),
        for (var d = 0; d < 7; d++) w(d, 60, hr: 170),
      ];
      final load = ActivityAnalytics.trainingLoad(spike, now: now);
      expect(load.ratio, greaterThan(1.5));
      expect(load.status, TrainingLoadStatus.veryHigh);
    });
  });

  group('readiness', () {
    final hrvBase = <double>[50.0, 52, 48, 51, 49, 50, 50, 53, 47, 50];
    final rhrBase = <double>[58.0, 59, 57, 58, 58, 60, 56, 58, 58, 58];
    final goodNight = SleepSummary(
      date: today,
      totalSleep: 7.5,
      deepSleep: 1.5,
      remSleep: 1.5,
      coreSleep: 4.5,
      awake: 0.3,
      timeInBed: 8,
      sleepEfficiency: 94,
      sleepScore: 99,
      hasStages: true,
    );

    test('at baseline with a great night scores well', () {
      final r = RecoveryAnalytics.readiness(
        hrvToday: 50,
        hrvBaseline: hrvBase,
        restingHeartRateToday: 58,
        restingHeartRateBaseline: rhrBase,
        lastNight: goodNight,
      );
      expect(r.hrvPoints, closeTo(20, 1));
      expect(r.restingHeartRatePoints, closeTo(15, 1));
      expect(r.score, inInclusiveRange(60, 70));
    });

    test('suppressed HRV and elevated RHR lower the score', () {
      final good = RecoveryAnalytics.readiness(
          hrvToday: 55,
          hrvBaseline: hrvBase,
          restingHeartRateToday: 56,
          restingHeartRateBaseline: rhrBase,
          lastNight: goodNight);
      final bad = RecoveryAnalytics.readiness(
          hrvToday: 38,
          hrvBaseline: hrvBase,
          restingHeartRateToday: 66,
          restingHeartRateBaseline: rhrBase,
          lastNight: goodNight);
      expect(bad.score!, lessThan(good.score!));
      expect(bad.hrvZScore!, lessThan(0));
      expect(bad.restingHeartRateZScore!, lessThan(0));
    });

    test('missing inputs are rescaled; nothing gives null', () {
      final sleepOnly = RecoveryAnalytics.readiness(lastNight: goodNight);
      expect(sleepOnly.score, 99);
      expect(sleepOnly.hrvPoints, isNull);

      final short = RecoveryAnalytics.readiness(
          hrvToday: 50, hrvBaseline: const [50, 51]);
      expect(short.hasScore, isFalse);
      expect(short.label, 'Not enough data');
    });
  });
}
