import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

void main() {
  test('every HealthDataType has a non-empty unit and display name', () {
    for (final t in HealthDataType.values) {
      expect(t.unit.trim(), isNotEmpty, reason: t.name);
      expect(t.displayName.trim(), isNotEmpty, reason: t.name);
    }
  });

  test('isQuantity is false only for sleep and workouts', () {
    final nonQuantity = {
      for (final t in HealthDataType.values)
        if (!t.isQuantity) t,
    };
    expect(nonQuantity, {HealthDataType.sleep, HealthDataType.workouts});
  });

  test('names round-trip through fromName', () {
    for (final t in HealthDataType.values) {
      expect(HealthDataType.fromName(t.name), t);
    }
    expect(HealthDataType.fromName('nope'), isNull);
  });

  test('quantity() rejects non-quantity types', () async {
    final source = MockHealthSource();
    final r = DateRange.today();
    for (final t in [HealthDataType.sleep, HealthDataType.workouts]) {
      await expectLater(
          source.quantity(t, r), throwsA(isA<UnsupportedDataType>()));
    }
  });
}
