import FluidAudio
import Foundation

enum DiarizationMetadata {
    static let library = "FluidAudio"
    static let libraryVersion = "0.14.4"
    static let model = "sortformer"
    static let variant = "fastV2_1"
}

// MARK: - DiarizationSegmentRecord

/// Sortformer から取得した確定済み segment を audio timeline 上で保持する内部表現。
struct DiarizationSegmentRecord: Sendable {
    let startSec: Double
    let endSec: Double
    let speakerIndex: Int
}

struct SpeakerEmbeddingCandidate: Sendable {
    let startSec: Double
    let endSec: Double
    let speakerIndex: Int
    let samples: [Float]
    let rms: Float
}

struct PendingDiarizationSegments: Sendable {
    private var segments: [DiarizationSegmentRecord] = []

    mutating func append(_ segment: DiarizationSegmentRecord) {
        segments.append(segment)
    }

    func snapshot() -> [DiarizationSegmentRecord] {
        segments
    }

    mutating func acknowledge(count: Int) {
        guard count > 0 else { return }
        segments.removeFirst(min(count, segments.count))
    }
}

/// 16 kHz mono audioをaudio timeline上の位置と一緒に、固定時間だけ保持する。
struct AudioTimelineBuffer: Sendable {
    private struct Chunk: Sendable {
        let startSample: Int64
        let samples: [Float]

        var endSample: Int64 { startSample + Int64(samples.count) }
    }

    let sampleRate: Int
    let retentionSec: Double
    private var chunks: [Chunk] = []
    private(set) var nextSample: Int64 = 0

    init(sampleRate: Int = 16_000, retentionSec: Double = 120) {
        self.sampleRate = sampleRate
        self.retentionSec = retentionSec
    }

    mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        chunks.append(Chunk(startSample: nextSample, samples: samples))
        nextSample += Int64(samples.count)
        prune()
    }

    func samples(from startSec: Double, to endSec: Double) -> [Float]? {
        guard startSec >= 0, endSec > startSec else { return nil }
        let startSample = Int64((startSec * Double(sampleRate)).rounded(.down))
        let endSample = Int64((endSec * Double(sampleRate)).rounded(.up))
        guard startSample >= chunks.first?.startSample ?? nextSample, endSample <= nextSample else {
            return nil
        }

        var result: [Float] = []
        result.reserveCapacity(Int(endSample - startSample))
        var cursor = startSample
        for chunk in chunks where chunk.endSample > startSample && chunk.startSample < endSample {
            guard chunk.startSample <= cursor else { return nil }
            let localStart = max(0, cursor - chunk.startSample)
            let localEnd = min(Int64(chunk.samples.count), endSample - chunk.startSample)
            guard localEnd > localStart else { continue }
            result.append(contentsOf: chunk.samples[Int(localStart)..<Int(localEnd)])
            cursor = chunk.startSample + localEnd
            if cursor >= endSample { break }
        }
        return cursor == endSample ? result : nil
    }

    private mutating func prune() {
        let retainedSamples = Int64(retentionSec * Double(sampleRate))
        let cutoff = max(0, nextSample - retainedSamples)
        guard let firstRetained = chunks.firstIndex(where: { $0.endSample > cutoff }) else {
            chunks.removeAll(keepingCapacity: true)
            return
        }
        if firstRetained > 0 {
            chunks.removeFirst(firstRetained)
        }
    }
}

struct DiarizationHealthSnapshot: Sendable {
    let audioInputEndSec: Double
    let syntheticSilenceSec: Double
    let diarizationProcessedEndSec: Double
    let processCallCount: Int64
    let updateCount: Int64
    let finalizedSpanCount: Int64
    let addAudioErrorCount: Int64
    let processErrorCount: Int64
    let lastDiarizationUpdateUnixTimeMs: Int64?
    let lastErrorUnixTimeMs: Int64?
    let lastError: String?
}

struct ASRProgressSnapshot: Sendable {
    let lastResultEndSec: Double?
    let lastResultUnixTimeMs: Int64?
    let resultCount: Int64
    let errorCount: Int64
    let lastErrorUnixTimeMs: Int64?
    let lastError: String?
}

actor ASRProgressTracker {
    private var lastResultEndSec: Double?
    private var lastResultUnixTimeMs: Int64?
    private var resultCount: Int64 = 0
    private var errorCount: Int64 = 0
    private var lastErrorUnixTimeMs: Int64?
    private var lastError: String?

    func recordResult(endSec: Double) {
        lastResultEndSec = max(lastResultEndSec ?? 0, endSec)
        lastResultUnixTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        resultCount += 1
    }

    func record(error: Error) {
        errorCount += 1
        lastErrorUnixTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        lastError = String(describing: error)
    }

    func snapshot() -> ASRProgressSnapshot {
        ASRProgressSnapshot(
            lastResultEndSec: lastResultEndSec,
            lastResultUnixTimeMs: lastResultUnixTimeMs,
            resultCount: resultCount,
            errorCount: errorCount,
            lastErrorUnixTimeMs: lastErrorUnixTimeMs,
            lastError: lastError
        )
    }
}

// MARK: - DiarizationStream

/// FluidAudio Sortformer のストリーミング diarizer をラップする actor。
/// 同セッション内のクラスタ index を sessionId 付きで返す。
/// - audio timeline は SpeechTranscriber.Result.range と同じ前提
/// - cross-session matching は非対応（プロセス再起動で sessionId が変わる）
actor DiarizationStream {
    private let diarizer: SortformerDiarizer
    private let sessionId: String
    private var segments: [DiarizationSegmentRecord] = []
    private var tentativeSegments: [DiarizationSegmentRecord] = []
    private var pendingFinalizedSegments = PendingDiarizationSegments()
    private var audioTimeline = AudioTimelineBuffer()
    private var pendingEmbeddingCandidates: [SpeakerEmbeddingCandidate] = []
    private var lastEmbeddingCandidateStartSec: [Int: Double] = [:]
    /// 直近 5 分のみ保持（メモリ抑制）
    private let retentionSec: Double = 300
    private var maxObservedEndSec: Double = -.infinity
    private var audioInputEndSec: Double = 0
    private var syntheticSilenceSec: Double = 0
    private var processCallCount: Int64 = 0
    private var updateCount: Int64 = 0
    private var finalizedSpanCount: Int64 = 0
    private var addAudioErrorCount: Int64 = 0
    private var processErrorCount: Int64 = 0
    private var lastDiarizationUpdateUnixTimeMs: Int64?
    private var lastErrorUnixTimeMs: Int64?
    private var lastError: String?

    init(sessionId: String) async throws {
        self.sessionId = sessionId
        let config = SortformerConfig.fastV2_1
        var timelineConfig = DiarizerTimelineConfig.sortformerDefault
        // chronixd-capture consumes DiarizerTimelineUpdate directly. Do not also retain
        // an unbounded copy of predictions and segments inside FluidAudio for long sessions.
        timelineConfig.maxStoredFrames = 0
        timelineConfig.storeSegments = false
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        let models = try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: .cpuAndNeuralEngine)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    /// 16kHz mono Float32 の audio chunk を投入する。
    func addAudio(
        _ samples: [Float],
        sourceSampleRate: Double,
        isSyntheticSilence: Bool = false
    ) throws {
        do {
            try diarizer.addAudio(samples, sourceSampleRate: sourceSampleRate)
            if sourceSampleRate > 0 {
                audioInputEndSec += Double(samples.count) / sourceSampleRate
                if isSyntheticSilence {
                    syntheticSilenceSec += Double(samples.count) / sourceSampleRate
                }
            }
            if sourceSampleRate == Double(audioTimeline.sampleRate) {
                audioTimeline.append(samples)
            }
        } catch {
            addAudioErrorCount += 1
            record(error: error)
            throw error
        }
    }

    /// 内部バッファを処理して finalized segment を取り込む。
    func processIfReady() throws {
        processCallCount += 1
        do {
            guard let update = try diarizer.process() else { return }
            record(update: update)
        } catch {
            processErrorCount += 1
            record(error: error)
            throw error
        }
    }

    /// セッション終了時に未確定 segment を flush。
    func finalize() throws {
        do {
            if let update = try diarizer.finalizeSession() {
                record(update: update)
            }
        } catch {
            processErrorCount += 1
            record(error: error)
            throw error
        }
    }

    /// 保存待ちの確定済み segment を返す。書き込み成功後に acknowledge する。
    func finalizedSegmentsForPersistence() -> [DiarizationSegmentRecord] {
        pendingFinalizedSegments.snapshot()
    }

    func acknowledgePersistedFinalizedSegments(count: Int) {
        pendingFinalizedSegments.acknowledge(count: count)
    }

    /// WeSpeaker embedding抽出待ちの、重なりがない単独話者区間を返す。
    func drainEmbeddingCandidates() -> [SpeakerEmbeddingCandidate] {
        let result = pendingEmbeddingCandidates
        pendingEmbeddingCandidates.removeAll(keepingCapacity: true)
        return result
    }

    func healthSnapshot() -> DiarizationHealthSnapshot {
        DiarizationHealthSnapshot(
            audioInputEndSec: audioInputEndSec,
            syntheticSilenceSec: syntheticSilenceSec,
            diarizationProcessedEndSec: Double(diarizer.numFramesProcessed) * Double(diarizer.config.frameDurationSeconds),
            processCallCount: processCallCount,
            updateCount: updateCount,
            finalizedSpanCount: finalizedSpanCount,
            addAudioErrorCount: addAudioErrorCount,
            processErrorCount: processErrorCount,
            lastDiarizationUpdateUnixTimeMs: lastDiarizationUpdateUnixTimeMs,
            lastErrorUnixTimeMs: lastErrorUnixTimeMs,
            lastError: lastError
        )
    }

    /// 指定の audio time レンジに最も多く重なる speaker を `{sessionId}_{N}` 形式で返す。
    func dominantSpeaker(from startSec: Double, to endSec: Double) -> String? {
        guard let index = Self.dominantSpeakerIndex(in: segments, from: startSec, to: endSec) else { return nil }
        return "\(sessionId)_\(index)"
    }

    // MARK: Private

    private func record(update: DiarizerTimelineUpdate) {
        updateCount += 1
        lastDiarizationUpdateUnixTimeMs = Self.nowUnixTimeMs
        appendSegments(from: update)
    }

    private func record(error: Error) {
        lastErrorUnixTimeMs = Self.nowUnixTimeMs
        lastError = String(describing: error)
    }

    private static var nowUnixTimeMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func appendSegments(from update: DiarizerTimelineUpdate) {
        tentativeSegments = update.tentativeSegments.map {
            DiarizationSegmentRecord(
                startSec: Double($0.startTime),
                endSec: Double($0.endTime),
                speakerIndex: $0.speakerIndex
            )
        }
        guard !update.finalizedSegments.isEmpty else { return }
        var newRecords: [DiarizationSegmentRecord] = []
        for seg in update.finalizedSegments {
            let record = DiarizationSegmentRecord(
                startSec: Double(seg.startTime),
                endSec: Double(seg.endTime),
                speakerIndex: seg.speakerIndex
            )
            segments.append(record)
            newRecords.append(record)
            pendingFinalizedSegments.append(record)
            finalizedSpanCount += 1
            if record.endSec > maxObservedEndSec {
                maxObservedEndSec = record.endSec
            }
        }
        let cutoff = maxObservedEndSec - retentionSec
        if let firstFresh = segments.firstIndex(where: { $0.endSec >= cutoff }), firstFresh > 0 {
            segments.removeFirst(firstFresh)
        }
        appendEmbeddingCandidates(from: newRecords)
    }

    private func appendEmbeddingCandidates(from records: [DiarizationSegmentRecord]) {
        for record in records.sorted(by: { $0.startSec < $1.startSec }) {
            guard record.endSec - record.startSec >= 3 else { continue }
            if let previous = lastEmbeddingCandidateStartSec[record.speakerIndex],
               record.startSec - previous < 30 {
                continue
            }
            let candidateEndSec = min(record.endSec, record.startSec + 10)
            let overlapsOtherSpeaker = Self.overlapsOtherSpeaker(
                speakerIndex: record.speakerIndex,
                from: record.startSec,
                to: candidateEndSec,
                finalizedSegments: segments,
                tentativeSegments: tentativeSegments
            )
            guard !overlapsOtherSpeaker,
                  let samples = audioTimeline.samples(from: record.startSec, to: candidateEndSec),
                  !samples.isEmpty
            else {
                continue
            }
            let squaredSum = samples.reduce(Float.zero) { $0 + $1 * $1 }
            let rms = sqrt(squaredSum / Float(samples.count))
            pendingEmbeddingCandidates.append(SpeakerEmbeddingCandidate(
                startSec: record.startSec,
                endSec: candidateEndSec,
                speakerIndex: record.speakerIndex,
                samples: samples,
                rms: rms
            ))
            if pendingEmbeddingCandidates.count > 16 {
                pendingEmbeddingCandidates.removeFirst(pendingEmbeddingCandidates.count - 16)
            }
            lastEmbeddingCandidateStartSec[record.speakerIndex] = record.startSec
        }
    }

    /// pure logic、テスト容易性のため static func。
    static func dominantSpeakerIndex(
        in segments: [DiarizationSegmentRecord],
        from startSec: Double,
        to endSec: Double
    ) -> Int? {
        guard endSec > startSec else { return nil }
        var weights: [Int: Double] = [:]
        for seg in segments {
            let overlapStart = max(seg.startSec, startSec)
            let overlapEnd = min(seg.endSec, endSec)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }
            weights[seg.speakerIndex, default: 0] += overlap
        }
        return weights.max(by: {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        })?.key
    }

    static func overlapsOtherSpeaker(
        speakerIndex: Int,
        from startSec: Double,
        to endSec: Double,
        finalizedSegments: [DiarizationSegmentRecord],
        tentativeSegments: [DiarizationSegmentRecord] = []
    ) -> Bool {
        (finalizedSegments + tentativeSegments).contains { other in
            other.speakerIndex != speakerIndex
                && max(startSec, other.startSec) < min(endSec, other.endSec)
        }
    }
}
