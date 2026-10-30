package com.deepakpal.health_sync_kit

/**
 * Attributes interval and point records to workout sessions by time overlap.
 *
 * Pure (no Health Connect types) so it can run on Dispatchers.Default and be
 * reasoned about in isolation. Times are epoch milliseconds.
 */
internal object WorkoutTotals {
    /** An interval record such as active calories or distance. */
    data class Interval(val start: Long, val end: Long, val value: Double, val pkg: String)

    /** One heart-rate sample. */
    data class Point(val time: Long, val value: Double, val pkg: String)

    enum class Source { SAME_APP, ALL_APPS }

    data class Total(val value: Double, val source: Source)

    /**
     * Prefers [items] written by [pkg]; falls back to every app only when the
     * session's own app wrote none that overlap.
     */
    private fun <T> prefer(items: List<T>, pkg: String, pkgOf: (T) -> String): Pair<List<T>, Source>? {
        if (items.isEmpty()) return null
        val same = items.filter { pkgOf(it) == pkg }
        return if (same.isNotEmpty()) same to Source.SAME_APP else items to Source.ALL_APPS
    }

    /**
     * Sum of `value × overlap / duration` over intervals overlapping
     * [start, end). A zero-length record counts fully if it lies inside.
     */
    fun sum(records: List<Interval>, start: Long, end: Long, pkg: String): Total? {
        val overlapping = records.filter {
            if (it.end <= it.start) it.start in start until end else it.start < end && it.end > start
        }
        val (picked, source) = prefer(overlapping, pkg) { it.pkg } ?: return null
        var total = 0.0
        for (r in picked) {
            val duration = r.end - r.start
            total += if (duration <= 0) {
                r.value
            } else {
                val overlap = minOf(r.end, end) - maxOf(r.start, start)
                r.value * overlap.toDouble() / duration.toDouble()
            }
        }
        return Total(total, source)
    }

    /** Mean of the points inside [start, end]. */
    fun mean(points: List<Point>, start: Long, end: Long, pkg: String): Total? {
        val inside = points.filter { it.time in start..end }
        val (picked, source) = prefer(inside, pkg) { it.pkg } ?: return null
        return Total(picked.sumOf { it.value } / picked.size, source)
    }

    /**
     * One label for the whole workout: "allApps" if any total fell back to
     * other apps, "sameApp" if all present totals came from the session's
     * app, null if no totals were found.
     */
    fun label(vararg totals: Total?): String? {
        val present = totals.filterNotNull()
        return when {
            present.isEmpty() -> null
            present.any { it.source == Source.ALL_APPS } -> "allApps"
            else -> "sameApp"
        }
    }
}
