package com.deepakpal.health_sync_kit

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.net.toUri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.aggregate.AggregateMetric
import androidx.health.connect.client.changes.DeletionChange
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.BasalMetabolicRateRecord
import androidx.health.connect.client.records.BloodGlucoseRecord
import androidx.health.connect.client.records.BloodPressureRecord
import androidx.health.connect.client.records.BodyFatRecord
import androidx.health.connect.client.records.BodyTemperatureRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.FloorsClimbedRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.HeightRecord
import androidx.health.connect.client.records.HydrationRecord
import androidx.health.connect.client.records.LeanBodyMassRecord
import androidx.health.connect.client.records.NutritionRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.AggregateGroupByPeriodRequest
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ChangesTokenRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.units.Energy
import androidx.health.connect.client.units.Length
import androidx.health.connect.client.units.Mass
import androidx.health.connect.client.units.Volume
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Duration
import java.time.Instant
import java.time.LocalDateTime
import java.time.Period
import java.time.ZoneId
import java.util.concurrent.ConcurrentHashMap
import kotlin.reflect.KClass

/**
 * Android side of health_sync_kit: Health Connect behind the `health_sync_kit`
 * channel. Values are converted to the same canonical units as iOS.
 *
 * Apps must declare the `android.permission.health.READ_*` permissions they
 * use, plus the permissions-rationale activity, in their own manifest (see
 * README).
 */
class HealthSyncKitPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {

    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    /** The in-flight requestAuthorization call; non-null from entry until its single reply. */
    private var authResult: MethodChannel.Result? = null
    /** Set while the Health Connect permission screen is on screen. */
    private var pendingAuth: PendingAuth? = null

    private class PendingAuth(
        val contract: ActivityResultContract<Set<String>, Set<String>>,
        val requested: Map<String, Set<String>>,
    )

    private val client: HealthConnectClient by lazy { HealthConnectClient.getOrCreate(context) }

    // ---------------------------------------------------------------- Lifecycle

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "health_sync_kit")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        finishAuth { it.error("queryFailed", "Plugin detached during a permission request", null) }
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        activity = b.activity
        binding = b
        b.addActivityResultListener(this)
        b.addRequestPermissionsResultListener(this)
    }

    // A config change re-attaches a new activity that receives the permission
    // result, so the pending request is kept.
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)
    override fun onDetachedFromActivity() {
        detachActivity()
        // No activity will ever deliver the result: fail it instead of hanging Dart.
        finishAuth { it.error("queryFailed", "Activity detached before the permission screen returned", null) }
    }

    private fun detachActivity() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
    }

    // ----------------------------------------------------------------- Dispatch

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val status = availability() // one SDK status lookup per call
        if (call.method == "availability") {
            result.success(status); return
        }
        if (call.method == "supportedTypes") {
            result.success(SUPPORTED_TYPES.filter { recordClass(it) != null }); return
        }
        if (status != "available") {
            result.error("notAvailable", "Health Connect is not available",
                mapOf("reason" to status)); return
        }
        if (call.method == "openSettings") { openSettings(status); result.success(null); return }
        if (call.method == "requestAuthorization") { requestAuthorization(call, result); return }

        scope.launch {
            try {
                // Queries, unit conversion, sorting and attribution run off the
                // main thread; the reply below goes back on Main (scope's dispatcher).
                val value: Any? = withContext(Dispatchers.Default) { when (call.method) {
                    "authorizationStatus" -> authorizationStatus(call.argument<String>("type")!!)
                    "quantity" -> quantity(call)
                    "sleep" -> sleep(call)
                    "workouts" -> workouts(call)
                    "statistics" -> statistics(call)
                    "dailyStatistics" -> dailyStatistics(call)
                    "changes" -> changes(call)
                    "writeQuantity" -> { writeQuantity(call); null }
                    else -> NOT_IMPLEMENTED
                } }
                if (value === NOT_IMPLEMENTED) result.notImplemented() else result.success(value)
            } catch (e: Unsupported) {
                result.error("unsupported", e.message, mapOf("type" to e.type))
            } catch (e: AnchorExpired) {
                result.error("anchorExpired", "Changes token expired", null)
            } catch (e: SecurityException) {
                result.error("denied", e.message, mapOf("type" to call.argument<String>("type")))
            } catch (e: Exception) {
                result.error("queryFailed", e.message ?: e.toString(), null)
            }
        }
    }

    private class Unsupported(val type: String?) : Exception("Unsupported data type $type")
    private class AnchorExpired : Exception()

    // -------------------------------------------------------------- Availability

    private fun availability(): String = when (HealthConnectClient.getSdkStatus(context)) {
        HealthConnectClient.SDK_AVAILABLE -> "available"
        HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "updateRequired"
        else -> if (Build.VERSION.SDK_INT in 26..33) "notInstalled" else "unsupported"
    }

    private fun openSettings(status: String) {
        val act = activity ?: return
        val intent = if (status == "available") {
            Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS)
        } else {
            // androidx.core.net.toUri (core-ktx, transitive via activity-ktx).
            Intent(
                Intent.ACTION_VIEW,
                "market://details?id=com.google.android.apps.healthdata&url=healthconnect%3A%2F%2Fonboarding".toUri(),
            )
        }
        act.startActivity(intent)
    }

    // ------------------------------------------------------------ Authorization

    private fun readPermission(type: String): String? =
        recordClass(type)?.let { HealthPermission.getReadPermission(it) }

    private fun writePermission(type: String): String? =
        recordClass(type)?.let { HealthPermission.getWritePermission(it) }

    private fun requestAuthorization(call: MethodCall, result: MethodChannel.Result) {
        val read = call.argument<List<String>>("read") ?: emptyList()
        val write = call.argument<List<String>>("write") ?: emptyList()
        val requested = mutableMapOf<String, MutableSet<String>>()
        read.forEach { t -> readPermission(t)?.let { requested.getOrPut(t) { mutableSetOf() }.add(it) } }
        write.forEach { t -> writePermission(t)?.let { requested.getOrPut(t) { mutableSetOf() }.add(it) } }
        val unsupported = (read + write).filter { it !in requested }

        if (authResult != null) {
            result.error("authInProgress", "A permission request is already in progress", null)
            return
        }
        val act = activity
        if (act == null) {
            result.error("queryFailed", "No foreground activity to show the permission screen", null)
            return
        }
        authResult = result
        scope.launch {
            try {
                val granted = client.permissionController.getGrantedPermissions()
                // Extra permissions for the derived active-calories fallback. Kept out
                // of `requested` so they don't affect activeEnergyBurned's status.
                val extras = if ("activeEnergyBurned" in read) DERIVED_ACTIVE_PERMISSIONS else emptySet()
                val all = requested.values.flatten().toSet() + extras
                if (granted.containsAll(all)) {
                    finishAuth { it.success(statusMap(requested, granted, unsupported)) }
                    return@launch
                }
                val contract = PermissionController.createRequestPermissionResultContract()
                pendingAuth = PendingAuth(contract, requested + unsupported.associateWith { emptySet<String>() })
                val intent = contract.createIntent(act, all)
                if (intent.action == ActivityResultContracts.RequestMultiplePermissions.ACTION_REQUEST_PERMISSIONS) {
                    // Android 14+: health permissions are runtime permissions and the
                    // contract returns a RequestMultiplePermissions intent, which only
                    // ComponentActivity's result registry understands. FlutterActivity
                    // has no Activity for that action, so ask for the permissions directly.
                    val perms = intent.getStringArrayExtra(
                        ActivityResultContracts.RequestMultiplePermissions.EXTRA_PERMISSIONS,
                    ) ?: all.toTypedArray()
                    ActivityCompat.requestPermissions(act, perms, AUTH_REQUEST_CODE)
                } else {
                    act.startActivityForResult(intent, AUTH_REQUEST_CODE)
                }
            } catch (e: Exception) {
                finishAuth { it.error("queryFailed", e.message ?: e.toString(), null) }
            }
        }
    }

    /**
     * Replies to the in-flight permission request exactly once. Every exit path
     * (granted, user cancel, error, activity or engine detach) goes through here.
     * All callers run on the main thread.
     */
    private fun finishAuth(reply: (MethodChannel.Result) -> Unit) {
        val r = authResult ?: return
        authResult = null
        pendingAuth = null
        reply(r)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != AUTH_REQUEST_CODE) return false
        val pending = pendingAuth ?: return true
        pendingAuth = null
        // A user cancel (back press) arrives here as an empty grant set.
        val justGranted = try {
            pending.contract.parseResult(resultCode, data)
        } catch (e: Exception) { emptySet() }
        completeAuth(pending, justGranted)
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ): Boolean {
        if (requestCode != AUTH_REQUEST_CODE) return false
        val pending = pendingAuth ?: return true
        pendingAuth = null
        // A user cancel arrives as empty arrays.
        val justGranted = permissions.filterIndexed { i, _ ->
            grantResults.getOrNull(i) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }.toSet()
        completeAuth(pending, justGranted)
        return true
    }

    /** Replies with the granted state after the permission screen closes. */
    private fun completeAuth(pending: PendingAuth, justGranted: Set<String>) {
        scope.launch {
            val granted = try {
                client.permissionController.getGrantedPermissions()
            } catch (e: Exception) { justGranted }
            finishAuth { it.success(statusMap(pending.requested, granted, emptyList())) }
        }
    }

    private fun statusMap(
        requested: Map<String, Set<String>>, granted: Set<String>, unsupported: List<String>,
    ): Map<String, String> {
        val out = mutableMapOf<String, String>()
        for ((type, perms) in requested) {
            out[type] = when {
                perms.isEmpty() -> "unsupported"
                granted.containsAll(perms) -> "authorized"
                else -> "denied"
            }
        }
        unsupported.forEach { out[it] = "unsupported" }
        return out
    }

    private suspend fun authorizationStatus(type: String): String {
        val perm = readPermission(type) ?: return "unsupported"
        return if (perm in client.permissionController.getGrantedPermissions()) "authorized" else "notDetermined"
    }

    // ------------------------------------------------------------------ Mapping

    private fun recordClass(type: String): KClass<out Record>? = when (type) {
        "steps" -> StepsRecord::class
        "distanceWalkingRunning" -> DistanceRecord::class
        "activeEnergyBurned" -> ActiveCaloriesBurnedRecord::class
        "flightsClimbed" -> FloorsClimbedRecord::class
        "exerciseTime", "workouts" -> ExerciseSessionRecord::class
        "height" -> HeightRecord::class
        "weight" -> WeightRecord::class
        "bodyFatPercentage" -> BodyFatRecord::class
        "leanBodyMass" -> LeanBodyMassRecord::class
        "heartRate" -> HeartRateRecord::class
        "restingHeartRate" -> RestingHeartRateRecord::class
        "heartRateVariabilityRMSSD" -> HeartRateVariabilityRmssdRecord::class
        "bloodPressureSystolic", "bloodPressureDiastolic" -> BloodPressureRecord::class
        "respiratoryRate" -> RespiratoryRateRecord::class
        "oxygenSaturation" -> OxygenSaturationRecord::class
        "bodyTemperature" -> BodyTemperatureRecord::class
        "bloodGlucose" -> BloodGlucoseRecord::class
        "dietaryWater" -> HydrationRecord::class
        "dietaryEnergy", "dietaryCarbohydrates", "dietaryFiber", "dietarySugar",
        "dietaryFat", "dietaryProtein", "dietaryCaffeine", "dietarySodium" -> NutritionRecord::class
        "sleep" -> SleepSessionRecord::class
        else -> null // basal energy, cycling distance, stand time, BMI, waist, SDNN…
    }

    /** Converts one record to zero or more canonical samples for [type]. */
    private fun toSamples(type: String, r: Record): List<Map<String, Any?>> {
        val (start, end) = timeSpan(r) ?: return emptyList()
        fun sample(value: Double?, id: String = r.metadata.id, s: Instant = start, e: Instant = end) =
            value?.let {
                mapOf(
                    "id" to id,
                    "value" to it,
                    "start" to s.toEpochMilli(),
                    "end" to e.toEpochMilli(),
                    "sourceName" to sourceName(r.metadata.dataOrigin.packageName),
                    "sourceId" to r.metadata.dataOrigin.packageName,
                    "device" to r.metadata.device?.model,
                )
            }

        val one: Double? = when (r) {
            is StepsRecord -> r.count.toDouble()
            is DistanceRecord -> r.distance.inMeters
            is ActiveCaloriesBurnedRecord -> r.energy.inKilocalories
            is FloorsClimbedRecord -> r.floors
            is ExerciseSessionRecord -> Duration.between(r.startTime, r.endTime).seconds / 60.0
            is HeightRecord -> r.height.inMeters * 100
            is WeightRecord -> r.weight.inKilograms
            is BodyFatRecord -> r.percentage.value
            is LeanBodyMassRecord -> r.mass.inKilograms
            is RestingHeartRateRecord -> r.beatsPerMinute.toDouble()
            is HeartRateVariabilityRmssdRecord -> r.heartRateVariabilityMillis
            is BloodPressureRecord -> if (type == "bloodPressureSystolic")
                r.systolic.inMillimetersOfMercury else r.diastolic.inMillimetersOfMercury
            is RespiratoryRateRecord -> r.rate
            is OxygenSaturationRecord -> r.percentage.value
            is BodyTemperatureRecord -> r.temperature.inCelsius
            is BloodGlucoseRecord -> r.level.inMilligramsPerDeciliter
            is HydrationRecord -> r.volume.inMilliliters
            is NutritionRecord -> when (type) {
                "dietaryEnergy" -> r.energy?.inKilocalories
                "dietaryCarbohydrates" -> r.totalCarbohydrate?.inGrams
                "dietaryFiber" -> r.dietaryFiber?.inGrams
                "dietarySugar" -> r.sugar?.inGrams
                "dietaryFat" -> r.totalFat?.inGrams
                "dietaryProtein" -> r.protein?.inGrams
                "dietaryCaffeine" -> r.caffeine?.inMilligrams
                "dietarySodium" -> r.sodium?.inGrams
                else -> null
            }
            is HeartRateRecord -> {
                // A series record: one canonical sample per point.
                return r.samples.mapIndexedNotNull { i, p ->
                    sample(p.beatsPerMinute.toDouble(), "${r.metadata.id}#$i", p.time, p.time)
                }
            }
            else -> null
        }
        return listOfNotNull(sample(one))
    }

    /**
     * Start/end of a record. IntervalRecord/InstantaneousRecord are internal in
     * connect-client 1.1.0, so match the concrete classes this plugin reads.
     */
    private fun timeSpan(r: Record): Pair<Instant, Instant>? = when (r) {
        is StepsRecord -> r.startTime to r.endTime
        is DistanceRecord -> r.startTime to r.endTime
        is ActiveCaloriesBurnedRecord -> r.startTime to r.endTime
        is FloorsClimbedRecord -> r.startTime to r.endTime
        is ExerciseSessionRecord -> r.startTime to r.endTime
        is HeartRateRecord -> r.startTime to r.endTime
        is HydrationRecord -> r.startTime to r.endTime
        is NutritionRecord -> r.startTime to r.endTime
        is SleepSessionRecord -> r.startTime to r.endTime
        is HeightRecord -> r.time to r.time
        is WeightRecord -> r.time to r.time
        is BodyFatRecord -> r.time to r.time
        is LeanBodyMassRecord -> r.time to r.time
        is RestingHeartRateRecord -> r.time to r.time
        is HeartRateVariabilityRmssdRecord -> r.time to r.time
        is BloodPressureRecord -> r.time to r.time
        is RespiratoryRateRecord -> r.time to r.time
        is OxygenSaturationRecord -> r.time to r.time
        is BodyTemperatureRecord -> r.time to r.time
        is BloodGlucoseRecord -> r.time to r.time
        else -> null
    }

    /** Package → app label. Concurrent: filled from Dispatchers.Default workers. */
    private val labelCache = ConcurrentHashMap<String, String>()

    private fun sourceName(pkg: String): String = labelCache.getOrPut(pkg) {
        try {
            val pm = context.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) { pkg }
    }

    private fun range(call: MethodCall): Pair<Instant, Instant> =
        Instant.ofEpochMilli(call.argument<Number>("start")!!.toLong()) to
            Instant.ofEpochMilli(call.argument<Number>("end")!!.toLong())

    private suspend fun <T : Record> readAll(cls: KClass<T>, start: Instant, end: Instant): List<T> {
        val out = mutableListOf<T>()
        var token: String? = null
        do {
            val response = client.readRecords(
                ReadRecordsRequest(
                    recordType = cls,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    ascendingOrder = true,
                    pageSize = 1000,
                    pageToken = token,
                )
            )
            out += response.records
            token = response.pageToken
        } while (token != null)
        return out
    }

    // ------------------------------------------------------------------ Queries

    private suspend fun quantity(call: MethodCall): List<Map<String, Any?>> {
        val type = call.argument<String>("type")!!
        val cls = recordClass(type)
        if (cls == null || type == "sleep" || type == "workouts") throw Unsupported(type)
        val (start, end) = range(call)
        return readAll(cls, start, end)
            .flatMap { toSamples(type, it) }
            .sortedBy { it["start"] as Long }
    }

    private suspend fun sleep(call: MethodCall): List<Map<String, Any?>> {
        val (start, end) = range(call)
        val out = mutableListOf<Map<String, Any?>>()
        for (session in readAll(SleepSessionRecord::class, start, end)) {
            val pkg = session.metadata.dataOrigin.packageName
            fun add(id: String, stage: String, s: Instant, e: Instant) = out.add(mapOf(
                "id" to id, "stage" to stage,
                "start" to s.toEpochMilli(), "end" to e.toEpochMilli(),
                "sourceName" to sourceName(pkg), "sourceId" to pkg,
            ))
            if (session.stages.isEmpty()) {
                add(session.metadata.id, "asleep", session.startTime, session.endTime)
            } else {
                session.stages.forEachIndexed { i, st ->
                    add("${session.metadata.id}#$i", sleepStage(st.stage), st.startTime, st.endTime)
                }
            }
        }
        return out
    }

    private fun sleepStage(stage: Int): String = when (stage) {
        SleepSessionRecord.STAGE_TYPE_DEEP -> "deep"
        SleepSessionRecord.STAGE_TYPE_REM -> "rem"
        SleepSessionRecord.STAGE_TYPE_LIGHT -> "core"
        SleepSessionRecord.STAGE_TYPE_SLEEPING -> "asleep"
        SleepSessionRecord.STAGE_TYPE_AWAKE,
        SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED,
        SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> "awake"
        else -> "unknown"
    }

    /**
     * Sessions plus totals in at most 4 Health Connect reads (one per record
     * type, more only if a type spans several 1000-record pages), instead of
     * one aggregate() per session. Totals are attributed by time overlap,
     * preferring records from the session's own app.
     */
    private suspend fun workouts(call: MethodCall): List<Map<String, Any?>> {
        val (start, end) = range(call)
        val sessions = readAll(ExerciseSessionRecord::class, start, end)
        if (sessions.isEmpty()) return emptyList()
        val from = sessions.minOf { it.startTime }
        val to = sessions.maxOf { it.endTime }

        // Each read needs its own permission; a missing one leaves only that field null.
        suspend fun <T> optional(read: suspend () -> List<T>): List<T>? =
            try { read() } catch (_: SecurityException) { null }

        val calories = optional {
            readAll(ActiveCaloriesBurnedRecord::class, from, to).map {
                WorkoutTotals.Interval(it.startTime.toEpochMilli(), it.endTime.toEpochMilli(),
                    it.energy.inKilocalories, it.metadata.dataOrigin.packageName)
            }
        }
        val distances = optional {
            readAll(DistanceRecord::class, from, to).map {
                WorkoutTotals.Interval(it.startTime.toEpochMilli(), it.endTime.toEpochMilli(),
                    it.distance.inMeters, it.metadata.dataOrigin.packageName)
            }
        }
        val heartRates = optional {
            readAll(HeartRateRecord::class, from, to).flatMap { r ->
                val pkg = r.metadata.dataOrigin.packageName
                r.samples.map { WorkoutTotals.Point(it.time.toEpochMilli(), it.beatsPerMinute.toDouble(), pkg) }
            }
        }

        return withContext(Dispatchers.Default) {
            sessions.map { w ->
                val s = w.startTime.toEpochMilli()
                val e = w.endTime.toEpochMilli()
                val pkg = w.metadata.dataOrigin.packageName
                val energy = calories?.let { WorkoutTotals.sum(it, s, e, pkg) }
                val distance = distances?.let { WorkoutTotals.sum(it, s, e, pkg) }
                val hr = heartRates?.let { WorkoutTotals.mean(it, s, e, pkg) }
                mapOf(
                    "id" to w.metadata.id,
                    "activityType" to exerciseName(w.exerciseType),
                    "start" to s,
                    "end" to e,
                    "sourceName" to sourceName(pkg),
                    "energyBurned" to energy?.value,
                    "distance" to distance?.value,
                    "averageHeartRate" to hr?.value,
                    "totalsSource" to WorkoutTotals.label(energy, distance, hr),
                )
            }
        }
    }

    private fun exerciseName(type: Int): String = when (type) {
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING,
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL -> "running"
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING,
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY -> "cycling"
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL,
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER -> "swimming"
        ExerciseSessionRecord.EXERCISE_TYPE_WALKING -> "walking"
        ExerciseSessionRecord.EXERCISE_TYPE_HIKING -> "hiking"
        ExerciseSessionRecord.EXERCISE_TYPE_YOGA -> "yoga"
        ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING,
        ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING -> "strengthTraining"
        ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING -> "highIntensityIntervalTraining"
        ExerciseSessionRecord.EXERCISE_TYPE_DANCING -> "dance"
        ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL -> "elliptical"
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING,
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE -> "rowing"
        ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING -> "stairClimbing"
        ExerciseSessionRecord.EXERCISE_TYPE_TENNIS -> "tennis"
        ExerciseSessionRecord.EXERCISE_TYPE_SOCCER -> "soccer"
        ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL -> "basketball"
        ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL -> "baseball"
        ExerciseSessionRecord.EXERCISE_TYPE_GOLF -> "golf"
        ExerciseSessionRecord.EXERCISE_TYPE_PILATES -> "pilates"
        ExerciseSessionRecord.EXERCISE_TYPE_BOXING -> "boxing"
        ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS -> "martialArts"
        else -> "other"
    }

    // -------------------------------------------------------------- Statistics

    /** Platform aggregate (de-duplicated across apps) for a type/option, if any. */
    private fun metric(type: String, option: String): AggregateMetric<*>? = when (type to option) {
        "steps" to "sum" -> StepsRecord.COUNT_TOTAL
        "distanceWalkingRunning" to "sum" -> DistanceRecord.DISTANCE_TOTAL
        "activeEnergyBurned" to "sum" -> ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL
        "flightsClimbed" to "sum" -> FloorsClimbedRecord.FLOORS_CLIMBED_TOTAL
        "exerciseTime" to "sum" -> ExerciseSessionRecord.EXERCISE_DURATION_TOTAL
        "heartRate" to "average" -> HeartRateRecord.BPM_AVG
        "heartRate" to "minimum" -> HeartRateRecord.BPM_MIN
        "heartRate" to "maximum" -> HeartRateRecord.BPM_MAX
        "restingHeartRate" to "average" -> RestingHeartRateRecord.BPM_AVG
        "restingHeartRate" to "minimum" -> RestingHeartRateRecord.BPM_MIN
        "restingHeartRate" to "maximum" -> RestingHeartRateRecord.BPM_MAX
        "weight" to "average" -> WeightRecord.WEIGHT_AVG
        "weight" to "minimum" -> WeightRecord.WEIGHT_MIN
        "weight" to "maximum" -> WeightRecord.WEIGHT_MAX
        "dietaryWater" to "sum" -> HydrationRecord.VOLUME_TOTAL
        "dietaryEnergy" to "sum" -> NutritionRecord.ENERGY_TOTAL
        "dietaryProtein" to "sum" -> NutritionRecord.PROTEIN_TOTAL
        else -> null // Dart computes it from raw samples
    }

    private fun canonical(v: Any?): Double? = when (v) {
        null -> null
        is Long -> v.toDouble()
        is Double -> v
        is Length -> v.inMeters
        is Energy -> v.inKilocalories
        is Mass -> v.inKilograms // weight (protein is handled below)
        is Volume -> v.inMilliliters
        is Duration -> v.seconds / 60.0
        else -> null
    }

    private fun canonical(type: String, v: Any?): Double? =
        if (type == "dietaryProtein" && v is Mass) v.inGrams else canonical(v)

    /**
     * Whether the active-calories fallback (total − basal) may run: only
     * activeEnergyBurned/sum, and only with both extra read permissions.
     */
    private suspend fun canDeriveActive(type: String, option: String): Boolean =
        type == "activeEnergyBurned" && option == "sum" &&
            client.permissionController.getGrantedPermissions().containsAll(DERIVED_ACTIVE_PERMISSIONS)

    /** total − basal, clamped at 0; null unless both are present. */
    private fun derivedActive(total: Energy?, basal: Energy?): Double? =
        if (total == null || basal == null) null
        else maxOf(0.0, total.inKilocalories - basal.inKilocalories)

    private suspend fun statistics(call: MethodCall): Map<String, Any?> {
        val type = call.argument<String>("type")!!
        val option = call.argument<String>("option")!!
        @Suppress("UNCHECKED_CAST")
        val m = metric(type, option) as AggregateMetric<Any>?
            ?: return mapOf("supported" to false)
        val (start, end) = range(call)
        val filter = TimeRangeFilter.between(start, end)
        val value = canonical(type, client.aggregate(AggregateRequest(setOf(m), filter))[m])
        if (value == null && canDeriveActive(type, option)) {
            val r = client.aggregate(AggregateRequest(
                setOf(TotalCaloriesBurnedRecord.ENERGY_TOTAL, BasalMetabolicRateRecord.BASAL_CALORIES_TOTAL),
                filter,
            ))
            val derived = derivedActive(
                r[TotalCaloriesBurnedRecord.ENERGY_TOTAL], r[BasalMetabolicRateRecord.BASAL_CALORIES_TOTAL])
            if (derived != null) return mapOf("supported" to true, "value" to derived, "derived" to true)
        }
        return mapOf("supported" to true, "value" to value)
    }

    private suspend fun dailyStatistics(call: MethodCall): Map<String, Any?> {
        val type = call.argument<String>("type")!!
        @Suppress("UNCHECKED_CAST")
        val m = metric(type, call.argument<String>("option")!!) as AggregateMetric<Any>?
            ?: return mapOf("supported" to false)
        val (start, end) = range(call)
        val zone = ZoneId.systemDefault()
        val localStart = LocalDateTime.ofInstant(start, zone).toLocalDate().atStartOfDay()
        val localEnd = LocalDateTime.ofInstant(end, zone)
        val filter = TimeRangeFilter.between(localStart, localEnd)
        val groups = client.aggregateGroupByPeriod(AggregateGroupByPeriodRequest(
            metrics = setOf(m),
            timeRangeFilter = filter,
            timeRangeSlicer = Period.ofDays(1),
        ))
        val buckets = linkedMapOf<Long, Map<String, Any?>>()
        for (g in groups) {
            val date = g.startTime.atZone(zone).toInstant().toEpochMilli()
            buckets[date] = mapOf("date" to date, "value" to canonical(type, g.result[m]))
        }
        // Fill days without active calories from total − basal (one extra call).
        val option = call.argument<String>("option")!!
        val hasGaps = buckets.isEmpty() || buckets.values.any { it["value"] == null }
        if (hasGaps && canDeriveActive(type, option)) {
            val fallback = client.aggregateGroupByPeriod(AggregateGroupByPeriodRequest(
                metrics = setOf(TotalCaloriesBurnedRecord.ENERGY_TOTAL, BasalMetabolicRateRecord.BASAL_CALORIES_TOTAL),
                timeRangeFilter = filter,
                timeRangeSlicer = Period.ofDays(1),
            ))
            for (g in fallback) {
                val date = g.startTime.atZone(zone).toInstant().toEpochMilli()
                if (buckets[date]?.get("value") != null) continue
                val derived = derivedActive(
                    g.result[TotalCaloriesBurnedRecord.ENERGY_TOTAL],
                    g.result[BasalMetabolicRateRecord.BASAL_CALORIES_TOTAL],
                ) ?: continue
                buckets[date] = mapOf("date" to date, "value" to derived, "derived" to true)
            }
        }
        return mapOf("supported" to true, "buckets" to buckets.values.sortedBy { it["date"] as Long })
    }

    // ------------------------------------------------------------ Incremental sync

    private suspend fun changes(call: MethodCall): Map<String, Any?> {
        val type = call.argument<String>("type")!!
        val cls = recordClass(type) ?: throw Unsupported(type)
        val anchor = call.argument<String>("anchor")
            ?: return mapOf(
                "added" to emptyList<Any>(), "deleted" to emptyList<Any>(),
                "anchor" to client.getChangesToken(ChangesTokenRequest(setOf(cls))),
                "hasMore" to false,
            )
        val response = client.getChanges(anchor)
        if (response.changesTokenExpired) throw AnchorExpired()
        val added = mutableListOf<Map<String, Any?>>()
        val deleted = mutableListOf<String>()
        for (change in response.changes) {
            when (change) {
                is UpsertionChange -> added += toSamples(type, change.record)
                is DeletionChange -> deleted += change.recordId
            }
        }
        return mapOf(
            "added" to added, "deleted" to deleted,
            "anchor" to response.nextChangesToken, "hasMore" to response.hasMore,
        )
    }

    // ------------------------------------------------------------------ Writing

    private suspend fun writeQuantity(call: MethodCall) {
        val type = call.argument<String>("type")!!
        val value = call.argument<Number>("value")!!.toDouble()
        val (start, rawEnd) = range(call)
        val end = if (rawEnd.isAfter(start)) rawEnd else start.plusSeconds(1)
        val offset = ZoneId.systemDefault().rules.getOffset(start)
        val endOffset = ZoneId.systemDefault().rules.getOffset(end)
        val record: Record = when (type) {
            "steps" -> StepsRecord(
                startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = endOffset,
                count = value.toLong(), metadata = Metadata.manualEntry())
            "activeEnergyBurned" -> ActiveCaloriesBurnedRecord(
                startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = endOffset,
                energy = Energy.kilocalories(value), metadata = Metadata.manualEntry())
            "dietaryWater" -> HydrationRecord(
                startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = endOffset,
                volume = Volume.milliliters(value), metadata = Metadata.manualEntry())
            "weight" -> WeightRecord(
                time = start, zoneOffset = offset,
                weight = Mass.kilograms(value), metadata = Metadata.manualEntry())
            else -> throw Unsupported(type)
        }
        client.insertRecords(listOf(record))
    }

    companion object {
        private const val AUTH_REQUEST_CODE = 0x4EA1

        /** Sentinel for unknown methods, so notImplemented() is sent on Main. */
        private val NOT_IMPLEMENTED = Any()

        /** Read permissions for deriving active calories as total − basal. */
        private val DERIVED_ACTIVE_PERMISSIONS = setOf(
            HealthPermission.getReadPermission(TotalCaloriesBurnedRecord::class),
            HealthPermission.getReadPermission(BasalMetabolicRateRecord::class),
        )

        /** Every type name Health Connect can serve (each has a record class). */
        private val SUPPORTED_TYPES = listOf(
            "steps", "distanceWalkingRunning", "activeEnergyBurned", "flightsClimbed",
            "exerciseTime", "workouts", "height", "weight", "bodyFatPercentage",
            "leanBodyMass", "heartRate", "restingHeartRate", "heartRateVariabilityRMSSD",
            "bloodPressureSystolic", "bloodPressureDiastolic", "respiratoryRate",
            "oxygenSaturation", "bodyTemperature", "bloodGlucose", "dietaryWater",
            "dietaryEnergy", "dietaryCarbohydrates", "dietaryFiber", "dietarySugar",
            "dietaryFat", "dietaryProtein", "dietaryCaffeine", "dietarySodium", "sleep",
        )
    }
}
