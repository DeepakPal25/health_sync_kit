/// How a quantity combines over time.
enum Aggregation {
  /// Values add up (steps, calories, distance). Daily value = sum.
  cumulative,

  /// Point measurements (heart rate, weight). Daily value = average.
  discrete,
}

/// Broad grouping, handy for building permission screens.
enum HealthCategory { activity, body, vitals, sleep, workouts, nutrition }

/// Every kind of health data health_sync_kit can read.
///
/// Quantity types ([isQuantity]) are read as `QuantitySample`s; [sleep] as
/// `SleepSample`s and [workouts] as `Workout`s. Values are always delivered in
/// the canonical [unit], on both iOS (HealthKit) and Android (Health Connect).
enum HealthDataType {
  // Activity
  steps('Steps', 'count', HealthCategory.activity, Aggregation.cumulative),
  distanceWalkingRunning('Walking + Running Distance', 'm',
      HealthCategory.activity, Aggregation.cumulative),
  distanceCycling(
      'Cycling Distance', 'm', HealthCategory.activity, Aggregation.cumulative),
  activeEnergyBurned('Active Calories', 'kcal', HealthCategory.activity,
      Aggregation.cumulative),
  basalEnergyBurned('Resting Calories', 'kcal', HealthCategory.activity,
      Aggregation.cumulative),
  flightsClimbed('Flights Climbed', 'count', HealthCategory.activity,
      Aggregation.cumulative),
  exerciseTime('Exercise Minutes', 'min', HealthCategory.activity,
      Aggregation.cumulative),
  standTime(
      'Stand Minutes', 'min', HealthCategory.activity, Aggregation.cumulative),

  // Body
  height('Height', 'cm', HealthCategory.body, Aggregation.discrete),
  weight('Weight', 'kg', HealthCategory.body, Aggregation.discrete),
  bodyMassIndex('BMI', 'kg/m²', HealthCategory.body, Aggregation.discrete),
  bodyFatPercentage('Body Fat', '%', HealthCategory.body, Aggregation.discrete),
  leanBodyMass(
      'Lean Body Mass', 'kg', HealthCategory.body, Aggregation.discrete),
  waistCircumference(
      'Waist Circumference', 'cm', HealthCategory.body, Aggregation.discrete),

  // Vitals
  heartRate('Heart Rate', 'bpm', HealthCategory.vitals, Aggregation.discrete),
  restingHeartRate(
      'Resting Heart Rate', 'bpm', HealthCategory.vitals, Aggregation.discrete),
  walkingHeartRateAverage(
      'Walking Heart Rate', 'bpm', HealthCategory.vitals, Aggregation.discrete),

  /// HRV as SDNN. Recorded by Apple Watch (iOS only).
  heartRateVariabilitySDNN(
      'HRV (SDNN)', 'ms', HealthCategory.vitals, Aggregation.discrete),

  /// HRV as RMSSD. Recorded by most Android wearables (Android only).
  /// SDNN and RMSSD are different measures: don't compare them directly.
  heartRateVariabilityRMSSD(
      'HRV (RMSSD)', 'ms', HealthCategory.vitals, Aggregation.discrete),
  bloodPressureSystolic('Systolic Blood Pressure', 'mmHg',
      HealthCategory.vitals, Aggregation.discrete),
  bloodPressureDiastolic('Diastolic Blood Pressure', 'mmHg',
      HealthCategory.vitals, Aggregation.discrete),
  respiratoryRate('Respiratory Rate', 'breaths/min', HealthCategory.vitals,
      Aggregation.discrete),
  oxygenSaturation(
      'Blood Oxygen', '%', HealthCategory.vitals, Aggregation.discrete),
  bodyTemperature(
      'Body Temperature', '°C', HealthCategory.vitals, Aggregation.discrete),
  bloodGlucose(
      'Blood Glucose', 'mg/dL', HealthCategory.vitals, Aggregation.discrete),

  // Nutrition
  dietaryEnergy('Dietary Energy', 'kcal', HealthCategory.nutrition,
      Aggregation.cumulative),
  dietaryCarbohydrates(
      'Carbohydrates', 'g', HealthCategory.nutrition, Aggregation.cumulative),
  dietaryFiber('Fiber', 'g', HealthCategory.nutrition, Aggregation.cumulative),
  dietarySugar('Sugar', 'g', HealthCategory.nutrition, Aggregation.cumulative),
  dietaryFat(
      'Total Fat', 'g', HealthCategory.nutrition, Aggregation.cumulative),
  dietaryProtein(
      'Protein', 'g', HealthCategory.nutrition, Aggregation.cumulative),
  dietaryWater('Water', 'mL', HealthCategory.nutrition, Aggregation.cumulative),
  dietaryCaffeine(
      'Caffeine', 'mg', HealthCategory.nutrition, Aggregation.cumulative),
  dietarySodium(
      'Sodium', 'g', HealthCategory.nutrition, Aggregation.cumulative),

  // Non-quantity
  sleep('Sleep', 'h', HealthCategory.sleep, Aggregation.cumulative),
  workouts('Workouts', 'min', HealthCategory.workouts, Aggregation.cumulative);

  const HealthDataType(
      this.displayName, this.unit, this.category, this.aggregation);

  final String displayName;

  /// The canonical unit every value of this type is delivered in.
  final String unit;
  final HealthCategory category;
  final Aggregation aggregation;

  /// Whether this type is read as `QuantitySample`s.
  bool get isQuantity =>
      this != HealthDataType.sleep && this != HealthDataType.workouts;

  bool get isCumulative => aggregation == Aggregation.cumulative;

  /// Parses the wire name used by the native layers.
  static HealthDataType? fromName(String name) {
    for (final t in values) {
      if (t.name == name) return t;
    }
    return null;
  }
}
