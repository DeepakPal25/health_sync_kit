import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_sync_kit/health_sync_kit.dart';
import 'package:health_sync_kit/src/source/live_health_source.dart'
    show mapHealthPlatformError;

const _channel = MethodChannel('health_sync_kit');

/// B3: LiveHealthSource argument encoding and reply parsing, through a mocked
/// method channel. Values here are synthetic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const live = LiveHealthSource();

  final day1 = DateTime(2026, 3, 2);
  final range = DateRange(day1, DateTime(2026, 3, 5)); // 3 local days
  int ms(DateTime d) => d.millisecondsSinceEpoch;

  /// Replies with [reply] to every call and records the calls made.
  List<MethodCall> mock(Object? Function(MethodCall call) reply) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return reply(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    return calls;
  }

  group('requests', () {
    test('availability parses known names; unknown is unsupported', () async {
      mock((_) => 'notInstalled');
      expect(await live.availability(), HealthAvailability.notInstalled);
      mock((_) => 'somethingNew');
      expect(await live.availability(), HealthAvailability.unsupported);
      mock((_) => null);
      expect(await live.availability(), HealthAvailability.unsupported);
    });

    test('supportedTypes drops names this Dart version does not know',
        () async {
      mock((_) => ['steps', 'heartRateVariabilityRMSSD', 'futureType']);
      expect(await live.supportedTypes(), {
        HealthDataType.steps,
        HealthDataType.heartRateVariabilityRMSSD,
      });
      mock((_) => null);
      expect(await live.supportedTypes(), isEmpty);
    });

    test('requestAuthorization sends names and ignores unknown keys', () async {
      final calls = mock((_) => {
            'steps': 'authorized',
            'sleep': 'denied',
            'futureType': 'authorized',
          });
      final r = await live.requestAuthorization({HealthDataType.steps},
          write: {HealthDataType.weight});
      expect(calls.single.arguments, {
        'read': ['steps'],
        'write': ['weight'],
      });
      expect(r.statusFor(HealthDataType.steps), AuthorizationStatus.authorized);
      expect(r.statusFor(HealthDataType.sleep), AuthorizationStatus.denied);
    });

    test('authorizationStatus sends the type name', () async {
      final calls = mock((_) => 'denied');
      expect(await live.authorizationStatus(HealthDataType.heartRate),
          AuthorizationStatus.denied);
      expect(calls.single.method, 'authorizationStatus');
      expect(calls.single.arguments, {'type': 'heartRate'});
    });

    test('writeQuantity sends value and ms; end defaults to start', () async {
      final calls = mock((_) => null);
      final t = DateTime(2026, 3, 2, 8);
      await live.writeQuantity(HealthDataType.weight, 70.5, start: t);
      await live.writeQuantity(HealthDataType.weight, 71,
          start: t, end: t.add(const Duration(minutes: 1)));
      expect(calls[0].arguments,
          {'type': 'weight', 'value': 70.5, 'start': ms(t), 'end': ms(t)});
      expect((calls[1].arguments as Map)['end'],
          ms(t.add(const Duration(minutes: 1))));
    });

    test('openSettings invokes the native method', () async {
      final calls = mock((_) => null);
      await live.openSettings();
      expect(calls.single.method, 'openSettings');
    });
  });

  group('sample parsing', () {
    test('quantity stamps the requested type and converts ms', () async {
      final t = DateTime(2026, 3, 2, 7, 30);
      final calls = mock((_) => [
            {
              'id': 'q1',
              'value': 512, // int on the wire → double
              'start': ms(t),
              'end': ms(t.add(const Duration(minutes: 5))),
              'sourceName': 'Watch',
              'sourceId': 'com.example.watch',
              'device': 'Watch7,1',
            },
          ]);
      final s = (await live.quantity(HealthDataType.steps, range)).single;
      expect(calls.single.arguments,
          {'type': 'steps', 'start': ms(range.start), 'end': ms(range.end)});
      expect(s.id, 'q1');
      expect(s.type, HealthDataType.steps);
      expect(s.value, 512.0);
      expect(s.start, t);
      expect(s.duration, const Duration(minutes: 5));
      expect(s.sourceId, 'com.example.watch');
      expect(s.device, 'Watch7,1');
    });

    test('quantity rejects non-quantity types without a channel call',
        () async {
      final calls = mock((_) => const []);
      await expectLater(live.quantity(HealthDataType.sleep, range),
          throwsA(const UnsupportedDataType(HealthDataType.sleep)));
      expect(calls, isEmpty);
    });

    test('quantity with a null reply is empty', () async {
      mock((_) => null);
      expect(await live.quantity(HealthDataType.steps, range), isEmpty);
    });

    test('sleep parses stages; unknown stage names fall back', () async {
      final t = DateTime(2026, 3, 2, 23);
      mock((_) => [
            {
              'id': 's1',
              'stage': 'deep',
              'start': ms(t),
              'end': ms(t.add(const Duration(hours: 1))),
              'sourceId': 'app',
            },
            {
              'id': 's2',
              'stage': 'notAStage',
              'start': ms(t.add(const Duration(hours: 1))),
              'end': ms(t.add(const Duration(hours: 2))),
            },
          ]);
      final s = await live.sleep(range);
      expect(s[0].stage, SleepStage.deep);
      expect(s[0].hours, 1.0);
      expect(s[0].sourceId, 'app');
      expect(s[1].stage, SleepStage.fromName('notAStage'));
    });

    test('workouts parse totals and attribution', () async {
      final t = DateTime(2026, 3, 3, 18);
      mock((_) => [
            {
              'id': 'w1',
              'activityType': 'running',
              'start': ms(t),
              'end': ms(t.add(const Duration(minutes: 30))),
              'energyBurned': 300,
              'distance': 5000.5,
              'averageHeartRate': 150,
              'sourceName': 'Runner',
              'totalsSource': 'allApps',
            },
            {
              'id': 'w2',
              'activityType': 'zorbing',
              'start': ms(t),
              'end': ms(t),
            },
          ]);
      final w = await live.workouts(range);
      expect(w[0].activityType, WorkoutActivityType.running);
      expect(w[0].energyBurned, 300.0);
      expect(w[0].distance, 5000.5);
      expect(w[0].averageHeartRate, 150.0);
      expect(w[0].totalsAttribution, WorkoutTotalsAttribution.allApps);
      expect(w[1].activityType, WorkoutActivityType.other);
      expect(w[1].energyBurned, isNull);
      expect(w[1].totalsAttribution, WorkoutTotalsAttribution.none);
    });
  });

  group('statistics parsing', () {
    test('sends type, option and range; returns the value', () async {
      final calls = mock((_) => {'supported': true, 'value': 61});
      final r = await live.statistics(
          HealthDataType.heartRate, range, StatisticsOption.average);
      expect(calls.single.arguments, {
        'type': 'heartRate',
        'option': 'average',
        'start': ms(range.start),
        'end': ms(range.end),
      });
      expect(r!.value, 61.0);
      expect(r.option, StatisticsOption.average);
      expect(r.start, range.start);
      expect(r.end, range.end);
    });

    test('supported:true with no value is a result with null value', () async {
      mock((_) => {'supported': true});
      final r = await live.statistics(
          HealthDataType.steps, range, StatisticsOption.sum);
      expect(r, isNotNull);
      expect(r!.value, isNull);
    });

    test('supported:false or null reply → null (client falls back)', () async {
      mock((_) => {'supported': false, 'value': 1});
      expect(
          await live.statistics(
              HealthDataType.steps, range, StatisticsOption.sum),
          isNull);
      mock((_) => null);
      expect(
          await live.statistics(
              HealthDataType.steps, range, StatisticsOption.sum),
          isNull);
    });

    test('dailyStatistics returns one value per local day, gaps as null',
        () async {
      // Native sends day 3 first, a mid-day timestamp, and skips day 2.
      mock((_) => {
            'supported': true,
            'buckets': [
              {'date': ms(DateTime(2026, 3, 4)), 'value': 30},
              {'date': ms(DateTime(2026, 3, 2, 12)), 'value': 10},
            ],
          });
      expect(
          await live.dailyStatistics(
              HealthDataType.steps, range, StatisticsOption.sum),
          [
            DailyValue(DateTime(2026, 3, 2), 10),
            DailyValue(DateTime(2026, 3, 3), null),
            DailyValue(DateTime(2026, 3, 4), 30),
          ]);
    });

    test('dailyStatistics unsupported → null', () async {
      mock((_) => {'supported': false});
      expect(
          await live.dailyStatistics(
              HealthDataType.steps, range, StatisticsOption.sum),
          isNull);
    });
  });

  group('changes parsing', () {
    test('parses added, deleted, anchor and hasMore', () async {
      final t = DateTime(2026, 3, 2, 9);
      final calls = mock((_) => {
            'added': [
              {'id': 'a', 'value': 70.2, 'start': ms(t), 'end': ms(t)},
            ],
            'deleted': ['old1', 'old2'],
            'anchor': 'tok-2',
            'hasMore': true,
          });
      final c = await live.changes(HealthDataType.weight, anchor: 'tok-1');
      expect(calls.single.arguments, {'type': 'weight', 'anchor': 'tok-1'});
      expect(c.type, HealthDataType.weight);
      expect(c.added.single.type, HealthDataType.weight);
      expect(c.added.single.value, 70.2);
      expect(c.deletedIds, ['old1', 'old2']);
      expect(c.anchor, 'tok-2');
      expect(c.hasMore, isTrue);
    });

    test('missing lists are empty and hasMore defaults to false', () async {
      final calls = mock((_) => {'anchor': 'tok'});
      final c = await live.changes(HealthDataType.steps);
      expect((calls.single.arguments as Map)['anchor'], isNull);
      expect(c.added, isEmpty);
      expect(c.deletedIds, isEmpty);
      expect(c.hasMore, isFalse);
    });

    test('a null reply is QueryFailed', () async {
      mock((_) => null);
      await expectLater(live.changes(HealthDataType.steps),
          throwsA(const QueryFailed('no response')));
    });
  });

  group('mapHealthPlatformError', () {
    HealthError map(String code, {String? message, Object? details}) =>
        mapHealthPlatformError(
            PlatformException(code: code, message: message, details: details));

    test('notAvailable carries details.reason', () {
      expect(map('notAvailable', details: {'reason': 'notInstalled'}),
          const HealthDataNotAvailable(reason: 'notInstalled'));
      final e = map('notAvailable') as HealthDataNotAvailable;
      expect(e.reason, isNull);
    });

    test('denied carries the type when given', () {
      final e =
          map('denied', details: {'type': 'heartRate'}) as AuthorizationDenied;
      expect(e.types, [HealthDataType.heartRate]);
      expect((map('denied') as AuthorizationDenied).types, isEmpty);
      expect(
          (map('denied', details: {'type': 'futureType'})
                  as AuthorizationDenied)
              .types,
          isEmpty);
    });

    test('unsupported with a type → UnsupportedDataType, else QueryFailed', () {
      expect(map('unsupported', details: {'type': 'heartRateVariabilitySDNN'}),
          const UnsupportedDataType(HealthDataType.heartRateVariabilitySDNN));
      expect(map('unsupported', message: 'nope'), const QueryFailed('nope'));
      expect(map('unsupported'), const QueryFailed('unsupported'));
    });

    test('anchorExpired and authInProgress', () {
      expect(map('anchorExpired'), const SyncAnchorExpired());
      expect(map('authInProgress'), const AuthorizationInProgress());
    });

    test('unknown codes become QueryFailed(message ?? code)', () {
      expect(map('queryFailed', message: 'boom'), const QueryFailed('boom'));
      expect(map('weird'), const QueryFailed('weird'));
    });

    test('a native error reaches the caller already mapped', () async {
      messenger.setMockMethodCallHandler(
          _channel,
          (_) async => throw PlatformException(
              code: 'anchorExpired', message: 'token too old'));
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      await expectLater(live.changes(HealthDataType.steps, anchor: 'x'),
          throwsA(const SyncAnchorExpired()));
    });
  });
}
