# Changelog

## 0.1.1 - 2026-11-18

- Shorter package description, within pub.dev's 180-character limit.
- Example: the iOS write usage string (`NSHealthUpdateUsageDescription`) no longer claims the app saves water; the example only reads health data.

## 0.1.0 - 2026-11-18

Initial release: a Flutter port of [HealthSyncKit](https://github.com/DeepakPal25/HealthSyncKit).

- `HealthSyncClient` over HealthKit (iOS) and Health Connect (Android), with 35 data types in canonical units.
- `HealthSource` seam, `LiveHealthSource`, and `MockHealthSource` with seeded `SyntheticHealthData`. `MockHealthSource.supported` limits the supported types; `MockHealthSource.pageSize` makes `changes()` paginate so change-feed handling can be tested.
- De-duplicated `statistics()` / `daily()` with raw-sample fallback. `StatisticsResult.isDerived` / `DailyValue.isDerived` mark values that were computed rather than read directly.
- Authorization: `requestAuthorization`, `authorizationStatus()` and `supportedTypes()`. Types the platform lacks are reported as `AuthorizationStatus.unsupported`, are not counted as denied, and are ignored by `AuthorizationResult.allGranted`. Concurrent `requestAuthorization` calls are queued and run one at a time.
- Typed errors (`sealed class HealthError`), including `AuthorizationInProgress` and `HealthDataNotAvailable(reason: 'pluginNotRegistered')` when no native plugin is registered.
- Workouts with calories, distance and heart-rate totals. `Workout.totalsAttribution` (`sameApp`, `allApps`, `none`) says where the totals came from.
- Sleep: night grouping across midnight, per-night source selection, `inBed` handling, naps, score, efficiency, circular consistency, sleep debt, social jetlag. `SleepNight.summary` is computed once and cached.
- Activity: score with configurable goals, today-aware streaks, longest streak, training load (ACWR).
- Recovery: readiness from HRV and resting-HR baselines plus sleep.
- Statistics: percentile, EMA, sample SD, time-based trend, baselines, anomaly detection.
- Incremental sync (`changes()`) and `writeQuantity()`.
- Fixes for HealthSyncKit issues; see doc/GAP_ANALYSIS.md.
- `PRIVACY.md` privacy policy template and a README "Publishing your app" section (App Store HealthKit review, Google Play Health Connect declaration).

### Android

- Builds with AGP 8.11.1, Kotlin 2.2.20, compileSdk 36 and Java 17. Apps need `compileSdk = 36`, AGP ≥ 8.9.1 and minSdk 26.
- Dependencies: `androidx.health.connect:connect-client` 1.1.0, `androidx.activity:activity-ktx` 1.13.0, `kotlinx-coroutines-android` 1.11.0.
- Android 14+ permission requests use `ActivityCompat.requestPermissions`; Android 13 and below launch the Health Connect permission screen.
- When no app writes active calories, `activeEnergyBurned` sums fall back to total calories − basal metabolic rate (clamped at 0) and are marked `isDerived`. `requestAuthorization` asks for `READ_TOTAL_CALORIES_BURNED` and `READ_BASAL_METABOLIC_RATE` whenever `activeEnergyBurned` is requested; add them to your manifest.
- Health Connect queries and conversion run off the main thread.

### iOS

- Deployment target iOS 13.
