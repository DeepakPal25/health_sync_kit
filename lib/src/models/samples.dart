import 'health_data_type.dart';

DateTime _ms(Object? v) =>
    DateTime.fromMillisecondsSinceEpoch((v as num).toInt());

/// A single recorded measurement. No HealthKit or Health Connect types leak
/// through: values are already converted to [HealthDataType.unit].
class QuantitySample {
  const QuantitySample({
    required this.id,
    required this.type,
    required this.value,
    required this.start,
    required this.end,
    this.sourceName,
    this.sourceId,
    this.device,
  });

  factory QuantitySample.fromMap(Map<Object?, Object?> m) => QuantitySample(
        id: m['id'] as String,
        type: HealthDataType.fromName(m['type'] as String)!,
        value: (m['value'] as num).toDouble(),
        start: _ms(m['start']),
        end: _ms(m['end']),
        sourceName: m['sourceName'] as String?,
        sourceId: m['sourceId'] as String?,
        device: m['device'] as String?,
      );

  final String id;
  final HealthDataType type;
  final double value;
  final DateTime start;
  final DateTime end;

  /// Human-readable source (e.g. "Deepak's Apple Watch", "Fitbit").
  final String? sourceName;

  /// Stable source identifier (bundle id / package name), used for
  /// de-duplication and source priority.
  final String? sourceId;

  /// Recording device model, if known.
  final String? device;

  String get unit => type.unit;
  Duration get duration => end.difference(start);

  @override
  bool operator ==(Object other) => other is QuantitySample && other.id == id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => 'QuantitySample(${type.name}: $value $unit @ $start)';
}

/// A paired blood-pressure reading.
class BloodPressureReading {
  const BloodPressureReading({
    required this.time,
    required this.systolic,
    required this.diastolic,
    this.sourceName,
  });

  final DateTime time;
  final double systolic;
  final double diastolic;
  final String? sourceName;

  @override
  String toString() =>
      'BloodPressureReading(${systolic.round()}/${diastolic.round()} @ $time)';
}

/// Stage of a sleep interval.
enum SleepStage {
  /// In bed, not necessarily asleep (iOS "inBed"). Never counted as sleep.
  inBed,

  /// Asleep, stage not recorded.
  asleep,

  /// Light/core sleep.
  core,
  deep,
  rem,
  awake,
  unknown;

  bool get isAsleep =>
      this == asleep || this == core || this == deep || this == rem;

  bool get isRestorative => this == deep || this == rem;

  static SleepStage fromName(String? name) => SleepStage.values
      .firstWhere((s) => s.name == name, orElse: () => SleepStage.unknown);
}

/// A sleep interval with stage information.
class SleepSample {
  const SleepSample({
    required this.id,
    required this.stage,
    required this.start,
    required this.end,
    this.sourceName,
    this.sourceId,
  });

  factory SleepSample.fromMap(Map<Object?, Object?> m) => SleepSample(
        id: m['id'] as String,
        stage: SleepStage.fromName(m['stage'] as String?),
        start: _ms(m['start']),
        end: _ms(m['end']),
        sourceName: m['sourceName'] as String?,
        sourceId: m['sourceId'] as String?,
      );

  final String id;
  final SleepStage stage;
  final DateTime start;
  final DateTime end;
  final String? sourceName;
  final String? sourceId;

  Duration get duration => end.difference(start);
  double get hours => duration.inSeconds / 3600;

  @override
  bool operator ==(Object other) => other is SleepSample && other.id == id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => 'SleepSample(${stage.name} $start → $end)';
}

/// Type of workout activity.
enum WorkoutActivityType {
  running,
  cycling,
  swimming,
  walking,
  hiking,
  yoga,
  strengthTraining,
  highIntensityIntervalTraining,
  crossTraining,
  dance,
  elliptical,
  rowing,
  stairClimbing,
  tennis,
  soccer,
  basketball,
  baseball,
  golf,
  pilates,
  barre,
  kickboxing,
  boxing,
  martialArts,
  mindAndBody,
  other;

  static WorkoutActivityType fromName(String? name) =>
      WorkoutActivityType.values.firstWhere((t) => t.name == name,
          orElse: () => WorkoutActivityType.other);
}

/// A recorded workout session.
/// Where a [Workout]'s totals ([Workout.energyBurned], [Workout.distance],
/// [Workout.averageHeartRate]) came from.
enum WorkoutTotalsAttribution {
  /// Every total came from the app that recorded the workout (iOS always;
  /// Android when that app also wrote the calorie/distance/heart-rate records).
  sameApp,

  /// Android only: at least one total came from other apps' records that
  /// overlap the session, because the workout's app wrote none. These can
  /// include activity outside the workout itself.
  allApps,

  /// No totals were found.
  none;

  static WorkoutTotalsAttribution fromName(String? name) => switch (name) {
        'sameApp' => sameApp,
        'allApps' => allApps,
        _ => none,
      };
}

class Workout {
  const Workout({
    required this.id,
    required this.activityType,
    required this.start,
    required this.end,
    this.energyBurned,
    this.distance,
    this.averageHeartRate,
    this.sourceName,
    this.totalsAttribution = WorkoutTotalsAttribution.none,
  });

  factory Workout.fromMap(Map<Object?, Object?> m) => Workout(
        id: m['id'] as String,
        activityType:
            WorkoutActivityType.fromName(m['activityType'] as String?),
        start: _ms(m['start']),
        end: _ms(m['end']),
        energyBurned: (m['energyBurned'] as num?)?.toDouble(),
        distance: (m['distance'] as num?)?.toDouble(),
        averageHeartRate: (m['averageHeartRate'] as num?)?.toDouble(),
        sourceName: m['sourceName'] as String?,
        totalsAttribution:
            WorkoutTotalsAttribution.fromName(m['totalsSource'] as String?),
      );

  final String id;
  final WorkoutActivityType activityType;
  final DateTime start;
  final DateTime end;

  /// Total energy in kcal, if recorded.
  final double? energyBurned;

  /// Total distance in metres, if recorded.
  final double? distance;

  /// Average heart rate during the session in bpm, if known. Used by
  /// training-load analytics.
  final double? averageHeartRate;
  final String? sourceName;

  /// Where the totals came from; see [WorkoutTotalsAttribution].
  final WorkoutTotalsAttribution totalsAttribution;

  Duration get duration => end.difference(start);
  double get minutes => duration.inSeconds / 60;

  @override
  bool operator ==(Object other) => other is Workout && other.id == id;
  @override
  int get hashCode => id.hashCode;
}
