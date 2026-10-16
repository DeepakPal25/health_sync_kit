import 'health_data_type.dart';

/// Errors surfaced by health_sync_kit. Sealed: `switch` over it is exhaustive.
sealed class HealthError implements Exception {
  const HealthError();

  /// A user-facing explanation.
  String get message;

  /// What the user or developer can do about it, if anything.
  String? get recoverySuggestion => null;

  @override
  String toString() => '$runtimeType: $message';
}

/// No health store on this device (iPad without Health, Android without
/// Health Connect, emulator).
final class HealthDataNotAvailable extends HealthError {
  const HealthDataNotAvailable({this.reason});

  /// `notInstalled`, `updateRequired` or `unsupported` (Android), or
  /// `pluginNotRegistered` when no native plugin answered the call.
  final String? reason;

  @override
  String get message => 'Health data is not available on this device'
      '${reason == null ? '' : ' ($reason)'}.';
  @override
  String? get recoverySuggestion => switch (reason) {
        'notInstalled' ||
        'updateRequired' =>
          'Install or update Health Connect from the Play Store '
              '(HealthSyncClient.openHealthSettings()).',
        'pluginNotRegistered' =>
          "Stop and rebuild the app (hot restart doesn't register new "
              'plugins); platform must be iOS or Android.',
        _ => 'HealthKit requires an iPhone or Apple Watch; Health Connect '
            'requires Android 9+.',
      };
  @override
  bool operator ==(Object other) =>
      other is HealthDataNotAvailable && other.reason == reason;
  @override
  int get hashCode => Object.hash(runtimeType, reason);
}

/// The user denied access.
final class AuthorizationDenied extends HealthError {
  const AuthorizationDenied([this.types = const []]);
  final List<HealthDataType> types;
  @override
  String get message => 'Access to health data was denied.';
  @override
  String? get recoverySuggestion =>
      'Grant access in the Health app (iOS) or Health Connect (Android).';
  @override
  bool operator ==(Object other) => other is AuthorizationDenied;
  @override
  int get hashCode => (AuthorizationDenied).hashCode;
}

/// A query failed in the platform store.
final class QueryFailed extends HealthError {
  const QueryFailed(this.reason);
  final String reason;
  @override
  String get message => 'Health query failed: $reason';
  @override
  bool operator ==(Object other) =>
      other is QueryFailed && other.reason == reason;
  @override
  int get hashCode => Object.hash(runtimeType, reason);
}

/// The data type isn't supported on this platform or OS version.
final class UnsupportedDataType extends HealthError {
  const UnsupportedDataType(this.type);
  final HealthDataType type;
  @override
  String get message =>
      '${type.displayName} is not supported on this platform.';
  @override
  bool operator ==(Object other) =>
      other is UnsupportedDataType && other.type == type;
  @override
  int get hashCode => Object.hash(runtimeType, type);
}

/// Another permission request is still showing on screen. Android can only
/// show one Health Connect permission screen at a time.
///
/// `LiveHealthSource` already queues overlapping `requestAuthorization`
/// calls from Dart, so you normally only see this when several Flutter
/// engines share one activity.
final class AuthorizationInProgress extends HealthError {
  const AuthorizationInProgress();
  @override
  String get message => 'A health permission request is already in progress.';
  @override
  String? get recoverySuggestion =>
      'Wait for the current permission request to finish, then try again.';
  @override
  bool operator ==(Object other) => other is AuthorizationInProgress;
  @override
  int get hashCode => (AuthorizationInProgress).hashCode;
}

/// A date range with `start` after `end`.
final class InvalidDateRange extends HealthError {
  const InvalidDateRange();
  @override
  String get message => 'Start date must be before or equal to end date.';
  @override
  bool operator ==(Object other) => other is InvalidDateRange;
  @override
  int get hashCode => (InvalidDateRange).hashCode;
}

/// An incremental-sync anchor is no longer valid (Health Connect change
/// tokens expire after ~30 days). Do a full read and start a new sync.
final class SyncAnchorExpired extends HealthError {
  const SyncAnchorExpired();
  @override
  String get message => 'The sync anchor has expired.';
  @override
  String? get recoverySuggestion =>
      'Call changes() without an anchor to start a fresh sync.';
  @override
  bool operator ==(Object other) => other is SyncAnchorExpired;
  @override
  int get hashCode => (SyncAnchorExpired).hashCode;
}
