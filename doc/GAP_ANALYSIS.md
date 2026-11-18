# Gap analysis: HealthSyncKit (Swift) → health_sync_kit (Flutter)

Reviewed: `DeepakPal25/HealthSyncKit` at HEAD, about 1,850 lines of Swift and 27 tests.
Legend: ✅ fixed/added in health_sync_kit 0.1.0 · 🔧 still to do in the Swift repo · 🗺️ roadmap for both.

## 1. Blockers in the Swift repo (fix first)

| # | Issue | Where | Fix |
|---|---|---|---|
| 1 | **SPM install is broken.** Targets point to `HealthSyncKit/HealthSyncKit` and `HealthSyncKit/HealthSyncKitTests`, but the sources live at `HealthSyncKit/` and `HealthSyncKitTests/`. `swift build` fails with "target path not found". | `Package.swift` | 🔧 `path: "HealthSyncKit"` / `path: "HealthSyncKitTests"`, and keep the `.docc` exclude. |
| 2 | **No release tags.** The README tells users `from: "1.0.0"`, but the repo has no tags, so SPM can't resolve it. | repo | 🔧 Tag `0.1.0` (pre-1.0 until the fixes below land) and add a CHANGELOG. |
| 3 | **No LICENSE file**, although the README says MIT. Without one, the code is legally "all rights reserved". | repo | 🔧 Add `LICENSE`. |
| 4 | **No CI.** Nothing proves it builds. | repo | 🔧 GitHub Actions on `macos-15`: `swift build`, `swift test`, plus `xcodebuild` for iOS. |

## 2. Correctness bugs in the analytics

| # | Bug | Effect | Status |
|---|---|---|---|
| 5 | `HKCategoryValueSleepAnalysis.inBed` → `.asleep` (`HealthKitMapper.sleepStage`) | Time in bed counts as sleep: total sleep, efficiency and score are all inflated. Every iPhone writes an `inBed` sample. | ✅ separate `SleepStage.inBed`, never counted |
| 6 | Sleep from multiple sources is summed | iPhone + Apple Watch (or AutoSleep + Watch) for the same night shows ~2× sleep. | ✅ one source per night (most staged sleep wins, or `sourcePriority`) |
| 7 | Overlapping stage samples within one source are summed | Double counting when a source writes overlapping intervals. | ✅ interval union per stage |
| 8 | Sleep grouped by `startOfDay(startDate)` | A 23:00–07:00 night is split across two days; `weeklyAverageSleep` divides by the wrong number of days. | ✅ sessions grouped by gap (2 h), dated by wake-up |
| 9 | Efficiency = sleep ÷ (sleep + awake samples) | Ignores un-recorded time in bed, so it reads high. | ✅ asleep ÷ (bedtime → wake) |
| 10 | Bedtime consistency uses minutes-of-day | 23:30 and 00:30 are treated as 23 h apart, so night owls get a score of 0. | ✅ circular mean/std |
| 11 | `ActivityAnalytics.dailySummary` sums raw samples | iPhone + Watch steps double count. Raw samples are the wrong input for totals. | ✅ `daily()` uses platform statistics (`HKStatisticsCollectionQuery`), with a `maxSource` fallback |
| 12 | `streak` starts at today | The streak shows 0 every morning until today's goal is met. | ✅ today-in-progress aware, plus `longestStreak` |
| 13 | SpO2 / body fat read with `HKUnit.percent()` | HealthKit returns 0.97, labelled "%". | ✅ scaled to 0–100 (and back when writing) |
| 14 | `percentChange(0 → x)` returns ±100; `(0 → 0)` returns −100 | Misleading numbers in the UI. | ✅ returns `null` |
| 15 | `trend` regresses on sample index | Irregular sampling distorts the slope, and the unit is "per sample". | ✅ `trendPerDay` on real dates (index version kept) |
| 16 | `authorizationStatus(for:)` returns *share* status | For read-only types HealthKit always says `sharingDenied`, so the app thinks access was denied. | ✅ `AuthorizationStatus.unknown` for read; documented |
| 17 | Blood pressure returned as two unrelated arrays | The caller has to re-pair them and can get it wrong. | ✅ `BloodPressureReading` paired by timestamp (🔧 better: `HKCorrelationType(.bloodPressure)`) |
| 18 | `Calendar.current` / `Date()` hard-coded | Date logic can't be unit-tested deterministically. | ✅ `now:` / `clock:` injection everywhere |
| 19 | README example claims `calculateScore(7.5, 1.5, 2.0, 91) → 88` | The formula gives 99. | 🔧 fix the README (or the weights) |
| 20 | `HealthConfiguration.readPermissions` is never used, and the default asks for *all* 34 types | Dead config; requesting everything gets apps rejected in App Review. | 🔧 use it in `requestAuthorization()` and default to an empty set |

## 3. Missing features (added in the Flutter version)

| Feature | Why it matters | Flutter | Swift |
|---|---|---|---|
| **Android / Health Connect** | Half the market | ✅ | n/a |
| **Testable seam + mock source** | The analytics can be tested and demoed without a device | ✅ `HealthSource`, `MockHealthSource`, `.synthetic()` | 🔧 add a `HealthStoreProtocol` + mock (as SwiftBLEKit does) |
| **De-duplicated daily series** | Charts and goals need per-day totals that are correct | ✅ `daily()` | 🔧 `HKStatisticsCollectionQuery` |
| **Incremental sync** | The kit is named *Sync*, but every query re-reads everything | ✅ `changes()` (anchored queries / change tokens) | 🔧 `HKAnchoredObjectQuery` |
| **Writing data** | Logging water, weight, steps | ✅ `writeQuantity()` | 🔧 (`writePermissions` exists but is unused) |
| **Readiness / recovery score** | The most-requested wellness metric | ✅ HRV and RHR vs. personal baseline + sleep | 🔧 port |
| **Personal baselines + anomalies** | "Your resting HR is unusually high today" | ✅ `baseline()`, `anomalies()` | 🔧 port |
| **Training load (ACWR)** | Overtraining warnings for fitness apps | ✅ `trainingLoad()` | 🔧 port |
| **Sleep debt, social jetlag, wake consistency, naps** | Sleep-coaching features | ✅ | 🔧 port |
| **Configurable goals** | 10k steps isn't right for everyone | ✅ `ActivityGoals` | 🔧 |
| **Percentile, EMA, sample SD** | Robust charts | ✅ | 🔧 |
| **Source metadata** (`sourceId`, device) | Needed for de-duplication and "data from…" UI | ✅ | partial (name only) |
| **Workout average HR** | Feeds training load and HR zones | ✅ | 🔧 |

## 4. Roadmap for both repos

1. **Background delivery.** On iOS: `HKObserverQuery` + `enableBackgroundDelivery` (needs the HealthKit Background Delivery entitlement on iOS 15+). On Android: WorkManager polling `getChanges()`. This is what makes "sync" work while the app is closed.
2. **Health Connect history permission.** (Documented in README → Accuracy notes; not implemented.) `PERMISSION_READ_HEALTH_DATA_HISTORY` for data older than 30 days.
3. **Write sleep sessions and workouts**, including Health Connect `ExerciseSessionRecord` with segments and laps.
4. **Workout routes** (`HKWorkoutRoute` / `ExerciseRoute`) and **heart-rate zones** (time in Z1–Z5 from the workout's HR series).
5. **More data types:** VO₂ max / cardio fitness, menstrual cycle, mindfulness minutes, ECG classification, walking steadiness, wrist temperature (overnight deviation is a strong readiness input), audio exposure.
6. **Units & locale:** imperial output (lb, mi, °F) via a `UnitPreferences` object.
7. **Caching layer:** an optional on-device cache keyed by sync anchor, so dashboards open instantly.
8. **Data quality flags:** `recordingMethod` (manual vs automatic) from Health Connect and `HKMetadataKeyWasUserEntered`, so manual entries can be excluded from analytics.
9. **Privacy:** ✅ (Flutter) [PRIVACY.md](../PRIVACY.md) template and README "Publishing your app" (entitlement, purpose strings, guideline 5.1.3, Play Health Connect declaration); the example shows the policy from Health Connect's rationale intent. Still to do: a `redact()` helper and documentation about not sending raw health data to analytics/crash tools (Apple guideline 5.1.3).
10. **Docs:** a DocC catalogue (Swift) and dartdoc (Flutter), plus a "Recipes" page (dashboard, sleep coach, step challenge).

## 5. Fixed after the 0.1.0 review (0.1.0 – Unreleased)

See CHANGELOG.md for the exact API. ✅ = fixed in the Flutter package.

| # | Issue | Effect before | Status |
|---|---|---|---|
| 21 | Types the platform lacks (e.g. HRV SDNN on Android) were reported as `denied` (Android) or `unknown` (iOS) | Apps showed "permission denied" for something no user can grant | ✅ `AuthorizationStatus.unsupported`, `supportedTypes()`, dropped before the platform call |
| 22 | Two quick `requestAuthorization` calls on Android | The second overwrote the first's pending result, so one Dart future never completed | ✅ requests are queued in Dart; native side replies exactly once and returns `AuthorizationInProgress` if a screen is already open |
| 23 | Permission reply missing on cancel / detached activity / `getGrantedPermissions` failure | Hanging futures | ✅ every path replies once |
| 24 | Android workout totals used one `aggregate()` per session, capped at 200 sessions | Slow, silently incomplete for long ranges; one missing permission dropped all three totals | ✅ ≤ 4 reads per call, attributed by overlap, per-field nulls, `Workout.totalsAttribution` |
| 25 | Android active calories empty when the writer (e.g. some watches) only writes total calories | Activity score and training load read 0 | ✅ fallback total − BMR (clamped at 0), flagged `isDerived` |
| 26 | Health Connect work ran on the main thread | Jank when loading 90+ days | ✅ `Dispatchers.Default`; replies on main |
| 27 | Plugin not registered (app not rebuilt) threw a raw `MissingPluginException` | Unhelpful crash | ✅ `HealthDataNotAvailable(reason: 'pluginNotRegistered')` |
| 28 | `SleepNight.summary` recomputed on every read | Repeated work in list UIs | ✅ cached (`late final`) |
| 29 | No privacy-policy guidance; Health Connect's rationale link opened nothing | Store rejection risk | ✅ PRIVACY.md, README "Publishing your app", example `PrivacyPolicyScreen` |

### Accuracy notes (behaviour to know, not bugs)

Full text is in README → Accuracy notes.

- **Android distance** is a single `DistanceRecord`, so `distanceWalkingRunning` also includes cycling. iOS keeps them separate.
- **Derived active calories** are total − BMR over the same bucket. They are an estimate and are marked `isDerived`.
- **Workout totals attribution:**
  - `sameApp` means only records from the session's own app were used.
  - `allApps` means that, for at least one total, no same-app records overlapped, so records from any app were used.
  - `none` means there were no totals.
  - iOS always reports `sameApp`, because the totals come from the HKWorkout itself.
- **Sleep stages:** Health Connect `SLEEPING` (and a session with no stages) → `asleep`; `AWAKE`, `AWAKE_IN_BED`, `OUT_OF_BED` → `awake`; `UNKNOWN` → `unknown`, which is not counted as sleep. iOS `inBed` is never counted as sleep.
- **HRV:** iOS reports SDNN and Android reports RMSSD. They are not interchangeable, so don't compare values across platforms. Use `supportedTypes()`.
- **Health Connect history:** by default only 30 days before the first grant are readable, and change tokens expire after ~30 days (`changes()` then needs a full re-read).

## 6. Verification still required

Done since 0.1.0:
- `flutter analyze` is clean and `flutter test` is green (128 passed, 5 skipped).
- The example app is built and run on an Android emulator (API 36) with Health Connect.

Still to do:
- iOS build plus a device with Apple Watch data (sleep stages, HRV SDNN, workouts).
- Android **real device** with at least one real writer (Fitbit / Samsung Health / Google Fit). Check:
  - daily aggregates against the writer's own totals;
  - sleep stages;
  - HRV RMSSD;
  - change-token expiry;
  - the active-calorie fallback against real BMR data.
