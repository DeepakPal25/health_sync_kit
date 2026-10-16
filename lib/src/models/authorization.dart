import 'health_data_type.dart';

/// The authorization state for one data type.
enum AuthorizationStatus {
  notDetermined,
  denied,
  authorized,

  /// The platform will not say. On iOS, HealthKit deliberately hides whether
  /// *read* access was granted (to protect privacy), so read-only types report
  /// `unknown` after the prompt. Treat it as "try the query; an empty result
  /// may mean no data or no permission".
  unknown,

  /// This platform has no such data type (for example
  /// `heartRateVariabilitySDNN` on Android, `heartRateVariabilityRMSSD` on
  /// iOS). [isAuthorized] is `false`; not counted in
  /// [AuthorizationResult.denied].
  unsupported;

  bool get isAuthorized => this == authorized;

  static AuthorizationStatus fromName(String? name) =>
      AuthorizationStatus.values.firstWhere((s) => s.name == name,
          orElse: () => AuthorizationStatus.unknown);
}

/// Result of a permission request.
class AuthorizationResult {
  const AuthorizationResult(this.statuses);

  final Map<HealthDataType, AuthorizationStatus> statuses;

  AuthorizationStatus statusFor(HealthDataType type) =>
      statuses[type] ?? AuthorizationStatus.notDetermined;

  /// All supported types definitely granted. Types the platform doesn't have
  /// ([AuthorizationStatus.unsupported]) are ignored. Always `false` on iOS
  /// for read-only types (see [AuthorizationStatus.unknown]); prefer
  /// [anyDenied] there.
  bool get allGranted => statuses.values
      .where((s) => s != AuthorizationStatus.unsupported)
      .every((s) => s.isAuthorized);

  /// Types this platform doesn't have.
  List<HealthDataType> get unsupported => [
        for (final e in statuses.entries)
          if (e.value == AuthorizationStatus.unsupported) e.key,
      ];

  List<HealthDataType> get denied => [
        for (final e in statuses.entries)
          if (e.value == AuthorizationStatus.denied) e.key,
      ];

  bool get anyDenied => denied.isNotEmpty;
}
