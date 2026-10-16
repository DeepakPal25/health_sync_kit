import '../models/authorization.dart';
import '../models/date_range.dart';
import '../models/health_data_type.dart';
import '../models/samples.dart';
import '../models/statistics.dart';

/// Whether the platform health store can be used.
enum HealthAvailability {
  available,

  /// Android: Health Connect isn't installed (Android 13 and below).
  notInstalled,

  /// Android: Health Connect must be updated.
  updateRequired,

  /// No health store on this device (iPad, old Android, emulator without HC).
  unsupported;

  bool get isAvailable => this == available;

  static HealthAvailability fromName(String? name) =>
      HealthAvailability.values.firstWhere((a) => a.name == name,
          orElse: () => HealthAvailability.unsupported);
}

/// The abstraction boundary over the platform health store.
///
/// `LiveHealthSource` talks to HealthKit (iOS) or Health Connect (Android)
/// through the native plugin; `MockHealthSource` serves in-memory data. All
/// analytics and `HealthSyncClient` are written against this interface, so
/// they run in unit tests and demos without a device.
abstract interface class HealthSource {
  Future<HealthAvailability> availability();

  /// The data types this platform can read at all (independent of
  /// permissions or whether the store is installed).
  Future<Set<HealthDataType>> supportedTypes();

  /// Requests read access to [read] and write access to [write].
  Future<AuthorizationResult> requestAuthorization(
    Set<HealthDataType> read, {
    Set<HealthDataType> write = const {},
  });

  Future<AuthorizationStatus> authorizationStatus(HealthDataType type);

  /// Raw samples of a quantity [type], oldest first.
  Future<List<QuantitySample>> quantity(HealthDataType type, DateRange range);

  Future<List<SleepSample>> sleep(DateRange range);

  Future<List<Workout>> workouts(DateRange range);

  /// One aggregate over [range], de-duplicated across sources by the
  /// platform. Returns `null` when the platform can't aggregate this type /
  /// option, in which case the client falls back to raw samples.
  ///
  /// Return a [StatisticsResult] with a `null` value when the platform can
  /// aggregate but there is no data.
  Future<StatisticsResult?> statistics(
      HealthDataType type, DateRange range, StatisticsOption option);

  /// Per-day aggregates over [range] (local calendar days), de-duplicated by
  /// the platform. Returns `null` when unsupported.
  Future<List<DailyValue>?> dailyStatistics(
      HealthDataType type, DateRange range, StatisticsOption option);

  /// Incremental sync: what changed for [type] since [anchor] (or everything
  /// from now on when [anchor] is `null`). Throws `SyncAnchorExpired` when the
  /// anchor is too old.
  Future<HealthChanges> changes(HealthDataType type, {String? anchor});

  /// Writes a quantity sample (requires write permission).
  Future<void> writeQuantity(
    HealthDataType type,
    double value, {
    required DateTime start,
    DateTime? end,
  });

  /// Opens the platform's health settings (Health Connect on Android, the
  /// Health app on iOS where possible).
  Future<void> openSettings();
}
