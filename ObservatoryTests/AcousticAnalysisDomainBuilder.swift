import Foundation

// U4a-1 §6: the analysis domain, and what the evidence can actually establish about
// where a capture join might be.
//
// Three corrections from the review are structural here:
//   * `.incomplete` does NOT mean "spliced" — the pattern defaults to `.unknownPattern`
//     and is only ever narrowed by named evidence (R3.1).
//   * Lifecycle and signal evidence are kept SEPARATE and never fused into a single
//     "the join is here" (R3.4). Each is candidate-grade with its own failure modes.
//   * `missingAudioIntervals` is NOT a subtractable file-relative span (R3.8, §6.5).

// MARK: - Session record (minimal, read-only)

/// Only the fields U4a needs, decoded directly from `completed_reflections_v1.json`.
/// Deliberately not `ReflectionSession`: this prototype must not break when unrelated
/// production fields change, and it must never touch transcript text.
struct U4aSessionRecord: Sendable {
    let id: String
    let audioFileName: String?
    let startedAt: Date?
    let endedAt: Date?
    let completeness: RecordedCompleteness
    let recognitionContinuityGaps: [Date]
    let audioRecordingReliable: Bool?
    let missingAudioIntervalCount: Int

    var wallSeconds: Double? {
        guard let s = startedAt, let e = endedAt else { return nil }
        return e.timeIntervalSince(s)
    }
}

enum U4aSessionStore {
    /// Resolves session audio and records beneath a backup ROOT, searching recursively
    /// so one `OBSERVATORY_U4A_SESSION_BACKUP_DIR` can cover several dated backups.
    static func backupRoot() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["OBSERVATORY_U4A_SESSION_BACKUP_DIR"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func findFiles(named name: String, under root: URL) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in e where url.lastPathComponent == name { out.append(url) }
        return out.sorted { $0.path < $1.path }
    }

    static func findAudio(sessionID: String, under root: URL) -> URL? {
        findFiles(named: "\(sessionID).caf", under: root).first
    }

    /// Parses every `completed_reflections_v1.json` under the root and returns the first
    /// record whose id has the given prefix.
    static func findRecord(sessionIDPrefix: String, under root: URL) -> U4aSessionRecord? {
        for url in findFiles(named: "completed_reflections_v1.json", under: root) {
            guard let data = try? Data(contentsOf: url),
                  let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { continue }
            for raw in array {
                guard let id = raw["id"] as? String, id.hasPrefix(sessionIDPrefix) else { continue }
                return parse(raw)
            }
        }
        return nil
    }

    static func parse(_ raw: [String: Any]) -> U4aSessionRecord {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func date(_ key: String) -> Date? {
            guard let s = raw[key] as? String else { return nil }
            return iso.date(from: s)
        }
        var completeness: RecordedCompleteness = .unknownLegacy
        if let c = raw["captureCompleteness"] {
            if let dict = c as? [String: Any] {
                if let inc = dict["incomplete"] as? [String: Any] {
                    completeness = .incomplete(endpointAudioSeconds: inc["endpointAudioSeconds"] as? Double)
                } else if dict["complete"] != nil {
                    completeness = .complete
                }
            } else if let s = c as? String, s == "complete" {
                completeness = .complete
            }
        }
        let gaps = (raw["recognitionContinuityGaps"] as? [String] ?? []).compactMap { iso.date(from: $0) }
        return U4aSessionRecord(
            id: raw["id"] as? String ?? "unknown",
            audioFileName: raw["audioFileName"] as? String,
            startedAt: date("startedAt"), endedAt: date("endedAt"),
            completeness: completeness,
            recognitionContinuityGaps: gaps.sorted(),
            audioRecordingReliable: raw["audioRecordingReliable"] as? Bool,
            missingAudioIntervalCount: (raw["missingAudioIntervals"] as? [[String: Any]])?.count ?? 0)
    }
}

// MARK: - Signal evidence

/// Candidate-grade only. Near-digital silence occurs in captured audio WITHOUT a join,
/// and a join can be seamless and leave no signature at all — so this scanner's output
/// is evidence, never a detector verdict (review R3.4).
enum JoinSignalScanner {
    struct Candidate: Sendable {
        let start: Double
        let end: Double
        let source: EvidenceSource
    }

    static func scan(signal: AudioSignal, config cfg: EstimatorConfig) -> [Candidate] {
        let hop = Int((signal.sampleRate * cfg.frameGeometry.hopMs / 1000).rounded())
        let frame = Int((signal.sampleRate * cfg.frameGeometry.levelFrameMs / 1000).rounded())
        guard hop > 0, frame > 0, signal.samples.count > frame else { return [] }
        let frameCount = signal.samples.count / hop
        var levels = [Double?](repeating: nil, count: frameCount)
        for i in 0..<frameCount {
            let center = i * hop + hop / 2
            let lo = center - frame / 2, hi = lo + frame
            guard lo >= 0, hi <= signal.samples.count else { continue }
            var sumSq = 0.0
            for n in lo..<hi { let v = Double(signal.samples[n]); sumSq += v * v }
            let rms = (sumSq / Double(frame)).squareRoot()
            levels[i] = rms > 0 ? 20 * log10(rms) : -Double.infinity
        }
        let hopSeconds = cfg.frameGeometry.hopMs / 1000
        var out: [Candidate] = []

        // (1) near-digital-silence runs
        let minRun = Int((cfg.joinEvidence.minNearSilenceRunSeconds / hopSeconds).rounded())
        var i = 0
        while i < frameCount {
            guard let l = levels[i], l < cfg.joinEvidence.nearDigitalSilenceDbfs else { i += 1; continue }
            var j = i
            while j < frameCount, let lj = levels[j], lj < cfg.joinEvidence.nearDigitalSilenceDbfs { j += 1 }
            if j - i >= minRun {
                out.append(Candidate(start: Double(i) * hopSeconds, end: Double(j) * hopSeconds,
                                     source: .signalNearDigitalSilence))
            }
            i = max(j, i + 1)
        }

        // (2) noise-floor steps between adjacent blocks
        let blockFrames = max(1, Int((cfg.joinEvidence.noiseFloorStepBlockSeconds / hopSeconds).rounded()))
        var blockFloors: [(index: Int, floor: Double)] = []
        var b = 0
        while b + blockFrames <= frameCount {
            let slice = (b..<(b + blockFrames)).compactMap { levels[$0] }.filter { $0.isFinite }
            if let f = AcousticAnalyzer.percentile(slice, cfg.noiseFloor.percentile) {
                blockFloors.append((b, f))
            }
            b += blockFrames
        }
        for k in 1..<max(1, blockFloors.count) {
            let delta = abs(blockFloors[k].floor - blockFloors[k - 1].floor)
            if delta >= cfg.joinEvidence.noiseFloorStepDb {
                let t = Double(blockFloors[k].index) * hopSeconds
                out.append(Candidate(start: t - cfg.joinEvidence.noiseFloorStepBlockSeconds / 2,
                                     end: t + cfg.joinEvidence.noiseFloorStepBlockSeconds / 2,
                                     source: .signalNoiseFloorStep))
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}

// MARK: - Domain builder

enum AcousticAnalysisDomainBuilder {

    /// §6.4's decision table. `sessionRecord == nil` means the source is a fixture or a
    /// synthetic signal — there is no session lifecycle record to consult at all, which
    /// is a sixth case the proposal's table did not enumerate (Amendment A3): the file
    /// is analyzed as one span, flagged `completenessUnknown`, with no wall-clock
    /// mapping. It is NOT silently treated as confirmed-complete.
    static func build(signal: AudioSignal,
                      fileDurationSeconds: Double,
                      sessionRecord: U4aSessionRecord?,
                      config cfg: EstimatorConfig,
                      syntheticKnownJoin: (start: Double, end: Double)? = nil) -> AnalysisDomain {

        var evidence: [EvidenceItem] = []
        var unresolved: [ExcludedRegion] = []
        var pattern: DiscontinuityPattern = .none
        var wallClockAvailable = false
        var suppressJoinSensitive = false
        var sourceExcluded = false

        if let known = syntheticKnownJoin {
            evidence.append(EvidenceItem(source: .syntheticConstruction,
                                         intervalStartSeconds: known.start, intervalEndSeconds: known.end,
                                         assumptions: [], note: .exactByConstruction))
        }

        // ---- Signal evidence (always collected; candidate-grade)
        let signalCandidates = JoinSignalScanner.scan(signal: signal, config: cfg)
        for c in signalCandidates {
            evidence.append(EvidenceItem(source: c.source,
                                         intervalStartSeconds: c.start, intervalEndSeconds: c.end,
                                         assumptions: c.source == .signalNearDigitalSilence
                                            ? [.nearSilenceIndicatesMicMute] : [.noiseFloorStepIndicatesJoin],
                                         note: .candidateOnlyFalsePositivesPossible))
        }
        if signalCandidates.isEmpty {
            evidence.append(EvidenceItem(source: .signalNearDigitalSilence,
                                         intervalStartSeconds: nil, intervalEndSeconds: nil,
                                         assumptions: [],
                                         note: .candidateOnlyFalseNegativesPossible))
        }

        guard let record = sessionRecord else {
            // Amendment A3 — no session record exists for this source.
            let span = TimeSpan(spanID: 0, startSeconds: 0, endSeconds: fileDurationSeconds)
            return AnalysisDomain(fileDurationSeconds: fileDurationSeconds,
                                  analyzableSpans: [span], excludedRegions: [],
                                  evidence: evidence, unresolvedRegions: [],
                                  wallClockMappingAvailable: false,
                                  joinSensitiveMeasurementsSuppressed: false,
                                  sourceExcluded: false)
        }

        // ---- §6.5: a write loss is a JOIN at a known offset with a known missing
        // duration, never a subtractable span. Until a constructed-loss test confirms
        // that reading, any source with a non-empty record is excluded outright.
        if record.missingAudioIntervalCount > 0 {
            sourceExcluded = true
            evidence.append(EvidenceItem(source: .writerLossRecord,
                                         intervalStartSeconds: nil, intervalEndSeconds: nil,
                                         assumptions: [.writerOffsetIsExact],
                                         note: .exactByConstruction))
        }

        switch record.completeness {
        case .complete:
            pattern = .none
            wallClockAvailable = record.missingAudioIntervalCount == 0

        case .notApplicable:
            pattern = .unknownPattern

        case .unknownLegacy:
            // Unknown provenance, NOT confirmed complete (review R3.7). The join could be
            // anywhere, so every join-sensitive measurement abstains — but §6.4 keeps
            // frame-local measurements reportable, so the span is NOT removed. Excluding
            // the whole file instead would discard measurements the policy permits.
            pattern = .unknownPattern
            suppressJoinSensitive = true

        case .incomplete(let endpoint):
            pattern = .unknownPattern
            // Lifecycle evidence: a BOUNDED interval, not a point. Each recognition-gap
            // timestamp yields a different implied join offset under the assumption that
            // it coincides with capture resumption — an assumption that is recorded, not
            // believed. The spread between the earliest and latest gap IS the bound.
            if let wall = record.wallSeconds, let endpoint, wall > 0, endpoint > 0,
               let start = record.startedAt, !record.recognitionContinuityGaps.isEmpty {
                let offsets = record.recognitionContinuityGaps.map { $0.timeIntervalSince(start) }
                let implied = offsets.map { endpoint - (wall - $0) }.filter { $0 >= 0 && $0 <= endpoint }
                if let lo = implied.min(), let hi = implied.max() {
                    evidence.append(EvidenceItem(
                        source: .lifecycleRecord, intervalStartSeconds: lo, intervalEndSeconds: hi,
                        assumptions: [.recognitionRestartEqualsCaptureResumption,
                                      .captureContinuousAfterResumption,
                                      .endedAtEqualsLastWrittenFrame],
                        note: .lifecycleInferenceUnderStatedAssumptions))
                    unresolved.append(ExcludedRegion(startSeconds: lo, endSeconds: hi,
                                                     reason: .unresolvedJoinRegion))
                }
            }
            // Signal candidates become unresolved regions too — the union, never a
            // tie-break between disagreeing sources (§6.4).
            for c in signalCandidates {
                unresolved.append(ExcludedRegion(startSeconds: c.start, endSeconds: c.end,
                                                 reason: .unresolvedJoinRegion))
            }
            if unresolved.isEmpty {
                // No bounded location at all: the join could be anywhere in the file, so
                // join-sensitive measurements abstain wholesale — the same treatment as
                // `.unknownLegacy`, and for the same reason.
                suppressJoinSensitive = true
            }
        }

        if let known = syntheticKnownJoin {
            unresolved.append(ExcludedRegion(startSeconds: known.start, endSeconds: known.end,
                                             reason: .unresolvedJoinRegion))
        }

        let guarded = merge(regions: unresolved.map {
            ExcludedRegion(startSeconds: $0.startSeconds - cfg.joins.guardSeconds,
                           endSeconds: $0.endSeconds + cfg.joins.guardSeconds,
                           reason: $0.reason)
        }, clampedTo: fileDurationSeconds)

        let spans = subtract(regions: guarded, fromDuration: fileDurationSeconds)
        if spans.count > 1 { pattern = spans.count > 2 ? .multipleJoins : pattern }

        return AnalysisDomain(
            fileDurationSeconds: fileDurationSeconds,
            analyzableSpans: sourceExcluded ? [] : spans,
            excludedRegions: guarded,
            evidence: evidence.sorted { ($0.source.rawValue, $0.intervalStartSeconds ?? -1)
                                            < ($1.source.rawValue, $1.intervalStartSeconds ?? -1) },
            unresolvedRegions: guarded,
            wallClockMappingAvailable: wallClockAvailable,
            joinSensitiveMeasurementsSuppressed: suppressJoinSensitive,
            sourceExcluded: sourceExcluded)
    }

    static func merge(regions: [ExcludedRegion], clampedTo duration: Double) -> [ExcludedRegion] {
        let clamped = regions
            .map { ExcludedRegion(startSeconds: max(0, $0.startSeconds),
                                  endSeconds: min(duration, $0.endSeconds), reason: $0.reason) }
            .filter { $0.endSeconds > $0.startSeconds }
            .sorted { $0.startSeconds < $1.startSeconds }
        var out: [ExcludedRegion] = []
        for r in clamped {
            if let last = out.last, r.startSeconds <= last.endSeconds {
                out[out.count - 1] = ExcludedRegion(startSeconds: last.startSeconds,
                                                    endSeconds: max(last.endSeconds, r.endSeconds),
                                                    reason: last.reason)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func subtract(regions: [ExcludedRegion], fromDuration duration: Double) -> [TimeSpan] {
        var spans: [TimeSpan] = []
        var cursor = 0.0
        var id = 0
        for r in regions {
            if r.startSeconds > cursor {
                spans.append(TimeSpan(spanID: id, startSeconds: cursor, endSeconds: r.startSeconds))
                id += 1
            }
            cursor = max(cursor, r.endSeconds)
        }
        if cursor < duration {
            spans.append(TimeSpan(spanID: id, startSeconds: cursor, endSeconds: duration))
        }
        return spans
    }
}
