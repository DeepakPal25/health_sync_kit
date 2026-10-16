import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

const _channel = MethodChannel('health_sync_kit');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const live = LiveHealthSource();

  /// Installs [handler] on the plugin channel for the current test.
  void mock(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(_channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  }

  group('A2: permission requests are serialised', () {
    test('two concurrent requests run one after another and both complete',
        () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final order = <String>[];
      mock((call) async {
        expect(call.method, 'requestAuthorization');
        final read = (call.arguments as Map)['read'] as List;
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        order.add('start ${read.single}');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('end ${read.single}');
        inFlight--;
        return {read.single: 'authorized'};
      });

      final a = live.requestAuthorization({HealthDataType.steps});
      final b = live.requestAuthorization({HealthDataType.sleep});
      final results = await Future.wait([a, b]);

      expect(maxInFlight, 1);
      expect(order, ['start steps', 'end steps', 'start sleep', 'end sleep']);
      expect(results[0].statusFor(HealthDataType.steps),
          AuthorizationStatus.authorized);
      expect(results[1].statusFor(HealthDataType.sleep),
          AuthorizationStatus.authorized);
    });

    test('a failed request does not block the next one', () async {
      var calls = 0;
      mock((call) async {
        calls++;
        if (calls == 1) {
          throw PlatformException(code: 'queryFailed', message: 'boom');
        }
        return {'steps': 'authorized'};
      });

      final a = live.requestAuthorization({HealthDataType.steps});
      final b = live.requestAuthorization({HealthDataType.steps});
      await expectLater(a, throwsA(const QueryFailed('boom')));
      expect((await b).allGranted, isTrue);
    });

    test('native authInProgress maps to AuthorizationInProgress', () async {
      mock((call) async =>
          throw PlatformException(code: 'authInProgress', message: 'busy'));
      final err = await live
          .requestAuthorization({HealthDataType.steps}).then<Object?>(
              (_) => null,
              onError: (Object e) => e);
      expect(err, isA<AuthorizationInProgress>());
      final e = err! as AuthorizationInProgress;
      expect(e.message, isNotEmpty);
      expect(e.recoverySuggestion, isNotNull);
    });
  });

  group('B1: plugin not registered', () {
    test('MissingPluginException maps to HealthDataNotAvailable', () async {
      // No mock handler installed: the channel has no implementation.
      messenger.setMockMethodCallHandler(_channel, null);
      final err = await live
          .availability()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(err, const HealthDataNotAvailable(reason: 'pluginNotRegistered'));
      final e = err! as HealthDataNotAvailable;
      expect(e.recoverySuggestion, contains('rebuild'));
      expect(e.recoverySuggestion, contains("hot restart doesn't register"));
      expect(e.message, contains('pluginNotRegistered'));
    });

    test('every channel call maps it, not just availability', () async {
      messenger.setMockMethodCallHandler(_channel, null);
      await expectLater(
          live.statistics(
              HealthDataType.steps,
              DateRange(DateTime(2026), DateTime(2026, 1, 2)),
              StatisticsOption.sum),
          throwsA(const HealthDataNotAvailable(reason: 'pluginNotRegistered')));
    });

    test('other reasons keep their existing suggestions', () {
      expect(
          const HealthDataNotAvailable(reason: 'notInstalled')
              .recoverySuggestion,
          contains('Play Store'));
      expect(const HealthDataNotAvailable().recoverySuggestion,
          contains('Android 9+'));
    });
  });

  group('A4: derived active calories', () {
    final day1 = DateTime(2026, 3, 2);
    final range = DateRange(day1, DateTime(2026, 3, 4)); // 2 local days

    test('statistics surfaces "derived" as StatisticsResult.isDerived',
        () async {
      mock(
          (call) async => {'supported': true, 'value': 420.0, 'derived': true});
      final client = HealthSyncClient(source: live);
      final r =
          await client.statistics(HealthDataType.activeEnergyBurned, range);
      expect(r.value, 420.0);
      expect(r.isDerived, isTrue);
      expect(r.deduplicated, isTrue);
    });

    test('statistics without "derived" is not derived', () async {
      mock((call) async => {'supported': true, 'value': 300.0});
      final r = await live.statistics(
          HealthDataType.activeEnergyBurned, range, StatisticsOption.sum);
      expect(r!.value, 300.0);
      expect(r.isDerived, isFalse);
    });

    test('dailyStatistics marks only the derived buckets', () async {
      mock((call) async => {
            'supported': true,
            'buckets': [
              {'date': day1.millisecondsSinceEpoch, 'value': 250.0},
              {
                'date':
                    day1.add(const Duration(days: 1)).millisecondsSinceEpoch,
                'value': 180.0,
                'derived': true,
              },
            ],
          });
      final client = HealthSyncClient(source: live);
      final days = await client.daily(HealthDataType.activeEnergyBurned, range);
      expect(days, [
        DailyValue(day1, 250.0),
        DailyValue(DateTime(2026, 3, 3), 180.0, isDerived: true),
      ]);
    });

    test('DailyValue equality includes isDerived', () {
      final d = DateTime(2026, 1, 1);
      expect(DailyValue(d, 1), isNot(DailyValue(d, 1, isDerived: true)));
      expect(
          DailyValue(d, 1, isDerived: true), DailyValue(d, 1, isDerived: true));
      expect(DailyValue(d, 1).isDerived, isFalse);
    });
  });
}
