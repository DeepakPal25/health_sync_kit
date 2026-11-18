# Changelog

## 0.1.0 – Unreleased

### Added
- `AuthorizationStatus.unsupported`: the platform has no such data type. `isAuthorized` is `false` and the type is not counted in `AuthorizationResult.denied`.
- `List<HealthDataType> get AuthorizationResult.unsupported`.
- `Future<Set<HealthDataType>> HealthSyncClient.supportedTypes()`.
- `Future<Set<HealthDataType>> HealthSource.supportedTypes()` (native method `supportedTypes`).
- `Set<HealthDataType> MockHealthSource.supported` (defaults to every type).
- `final class AuthorizationInProgress extends HealthError` (native error code `authInProgress`): Android was asked to show a second Health Connect permission screen while one was already open.
- `enum WorkoutTotalsAttribution { sameApp, allApps, none }` and `final WorkoutTotalsAttribution Workout.totalsAttribution` (map key `totalsSource`; defaults to `none`).
- `final bool StatisticsResult.isDerived` (constructor `this.isDerived = false`) and `final bool DailyValue.isDerived` (constructor `const DailyValue(DateTime date, double? value, {bool isDerived = false})`; map key `derived`).
- Android: when no app writes active calories, `activeEnergyBurned` sum statistics and daily buckets fall back to total calories − basal metabolic rate (clamped at 0) and are marked `isDerived`. The fallback only runs when `READ_TOTAL_CALORIES_BURNED` and `READ_BASAL_METABOLIC_RATE` are granted. `requestAuthorization` asks for both whenever `activeEnergyBurned` is in `read`; add them to your manifest.
- `int? MockHealthSource.pageSize`: when set, `changes()` returns at most this many changes per call with `hasMore: true`, so change-feed pagination can be tested.
- `PRIVACY.md` privacy policy template and a README "Publishing your app" section (App Store HealthKit review, Google Play Health Connect declaration). The example app shows a privacy policy screen when Health Connect opens it from its permissions UI.

### Changed
- **Breaking (custom `HealthSource` implementations):** `HealthSource` gains the abstract `supportedTypes()` method.
- **Breaking (custom `HealthSource` implementations):** `HealthSource.statistics` now returns `Future<StatisticsResult?>` instead of `Future<double?>`, so a source can report `isDerived`. Wrap your value in `StatisticsResult(type:, option:, value:, start:, end:)`. `HealthSyncClient.statistics` returns it unchanged.
- `DailyValue ==` / `hashCode` now include `isDerived`.
- `HealthSyncClient.requestAuthorization` drops unsupported types before calling the platform and reports them as `AuthorizationStatus.unsupported` (they were previously reported as `denied` on Android and `unknown` on iOS).
- `AuthorizationResult.allGranted` ignores unsupported types.
- `authorizationStatus()` returns `unsupported` instead of `denied` (Android) / `unknown` (iOS) for types the platform lacks.
- **Breaking (exhaustive `switch` over `HealthError`):** the sealed class gains `AuthorizationInProgress`; add a case for it.
- `LiveHealthSource.requestAuthorization` calls are queued and run one at a time. A failed request does not block the next one.
- Android 14+: `requestAuthorization` showed no permission screen and failed with `queryFailed` ("No Activity found to handle Intent … REQUEST_PERMISSIONS"), because on Android 14+ the Health Connect contract returns a runtime-permission intent that only `ComponentActivity` can launch. The plugin now detects that intent and asks with `ActivityCompat.requestPermissions` (androidx.core, transitive via activity-ktx), replying from `onRequestPermissionsResult`. Android 13 and below still launch the Health Connect intent.
- Android: every permission request now replies exactly once, including when the user cancels, the activity is detached, or `getGrantedPermissions` throws (these previously could leave the Dart future hanging).
- Android `workouts()`: totals no longer use one `aggregate()` call per session (which also stopped after 200 sessions). Calories, distance and heart rate are each read once over the whole range and attributed to sessions by time overlap, preferring records from the session's own app. A missing permission now leaves only that one field null; before, it dropped all three.
- Android: Health Connect queries, conversion, sorting and workout attribution run on `Dispatchers.Default`; replies are still sent on the main thread. The SDK availability status is looked up once per method call.
- A call with no native plugin behind it (app not rebuilt after adding the plugin, or an unsupported platform) now throws `HealthDataNotAvailable(reason: 'pluginNotRegistered')` instead of a raw `MissingPluginException`.
- **Breaking (Android build):** the plugin now builds with AGP 8.11.1, Kotlin 2.2.20, compileSdk 36 and Java 17 (was AGP 8.3.2, Kotlin 1.9.24, compileSdk 35, Java 11), matching `flutter create -t plugin` on Flutter 3.38. Apps need `compileSdk = 36` and AGP ≥ 8.9.1, which `androidx.activity` 1.13.0 / `androidx.core` 1.18.0 require. minSdk stays 26.
- Android dependencies: `androidx.activity:activity-ktx` 1.9.3 → 1.13.0, `kotlinx-coroutines-android` 1.8.1 → 1.11.0. `connect-client` stays 1.1.0.
- Android: `openSettings` builds the Play Store URI with `androidx.core.net.toUri` (core-ktx, transitive via activity-ktx) instead of `Uri.parse`.
- iOS: the plugin failed to compile for its iOS 13 deployment target (`'errorNoData' is only available in iOS 14.0`). `statistics` and daily statistics now check `HKError.errorNoData` behind `#available(iOS 14.0, *)`; on iOS 13 an empty range already returns nil statistics without an error.
- **Breaking (minor):** `SleepNight`'s constructor is no longer `const`. `SleepNight.summary` is now computed once on first access and cached (`late final`) instead of being recomputed on every read.

## 0.1.0

Initial release: a Flutter port of [HealthSyncKit](https://github.com/DeepakPal25/HealthSyncKit).

- `HealthSyncClient` over HealthKit (iOS) and Health Connect (Android), with 35 data types in canonical units.
- `HealthSource` seam, `LiveHealthSource`, and `MockHealthSource` with seeded `SyntheticHealthData`.
- De-duplicated `statistics()` / `daily()` with raw-sample fallback.
- Sleep: night grouping across midnight, per-night source selection, `inBed` handling, naps, score, efficiency, circular consistency, sleep debt, social jetlag.
- Activity: score with configurable goals, today-aware streaks, longest streak, training load (ACWR).
- Recovery: readiness from HRV and resting-HR baselines plus sleep.
- Statistics: percentile, EMA, sample SD, time-based trend, baselines, anomaly detection.
- Incremental sync (`changes()`) and `writeQuantity()`.
- Fixes for HealthSyncKit issues; see doc/GAP_ANALYSIS.md.
