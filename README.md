# health_sync_kit

[![CI](https://github.com/DeepakPal25/health_sync_kit/actions/workflows/ci.yml/badge.svg)](https://github.com/DeepakPal25/health_sync_kit/actions/workflows/ci.yml)
![Platforms](https://img.shields.io/badge/platforms-iOS%2013%2B%20%7C%20Android%208%2B-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

**HealthKit + Health Connect for Flutter, with an analytics layer built in.**
A Flutter port of [HealthSyncKit](https://github.com/DeepakPal25/HealthSyncKit).

Most health plugins hand you raw records and stop. health_sync_kit gives you
typed data in the same units on both platforms, **de-duplicated** daily totals
(no more phone + watch double counting), incremental sync, and the analytics
apps actually build: sleep score, readiness, streaks, anomalies and training
load. All analytics are pure Dart and run in unit tests against a mock source.

```dart
final health = HealthSyncClient();

await health.requestAuthorization({
  HealthDataType.steps,
  HealthDataType.sleep,
  HealthDataType.restingHeartRate,
  HealthDataType.heartRateVariabilitySDNN,   // iOS
  HealthDataType.heartRateVariabilityRMSSD,  // Android
});

final week   = await health.dailySteps(DateRange.lastWeek());   // de-duplicated
final night  = await health.lastNight();                         // one source, one night
final ready  = await health.readiness();                         // HRV + RHR baselines + sleep
final streak = await health.streak(goal: 10000);

print('${night?.summary.sleepScore} sleep · ${ready.score} ${ready.label} · $streak-day streak');
```

## Features

| | |
|---|---|
| **35 data types** | Activity, body, vitals, sleep (with stages), workouts, nutrition. Values arrive in canonical units on both platforms (`HealthDataType.unit`). |
| **De-duplicated statistics** | `daily()` and `statistics()` use `HKStatisticsCollectionQuery` / Health Connect aggregates, which merge overlapping sources. They fall back to raw samples (flagged `deduplicated: false`) when the platform can't aggregate a type. |
| **Sleep that's actually right** | Nights are grouped across midnight and attributed to the wake-up date. One source is chosen per night, preferring the staged one. `inBed` is never counted as sleep. Naps are separated out. |
| **Analytics** | Sleep score, efficiency, circular bedtime/wake consistency, sleep debt, social jetlag; activity score, streaks (today-aware), longest streak; readiness from HRV and resting-HR baselines; acute:chronic training load; z-score anomalies; time-based trends, EMA, percentiles. |
| **Incremental sync** | `changes()` uses `HKAnchoredObjectQuery` / Health Connect change tokens: new and deleted samples since your last anchor. |
| **Writing** | `writeQuantity()` for steps, active energy, water and weight on Android, and any quantity type on iOS. |
| **Testable** | `HealthSource` is the seam. `MockHealthSource` (and `.synthetic()` with realistic, seeded data) powers tests, previews and demos. |

## Install

```yaml
dependencies:
  health_sync_kit:
    git: https://github.com/DeepakPal25/health_sync_kit
```

### iOS (HealthKit)

1. In Xcode, open *Runner → Signing & Capabilities → + Capability → HealthKit*.
2. Add the following to `ios/Runner/Info.plist`:

```xml
<key>NSHealthShareUsageDescription</key>
<string>Reads your activity, sleep and heart data to show your trends.</string>
<key>NSHealthUpdateUsageDescription</key>
<string>Saves the data you log in this app to Apple Health.</string>
```

iOS deliberately hides whether *read* access was granted. After the prompt,
read-only types report `AuthorizationStatus.unknown`, and a denied type simply
returns no data.

### Android (Health Connect)

- **Requirements:** minSdk 26. On Android 13 and below, Health Connect is an
  app from the Play Store (`HealthAvailability.notInstalled`); call
  `openHealthSettings()` to send users there.
- **Permissions:** declare one per data type you read or write in
  `android/app/src/main/AndroidManifest.xml`, and add the privacy-policy
  rationale screen Health Connect requires:

```xml
<uses-permission android:name="android.permission.health.READ_STEPS"/>
<uses-permission android:name="android.permission.health.READ_SLEEP"/>
<uses-permission android:name="android.permission.health.READ_HEART_RATE"/>
<uses-permission android:name="android.permission.health.READ_RESTING_HEART_RATE"/>
<uses-permission android:name="android.permission.health.READ_HEART_RATE_VARIABILITY"/>
<uses-permission android:name="android.permission.health.READ_EXERCISE"/>
<uses-permission android:name="android.permission.health.READ_ACTIVE_CALORIES_BURNED"/>
<!-- Fallback when no app writes active calories: total − basal. -->
<uses-permission android:name="android.permission.health.READ_TOTAL_CALORIES_BURNED"/>
<uses-permission android:name="android.permission.health.READ_BASAL_METABOLIC_RATE"/>
<uses-permission android:name="android.permission.health.READ_DISTANCE"/>
<!-- …and WRITE_* for anything you write -->

<application …>
  <activity android:name=".MainActivity" …>
    <!-- Android 13 and below: Health Connect's "privacy policy" link -->
    <intent-filter>
      <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>
    </intent-filter>
  </activity>
  <!-- Android 14+ -->
  <activity-alias
      android:name="ViewPermissionUsageActivity"
      android:exported="true"
      android:targetActivity=".MainActivity"
      android:permission="android.permission.START_VIEW_PERMISSION_USAGE">
    <intent-filter>
      <action android:name="android.intent.action.VIEW_PERMISSION_USAGE"/>
      <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>
    </intent-filter>
  </activity-alias>
</application>
```

- **Data access window:** by default Health Connect returns only the last 30
  days of data that other apps wrote before your app was granted access.

#### Platform differences

| Type | iOS | Android |
|---|---|---|
| HRV | `heartRateVariabilitySDNN` | `heartRateVariabilityRMSSD` (a different measure; don't compare them) |
| Basal energy, cycling distance, stand time, BMI, waist, walking HR | ✓ | ✗ (`UnsupportedDataType`) |
| `inBed` sleep stage | ✓ | ✗ (sessions only) |
| Sync anchors | anchors never expire | change tokens expire after ~30 days (`SyncAnchorExpired`) |

#### Accuracy notes

- **Distance (Android).** Health Connect has a single `DistanceRecord` for
  every activity. So `distanceWalkingRunning` on Android also includes
  cycling, rowing and any other distance an app writes. iOS keeps walking or
  running and cycling apart.
- **Active calories (Android).** Many devices write only total calories. When
  no app writes active calories, `statistics()` and `daily()` for
  `activeEnergyBurned` fall back to total calories − basal metabolic rate,
  clamped at 0. Those results have `isDerived == true` (`StatisticsResult.isDerived`,
  `DailyValue.isDerived`). The fallback needs `READ_TOTAL_CALORIES_BURNED` and
  `READ_BASAL_METABOLIC_RATE` in your manifest. `requestAuthorization` asks
  for both whenever you read `activeEnergyBurned`. Raw samples
  (`activeEnergy()`) are never derived.
- **Workout totals.** `Workout.totalsAttribution` says where a workout's
  calories, distance and heart rate came from:
  - `sameApp`: records from the app that wrote the session.
  - `allApps`: for at least one total, no records from that app overlapped
    the session, so records from every app were used. They can include a
    phone's background step distance.
  - `none`: no totals.

  On iOS it is always `sameApp`, because the totals come from the workout's
  own statistics.
- **Sleep stages.** Each platform's values map to `SleepStage` as follows.
  `inBed` and `awake` never count as sleep (`SleepStage.isAsleep` is true for
  `asleep`, `core`, `deep` and `rem` only).

  | `SleepStage` | Android (`SleepSessionRecord.STAGE_TYPE_*`) | iOS (`HKCategoryValueSleepAnalysis`) |
  |---|---|---|
  | `core` | `LIGHT` | `asleepCore` (iOS 16+) |
  | `deep` | `DEEP` | `asleepDeep` (iOS 16+) |
  | `rem` | `REM` | `asleepREM` (iOS 16+) |
  | `asleep` | `SLEEPING`; a session with no stages becomes one `asleep` sample covering it | `asleepUnspecified` / `asleep` |
  | `awake` | `AWAKE`, `AWAKE_IN_BED`, `OUT_OF_BED` | `awake` |
  | `inBed` | — (never produced) | `inBed` |
  | `unknown` | `UNKNOWN` and any other value | values the SDK doesn't recognise |
- **HRV.** iOS reports SDNN and Health Connect reports RMSSD. They measure
  different things: RMSSD is typically higher, and they don't convert into
  each other. Don't compare or merge them. Check `await client.supportedTypes()`
  to see which one the platform has. `heartRateVariability()` and
  `readiness()` choose it for you, and baselines are only built from one
  measure.
- **History (Android).** Health Connect returns only the last 30 days of data
  written before your app was granted access. Longer ranges come back short
  without an error. `changes()` tokens also expire after about 30 days
  (`SyncAnchorExpired`); call `changes()` with no anchor again to resync.

## Usage

### Raw samples & statistics

```dart
final hr   = await health.heartRate(DateRange.today());
final bp   = await health.bloodPressure(DateRange.lastMonth()); // paired readings
final avg  = await health.statistics(HealthDataType.heartRate, DateRange.today(),
                                     option: StatisticsOption.average);
final kcal = await health.daily(HealthDataType.activeEnergyBurned, DateRange.lastWeek());
```

### Sleep

```dart
final nights = await health.sleepNights(DateRange.lastDays(14));
for (final n in nights.where((n) => !n.isNap)) {
  final s = n.summary;
  print('${n.date}: ${s.totalSleep.toStringAsFixed(1)} h, score ${s.sleepScore}, '
        'deep ${s.deepSleep.toStringAsFixed(1)} h, from ${n.sourceName}');
}
SleepAnalytics.bedtimeConsistency(nights); // 0–100, circular statistics
SleepAnalytics.sleepDebt(nights, need: 8); // hours, last 7 nights
SleepAnalytics.socialJetlag(nights);       // hours, weekend vs weekday mid-sleep
```

### Activity

```dart
final today = await health.activitySummary(DateTime.now(),
    goals: const ActivityGoals(steps: 8000));
print('${today.activityScore}/100');

final series = await health.dailySteps(DateRange.lastDays(90));
ActivityAnalytics.streak(series, 10000);        // today-in-progress aware
ActivityAnalytics.longestStreak(series, 10000);
HealthStatistics.trendPerDay(series);           // steps/day trend, gap-aware
```

### Recovery, load and anomalies

```dart
final r = await health.readiness();   // score, label, HRV / RHR z-scores
final load = await health.trainingLoad();   // acute:chronic ratio + status
final odd = await health.anomalies(HealthDataType.restingHeartRate, DateRange.lastMonth());
```

> Readiness, training load and anomalies are wellness heuristics, not
> medical advice. Say so in your UI.

### Incremental sync

```dart
var anchor = prefs.getString('weightAnchor');           // null on first run
try {
  final c = await health.changes(HealthDataType.weight, anchor: anchor);
  upsert(c.added); delete(c.deletedIds);
  await prefs.setString('weightAnchor', c.anchor);
} on SyncAnchorExpired {
  await prefs.remove('weightAnchor');                   // do a full re-read
}
```

## Publishing your app

Both stores review apps that read health data, and both require a privacy
policy. [PRIVACY.md](PRIVACY.md) is a template you can fill in.

### App Store (HealthKit)

- **Entitlement:** turn on the HealthKit capability (see [Install](#ios-healthkit)).
  This adds `com.apple.developer.healthkit` to `Runner.entitlements`. Only tick
  *Clinical Health Records* if you really read them; it gets extra review.
- **Purpose strings:** `NSHealthShareUsageDescription` (read) and
  `NSHealthUpdateUsageDescription` (write) must say specifically what you do
  with the data. Without them the app crashes when it asks for permission.
  Vague text such as "Needs health data" is a common reason for rejection.
- **Guideline 5.1.3 (Health and Health Research):**
  - Don't use health data for advertising, marketing or data mining, or share
    it with third parties for those purposes.
  - Never store it in iCloud.
  - Never write false or inaccurate data to HealthKit.
  - Link a privacy policy in App Store Connect and in the app.
- **App Privacy details:** declare *Health & Fitness* data in App Store Connect.

### Google Play (Health Connect)

- **Show your privacy policy from Health Connect.** The rationale
  intent-filter and the `ViewPermissionUsageActivity` alias (see
  [Install](#android-health-connect)) let Health Connect open your app from its
  "privacy policy" link. Your app must then show the policy. The example
  shows one way: `MainActivity` checks the intent action
  (`androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE` or
  `android.intent.action.VIEW_PERMISSION_USAGE`) and tells Flutter over a
  small `MethodChannel`, which then shows `PrivacyPolicyScreen`. See
  `example/android/.../MainActivity.kt` and `example/lib/privacy_policy_screen.dart`.
- **Play Console Health Connect declaration:** under *App content → Health
  apps* (Health Connect permissions), justify every `android.permission.health.*`
  permission in your manifest. Apps without this declaration, or with
  permissions they can't justify, are rejected.
- **Request only what you use.**
  - Declare and request only the permissions for types your app actually
    shows.
  - If you read `activeEnergyBurned`, also declare `READ_TOTAL_CALORIES_BURNED`
    and `READ_BASAL_METABOLIC_RATE`, and justify them as the fallback for
    devices that don't write active calories.
  - If you don't want the fallback, remove both. Active calories then come
    back empty on those devices.
- **Data safety form:** declare *Health and fitness* data and match what your
  privacy policy says.

## Testing

```dart
final source = MockHealthSource();
source.addQuantity(HealthDataType.steps, 5000, start: t, sourceName: 'iPhone');
source.addQuantity(HealthDataType.steps, 5200, start: t, sourceName: 'Watch');
final client = HealthSyncClient(source: source, clock: () => fixedNow);
expect((await client.dailySteps(range)).first.value, 5200); // not 10200
```

The mock can also:

- serve realistic, seeded data across all the analytics (`MockHealthSource.synthetic(days: 60, seed: 1)`)
- inject errors (`nextError`)
- simulate denied permissions (`grantAll = false`)
- simulate a missing health store (`availabilityValue`)
- force the raw-sample fallback (`supportsStatistics = false`)

## Architecture

```
HealthSyncClient            ← public API, fallbacks, convenience
   │
   ├── analytics/            ← pure Dart: Sleep, Activity, Recovery, HealthStatistics
   ├── models/               ← HealthDataType, samples, DateRange, errors
   └── source/HealthSource   ← the seam
          ├── LiveHealthSource  → MethodChannel → HealthKit (Swift) / Health Connect (Kotlin)
          └── MockHealthSource  (+ SyntheticHealthData)
```

### What changed from HealthSyncKit

See [`doc/GAP_ANALYSIS.md`](doc/GAP_ANALYSIS.md) for the full list. In short:

| HealthSyncKit (Swift) | health_sync_kit |
|---|---|
| `inBed` mapped to `.asleep` (inflates sleep) | separate `inBed` stage, never counted |
| Phone + Watch sleep/steps summed | one source per night; de-duplicated platform stats |
| Sleep grouped by start-day (nights split at midnight) | sessions grouped by gap, dated by wake-up |
| Bedtime consistency on minutes-of-day (23:30 vs 00:30 = 23 h apart) | circular statistics |
| SpO2 / body fat returned as 0–1 but labelled `%` | 0–100 |
| Streak = 0 every morning until today's goal is hit | today-in-progress aware |
| `percentChange(0 → x)` = ±100 | `null` (undefined) |
| Trend per sample index | also `trendPerDay` on real dates |
| Read-auth status looks "denied" | `AuthorizationStatus.unknown` (HealthKit hides it) |
| Blood pressure as two unrelated lists | paired `BloodPressureReading`s |
| iOS only | iOS + Android |

## Roadmap

- Background delivery (`HKObserverQuery` + `enableBackgroundDelivery`, Health Connect + WorkManager)
- Writing sleep sessions and workouts
- Health Connect history permission (data older than 30 days)
- Workout routes (GPS) and heart-rate zones
- Menstrual cycle, mindfulness, ECG, VO₂ max, cardio fitness
- Units preferences (imperial)

## License

MIT. See [LICENSE](LICENSE).
