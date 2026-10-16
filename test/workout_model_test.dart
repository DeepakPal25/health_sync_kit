import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

void main() {
  group('A3: Workout.fromMap totals attribution', () {
    Map<String, Object?> base([Map<String, Object?> extra = const {}]) => {
          'id': 'w1',
          'activityType': 'running',
          'start': DateTime.utc(2026, 1, 1, 7).millisecondsSinceEpoch,
          'end': DateTime.utc(2026, 1, 1, 8).millisecondsSinceEpoch,
          ...extra,
        };

    test('sameApp totals', () {
      final w = Workout.fromMap(base({
        'energyBurned': 400,
        'distance': 10000,
        'averageHeartRate': 150,
        'totalsSource': 'sameApp',
      }));
      expect(w.totalsAttribution, WorkoutTotalsAttribution.sameApp);
      expect(w.energyBurned, 400.0);
      expect(w.distance, 10000.0);
      expect(w.averageHeartRate, 150.0);
      expect(w.minutes, 60);
    });

    test('allApps totals', () {
      final w = Workout.fromMap(base({
        'energyBurned': 123.5,
        'totalsSource': 'allApps',
      }));
      expect(w.totalsAttribution, WorkoutTotalsAttribution.allApps);
      expect(w.distance, isNull);
    });

    test('null / missing / unknown totalsSource is none', () {
      expect(Workout.fromMap(base()).totalsAttribution,
          WorkoutTotalsAttribution.none);
      expect(Workout.fromMap(base({'totalsSource': null})).totalsAttribution,
          WorkoutTotalsAttribution.none);
      expect(Workout.fromMap(base({'totalsSource': 'x'})).totalsAttribution,
          WorkoutTotalsAttribution.none);
    });

    test('mock marks workouts with totals as sameApp', () {
      final source = MockHealthSource();
      final t = DateTime(2026, 1, 1, 7);
      final a = source.addWorkout(WorkoutActivityType.running,
          start: t, end: t.add(const Duration(hours: 1)), energyBurned: 300);
      final b = source.addWorkout(WorkoutActivityType.yoga,
          start: t, end: t.add(const Duration(hours: 1)));
      expect(a.totalsAttribution, WorkoutTotalsAttribution.sameApp);
      expect(b.totalsAttribution, WorkoutTotalsAttribution.none);
    });
  });
}
