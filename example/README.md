# health_sync_kit example

A health dashboard covering readiness, activity with a 7-day chart and streak,
sleep stages and consistency, training load and resting-HR anomalies. With
**Demo data** on (the default), it runs on `MockHealthSource.synthetic()`, so it
works on any emulator.

```sh
cd example
flutter create --platforms=android,ios .
flutter run
```

To use real data, switch **Demo data** off, then:

- iOS: enable the HealthKit capability and add the Info.plist keys from the main README.
- Android: add the `android.permission.health.READ_*` permissions and the
  rationale intent-filter / activity-alias from the main README to
  `android/app/src/main/AndroidManifest.xml`, and set `minSdk 26` in
  `android/app/build.gradle`.
