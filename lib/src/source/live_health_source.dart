import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/authorization.dart';
import '../models/date_range.dart';
import '../models/health_data_type.dart';
import '../models/health_error.dart';
import '../models/samples.dart';
import '../models/statistics.dart';
import 'health_source.dart';

const _channel = MethodChannel('health_sync_kit');

/// Maps a native [PlatformException] to a typed [HealthError].
@visibleForTesting
HealthError mapHealthPlatformError(PlatformException e) {
  final details = e.details;
  final typeName = details is Map ? details['type'] as String? : null;
  final type = typeName == null ? null : HealthDataType.fromName(typeName);
  switch (e.code) {
    case 'notAvailable':
      return HealthDataNotAvailable(
          reason: details is Map ? details['reason'] as String? : null);
    case 'denied':
      return AuthorizationDenied([if (type != null) type]);
    case 'unsupported':
      return type == null
          ? QueryFailed(e.message ?? 'unsupported')
          : UnsupportedDataType(type);
    case 'anchorExpired':
      return const SyncAnchorExpired();
    case 'authInProgress':
      return const AuthorizationInProgress();
    default:
      return QueryFailed(e.message ?? e.code);
  }
}

Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
  try {
    return await _channel.invokeMethod<T>(method, args);
  } on PlatformException catch (e) {
    throw mapHealthPlatformError(e);
  } on MissingPluginException {
    // No native handler: the app wasn't rebuilt after adding the plugin, or
    // the platform isn't iOS/Android.
    throw const HealthDataNotAvailable(reason: 'pluginNotRegistered');
  }
}

Map<String, Object?> _range(DateRange r) => {
      'start': r.start.millisecondsSinceEpoch,
      'end': r.end.millisecondsSinceEpoch,
    };

List<Map<Object?, Object?>> _maps(List<Object?>? raw) =>
    [for (final m in raw ?? const []) m as Map<Object?, Object?>];

/// The production [HealthSource]: HealthKit on iOS, Health Connect on
/// Android.
class LiveHealthSource implements HealthSource {
  const LiveHealthSource();

  /// Tail of the queue of permission requests. Android can show only one
  /// permission screen at a time, so overlapping calls run one after another.
  static Future<void> _authQueue = Future<void>.value();

  @override
  Future<HealthAvailability> availability() async =>
      HealthAvailability.fromName(await _invoke<String>('availability'));

  @override
  Future<Set<HealthDataType>> supportedTypes() async {
    final raw = await _invoke<List<Object?>>('supportedTypes');
    return {
      for (final n in raw ?? const [])
        if (HealthDataType.fromName(n as String) case final t?) t,
    };
  }

  @override
  Future<AuthorizationResult> requestAuthorization(
    Set<HealthDataType> read, {
    Set<HealthDataType> write = const {},
  }) {
    final run = _authQueue.then((_) => _requestAuthorization(read, write));
    // The next request waits for this one whether it succeeds or fails.
    _authQueue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<AuthorizationResult> _requestAuthorization(
    Set<HealthDataType> read,
    Set<HealthDataType> write,
  ) async {
    final raw = await _invoke<Map<Object?, Object?>>('requestAuthorization', {
      'read': [for (final t in read) t.name],
      'write': [for (final t in write) t.name],
    });
    final statuses = <HealthDataType, AuthorizationStatus>{};
    raw?.forEach((k, v) {
      final type = HealthDataType.fromName(k as String);
      if (type != null) {
        statuses[type] = AuthorizationStatus.fromName(v as String?);
      }
    });
    return AuthorizationResult(statuses);
  }

  @override
  Future<AuthorizationStatus> authorizationStatus(HealthDataType type) async =>
      AuthorizationStatus.fromName(
          await _invoke<String>('authorizationStatus', {'type': type.name}));

  @override
  Future<List<QuantitySample>> quantity(
      HealthDataType type, DateRange range) async {
    if (!type.isQuantity) throw UnsupportedDataType(type);
    final raw = await _invoke<List<Object?>>(
        'quantity', {'type': type.name, ..._range(range)});
    return [
      for (final m in _maps(raw))
        QuantitySample.fromMap({...m, 'type': type.name}),
    ];
  }

  @override
  Future<List<SleepSample>> sleep(DateRange range) async {
    final raw = await _invoke<List<Object?>>('sleep', _range(range));
    return [for (final m in _maps(raw)) SleepSample.fromMap(m)];
  }

  @override
  Future<List<Workout>> workouts(DateRange range) async {
    final raw = await _invoke<List<Object?>>('workouts', _range(range));
    return [for (final m in _maps(raw)) Workout.fromMap(m)];
  }

  @override
  Future<StatisticsResult?> statistics(
      HealthDataType type, DateRange range, StatisticsOption option) async {
    final raw = await _invoke<Map<Object?, Object?>>('statistics', {
      'type': type.name,
      'option': option.name,
      ..._range(range),
    });
    if (raw == null || raw['supported'] != true) return null;
    return StatisticsResult(
      type: type,
      option: option,
      value: (raw['value'] as num?)?.toDouble(),
      start: range.start,
      end: range.end,
      isDerived: raw['derived'] == true,
    );
  }

  @override
  Future<List<DailyValue>?> dailyStatistics(
      HealthDataType type, DateRange range, StatisticsOption option) async {
    final raw = await _invoke<Map<Object?, Object?>>('dailyStatistics', {
      'type': type.name,
      'option': option.name,
      ..._range(range),
    });
    if (raw == null || raw['supported'] != true) return null;
    final byDay = <DateTime, DailyValue>{};
    for (final m in _maps(raw['buckets'] as List<Object?>?)) {
      final date = startOfDay(
          DateTime.fromMillisecondsSinceEpoch((m['date'] as num).toInt()));
      byDay[date] = DailyValue(date, (m['value'] as num?)?.toDouble(),
          isDerived: m['derived'] == true);
    }
    // Normalise to one entry per local day in range.
    return [
      for (final day in range.splitByDay())
        byDay[startOfDay(day.start)] ?? DailyValue(startOfDay(day.start), null),
    ];
  }

  @override
  Future<HealthChanges> changes(HealthDataType type, {String? anchor}) async {
    final raw = await _invoke<Map<Object?, Object?>>(
        'changes', {'type': type.name, 'anchor': anchor});
    if (raw == null) throw const QueryFailed('no response');
    return HealthChanges(
      type: type,
      added: [
        for (final m in _maps(raw['added'] as List<Object?>?))
          QuantitySample.fromMap({...m, 'type': type.name}),
      ],
      deletedIds: [
        for (final id in (raw['deleted'] as List<Object?>? ?? const []))
          id as String,
      ],
      anchor: raw['anchor'] as String,
      hasMore: raw['hasMore'] as bool? ?? false,
    );
  }

  @override
  Future<void> writeQuantity(
    HealthDataType type,
    double value, {
    required DateTime start,
    DateTime? end,
  }) =>
      _invoke<void>('writeQuantity', {
        'type': type.name,
        'value': value,
        'start': start.millisecondsSinceEpoch,
        'end': (end ?? start).millisecondsSinceEpoch,
      });

  @override
  Future<void> openSettings() => _invoke<void>('openSettings');
}
