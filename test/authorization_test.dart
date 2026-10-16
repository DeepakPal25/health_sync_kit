import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

void main() {
  final now = DateTime(2026, 11, 18, 10);

  late MockHealthSource source;
  late HealthSyncClient client;

  setUp(() {
    source = MockHealthSource();
    client = HealthSyncClient(source: source, clock: () => now);
  });

  group('A1: unsupported types', () {
    test('mock supports every type by default', () async {
      expect(await client.supportedTypes(), HealthDataType.values.toSet());
    });

    test('unsupported SDNN is reported unsupported, not denied', () async {
      source.supported.remove(HealthDataType.heartRateVariabilitySDNN);
      final r = await client.requestAuthorization(
          {HealthDataType.heartRateVariabilitySDNN, HealthDataType.steps});

      expect(r.statusFor(HealthDataType.heartRateVariabilitySDNN),
          AuthorizationStatus.unsupported);
      expect(r.statusFor(HealthDataType.steps), AuthorizationStatus.authorized);
      expect(r.denied, isEmpty);
      expect(r.unsupported, [HealthDataType.heartRateVariabilitySDNN]);
      expect(r.allGranted, isTrue);
      expect(AuthorizationStatus.unsupported.isAuthorized, isFalse);
      expect(await client.supportedTypes(),
          isNot(contains(HealthDataType.heartRateVariabilitySDNN)));
    });

    test('unsupported types never reach the source', () async {
      source.supported.remove(HealthDataType.heartRateVariabilitySDNN);
      source.grantAll = false;
      final r = await client
          .requestAuthorization({HealthDataType.heartRateVariabilitySDNN});
      expect(r.unsupported, [HealthDataType.heartRateVariabilitySDNN]);
      expect(r.denied, isEmpty, reason: 'grantAll=false must not apply');
    });

    test('authorizationStatus is unsupported for a missing type', () async {
      source.supported.remove(HealthDataType.heartRateVariabilitySDNN);
      expect(
          await client
              .authorizationStatus(HealthDataType.heartRateVariabilitySDNN),
          AuthorizationStatus.unsupported);
    });

    test('heartRateVariability() still returns RMSSD when SDNN is unsupported',
        () async {
      source.supported.remove(HealthDataType.heartRateVariabilitySDNN);
      source.addQuantity(HealthDataType.heartRateVariabilityRMSSD, 42,
          start: now.subtract(const Duration(hours: 2)));
      final hrv = await client.heartRateVariability(DateRange.today(now: now));
      expect(hrv, hasLength(1));
      expect(hrv.single.type, HealthDataType.heartRateVariabilityRMSSD);
      expect(hrv.single.value, 42);
    });
  });
}
