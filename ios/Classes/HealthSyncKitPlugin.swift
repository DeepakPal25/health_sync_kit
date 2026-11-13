import Flutter
import HealthKit
import UIKit

/// iOS side of health_sync_kit: HealthKit behind the `health_sync_kit` channel.
///
/// Ported from HealthSyncKit's HealthKitMapper / Queries, with these fixes:
/// - percent types (SpO2, body fat) are returned as 0–100, not HealthKit's 0–1
/// - `inBed` is reported as its own stage instead of "asleep"
/// - statistics are bucketed per day with HKStatisticsCollectionQuery, which
///   de-duplicates iPhone + Apple Watch
/// - anchored queries for incremental sync
public final class HealthSyncKitPlugin: NSObject, FlutterPlugin {

    private let store = HKHealthStore()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "health_sync_kit",
                                           binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(HealthSyncKitPlugin(), channel: channel)
    }

    // MARK: - Dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }

        if call.method == "availability" {
            result(HKHealthStore.isHealthDataAvailable() ? "available" : "unsupported")
            return
        }
        if call.method == "supportedTypes" {
            // RMSSD has no HealthKit type, so it is never listed.
            result(Array(Self.quantityIds.keys).sorted() + ["sleep", "workouts"])
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            result(FlutterError(code: "notAvailable", message: "HealthKit is not available",
                                details: ["reason": "unsupported"]))
            return
        }

        switch call.method {
        case "requestAuthorization": requestAuthorization(args, reply)
        case "authorizationStatus": authorizationStatus(args, reply)
        case "quantity": quantity(args, reply)
        case "sleep": sleep(args, reply)
        case "workouts": workouts(args, reply)
        case "statistics": statistics(args, reply)
        case "dailyStatistics": dailyStatistics(args, reply)
        case "changes": changes(args, reply)
        case "writeQuantity": writeQuantity(args, reply)
        case "openSettings":
            let health = URL(string: "x-apple-health://")!
            let target = UIApplication.shared.canOpenURL(health)
                ? health : URL(string: UIApplication.openSettingsURLString)!
            UIApplication.shared.open(target)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Authorization

    private func requestAuthorization(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        let readNames = args["read"] as? [String] ?? []
        let writeNames = args["write"] as? [String] ?? []
        let read = Set(readNames.compactMap(Self.objectType))
        let write = Set(writeNames.compactMap(Self.sampleType))

        store.requestAuthorization(toShare: write, read: read) { [weak self] _, error in
            guard let self else { return }
            if let error {
                reply(FlutterError(code: "queryFailed", message: error.localizedDescription, details: nil))
                return
            }
            var statuses: [String: String] = [:]
            for name in Set(readNames + writeNames) {
                statuses[name] = self.status(for: name, requestedWrite: writeNames.contains(name))
            }
            reply(statuses)
        }
    }

    private func authorizationStatus(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        let name = args["type"] as? String ?? ""
        reply(status(for: name, requestedWrite: false))
    }

    /// HealthKit only reveals *write* status. Read access is deliberately
    /// hidden: once the prompt has been shown we can only say "unknown".
    private func status(for name: String, requestedWrite: Bool) -> String {
        guard let type = Self.objectType(name) else { return "unsupported" }
        let share = store.authorizationStatus(for: type)
        switch share {
        case .sharingAuthorized: return "authorized"
        case .sharingDenied: return requestedWrite ? "denied" : "unknown"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Quantity

    private func quantity(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        guard let name = args["type"] as? String, let type = Self.quantityType(name) else {
            reply(Self.unsupported(args["type"])); return
        }
        let unit = Self.unit(for: name)
        let scale = Self.scale(for: name)
        let predicate = HKQuery.predicateForSamples(withStart: Self.date(args["start"]),
                                                    end: Self.date(args["end"]),
                                                    options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
            if let error { reply(Self.queryFailed(error)); return }
            reply((samples as? [HKQuantitySample] ?? []).map {
                Self.encode($0, unit: unit, scale: scale)
            })
        }
        store.execute(query)
    }

    private static func encode(_ s: HKQuantitySample, unit: HKUnit, scale: Double) -> [String: Any] {
        var m: [String: Any] = [
            "id": s.uuid.uuidString,
            "value": s.quantity.doubleValue(for: unit) * scale,
            "start": ms(s.startDate),
            "end": ms(s.endDate),
            "sourceName": s.sourceRevision.source.name,
            "sourceId": s.sourceRevision.source.bundleIdentifier,
        ]
        if let model = s.device?.model { m["device"] = model }
        return m
    }

    // MARK: - Sleep

    private func sleep(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            reply(Self.unsupported("sleep")); return
        }
        // Overlap predicate: a night that began before `start` is included.
        let predicate = HKQuery.predicateForSamples(withStart: Self.date(args["start"]),
                                                    end: Self.date(args["end"]), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
            if let error { reply(Self.queryFailed(error)); return }
            reply((samples as? [HKCategorySample] ?? []).map { s -> [String: Any] in
                [
                    "id": s.uuid.uuidString,
                    "stage": Self.sleepStage(s.value),
                    "start": Self.ms(s.startDate),
                    "end": Self.ms(s.endDate),
                    "sourceName": s.sourceRevision.source.name,
                    "sourceId": s.sourceRevision.source.bundleIdentifier,
                ]
            })
        }
        store.execute(query)
    }

    private static func sleepStage(_ value: Int) -> String {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: value) else { return "unknown" }
        if #available(iOS 16.0, *) {
            switch v {
            case .asleepCore: return "core"
            case .asleepDeep: return "deep"
            case .asleepREM: return "rem"
            default: break
            }
        }
        switch v {
        case .inBed: return "inBed"
        case .awake: return "awake"
        default: return "asleep" // asleep / asleepUnspecified
        }
    }

    // MARK: - Workouts

    private func workouts(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: Self.date(args["start"]),
                                                    end: Self.date(args["end"]),
                                                    options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
            if let error { reply(Self.queryFailed(error)); return }
            reply((samples as? [HKWorkout] ?? []).map(Self.encodeWorkout))
        }
        store.execute(query)
    }

    private static func encodeWorkout(_ w: HKWorkout) -> [String: Any] {
        var m: [String: Any] = [
            "id": w.uuid.uuidString,
            "activityType": activityName(w.workoutActivityType),
            "start": ms(w.startDate),
            "end": ms(w.endDate),
            "sourceName": w.sourceRevision.source.name,
        ]
        if #available(iOS 16.0, *) {
            if let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
                m["energyBurned"] = energy.doubleValue(for: .kilocalorie())
            }
            let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
            for id in distanceTypes {
                if let d = w.statistics(for: HKQuantityType(id))?.sumQuantity() {
                    m["distance"] = d.doubleValue(for: .meter()); break
                }
            }
            if let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity() {
                m["averageHeartRate"] = hr.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            }
        } else {
            if let e = w.totalEnergyBurned { m["energyBurned"] = e.doubleValue(for: .kilocalorie()) }
            if let d = w.totalDistance { m["distance"] = d.doubleValue(for: .meter()) }
        }
        // A workout's statistics come from its own associated samples.
        if m["energyBurned"] != nil || m["distance"] != nil || m["averageHeartRate"] != nil {
            m["totalsSource"] = "sameApp"
        }
        return m
    }

    private static func activityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "running"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .walking: return "walking"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "strengthTraining"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .crossTraining: return "crossTraining"
        case .socialDance, .cardioDance: return "dance"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing, .stairs, .stepTraining: return "stairClimbing"
        case .tennis, .tableTennis: return "tennis"
        case .soccer: return "soccer"
        case .basketball: return "basketball"
        case .baseball, .softball: return "baseball"
        case .golf: return "golf"
        case .pilates: return "pilates"
        case .barre: return "barre"
        case .kickboxing: return "kickboxing"
        case .boxing: return "boxing"
        case .martialArts: return "martialArts"
        case .mindAndBody, .taiChi: return "mindAndBody"
        default: return "other"
        }
    }

    // MARK: - Statistics

    private static func statisticsOptions(_ option: String, cumulative: Bool) -> HKStatisticsOptions? {
        switch (option, cumulative) {
        case ("sum", true): return .cumulativeSum
        case ("average", false): return .discreteAverage
        case ("minimum", false): return .discreteMin
        case ("maximum", false): return .discreteMax
        case ("mostRecent", _): return .mostRecent
        default: return nil // e.g. "average" of steps: let Dart compute it
        }
    }

    private static func value(of stats: HKStatistics?, option: String, unit: HKUnit, scale: Double) -> Double? {
        let q: HKQuantity?
        switch option {
        case "sum": q = stats?.sumQuantity()
        case "average": q = stats?.averageQuantity()
        case "minimum": q = stats?.minimumQuantity()
        case "maximum": q = stats?.maximumQuantity()
        case "mostRecent": q = stats?.mostRecentQuantity()
        default: q = nil
        }
        return q.map { $0.doubleValue(for: unit) * scale }
    }

    private func statistics(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        guard let name = args["type"] as? String, let type = Self.quantityType(name),
              let option = args["option"] as? String else { reply(["supported": false]); return }
        guard let options = Self.statisticsOptions(option, cumulative: type.aggregationStyle == .cumulative) else {
            reply(["supported": false]); return
        }
        let unit = Self.unit(for: name), scale = Self.scale(for: name)
        let predicate = HKQuery.predicateForSamples(withStart: Self.date(args["start"]),
                                                    end: Self.date(args["end"]), options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: options) { _, stats, error in
            if let error, !Self.isNoData(error) {
                reply(Self.queryFailed(error)); return
            }
            var out: [String: Any] = ["supported": true]
            if let v = Self.value(of: stats, option: option, unit: unit, scale: scale) { out["value"] = v }
            reply(out)
        }
        store.execute(query)
    }

    private func dailyStatistics(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        guard let name = args["type"] as? String, let type = Self.quantityType(name),
              let option = args["option"] as? String else { reply(["supported": false]); return }
        guard let options = Self.statisticsOptions(option, cumulative: type.aggregationStyle == .cumulative) else {
            reply(["supported": false]); return
        }
        let start = Self.date(args["start"]), end = Self.date(args["end"])
        let unit = Self.unit(for: name), scale = Self.scale(for: name)
        let anchor = Calendar.current.startOfDay(for: start)
        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: anchor, end: end, options: .strictStartDate),
            options: options,
            anchorDate: anchor,
            intervalComponents: DateComponents(day: 1))
        query.initialResultsHandler = { _, collection, error in
            if let error, !Self.isNoData(error) {
                reply(Self.queryFailed(error)); return
            }
            var buckets: [[String: Any]] = []
            collection?.enumerateStatistics(from: anchor, to: end) { stats, _ in
                var b: [String: Any] = ["date": Self.ms(stats.startDate)]
                if let v = Self.value(of: stats, option: option, unit: unit, scale: scale) { b["value"] = v }
                buckets.append(b)
            }
            reply(["supported": true, "buckets": buckets])
        }
        store.execute(query)
    }

    // MARK: - Incremental sync

    private func changes(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        guard let name = args["type"] as? String, let type = Self.quantityType(name) else {
            reply(Self.unsupported(args["type"])); return
        }
        var anchor: HKQueryAnchor?
        var predicate: NSPredicate?
        if let encoded = args["anchor"] as? String {
            guard let data = Data(base64Encoded: encoded),
                  let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else {
                reply(FlutterError(code: "anchorExpired", message: "Invalid sync anchor", details: nil)); return
            }
            anchor = decoded
        } else {
            // First sync: only fetch the current anchor, not the whole history.
            predicate = HKQuery.predicateForSamples(withStart: Date.distantFuture, end: nil, options: [])
        }
        let unit = Self.unit(for: name), scale = Self.scale(for: name)
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor,
                                          limit: 5000) { _, samples, deleted, newAnchor, error in
            if let error { reply(Self.queryFailed(error)); return }
            let encoded = newAnchor.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }?.base64EncodedString() ?? ""
            let added = (samples as? [HKQuantitySample] ?? []).map { Self.encode($0, unit: unit, scale: scale) }
            reply([
                "added": added,
                "deleted": (deleted ?? []).map { $0.uuid.uuidString },
                "anchor": encoded,
                "hasMore": (samples?.count ?? 0) >= 5000,
            ])
        }
        store.execute(query)
    }

    // MARK: - Writing

    private func writeQuantity(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
        guard let name = args["type"] as? String, let type = Self.quantityType(name),
              let value = args["value"] as? Double else {
            reply(Self.unsupported(args["type"])); return
        }
        let quantity = HKQuantity(unit: Self.unit(for: name), doubleValue: value / Self.scale(for: name))
        let sample = HKQuantitySample(type: type, quantity: quantity,
                                      start: Self.date(args["start"]), end: Self.date(args["end"]))
        store.save(sample) { _, error in
            if let error {
                let denied = (error as? HKError)?.code == .errorAuthorizationDenied
                reply(FlutterError(code: denied ? "denied" : "queryFailed",
                                   message: error.localizedDescription, details: ["type": name]))
            } else {
                reply(nil)
            }
        }
    }

    // MARK: - Type & unit mapping

    private static let quantityIds: [String: HKQuantityTypeIdentifier] = [
        "steps": .stepCount,
        "distanceWalkingRunning": .distanceWalkingRunning,
        "distanceCycling": .distanceCycling,
        "activeEnergyBurned": .activeEnergyBurned,
        "basalEnergyBurned": .basalEnergyBurned,
        "flightsClimbed": .flightsClimbed,
        "exerciseTime": .appleExerciseTime,
        "standTime": .appleStandTime,
        "height": .height,
        "weight": .bodyMass,
        "bodyMassIndex": .bodyMassIndex,
        "bodyFatPercentage": .bodyFatPercentage,
        "leanBodyMass": .leanBodyMass,
        "waistCircumference": .waistCircumference,
        "heartRate": .heartRate,
        "restingHeartRate": .restingHeartRate,
        "walkingHeartRateAverage": .walkingHeartRateAverage,
        "heartRateVariabilitySDNN": .heartRateVariabilitySDNN,
        "bloodPressureSystolic": .bloodPressureSystolic,
        "bloodPressureDiastolic": .bloodPressureDiastolic,
        "respiratoryRate": .respiratoryRate,
        "oxygenSaturation": .oxygenSaturation,
        "bodyTemperature": .bodyTemperature,
        "bloodGlucose": .bloodGlucose,
        "dietaryEnergy": .dietaryEnergyConsumed,
        "dietaryCarbohydrates": .dietaryCarbohydrates,
        "dietaryFiber": .dietaryFiber,
        "dietarySugar": .dietarySugar,
        "dietaryFat": .dietaryFatTotal,
        "dietaryProtein": .dietaryProtein,
        "dietaryWater": .dietaryWater,
        "dietaryCaffeine": .dietaryCaffeine,
        "dietarySodium": .dietarySodium,
    ]

    private static func quantityType(_ name: String) -> HKQuantityType? {
        quantityIds[name].flatMap { HKObjectType.quantityType(forIdentifier: $0) }
    }

    private static func objectType(_ name: String) -> HKObjectType? {
        switch name {
        case "sleep": return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case "workouts": return HKObjectType.workoutType()
        default: return quantityType(name)
        }
    }

    private static func sampleType(_ name: String) -> HKSampleType? {
        objectType(name) as? HKSampleType
    }

    private static func unit(for name: String) -> HKUnit {
        switch name {
        case "steps", "flightsClimbed", "bodyMassIndex": return .count()
        case "distanceWalkingRunning", "distanceCycling": return .meter()
        case "activeEnergyBurned", "basalEnergyBurned", "dietaryEnergy": return .kilocalorie()
        case "exerciseTime", "standTime": return .minute()
        case "height", "waistCircumference": return .meterUnit(with: .centi)
        case "weight", "leanBodyMass": return .gramUnit(with: .kilo)
        case "bodyFatPercentage", "oxygenSaturation": return .percent()
        case "heartRate", "restingHeartRate", "walkingHeartRateAverage", "respiratoryRate":
            return HKUnit.count().unitDivided(by: .minute())
        case "heartRateVariabilitySDNN": return .secondUnit(with: .milli)
        case "bloodPressureSystolic", "bloodPressureDiastolic": return .millimeterOfMercury()
        case "bodyTemperature": return .degreeCelsius()
        case "bloodGlucose": return HKUnit(from: "mg/dL")
        case "dietaryWater": return .literUnit(with: .milli)
        case "dietaryCaffeine": return .gramUnit(with: .milli)
        default: return .gram() // carbs, fiber, sugar, fat, protein, sodium
        }
    }

    /// HealthKit stores percentages as fractions (0.97); Dart gets 97.
    private static func scale(for name: String) -> Double {
        name == "bodyFatPercentage" || name == "oxygenSaturation" ? 100 : 1
    }

    // MARK: - Helpers

    private static func date(_ v: Any?) -> Date {
        Date(timeIntervalSince1970: ((v as? NSNumber)?.doubleValue ?? 0) / 1000)
    }

    private static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    private static func queryFailed(_ error: Error) -> FlutterError {
        let denied = (error as? HKError)?.code == .errorAuthorizationDenied
        return FlutterError(code: denied ? "denied" : "queryFailed",
                            message: error.localizedDescription, details: nil)
    }

    /// "No data" is an empty result, not a failure. `errorNoData` is iOS 14+
    /// API; iOS 13 reports an empty range as nil statistics without an error.
    private static func isNoData(_ error: Error) -> Bool {
        if #available(iOS 14.0, *) {
            return (error as? HKError)?.code == .errorNoData
        }
        return false
    }

    private static func unsupported(_ type: Any?) -> FlutterError {
        FlutterError(code: "unsupported", message: "Unsupported data type",
                     details: ["type": type as Any])
    }
}
