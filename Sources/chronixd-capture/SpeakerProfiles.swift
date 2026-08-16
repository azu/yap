import Darwin
import FluidAudio
import Foundation

enum SpeakerEmbeddingMetadata {
    static let current = SpeakerEmbeddingSource(
        library: "FluidAudio",
        libraryVersion: DiarizationMetadata.libraryVersion,
        model: "wespeaker_v2",
        variant: "pyannote_segmentation",
        dimension: 256,
        sampleRate: 16_000
    )
}

struct SpeakerEmbeddingSource: Codable, Hashable, Sendable {
    let library: String
    let libraryVersion: String
    let model: String
    let variant: String
    let dimension: Int
    let sampleRate: Int

    /// Embeddings remain comparable when the model contract is unchanged.
    /// FluidAudio patch releases are recorded for diagnostics, but do not by
    /// themselves invalidate an existing profile. Minor releases remain
    /// isolated because they can change the bundled model or preprocessing.
    func isCompatible(with other: SpeakerEmbeddingSource) -> Bool {
        library == other.library
            && model == other.model
            && variant == other.variant
            && dimension == other.dimension
            && sampleRate == other.sampleRate
            && compatibilityVersion == other.compatibilityVersion
    }

    private var compatibilityVersion: String {
        let components = libraryVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return libraryVersion }
        return components.prefix(2).joined(separator: ".")
    }
}

struct SpeakerEmbeddingSample: Codable, Sendable {
    let id: String
    let unixTimeMs: Int64
    let endUnixTimeMs: Int64
    let sessionId: String
    let speakerId: String
    let speakerIndex: Int
    let device: String?
    let durationSec: Double
    let rms: Float
    let embedding: [Float]
    let proposedProfileId: String?
    let matchDistance: Float?
    let matchMargin: Float?
    let learnEligible: Bool
    let source: SpeakerEmbeddingSource
}

struct SpeakerMappingRecord: Codable, Sendable {
    let id: String
    let createdUnixTimeMs: Int64
    let sessionId: String
    let speakerId: String
    let speakerIndex: Int
    let profileId: String
    let fromUnixTimeMs: Int64?
    let toUnixTimeMs: Int64?
    let source: String
}

struct SpeakerForgetResult: Codable, Sendable {
    let profileId: String
    let removedEmbeddingCount: Int
    let removedMappingCount: Int
}

struct SpeakerProfile: Sendable {
    let id: String
    let source: SpeakerEmbeddingSource
    let centroid: [Float]
    let confirmedSampleCount: Int
    let adaptiveSampleCount: Int

    var sampleCount: Int { confirmedSampleCount + adaptiveSampleCount }

    func addingAdaptive(_ embedding: [Float]) -> SpeakerProfile {
        guard embedding.count == centroid.count else { return self }
        // Keep a newly confirmed profile anchored while capture is running.
        // Restart-time reconstruction revalidates adaptive samples and gives
        // the confirmed centroid twice the weight of the adaptive centroid.
        let existingWeight = Float(max(10, min(sampleCount * 2, 100)))
        let sum = zip(centroid, embedding).map { $0.0 * existingWeight + $0.1 }
        return SpeakerProfile(
            id: id,
            source: source,
            centroid: SpeakerVector.normalize(sum),
            confirmedSampleCount: confirmedSampleCount,
            adaptiveSampleCount: min(50, adaptiveSampleCount + 1)
        )
    }
}

enum SpeakerVector {
    static func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { return [] }
        return vector.map { $0 / magnitude }
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard left.count == lhs.count, right.count == rhs.count else { return nil }
        let similarity = zip(left, right).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        return 1 - similarity
    }
}

struct SpeakerProfileMatch: Sendable {
    let profileId: String
    let distance: Float
    let margin: Float?

    var hasCompetingProfile: Bool { margin != nil }
}

struct SpeakerProfileMatcher: Sendable {
    let recognitionMaxDistance: Float
    let adaptationMaxDistance: Float
    let minimumMargin: Float

    init(
        recognitionMaxDistance: Float = 0.45,
        adaptationMaxDistance: Float = 0.35,
        minimumMargin: Float = 0.08
    ) {
        self.recognitionMaxDistance = recognitionMaxDistance
        self.adaptationMaxDistance = adaptationMaxDistance
        self.minimumMargin = minimumMargin
    }

    func match(embedding: [Float], profiles: [String: SpeakerProfile]) -> SpeakerProfileMatch? {
        let ranked = profiles.values.compactMap { profile -> (String, Float)? in
            guard let distance = SpeakerVector.cosineDistance(embedding, profile.centroid) else { return nil }
            return (profile.id, distance)
        }.sorted {
            $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0
        }
        guard let best = ranked.first else { return nil }
        let margin = ranked.count > 1 ? ranked[1].1 - best.1 : nil
        if let margin {
            guard best.1 <= recognitionMaxDistance, margin >= minimumMargin else { return nil }
        } else {
            // Without a competing profile there is no separation evidence.
            // Permit only a strong recognition result and never adapt from it.
            guard best.1 <= adaptationMaxDistance else { return nil }
        }
        return SpeakerProfileMatch(profileId: best.0, distance: best.1, margin: margin)
    }

    func canAdapt(_ match: SpeakerProfileMatch) -> Bool {
        match.hasCompetingProfile
            && match.distance <= adaptationMaxDistance
            && match.margin! >= minimumMargin
    }
}

struct SpeakerMappingResolver: Sendable {
    private let mappingsBySpeaker: [String: [SpeakerMappingRecord]]

    init(mappings: [SpeakerMappingRecord]) {
        mappingsBySpeaker = Dictionary(grouping: mappings) {
            Self.key(sessionId: $0.sessionId, speakerIndex: $0.speakerIndex)
        }
    }

    func mapping(sessionId: String, speakerIndex: Int, at unixTimeMs: Int64) -> SpeakerMappingRecord? {
        mappingsBySpeaker[Self.key(sessionId: sessionId, speakerIndex: speakerIndex)]?
            .filter { mapping in
                mapping.sessionId == sessionId
                    && mapping.speakerIndex == speakerIndex
                    && (mapping.fromUnixTimeMs == nil || unixTimeMs >= mapping.fromUnixTimeMs!)
                    && (mapping.toUnixTimeMs == nil || unixTimeMs <= mapping.toUnixTimeMs!)
            }
            .max {
                if $0.createdUnixTimeMs != $1.createdUnixTimeMs {
                    return $0.createdUnixTimeMs < $1.createdUnixTimeMs
                }
                return $0.id < $1.id
            }
    }

    private static func key(sessionId: String, speakerIndex: Int) -> String {
        "\(sessionId)_\(speakerIndex)"
    }
}

enum SpeakerProfileBuilder {
    static func build(
        samples: [SpeakerEmbeddingSample],
        mappings: [SpeakerMappingRecord],
        source: SpeakerEmbeddingSource = SpeakerEmbeddingMetadata.current,
        matcher: SpeakerProfileMatcher = .init()
    ) -> [String: SpeakerProfile] {
        (try? build(
            mappings: mappings,
            source: source,
            matcher: matcher,
            enumerate: { body in samples.forEach(body) }
        )) ?? [:]
    }

    /// Rebuild profiles without retaining every saved embedding in memory.
    static func build(
        store: SpeakerStore,
        mappings: [SpeakerMappingRecord],
        source: SpeakerEmbeddingSource = SpeakerEmbeddingMetadata.current,
        matcher: SpeakerProfileMatcher = .init()
    ) throws -> [String: SpeakerProfile] {
        try build(
            mappings: mappings,
            source: source,
            matcher: matcher,
            enumerate: { body in try store.forEachSample(body) }
        )
    }

    private static func build(
        mappings: [SpeakerMappingRecord],
        source: SpeakerEmbeddingSource,
        matcher: SpeakerProfileMatcher,
        enumerate: (_ body: (SpeakerEmbeddingSample) -> Void) throws -> Void
    ) throws -> [String: SpeakerProfile] {
        let resolver = SpeakerMappingResolver(mappings: mappings)
        var confirmed: [String: SpeakerVectorAccumulator] = [:]
        var adaptive: [String: [SpeakerEmbeddingSample]] = [:]

        try enumerate { sample in
            guard sample.source.isCompatible(with: source),
                  sample.embedding.count == source.dimension,
                  let mapping = resolver.mapping(
                      sessionId: sample.sessionId,
                      speakerIndex: sample.speakerIndex,
                      at: sample.unixTimeMs
                  )
            else {
                return
            }
            confirmed[mapping.profileId, default: SpeakerVectorAccumulator(dimension: source.dimension)]
                .add(sample.embedding)
        }

        var confirmedProfiles: [String: SpeakerProfile] = [:]
        for (profileId, accumulator) in confirmed {
            guard let centroid = accumulator.centroid else { continue }
            confirmedProfiles[profileId] = SpeakerProfile(
                id: profileId,
                source: source,
                centroid: centroid,
                confirmedSampleCount: accumulator.count,
                adaptiveSampleCount: 0
            )
        }

        try enumerate { sample in
            guard sample.source.isCompatible(with: source),
                  sample.embedding.count == source.dimension
            else {
                return
            }
            if resolver.mapping(
                sessionId: sample.sessionId,
                speakerIndex: sample.speakerIndex,
                at: sample.unixTimeMs
            ) != nil {
                return
            }
            guard sample.learnEligible,
                  sample.matchMargin != nil,
                  let profileId = sample.proposedProfileId
            else {
                return
            }
            var recent = adaptive[profileId, default: []]
            recent.append(sample)
            if recent.count > 50 {
                recent.sort {
                    $0.unixTimeMs != $1.unixTimeMs
                        ? $0.unixTimeMs < $1.unixTimeMs
                        : $0.id < $1.id
                }
                recent.removeFirst(recent.count - 50)
            }
            adaptive[profileId] = recent
        }

        var profiles: [String: SpeakerProfile] = [:]
        for (profileId, confirmedProfile) in confirmedProfiles {
            let adaptiveSamples = (adaptive[profileId] ?? [])
                .filter { sample in
                    guard let match = matcher.match(
                        embedding: sample.embedding,
                        profiles: confirmedProfiles
                    ) else {
                        return false
                    }
                    return match.profileId == profileId && matcher.canAdapt(match)
                }
            let centroid = weightedCentroid(
                confirmed: confirmedProfile.centroid,
                adaptive: SpeakerVectorAccumulator.centroid(
                    of: adaptiveSamples.map(\.embedding),
                    dimension: source.dimension
                )
            ) ?? confirmedProfile.centroid
            profiles[profileId] = SpeakerProfile(
                id: profileId,
                source: source,
                centroid: centroid,
                confirmedSampleCount: confirmedProfile.confirmedSampleCount,
                adaptiveSampleCount: adaptiveSamples.count
            )
        }
        return profiles
    }

    /// Manual evidence is authoritative. Adaptive samples can move a profile,
    /// but their aggregate contribution is capped at one third of the centroid.
    private static func weightedCentroid(
        confirmed: [Float],
        adaptive: [Float]?
    ) -> [Float]? {
        guard let adaptive else { return confirmed }
        let sum = zip(confirmed, adaptive).map { confirmedValue, adaptiveValue in
            confirmedValue * 2 + adaptiveValue
        }
        let normalized = SpeakerVector.normalize(sum)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct SpeakerVectorAccumulator {
    private var sum: [Float]
    private(set) var count = 0

    init(dimension: Int) {
        sum = [Float](repeating: 0, count: dimension)
    }

    mutating func add(_ vector: [Float]) {
        guard vector.count == sum.count else { return }
        for index in vector.indices {
            sum[index] += vector[index]
        }
        count += 1
    }

    var centroid: [Float]? {
        guard count > 0 else { return nil }
        let normalized = SpeakerVector.normalize(sum)
        return normalized.isEmpty ? nil : normalized
    }

    static func centroid(of vectors: [[Float]], dimension: Int) -> [Float]? {
        var accumulator = SpeakerVectorAccumulator(dimension: dimension)
        vectors.forEach { accumulator.add($0) }
        return accumulator.centroid
    }
}

final class SpeakerStore: @unchecked Sendable {
    let dataDir: String
    private let writeLock = NSLock()

    private var speakersDir: String { dataDir + "/speakers/" }
    private var embeddingsDir: String { speakersDir + "embeddings/" }
    private var mappingsDir: String { speakersDir + "mappings/" }
    private var lockPath: String { speakersDir + ".write.lock" }

    init(dataDir: String) {
        self.dataDir = dataDir
    }

    func setup() throws {
        try FileManager.default.createDirectory(atPath: embeddingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mappingsDir, withIntermediateDirectories: true)
    }

    func append(sample: SpeakerEmbeddingSample, timestamp: Date) throws {
        try append(sample, to: embeddingsDir, timestamp: timestamp)
    }

    func append(mapping: SpeakerMappingRecord, timestamp: Date) throws {
        try append(mapping, to: mappingsDir, timestamp: timestamp)
    }

    func loadSamples(sessionIds: Set<String>? = nil) throws -> [SpeakerEmbeddingSample] {
        var samples: [SpeakerEmbeddingSample] = []
        try forEachSample(sessionIds: sessionIds) { samples.append($0) }
        return samples
    }

    func forEachSample(
        sessionIds: Set<String>? = nil,
        _ body: (SpeakerEmbeddingSample) -> Void
    ) throws {
        let markers = sessionIds?.map { "\"sessionId\":\"\($0)\"" }
        try forEachRecord(
            from: embeddingsDir,
            as: SpeakerEmbeddingSample.self,
            prefilter: markers.map { markers in
                { line in
                    // Files written by this program use compact sorted JSON.
                    // If a line was reformatted, decode it instead of silently
                    // treating it as a non-matching session.
                    !line.contains("\"sessionId\":\"")
                        || markers.contains { marker in line.contains(marker) }
                }
            }
        ) { sample in
            guard sessionIds?.contains(sample.sessionId) ?? true else { return }
            body(sample)
        }
    }

    func loadMappings() throws -> [SpeakerMappingRecord] {
        try loadRecords(from: mappingsDir, as: SpeakerMappingRecord.self) { _ in true }
    }

    /// Permanently remove mappings and embeddings currently associated with a
    /// profile. Capture should be stopped first so its in-memory profile cannot
    /// append a new automatic match after this operation finishes.
    func forget(profileId: String) throws -> SpeakerForgetResult {
        writeLock.lock()
        defer { writeLock.unlock() }
        try setup()
        return try withExclusiveFileLock {
            let mappings = try loadMappings()
            let resolver = SpeakerMappingResolver(mappings: mappings)
            let removedEmbeddings = try rewriteRecords(
                in: embeddingsDir,
                as: SpeakerEmbeddingSample.self
            ) { sample in
                let mappedProfile = resolver.mapping(
                    sessionId: sample.sessionId,
                    speakerIndex: sample.speakerIndex,
                    at: sample.unixTimeMs
                )?.profileId
                return sample.proposedProfileId != profileId && mappedProfile != profileId
            }
            let removedMappings = try rewriteRecords(
                in: mappingsDir,
                as: SpeakerMappingRecord.self
            ) { mapping in
                mapping.profileId != profileId
            }
            return SpeakerForgetResult(
                profileId: profileId,
                removedEmbeddingCount: removedEmbeddings,
                removedMappingCount: removedMappings
            )
        }
    }

    private func append<T: Encodable>(_ record: T, to directory: String, timestamp: Date) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try setup()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let path = directory + "\(formatter.string(from: timestamp))_\(CaptureStore.currentDevice).ndjson"
        var line = data
        line.append(0x0A)
        try withExclusiveFileLock {
            try NDJSONFileAppender.append(line, to: path)
        }
    }

    private func loadRecords<T: Decodable>(
        from directory: String,
        as _: T.Type,
        prefilter: ((Substring) -> Bool)? = nil,
        include: (T) -> Bool
    ) throws -> [T] {
        var records: [T] = []
        try forEachRecord(from: directory, as: T.self, prefilter: prefilter) { record in
            if include(record) {
                records.append(record)
            }
        }
        return records
    }

    private func forEachRecord<T: Decodable>(
        from directory: String,
        as _: T.Type,
        prefilter: ((Substring) -> Bool)? = nil,
        body: (T) -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: directory) else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        let decoder = JSONDecoder()
        for file in files.sorted() where file.hasSuffix(".ndjson") {
            let url = URL(fileURLWithPath: directory + file)
            let content = try String(contentsOf: url, encoding: .utf8)
            for (lineIndex, line) in content.split(separator: "\n").enumerated() {
                if let prefilter, !prefilter(line) { continue }
                do {
                    let record = try decoder.decode(T.self, from: Data(line.utf8))
                    body(record)
                } catch {
                    throw SpeakerStoreError.invalidRecord(
                        path: url.path,
                        line: lineIndex + 1,
                        underlying: error
                    )
                }
            }
        }
    }

    private func rewriteRecords<T: Decodable>(
        in directory: String,
        as _: T.Type,
        keep: (T) -> Bool
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        let decoder = JSONDecoder()
        var removedCount = 0
        for file in files.sorted() where file.hasSuffix(".ndjson") {
            let url = URL(fileURLWithPath: directory + file)
            let content = try String(contentsOf: url, encoding: .utf8)
            var keptLines: [Substring] = []
            var fileRemovedCount = 0
            for (lineIndex, line) in content.split(separator: "\n").enumerated() {
                do {
                    let record = try decoder.decode(T.self, from: Data(line.utf8))
                    if keep(record) {
                        keptLines.append(line)
                    } else {
                        fileRemovedCount += 1
                    }
                } catch {
                    throw SpeakerStoreError.invalidRecord(
                        path: url.path,
                        line: lineIndex + 1,
                        underlying: error
                    )
                }
            }
            guard fileRemovedCount > 0 else { continue }
            let replacement = keptLines.isEmpty
                ? Data()
                : Data((keptLines.joined(separator: "\n") + "\n").utf8)
            try replacement.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
            removedCount += fileRemovedCount
        }
        return removedCount
    }

    private func withExclusiveFileLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(
            lockPath,
            O_RDWR | O_CREAT | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}

enum SpeakerStoreError: LocalizedError {
    case invalidRecord(path: String, line: Int, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .invalidRecord(path, line, underlying):
            return "Invalid speaker NDJSON at \(path):\(line): \(underlying)"
        }
    }
}

enum SpeakerIdentityError: LocalizedError {
    case invalidAudio([String])
    case invalidEmbedding(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidAudio(issues):
            return "Speaker audio was rejected: \(issues.joined(separator: ", "))"
        case let .invalidEmbedding(expected, actual):
            return "Unexpected speaker embedding dimension: expected \(expected), got \(actual)"
        }
    }
}

actor SpeakerIdentityStream {
    private let manager: DiarizerManager
    private let matcher: SpeakerProfileMatcher
    private var profiles: [String: SpeakerProfile]

    init(store: SpeakerStore, matcher: SpeakerProfileMatcher = .init()) async throws {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        self.manager = manager
        self.matcher = matcher
        self.profiles = try SpeakerProfileBuilder.build(
            store: store,
            mappings: try store.loadMappings()
        )
    }

    func identify(
        candidate: SpeakerEmbeddingCandidate,
        engineStartUnixMs: Int64,
        sessionId: String,
        device: String?
    ) throws -> SpeakerEmbeddingSample {
        let validation = manager.validateAudio(candidate.samples)
        guard validation.isValid else {
            throw SpeakerIdentityError.invalidAudio(validation.issues)
        }
        let embedding = try manager.extractSpeakerEmbedding(from: candidate.samples)
        guard embedding.count == SpeakerEmbeddingMetadata.current.dimension else {
            throw SpeakerIdentityError.invalidEmbedding(
                expected: SpeakerEmbeddingMetadata.current.dimension,
                actual: embedding.count
            )
        }
        let match = matcher.match(embedding: embedding, profiles: profiles)
        let learnEligible = match.map(matcher.canAdapt) ?? false
        let sample = SpeakerEmbeddingSample(
            id: String(UUID().uuidString.prefix(12).lowercased()),
            unixTimeMs: engineStartUnixMs + Int64(candidate.startSec * 1000),
            endUnixTimeMs: engineStartUnixMs + Int64(candidate.endSec * 1000),
            sessionId: sessionId,
            speakerId: "\(sessionId)_\(candidate.speakerIndex)",
            speakerIndex: candidate.speakerIndex,
            device: device,
            durationSec: candidate.endSec - candidate.startSec,
            rms: candidate.rms,
            embedding: embedding,
            proposedProfileId: match?.profileId,
            matchDistance: match?.distance,
            matchMargin: match?.margin,
            learnEligible: learnEligible,
            source: SpeakerEmbeddingMetadata.current
        )
        if learnEligible, let profileId = match?.profileId, let profile = profiles[profileId] {
            profiles[profileId] = profile.addingAdaptive(embedding)
        }
        return sample
    }
}

struct SpeakerProfileResolver: Sendable {
    private let mappingResolver: SpeakerMappingResolver
    private let automaticProfiles: [String: String]

    init(
        samples: [SpeakerEmbeddingSample],
        mappings: [SpeakerMappingRecord],
        profiles: [String: SpeakerProfile]? = nil,
        matcher: SpeakerProfileMatcher = .init()
    ) {
        mappingResolver = SpeakerMappingResolver(mappings: mappings)
        var counts: [String: [String: Int]] = [:]
        for sample in samples where sample.learnEligible && sample.matchMargin != nil {
            guard let proposed = sample.proposedProfileId else { continue }
            if let profiles {
                guard let currentMatch = matcher.match(
                    embedding: sample.embedding,
                    profiles: profiles
                ), currentMatch.profileId == proposed, matcher.canAdapt(currentMatch)
                else {
                    continue
                }
            }
            let key = "\(sample.sessionId)_\(sample.speakerIndex)"
            counts[key, default: [:]][proposed, default: 0] += 1
        }
        automaticProfiles = counts.compactMapValues { profileCounts in
            let ranked = profileCounts.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }
            guard let first = ranked.first,
                  ranked.count == 1 || first.value > ranked[1].value
            else {
                return nil
            }
            return first.key
        }
    }

    func profileId(sessionId: String, speakerIndex: Int, at unixTimeMs: Int64) -> String? {
        if let mapping = mappingResolver.mapping(
            sessionId: sessionId,
            speakerIndex: speakerIndex,
            at: unixTimeMs
        ) {
            return mapping.profileId
        }
        return automaticProfiles["\(sessionId)_\(speakerIndex)"]
    }
}

func parseSpeakerIndex(from speakerId: String?) -> Int? {
    guard let suffix = speakerId?.split(separator: "_").last else { return nil }
    return Int(suffix)
}

func resolvedSpeakerIndex(
    for transcription: TranscriptionRecord,
    spans: [SpeakerSpanRecord]
) -> Int? {
    guard let sessionId = transcription.sessionId else {
        return parseSpeakerIndex(from: transcription.speakerId)
    }
    var weights: [Int: Int64] = [:]
    for span in spans where span.sessionId == sessionId {
        let overlap = min(transcription.endUnixTimeMs, span.endUnixTimeMs)
            - max(transcription.unixTimeMs, span.unixTimeMs)
        if overlap > 0 {
            weights[span.speakerIndex, default: 0] += overlap
        }
    }
    return weights.max {
        $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
    }?.key ?? parseSpeakerIndex(from: transcription.speakerId)
}
