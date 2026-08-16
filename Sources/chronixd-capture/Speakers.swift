import ArgumentParser
import Foundation

struct Speakers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Review and map persistent speaker profiles.",
        subcommands: [Review.self, Assign.self, List.self, Forget.self]
    )

    struct Assign: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Assign a session-scoped speaker to a persistent profile."
        )

        @Option(name: .long, help: "Data directory (required).")
        var dataDir: String

        @Option(name: .long, help: "Capture session ID.")
        var session: String

        @Option(name: .long, help: "Sortformer speaker index.")
        var speakerIndex: Int

        @Option(name: .long, help: "Persistent profile ID, such as self.")
        var profile: String

        @Option(name: .long, help: "Optional start time (ISO 8601 or HH:mm on the session date).")
        var from: String?

        @Option(name: .long, help: "Optional end time (ISO 8601 or HH:mm on the session date).")
        var to: String?

        func validate() throws {
            guard speakerIndex >= 0 else {
                throw ValidationError("--speaker-index must be zero or greater.")
            }
            guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--profile must not be empty.")
            }
        }

        func run() throws {
            let captureRecords = try CaptureStore(dataDir: dataDir).readRecords(sessionId: session)
            let speakerStore = SpeakerStore(dataDir: dataDir)
            let allSessionSamples = try speakerStore.loadSamples(sessionIds: [session])
            let sessionSamples = allSessionSamples.filter {
                $0.speakerIndex == speakerIndex
            }
            let knownIndices = Set(captureRecords.compactMap(Self.speakerIndex))
                .union(sessionSamples.map(\.speakerIndex))
            guard knownIndices.contains(speakerIndex) else {
                throw CleanExit.message("No speaker \(speakerIndex) was found in session \(session).")
            }

            let timeBounds = captureRecords.flatMap(Self.timeBounds)
                + allSessionSamples.flatMap { [$0.unixTimeMs, $0.endUnixTimeMs] }
            guard let sessionStartMs = timeBounds.min(), let sessionEndMs = timeBounds.max() else {
                throw CleanExit.message("No timestamped data was found in session \(session).")
            }
            let sessionDate = Date(timeIntervalSince1970: Double(sessionStartMs) / 1000)
            let fromMs = try from.map { try Context.parseTime($0, relativeTo: sessionDate) }
            let toMs = try to.map { try Context.parseTime($0, relativeTo: sessionDate) }
            if let fromMs, let toMs, fromMs > toMs {
                throw ValidationError("--from must be earlier than or equal to --to.")
            }
            let effectiveStart = fromMs ?? sessionStartMs
            let effectiveEnd = toMs ?? sessionEndMs
            guard effectiveStart <= sessionEndMs, effectiveEnd >= sessionStartMs else {
                throw ValidationError("--from/--to does not overlap session \(session). Use ISO 8601 or HH:mm on the session date.")
            }
            let now = Date()
            let mapping = SpeakerMappingRecord(
                id: String(UUID().uuidString.prefix(12).lowercased()),
                createdUnixTimeMs: Int64(now.timeIntervalSince1970 * 1000),
                sessionId: session,
                speakerId: "\(session)_\(speakerIndex)",
                speakerIndex: speakerIndex,
                profileId: profile.trimmingCharacters(in: .whitespacesAndNewlines),
                fromUnixTimeMs: fromMs,
                toUnixTimeMs: toMs,
                source: "manual"
            )
            try speakerStore.append(mapping: mapping, timestamp: now)
            print(try SpeakerJSON.encode(mapping))
        }

        private static func speakerIndex(_ record: any CaptureRecord) -> Int? {
            switch record {
            case let span as SpeakerSpanRecord:
                return span.speakerIndex
            case let transcription as TranscriptionRecord:
                return parseSpeakerIndex(from: transcription.speakerId)
            default:
                return nil
            }
        }

        private static func timeBounds(_ record: any CaptureRecord) -> [Int64] {
            switch record {
            case let record as ScreenshotRecord: [record.unixTimeMs]
            case let record as TranscriptionRecord: [record.unixTimeMs, record.endUnixTimeMs]
            case let record as CameraRecord: [record.unixTimeMs]
            case let record as SpeakerSpanRecord: [record.unixTimeMs, record.endUnixTimeMs]
            case let record as DiarizationHealthRecord: [record.unixTimeMs]
            default: []
            }
        }
    }

    struct Review: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show speaker clusters, excerpts, and current profile proposals for a session."
        )

        @Option(name: .long, help: "Data directory (required).")
        var dataDir: String

        @Option(name: .long, help: "Capture session ID.")
        var session: String

        func run() throws {
            let records = try CaptureStore(dataDir: dataDir).readRecords(sessionId: session)
            let speakerStore = SpeakerStore(dataDir: dataDir)
            let samples = try speakerStore.loadSamples(sessionIds: [session])
            let mappings = try speakerStore.loadMappings()
            let profiles = try SpeakerProfileBuilder.build(store: speakerStore, mappings: mappings)
            let sessionSamples = samples.filter { $0.sessionId == session }
            let resolver = SpeakerProfileResolver(
                samples: samples,
                mappings: mappings,
                profiles: profiles
            )
            let allSpans = records.compactMap { $0 as? SpeakerSpanRecord }

            var indices = Set(records.compactMap { record -> Int? in
                switch record {
                case let span as SpeakerSpanRecord: return span.speakerIndex
                case let transcription as TranscriptionRecord:
                    return parseSpeakerIndex(from: transcription.speakerId)
                default: return nil
                }
            })
            indices.formUnion(sessionSamples.map(\.speakerIndex))
            guard !indices.isEmpty else {
                throw CleanExit.message("No speaker data was found for session \(session).")
            }

            for index in indices.sorted() {
                let clusterId = "\(session)_\(index)"
                let clusterSamples = sessionSamples.filter { $0.speakerIndex == index }
                let spans = allSpans.filter { $0.speakerIndex == index }
                let excerpts = records.compactMap { $0 as? TranscriptionRecord }
                    .filter { resolvedSpeakerIndex(for: $0, spans: allSpans) == index }
                    .sorted { $0.unixTimeMs < $1.unixTimeMs }
                    .prefix(5)
                    .map { SpeakerReviewExcerpt(unixTimeMs: $0.unixTimeMs, text: $0.text) }
                let latestTime = ([spans.map(\.endUnixTimeMs), clusterSamples.map(\.endUnixTimeMs)]
                    .flatMap { $0 }
                    .max()) ?? 0
                let proposedCounts = Dictionary(grouping: clusterSamples.compactMap(\.proposedProfileId), by: { $0 })
                    .mapValues(\.count)
                let output = SpeakerReviewOutput(
                    sessionId: session,
                    speakerId: clusterId,
                    speakerIndex: index,
                    profileId: resolver.profileId(
                        sessionId: session,
                        speakerIndex: index,
                        at: latestTime
                    ),
                    spanCount: spans.count,
                    embeddingCount: clusterSamples.count,
                    learnEligibleCount: clusterSamples.filter(\.learnEligible).count,
                    proposedProfileCounts: proposedCounts,
                    excerpts: Array(excerpts)
                )
                print(try SpeakerJSON.encode(output))
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List persistent speaker profiles reconstructed from saved data."
        )

        @Option(name: .long, help: "Data directory (required).")
        var dataDir: String

        func run() throws {
            let store = SpeakerStore(dataDir: dataDir)
            let profiles = try SpeakerProfileBuilder.build(
                store: store,
                mappings: try store.loadMappings()
            )
            for profile in profiles.values.sorted(by: { $0.id < $1.id }) {
                let output = SpeakerProfileSummary(
                    profileId: profile.id,
                    confirmedSampleCount: profile.confirmedSampleCount,
                    adaptiveSampleCount: profile.adaptiveSampleCount,
                    sampleCount: profile.sampleCount,
                    source: profile.source
                )
                print(try SpeakerJSON.encode(output))
            }
        }
    }

    struct Forget: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Permanently remove a profile's mappings and associated embeddings. Stop capture first."
        )

        @Option(name: .long, help: "Data directory (required).")
        var dataDir: String

        @Option(name: .long, help: "Persistent profile ID to remove.")
        var profile: String

        @Flag(name: .long, help: "Confirm permanent deletion. Capture must be stopped first.")
        var confirm = false

        func validate() throws {
            guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--profile must not be empty.")
            }
            guard confirm else {
                throw ValidationError("This permanently removes speaker mappings and embeddings. Stop capture, then pass --confirm.")
            }
        }

        func run() throws {
            let profileId = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try SpeakerStore(dataDir: dataDir).forget(profileId: profileId)
            print(try SpeakerJSON.encode(result))
        }
    }
}

private struct SpeakerReviewExcerpt: Codable {
    let unixTimeMs: Int64
    let text: String
}

private struct SpeakerReviewOutput: Codable {
    let sessionId: String
    let speakerId: String
    let speakerIndex: Int
    let profileId: String?
    let spanCount: Int
    let embeddingCount: Int
    let learnEligibleCount: Int
    let proposedProfileCounts: [String: Int]
    let excerpts: [SpeakerReviewExcerpt]
}

private struct SpeakerProfileSummary: Codable {
    let profileId: String
    let confirmedSampleCount: Int
    let adaptiveSampleCount: Int
    let sampleCount: Int
    let source: SpeakerEmbeddingSource
}

private enum SpeakerJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
