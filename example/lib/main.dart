import 'dart:async';

import 'package:flutter/material.dart';
import 'package:health_sync_kit/health_sync_kit.dart';

import 'privacy_policy_screen.dart';

/// Health dashboard demo. "Demo data" (default) runs everything on
/// MockHealthSource.synthetic(), so it works on any emulator. Switch it off
/// to read real HealthKit / Health Connect data.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(HealthDemoApp(showPrivacyPolicy: await launchedForPrivacyPolicy()));
}

class HealthDemoApp extends StatefulWidget {
  const HealthDemoApp({super.key, this.showPrivacyPolicy = false});

  /// Start on the privacy policy (Health Connect opened the app for it).
  final bool showPrivacyPolicy;

  @override
  State<HealthDemoApp> createState() => _HealthDemoAppState();
}

class _HealthDemoAppState extends State<HealthDemoApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Health Connect can open the policy while the app is already running.
    // Reply immediately: push() only completes when the route is popped.
    launchChannel.setMethodCallHandler((call) async {
      if (call.method == 'showPrivacyPolicy') {
        unawaited(_navigator.currentState?.push(PrivacyPolicyScreen.route()));
      }
    });
  }

  @override
  void dispose() {
    launchChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigator,
        title: 'health_sync_kit demo',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: widget.showPrivacyPolicy
            ? const PrivacyPolicyScreen()
            : const DashboardPage(),
      );
}

const _readTypes = {
  HealthDataType.steps,
  HealthDataType.activeEnergyBurned,
  HealthDataType.distanceWalkingRunning,
  HealthDataType.exerciseTime,
  HealthDataType.heartRate,
  HealthDataType.restingHeartRate,
  HealthDataType.heartRateVariabilitySDNN,
  HealthDataType.heartRateVariabilityRMSSD,
  HealthDataType.sleep,
  HealthDataType.workouts,
};

class _DashboardData {
  _DashboardData({
    required this.activity,
    required this.week,
    required this.streak,
    required this.night,
    required this.consistency,
    required this.debt,
    required this.readiness,
    required this.load,
    required this.anomalies,
  });

  final ActivitySummary activity;
  final List<DailyValue> week;
  final int streak;
  final SleepNight? night;
  final double consistency;
  final double debt;
  final ReadinessScore readiness;
  final TrainingLoad load;
  final List<Anomaly> anomalies;
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _demo = true;
  late HealthSyncClient _client;
  Future<_DashboardData>? _future;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  void _setup() {
    _client = HealthSyncClient(
        source: _demo ? MockHealthSource.synthetic(days: 45) : null);
    _future = _load();
  }

  Future<_DashboardData> _load() async {
    if (!_demo) {
      final availability = await _client.availability();
      if (!availability.isAvailable) {
        throw HealthDataNotAvailable(reason: availability.name);
      }
      await _client.requestAuthorization(_readTypes);
    }
    final now = DateTime.now();
    final nights = await _client.sleepNights(DateRange.lastDays(14));
    final results = await Future.wait<Object?>([
      _client.activitySummary(now),
      _client.dailySteps(DateRange.lastDays(6)),
      _client.streak(),
      _client.lastNight(),
      _client.readiness(),
      _client.trainingLoad(),
      _client.anomalies(
          HealthDataType.restingHeartRate, DateRange.lastDays(30)),
    ]);
    return _DashboardData(
      activity: results[0]! as ActivitySummary,
      week: results[1]! as List<DailyValue>,
      streak: results[2]! as int,
      night: results[3] as SleepNight?,
      consistency: SleepAnalytics.bedtimeConsistency(nights),
      debt: SleepAnalytics.sleepDebt(nights),
      readiness: results[4]! as ReadinessScore,
      load: results[5]! as TrainingLoad,
      anomalies: results[6]! as List<Anomaly>,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Health'),
        actions: [
          IconButton(
            tooltip: 'Privacy policy',
            icon: const Icon(Icons.privacy_tip_outlined),
            onPressed: () =>
                Navigator.of(context).push(PrivacyPolicyScreen.route()),
          ),
          const Text('Demo data'),
          Switch(
            value: _demo,
            onChanged: (v) => setState(() {
              _demo = v;
              _setup();
            }),
          ),
        ],
      ),
      body: FutureBuilder<_DashboardData>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return _ErrorView(snap.error!,
                onSettings: _client.openHealthSettings);
          }
          final d = snap.data;
          if (d == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: () async {
              final next = _load();
              setState(() {
                _future = next;
              });
              await next;
            },
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _ReadinessCard(d.readiness),
                _ActivityCard(d.activity, d.week, d.streak),
                _SleepCard(d.night, d.consistency, d.debt),
                _LoadCard(d.load),
                _AnomalyCard(d.anomalies),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Wellness insights only, not medical advice.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard(this.r);
  final ReadinessScore r;

  @override
  Widget build(BuildContext context) => _Section(
        title: 'Readiness',
        trailing: Chip(label: Text(r.label)),
        child: Row(children: [
          Text(r.score?.toString() ?? '--',
              style: Theme.of(context).textTheme.displayMedium),
          const SizedBox(width: 16),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _kv('HRV vs baseline', _z(r.hrvZScore)),
              _kv('Resting HR vs baseline', _z(r.restingHeartRateZScore)),
              _kv('Sleep points', r.sleepPoints?.toStringAsFixed(0) ?? '--'),
            ]),
          ),
        ]),
      );

  static String _z(double? z) =>
      z == null ? '--' : '${z >= 0 ? '+' : ''}${z.toStringAsFixed(1)} SD';
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard(this.a, this.week, this.streak);
  final ActivitySummary a;
  final List<DailyValue> week;
  final int streak;

  @override
  Widget build(BuildContext context) {
    final maxSteps =
        week.fold<double>(10000, (m, d) => (d.value ?? 0) > m ? d.value! : m);
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return _Section(
      title: 'Activity',
      trailing: Chip(label: Text('🔥 $streak-day streak')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _progress('Steps', a.steps, a.goals.steps, ''),
        _progress(
            'Active energy', a.activeCalories, a.goals.activeCalories, ' kcal'),
        _progress(
            'Exercise', a.exerciseMinutes, a.goals.exerciseMinutes, ' min'),
        _kv('Activity score', '${a.activityScore}/100'),
        const SizedBox(height: 12),
        SizedBox(
          height: 90,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final d in week)
                Expanded(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: 70 * ((d.value ?? 0) / maxSteps),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: (d.value ?? 0) >= a.goals.steps
                                ? Colors.teal
                                : Colors.teal.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(days[d.date.weekday - 1],
                            style: const TextStyle(fontSize: 11)),
                      ]),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _SleepCard extends StatelessWidget {
  const _SleepCard(this.night, this.consistency, this.debt);
  final SleepNight? night;
  final double consistency;
  final double debt;

  @override
  Widget build(BuildContext context) {
    final n = night;
    if (n == null) {
      return const _Section(
          title: 'Sleep', child: Text('No sleep recorded last night.'));
    }
    final s = n.summary;
    final total = s.timeInBed <= 0 ? 1 : s.timeInBed;
    Widget seg(double hours, Color color) => Expanded(
          flex: (hours / total * 1000).round().clamp(1, 1000),
          child: Container(height: 14, color: color),
        );
    return _Section(
      title: 'Sleep',
      trailing: Chip(label: Text('Score ${s.sleepScore}')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            '${_h(s.totalSleep)} asleep · ${s.sleepEfficiency.toStringAsFixed(0)}% efficiency'),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Row(children: [
            seg(s.deepSleep, Colors.indigo),
            seg(s.coreSleep, Colors.blue),
            seg(s.remSleep, Colors.lightBlue),
            seg(s.awake, Colors.orange),
          ]),
        ),
        const SizedBox(height: 4),
        Text(
            'Deep ${_h(s.deepSleep)} · Core ${_h(s.coreSleep)} · '
            'REM ${_h(s.remSleep)} · Awake ${_h(s.awake)}',
            style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        _kv('Bedtime consistency (14 d)', '${consistency.round()}/100'),
        _kv('Sleep debt (7 d)', _h(debt)),
        _kv('Source', n.sourceName ?? '--'),
      ]),
    );
  }
}

class _LoadCard extends StatelessWidget {
  const _LoadCard(this.load);
  final TrainingLoad load;

  @override
  Widget build(BuildContext context) => _Section(
        title: 'Training load',
        trailing: Chip(label: Text(load.status.name)),
        child: Column(children: [
          _kv('Acute (7 d avg)', load.acute.toStringAsFixed(1)),
          _kv('Chronic (28 d avg)', load.chronic.toStringAsFixed(1)),
          _kv('Ratio', load.ratio?.toStringAsFixed(2) ?? '--'),
        ]),
      );
}

class _AnomalyCard extends StatelessWidget {
  const _AnomalyCard(this.anomalies);
  final List<Anomaly> anomalies;

  @override
  Widget build(BuildContext context) => _Section(
        title: 'Resting HR anomalies (30 d)',
        child: anomalies.isEmpty
            ? const Text('Nothing unusual.')
            : Column(children: [
                for (final a in anomalies)
                  _kv('${a.date.day}/${a.date.month}',
                      '${a.value.round()} bpm (${a.zScore.toStringAsFixed(1)} SD)'),
              ]),
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView(this.error, {required this.onSettings});
  final Object error;
  final Future<void> Function() onSettings;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                error is HealthError
                    ? (error as HealthError).message
                    : '$error',
                textAlign: TextAlign.center),
            if (error is HealthError &&
                (error as HealthError).recoverySuggestion != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text((error as HealthError).recoverySuggestion!,
                    textAlign: TextAlign.center),
              ),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: onSettings,
                child: const Text('Open health settings')),
          ]),
        ),
      );
}

Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [Expanded(child: Text(k)), Text(v)]),
    );

Widget _progress(String label, double value, double goal, String unit) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label: ${value.round()}$unit / ${goal.round()}$unit'),
        const SizedBox(height: 4),
        LinearProgressIndicator(
            value: ActivityAnalytics.goalProgress(value, goal)),
      ]),
    );

String _h(double hours) {
  final m = (hours * 60).round();
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}
