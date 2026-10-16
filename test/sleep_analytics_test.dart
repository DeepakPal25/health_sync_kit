import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

int _id = 0;
SleepSample s(SleepStage stage, DateTime start, int minutes,
        {String source = 'Watch'}) =>
    SleepSample(
      id: 's${_id++}',
      stage: stage,
      start: start,
      end: start.add(Duration(minutes: minutes)),
      sourceName: source,
      sourceId: source,
    );

/// A staged night: 23:00 → 07:00 (8 h in bed), 7.5 h asleep.
List<SleepSample> stagedNight(DateTime bed, {String source = 'Watch'}) {
  var t = bed;
  final out = <SleepSample>[];
  void add(SleepStage st, int m) {
    out.add(s(st, t, m, source: source));
    t = t.add(Duration(minutes: m));
  }

  add(SleepStage.awake, 15);
  add(SleepStage.core, 120);
  add(SleepStage.deep, 90);
  add(SleepStage.core, 60);
  add(SleepStage.rem, 90);
  add(SleepStage.awake, 15);
  add(SleepStage.core, 90);
  return out;
}

void main() {
  final bed = DateTime(2026, 3, 9, 23); // Monday 23:00

  test('a night across midnight is one session attributed to the wake date',
      () {
    final nights = SleepAnalytics.nights(stagedNight(bed));
    expect(nights, hasLength(1));
    expect(nights.single.date, DateTime(2026, 3, 10));
    expect(nights.single.start, bed);
    expect(nights.single.end, DateTime(2026, 3, 10, 7));
  });

  test('summary totals, efficiency and score', () {
    final summary = SleepAnalytics.nights(stagedNight(bed)).single.summary;
    expect(summary.totalSleep, closeTo(7.5, 1e-9));
    expect(summary.deepSleep, 1.5);
    expect(summary.remSleep, 1.5);
    expect(summary.coreSleep, closeTo(4.5, 1e-9));
    expect(summary.awake, 0.5);
    expect(summary.timeInBed, 8);
    expect(summary.sleepEfficiency, closeTo(93.75, 1e-9));
    expect(summary.hasStages, isTrue);
    // 40 (duration) + 25 (deep 20%) + 25 (REM 20%) + 9.375 (eff) = 99
    expect(summary.sleepScore, 99);
  });

  test('inBed is never counted as sleep (HealthSyncKit counted it)', () {
    final samples = [
      s(SleepStage.inBed, bed, 8 * 60, source: 'iPhone'),
      ...stagedNight(bed, source: 'iPhone'),
    ];
    final summary = SleepAnalytics.nights(samples).single.summary;
    expect(summary.totalSleep, closeTo(7.5, 1e-9));
  });

  test('phone + watch recording the same night are not double counted', () {
    final samples = [
      s(SleepStage.asleep, bed.add(const Duration(minutes: 20)), 7 * 60,
          source: 'iPhone'),
      ...stagedNight(bed, source: 'Watch'),
    ];
    final night = SleepAnalytics.nights(samples).single;
    expect(night.sourceName, 'Watch', reason: 'the staged source wins');
    expect(night.summary.totalSleep, closeTo(7.5, 1e-9));
  });

  test('source priority overrides the automatic choice', () {
    final samples = [
      s(SleepStage.asleep, bed, 7 * 60, source: 'iPhone'),
      ...stagedNight(bed, source: 'Watch'),
    ];
    final night =
        SleepAnalytics.nights(samples, sourcePriority: ['iPhone']).single;
    expect(night.sourceName, 'iPhone');
    expect(night.summary.hasStages, isFalse);
  });

  test('overlapping samples from one source count once', () {
    final samples = [
      s(SleepStage.asleep, bed, 120),
      s(SleepStage.asleep, bed.add(const Duration(minutes: 60)), 120),
    ];
    expect(SleepAnalytics.nights(samples).single.summary.totalSleep, 3);
  });

  test('naps are separate sessions and excluded from averages', () {
    final nap = s(SleepStage.asleep, DateTime(2026, 3, 10, 14), 40);
    final nights = SleepAnalytics.nights([...stagedNight(bed), nap]);
    expect(nights, hasLength(2));
    expect(nights.last.isNap, isTrue);
    expect(SleepAnalytics.averageSleep(nights), closeTo(7.5, 1e-9));
  });

  test('summary() picks the main night', () {
    final nap = s(SleepStage.asleep, DateTime(2026, 3, 10, 14), 40);
    expect(SleepAnalytics.summary([nap, ...stagedNight(bed)]).totalSleep,
        closeTo(7.5, 1e-9));
    expect(SleepAnalytics.summary(const []).totalSleep, 0);
  });

  test('calculateScore matches HealthSyncKit', () {
    expect(
        SleepAnalytics.calculateScore(
            totalSleep: 7.5, deepSleep: 1.5, remSleep: 2.0, efficiency: 91),
        99);
    expect(
        SleepAnalytics.calculateScore(
            totalSleep: 4, deepSleep: 0, remSleep: 0, efficiency: 50),
        21);
  });

  group('consistency (circular)', () {
    List<SleepNight> nightsAt(List<DateTime> bedtimes) => [
          for (final b in bedtimes)
            SleepAnalytics.nights([s(SleepStage.asleep, b, 7 * 60)]).single,
        ];

    test('23:30 and 00:30 are an hour apart, not 23 hours', () {
      final n = nightsAt([
        DateTime(2026, 3, 1, 23, 30),
        DateTime(2026, 3, 3, 0, 30),
        DateTime(2026, 3, 3, 23, 30),
        DateTime(2026, 3, 5, 0, 30),
      ]);
      final score = SleepAnalytics.bedtimeConsistency(n);
      expect(score, greaterThan(60));
      expect(SleepAnalytics.circularStdMinutes([for (final x in n) x.start]),
          closeTo(30, 1));
    });

    test('identical bedtimes score 100', () {
      final n = nightsAt([
        DateTime(2026, 3, 1, 23),
        DateTime(2026, 3, 2, 23),
        DateTime(2026, 3, 3, 23),
      ]);
      expect(SleepAnalytics.bedtimeConsistency(n), closeTo(100, 1e-6));
    });
  });

  test('sleep debt and social jetlag', () {
    // Weekdays 6 h (bed 00:00), weekend 9 h (bed 01:00).
    final nights = <SleepNight>[];
    for (var d = 1; d <= 7; d++) {
      final wake = DateTime(2026, 3, 1 + d); // Mon 2 Mar … Sun 8 Mar
      final weekend = wake.weekday >= DateTime.saturday;
      final bedTime = weekend
          ? wake.add(const Duration(hours: 1))
          : wake.subtract(const Duration(hours: 0));
      nights.add(SleepAnalytics.nights(
          [s(SleepStage.asleep, bedTime, weekend ? 9 * 60 : 6 * 60)]).single);
    }
    expect(SleepAnalytics.sleepDebt(nights, need: 8), closeTo(10, 1e-9));
    // Mid-sleep: weekdays 03:00, weekend 05:30 → 2.5 h social jetlag.
    expect(SleepAnalytics.socialJetlag(nights), closeTo(2.5, 0.01));
  });

  test('B2: SleepNight.summary is computed once and cached', () {
    final night = SleepAnalytics.nights(stagedNight(bed)).single;
    final first = night.summary;
    expect(identical(night.summary, first), isTrue);
    night.isNap; // reads summary internally
    expect(identical(night.summary, first), isTrue);
    // Cached value is still the right one: 7.5 h asleep.
    expect(first.totalSleep, closeTo(7.5, 1e-9));
  });
}
