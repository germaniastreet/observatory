import Foundation
import Combine
import HealthKit

/// Adapter between HealthKit and Observatory's own normalized `BiometricSample`
/// type -- per PROJECT_CONSTRAINTS.md #4 ("every source must enter through a
/// normalized signal/provenance layer; external sources must never feed
/// directly into interpretation logic") and #11 ("no engine should depend on
/// a specific device/vendor unless it is an adapter"), this is that adapter,
/// not a general-purpose HealthKit wrapper. It only ever produces
/// `BiometricSample` values; nothing downstream (ReflectionAnalyzer, the
/// observation engines, any UI) ever touches an `HKSample` directly.
///
/// This is the v117 "Biometric Signal Foundation" milestone from
/// VERSION_HISTORY.txt -- the first source of real biometric evidence for a
/// reflection. Before this, `ReflectionSessionStore` always produced an
/// empty, `.unavailable`-quality `BiometricWindow` for every session (see
/// its doc comments on `startReflection`/`stopAndObserve`); the UI in
/// ReflectionDetailScreen and elsewhere was already built to render real
/// samples, it just never received any.
///
/// Scope: this reads heart rate, heart rate variability (SDNN), and
/// respiratory rate -- the three vitals that already fit `BiometricSample`'s
/// per-timestamp shape. The v117 roadmap entry also lists sleep and workout
/// metrics; those are HealthKit category/workout samples, not point-in-time
/// quantity samples, and don't fit this model without either a second
/// normalized type or a deliberate widening of this one -- see
/// PROJECT_ARCHITECTURE.md section on this adapter. Left for a later,
/// explicitly-scoped version rather than backed into here.
///
/// This is also read-only backfill (queries after the fact), not the live
/// `HKLiveWorkoutBuilder` + Watch path SettingsScreen's "Architecture Notes"
/// card describes -- that requires a companion watchOS target and
/// WatchConnectivity, which don't exist in this iPhone-only build. Backfill
/// is the achievable slice: a person's iPhone Health app already has heart
/// rate data from a paired Watch (or any other source they've connected)
/// without Observatory needing to talk to a Watch itself.
///
/// NOTE (same caveat as SpeakerDiarizationEngine): this is written against
/// HealthKit's documented API without a compiler available in this
/// environment to verify it. If Xcode reports a "has no member" or "cannot
/// find type" error anywhere in this file, the fix is almost certainly a
/// small rename once the real error is visible.
@MainActor
final class HealthKitManager: ObservableObject {
    static let engineVersion = "0.1"

    private let healthStore = HKHealthStore()

    /// True once `requestAuthorization()` has completed without throwing.
    /// This does NOT mean every read type was actually granted -- HealthKit
    /// deliberately never reveals per-type grant/deny status to the
    /// requesting app, to avoid an app being able to infer sensitive
    /// health-data presence or absence from a denial. It means "we asked,
    /// and can proceed to query" -- `fetchSamples` may still legitimately
    /// come back empty if the person declined some or all types.
    @Published private(set) var isAuthorized = false

    /// Set if HealthKit itself isn't available on this device, or the
    /// authorization request threw. Distinct from "the person said no to
    /// some types," which HealthKit doesn't report -- see `isAuthorized`.
    @Published private(set) var authorizationUnavailable = false

    /// False on devices without Health app support (e.g. iPad). Every call
    /// site should check this before assuming any samples will ever come
    /// back, and to avoid showing HealthKit UI where it can never work.
    nonisolated var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(heartRate) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        if let respiration = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { types.insert(respiration) }
        return types
    }

    /// Requests read access to heart rate, HRV, and respiratory rate. Safe
    /// to call more than once (and safe to call speculatively at reflection
    /// start, mirroring `SpeechRecognitionManager.requestPermissions()`) --
    /// HealthKit no-ops a repeat request for types already decided, and
    /// just re-shows the prompt for anything genuinely still undecided.
    func requestAuthorization() async {
        guard isHealthDataAvailable else {
            authorizationUnavailable = true
            return
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            authorizationUnavailable = false
        } catch {
            print("HealthKit authorization failed: \(error.localizedDescription)")
            authorizationUnavailable = true
        }
    }

    /// Extra time searched on either side of a reflection's actual
    /// start/end when fetching HealthKit samples for it.
    ///
    /// Confirmed empirically (a real ~4-minute reflection, Apple Watch worn
    /// throughout, HealthKit access genuinely granted): querying the
    /// reflection's *exact* window came back completely empty, and checking
    /// Health app directly (Browse -> Heart -> Heart Rate) confirmed there
    /// simply was no sample recorded in that exact window -- not a bug.
    /// Apple Watch only samples heart rate passively every several minutes
    /// outside an active workout, and HRV only a handful of times a day, so
    /// a strict match against a short reflection's window will very often
    /// come back honestly empty even with everything working correctly.
    /// Padding the search window materially improves the odds of catching a
    /// real nearby sample without fabricating anything -- every returned
    /// `BiometricSample.timestamp` is still the sample's own real
    /// HealthKit-reported time, so it's always clear how far a given sample
    /// actually falls from the reflection's own start/end, not silently
    /// presented as "during" the reflection.
    static let queryPadding: TimeInterval = 10 * 60

    /// Result of a padded HealthKit fetch: the normalized samples plus the
    /// actual `[queryStart, queryEnd]` that was searched (reflection
    /// start/end widened by `queryPadding` on each side) -- callers should
    /// record this actual window (not the reflection's own start/end) on
    /// `BiometricWindow`, per PROJECT_CONSTRAINTS.md #5 (every observation
    /// must retain its real time window), so "Body signals from X-Y" in the
    /// UI always describes what was truly searched.
    struct FetchResult {
        let samples: [BiometricSample]
        let queryStart: Date
        let queryEnd: Date
    }

    /// Fetches heart rate, HRV, and respiratory samples for a reflection,
    /// searching `[reflectionStart - queryPadding, reflectionEnd +
    /// queryPadding]` (see `queryPadding`'s doc comment for why padding is
    /// necessary at all), normalized and merged into this app's own
    /// `BiometricSample` array -- one entry per distinct sample timestamp,
    /// with whichever of the three vitals actually landed on that timestamp
    /// (HealthKit doesn't guarantee they share timestamps).
    ///
    /// Returns an empty `samples` array (never throws) if HealthKit is
    /// unavailable, unauthorized, or genuinely has no samples in the padded
    /// window -- callers should treat all three the same way
    /// `BiometricWindow(quality: .unavailable)` already means "no evidence,"
    /// not an error state (see PROJECT_CONSTRAINTS.md #9: absence of
    /// evidence is a valid result).
    func fetchSamples(reflectionStart: Date, reflectionEnd: Date) async -> FetchResult {
        let start = reflectionStart.addingTimeInterval(-Self.queryPadding)
        let end = reflectionEnd.addingTimeInterval(Self.queryPadding)

        guard isHealthDataAvailable else {
            return FetchResult(samples: [], queryStart: start, queryEnd: end)
        }

        async let heartRateSamples = quantitySamples(
            identifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            start: start,
            end: end
        )
        async let hrvSamples = quantitySamples(
            identifier: .heartRateVariabilitySDNN,
            unit: HKUnit.secondUnit(with: .milli),
            start: start,
            end: end
        )
        async let respirationSamples = quantitySamples(
            identifier: .respiratoryRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            start: start,
            end: end
        )

        let (heartRate, hrv, respiration) = await (heartRateSamples, hrvSamples, respirationSamples)
        guard !(heartRate.isEmpty && hrv.isEmpty && respiration.isEmpty) else {
            return FetchResult(samples: [], queryStart: start, queryEnd: end)
        }

        var byTimestamp: [Date: BiometricSample] = [:]

        func emptySample(at date: Date) -> BiometricSample {
            BiometricSample(timestamp: date, heartRate: nil, respiration: nil, hrv: nil, source: .healthKitBackfill, quality: .medium)
        }

        for (date, value) in heartRate {
            var sample = byTimestamp[date] ?? emptySample(at: date)
            sample.heartRate = value
            byTimestamp[date] = sample
        }
        for (date, value) in hrv {
            var sample = byTimestamp[date] ?? emptySample(at: date)
            sample.hrv = value
            byTimestamp[date] = sample
        }
        for (date, value) in respiration {
            var sample = byTimestamp[date] ?? emptySample(at: date)
            sample.respiration = value
            byTimestamp[date] = sample
        }

        let samples = byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
        return FetchResult(samples: samples, queryStart: start, queryEnd: end)
    }

    /// Runs one HealthKit sample query for a single quantity type and
    /// returns raw `(timestamp, value-in-unit)` pairs -- kept separate from
    /// `BiometricSample` construction so `fetchSamples` can run all three
    /// vitals concurrently via `async let` rather than serially.
    ///
    /// Wrapped in `withTimeout` (below): HKSampleQuery's completion handler
    /// is documented to always be called, but in practice, when a read type
    /// was requested but not actually granted (which this app can't detect
    /// -- see `isAuthorized`'s doc comment), some iOS versions have been
    /// observed to never invoke it at all rather than calling back with an
    /// empty/denied result. Without a bound on that, the `Task` awaiting
    /// this would suspend forever, right at the point a reflection is being
    /// stopped -- exactly the moment this needs to reliably resolve one way
    /// or the other.
    private func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> [(Date, Double)] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withTimeout(seconds: 8, default: []) {
            await withCheckedContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
                ) { _, samples, error in
                    guard let quantitySamples = samples as? [HKQuantitySample], error == nil else {
                        if let error {
                            print("HealthKit query failed (\(identifier.rawValue)): \(error.localizedDescription)")
                        }
                        continuation.resume(returning: [])
                        return
                    }
                    let values = quantitySamples.map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
                    continuation.resume(returning: values)
                }
                self.healthStore.execute(query)
            }
        }
    }

    /// Races `operation` against a plain timer and returns whichever finishes
    /// first, defaulting to `defaultValue` if the timer wins. Used to bound
    /// every HealthKit call in this file so a query or authorization request
    /// that never calls back (see `quantitySamples`'s doc comment) can never
    /// leave a reflection's Stop flow waiting indefinitely -- it always
    /// resolves within `seconds`, worst case with an honest empty result
    /// rather than no result at all.
    private func withTimeout<T: Sendable>(seconds: TimeInterval, default defaultValue: T, operation: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return defaultValue
            }
            let result = await group.next() ?? defaultValue
            group.cancelAll()
            return result
        }
    }
}
