/// Cross-platform health data (HealthKit + Health Connect) with a built-in
/// analytics layer. A Flutter port of
/// [HealthSyncKit](https://github.com/DeepakPal25/HealthSyncKit).
library;

export 'src/analytics/activity_analytics.dart';
export 'src/analytics/health_statistics.dart';
export 'src/analytics/recovery_analytics.dart';
export 'src/analytics/sleep_analytics.dart';
export 'src/client/health_sync_client.dart';
export 'src/models/authorization.dart';
export 'src/models/date_range.dart';
export 'src/models/health_data_type.dart';
export 'src/models/health_error.dart';
export 'src/models/samples.dart';
export 'src/models/statistics.dart';
export 'src/source/health_source.dart';
export 'src/source/live_health_source.dart' show LiveHealthSource;
export 'src/source/mock_health_source.dart';
