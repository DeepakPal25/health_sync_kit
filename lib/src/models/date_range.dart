import 'health_error.dart';

/// Returns local midnight of [t]'s calendar day.
DateTime startOfDay(DateTime t) => DateTime(t.year, t.month, t.day);

/// Adds whole calendar days (DST-safe, unlike `add(Duration(days: n))`).
DateTime addDays(DateTime day, int days) => DateTime(day.year, day.month,
    day.day + days, day.hour, day.minute, day.second, day.millisecond);

/// A bounded time interval for health queries. `start` is inclusive, `end`
/// exclusive.
class DateRange {
  /// Throws [InvalidDateRange] if [start] is after [end].
  DateRange(this.start, this.end) {
    if (start.isAfter(end)) throw const InvalidDateRange();
  }

  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  // ---------------------------------------------------------------- Factories
  // Each takes an optional `now` so date logic is testable.

  /// Midnight today → now.
  factory DateRange.today({DateTime? now}) {
    final n = now ?? DateTime.now();
    return DateRange(startOfDay(n), n);
  }

  /// The whole of yesterday.
  factory DateRange.yesterday({DateTime? now}) {
    final today = startOfDay(now ?? DateTime.now());
    return DateRange(addDays(today, -1), today);
  }

  /// The whole calendar day containing [day].
  factory DateRange.day(DateTime day) {
    final s = startOfDay(day);
    return DateRange(s, addDays(s, 1));
  }

  /// The last [days] full calendar days plus today so far.
  factory DateRange.lastDays(int days, {DateTime? now}) {
    final n = now ?? DateTime.now();
    return DateRange(addDays(startOfDay(n), -days), n);
  }

  factory DateRange.lastWeek({DateTime? now}) =>
      DateRange.lastDays(7, now: now);
  factory DateRange.lastMonth({DateTime? now}) =>
      DateRange.lastDays(30, now: now);

  /// Monday 00:00 of this week → now.
  factory DateRange.thisWeek({DateTime? now}) {
    final n = now ?? DateTime.now();
    final today = startOfDay(n);
    return DateRange(addDays(today, -(today.weekday - DateTime.monday)), n);
  }

  /// The 1st of this month → now.
  factory DateRange.thisMonth({DateTime? now}) {
    final n = now ?? DateTime.now();
    return DateRange(DateTime(n.year, n.month), n);
  }

  /// Splits the range into calendar-day sub-ranges.
  List<DateRange> splitByDay() {
    final out = <DateRange>[];
    var cursor = start;
    while (cursor.isBefore(end)) {
      final next = addDays(startOfDay(cursor), 1);
      out.add(DateRange(cursor, next.isBefore(end) ? next : end));
      cursor = next;
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'DateRange($start → $end)';
}
