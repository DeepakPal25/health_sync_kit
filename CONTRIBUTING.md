# Contributing

Thanks for helping! Issues and PRs are welcome.

1. `flutter pub get`
2. `flutter analyze` and `flutter test` must pass. Every Dart-layer change needs a
   test against `MockHealthSource` (or `MockHealthSource.synthetic()`); no device required.
3. `dart format lib test`
4. Native changes (Swift / Kotlin): describe the device(s), OS versions and data
   sources (Apple Watch, Fitbit, Samsung Health…) you tested with in the PR.
5. Add a line to `CHANGELOG.md`.

The project is pre-1.0: minor releases may include small breaking changes,
always noted in the changelog.
