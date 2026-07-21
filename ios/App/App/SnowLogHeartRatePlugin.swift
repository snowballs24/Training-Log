import Capacitor
import HealthKit

@objc(SnowLogHeartRatePlugin)
final class SnowLogHeartRatePlugin: CAPInstancePlugin, CAPBridgedPlugin {
    let identifier = "SnowLogHeartRatePlugin"
    let jsName = "SnowLogHeartRate"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "requestAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startMonitoring", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopMonitoring", returnType: CAPPluginReturnPromise)
    ]

    private let healthStore = HKHealthStore()
    private let staleInterval: TimeInterval = 10 * 60
    private var observerQuery: HKObserverQuery?
    private var staleWorkItem: DispatchWorkItem?

    private var heartRateType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .heartRate)
    }

    @objc func requestAuthorization(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable(), let heartRateType else {
            call.resolve(["enabled": false])
            return
        }

        // SnowLog requests read access to heart rate only. The empty share set is
        // intentional: this plugin never creates workouts or writes health data.
        healthStore.requestAuthorization(toShare: [], read: [heartRateType]) { [weak self] success, _ in
            guard success, let self else {
                call.resolve(["enabled": false])
                return
            }

            // HealthKit intentionally doesn't disclose read-denial status. A
            // readable historical sample is the safest positive confirmation;
            // otherwise the web setting remains off and no value is shown.
            self.checkForReadableHeartRateSample { readable in
                call.resolve(["enabled": readable])
            }
        }
    }

    @objc func startMonitoring(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable(), let heartRateType else {
            publishUnavailable()
            call.resolve()
            return
        }

        if observerQuery == nil {
            let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completion, _ in
                self?.queryLatestHeartRate()
                completion()
            }
            observerQuery = query
            healthStore.execute(query)
        }

        queryLatestHeartRate()
        call.resolve()
    }

    @objc func stopMonitoring(_ call: CAPPluginCall) {
        stopMonitoring()
        call.resolve()
    }

    deinit {
        stopMonitoring()
    }

    private func stopMonitoring() {
        if let observerQuery {
            healthStore.stop(observerQuery)
            self.observerQuery = nil
        }
        staleWorkItem?.cancel()
        staleWorkItem = nil
        publishUnavailable()
    }

    private func checkForReadableHeartRateSample(completion: @escaping (Bool) -> Void) {
        guard let heartRateType else {
            completion(false)
            return
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sort]
        ) { _, samples, _ in
            completion((samples as? [HKQuantitySample])?.isEmpty == false)
        }
        healthStore.execute(query)
    }

    private func queryLatestHeartRate() {
        guard let heartRateType else {
            publishUnavailable()
            return
        }

        let now = Date()
        let start = now.addingTimeInterval(-staleInterval)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictEndDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: predicate,
            limit: 50,
            sortDescriptors: [sort]
        ) { [weak self] _, samples, _ in
            guard let self else { return }
            let quantitySamples = (samples as? [HKQuantitySample]) ?? []
            let sample = quantitySamples.first(where: self.isFromAppleWatch) ?? quantitySamples.first
            self.publish(sample: sample, now: now)
        }
        healthStore.execute(query)
    }

    private func isFromAppleWatch(_ sample: HKQuantitySample) -> Bool {
        let productType = sample.sourceRevision.productType?.lowercased() ?? ""
        let sourceName = sample.sourceRevision.source.name.lowercased()
        let deviceName = sample.device?.name?.lowercased() ?? ""
        return productType.hasPrefix("watch") || sourceName.contains("watch") || deviceName.contains("watch")
    }

    private func publish(sample: HKQuantitySample?, now: Date) {
        guard let sample else {
            publishUnavailable()
            return
        }

        let age = now.timeIntervalSince(sample.endDate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let value = Int(sample.quantity.doubleValue(for: unit).rounded())
        guard age >= 0, age < staleInterval, (20...250).contains(value) else {
            publishUnavailable()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.staleWorkItem?.cancel()
            self.notifyListeners("heartRateChanged", data: [
                "available": true,
                "value": value,
                "measuredAtMs": sample.endDate.timeIntervalSince1970 * 1_000
            ])

            let workItem = DispatchWorkItem { [weak self] in
                self?.publishUnavailable()
            }
            self.staleWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, self.staleInterval - age),
                execute: workItem
            )
        }
    }

    private func publishUnavailable() {
        DispatchQueue.main.async { [weak self] in
            self?.staleWorkItem?.cancel()
            self?.staleWorkItem = nil
            self?.notifyListeners("heartRateChanged", data: ["available": false])
        }
    }
}
