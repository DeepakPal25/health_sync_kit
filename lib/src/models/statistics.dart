import 'health_data_type.dart';
import 'samples.dart';

/// Aggregation option for statistics queries.
enum StatisticsOption { sum, average, minimum, maximum, mostRecent }

/// The result of a statistics query over one range.
class StatisticsResult {
  const StatisticsResult({
    required this.type,
    required this.option,
    required this.value,
    required this.start,
    required this.end,
    this.deduplicated = true,
    this.isDerived = false,
  });

  final HealthDataType type;
  final StatisticsOption option;

  /// `null` when there is no data in range.
  final double? value;
  final DateTime start;
  final DateTime end;

  /// Whether the platform merged overlapping sources (phone + watch). `false`
  /// when the value had to be computed from raw samples, where overlapping
  /// sources can double-count cumulative types.
  final bool deduplicated;

  /// The value was estimated rather than read directly. On Android, when no
  /// app writes active calories, `activeEnergyBurned` is computed as total
  /// calories − basal metabolic rate (clamped at 0).
  final bool isDerived;

  String get unit => type.unit;
  bool get isAvailable => value != null;

  @override
  String toString() =>
      'StatisticsResult(${type.name} ${option.name}: $value $unit)';
}

/// One bucket of a daily statistics series.
class DailyValue {
  const DailyValue(this.date, this.value, {this.isDerived = false});

  /// Local midnight of the day.
  final DateTime date;

  /// `null` when there was no data that day.
  final double? value;

  /// The value was estimated rather than read directly (see
  /// [StatisticsResult.isDerived]).
  final bool isDerived;

  @override
  bool operator ==(Object other) =>
      other is DailyValue &&
      other.date == date &&
      other.value == value &&
      other.isDerived == isDerived;
  @override
  int get hashCode => Object.hash(date, value, isDerived);
  @override
  String toString() =>
      'DailyValue($date: $value${isDerived ? ' (derived)' : ''})';
}

/// The result of an incremental sync: what changed since the last anchor.
class HealthChanges {
  const HealthChanges({
    required this.type,
    required this.added,
    required this.deletedIds,
    required this.anchor,
    this.hasMore = false,
  });

  final HealthDataType type;

  /// New or updated samples.
  final List<QuantitySample> added;

  /// Ids of samples deleted from the store.
  final List<String> deletedIds;

  /// Opaque token to pass to the next `changes()` call. Persist it.
  final String anchor;

  /// More changes are waiting; call again with [anchor] right away.
  final bool hasMore;
}
