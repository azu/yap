import Foundation
import XCTest
@testable import chronixd_capture

final class SpeakerProfilesTests: XCTestCase {
    func testAudioTimelineExtractsRangesAndPrunesOldChunks() throws {
        var timeline = AudioTimelineBuffer(sampleRate: 10, retentionSec: 2)
        timeline.append(Array(0..<10).map(Float.init))
        timeline.append(Array(10..<20).map(Float.init))

        XCTAssertEqual(try XCTUnwrap(timeline.samples(from: 0.5, to: 1.5)), Array(5..<15).map(Float.init))

        timeline.append(Array(20..<30).map(Float.init))
        XCTAssertNil(timeline.samples(from: 0, to: 0.5))
        XCTAssertEqual(try XCTUnwrap(timeline.samples(from: 1, to: 3)), Array(10..<30).map(Float.init))
    }

    func testOverlapRejectsOnlyAnotherSpeaker() {
        let segments = [
            DiarizationSegmentRecord(startSec: 0, endSec: 5, speakerIndex: 0),
            DiarizationSegmentRecord(startSec: 4, endSec: 6, speakerIndex: 1),
        ]
        XCTAssertTrue(DiarizationStream.overlapsOtherSpeaker(
            speakerIndex: 0,
            from: 0,
            to: 5,
            finalizedSegments: segments
        ))
        XCTAssertFalse(DiarizationStream.overlapsOtherSpeaker(
            speakerIndex: 0,
            from: 0,
            to: 4,
            finalizedSegments: segments
        ))
    }

    func testTentativeOtherSpeakerRejectsEmbeddingCandidate() {
        let finalized = [DiarizationSegmentRecord(startSec: 0, endSec: 5, speakerIndex: 0)]
        let tentative = [DiarizationSegmentRecord(startSec: 2, endSec: 6, speakerIndex: 1)]

        XCTAssertTrue(DiarizationStream.overlapsOtherSpeaker(
            speakerIndex: 0,
            from: 0,
            to: 5,
            finalizedSegments: finalized,
            tentativeSegments: tentative
        ))
    }

    func testManualMappingBuildsConfirmedProfile() throws {
        let sample = makeSample(
            embedding: unitVector(at: 0),
            proposedProfileId: "wrong",
            learnEligible: true
        )
        let mapping = makeMapping(profileId: "self")
        let profiles = SpeakerProfileBuilder.build(samples: [sample], mappings: [mapping])
        let profile = try XCTUnwrap(profiles["self"])

        XCTAssertEqual(profile.confirmedSampleCount, 1)
        XCTAssertEqual(profile.adaptiveSampleCount, 0)
        XCTAssertEqual(profile.centroid, unitVector(at: 0))
        XCTAssertNil(profiles["wrong"])
    }

    func testMatcherRequiresSeparationFromSecondProfile() throws {
        let source = SpeakerEmbeddingMetadata.current
        let profiles = [
            "self": SpeakerProfile(
                id: "self",
                source: source,
                centroid: unitVector(at: 0),
                confirmedSampleCount: 1,
                adaptiveSampleCount: 0
            ),
            "other": SpeakerProfile(
                id: "other",
                source: source,
                centroid: unitVector(at: 1),
                confirmedSampleCount: 1,
                adaptiveSampleCount: 0
            ),
        ]
        let matcher = SpeakerProfileMatcher()
        XCTAssertEqual(try XCTUnwrap(matcher.match(
            embedding: unitVector(at: 0),
            profiles: profiles
        )).profileId, "self")

        var ambiguous = [Float](repeating: 0, count: 256)
        ambiguous[0] = 1
        ambiguous[1] = 1
        XCTAssertNil(matcher.match(embedding: ambiguous, profiles: profiles))
    }

    func testSingleProfileRejectsWeakMatchAndDoesNotAdaptStrongMatch() throws {
        let source = SpeakerEmbeddingMetadata.current
        let profiles = [
            "self": SpeakerProfile(
                id: "self",
                source: source,
                centroid: unitVector(at: 0),
                confirmedSampleCount: 1,
                adaptiveSampleCount: 0
            ),
        ]
        let matcher = SpeakerProfileMatcher()
        var distancePointFour = [Float](repeating: 0, count: 256)
        distancePointFour[0] = 0.6
        distancePointFour[1] = 0.8

        XCTAssertNil(matcher.match(embedding: distancePointFour, profiles: profiles))
        let strongMatch = try XCTUnwrap(matcher.match(
            embedding: unitVector(at: 0),
            profiles: profiles
        ))
        XCTAssertFalse(matcher.canAdapt(strongMatch))
    }

    func testLibraryPatchVersionDoesNotInvalidateProfile() throws {
        let source = SpeakerEmbeddingMetadata.current
        let olderSource = SpeakerEmbeddingSource(
            library: source.library,
            libraryVersion: "0.14.3",
            model: source.model,
            variant: source.variant,
            dimension: source.dimension,
            sampleRate: source.sampleRate
        )
        let sample = makeSample(
            embedding: unitVector(at: 0),
            proposedProfileId: nil,
            learnEligible: false,
            source: olderSource
        )

        let profile = try XCTUnwrap(SpeakerProfileBuilder.build(
            samples: [sample],
            mappings: [makeMapping(profileId: "self")]
        )["self"])
        XCTAssertEqual(profile.confirmedSampleCount, 1)
    }

    func testLibraryMinorVersionKeepsProfilesIsolated() {
        let source = SpeakerEmbeddingMetadata.current
        let newerMinorSource = SpeakerEmbeddingSource(
            library: source.library,
            libraryVersion: "0.15.0",
            model: source.model,
            variant: source.variant,
            dimension: source.dimension,
            sampleRate: source.sampleRate
        )
        let sample = makeSample(
            embedding: unitVector(at: 0),
            proposedProfileId: nil,
            learnEligible: false,
            source: newerMinorSource
        )

        XCTAssertTrue(SpeakerProfileBuilder.build(
            samples: [sample],
            mappings: [makeMapping(profileId: "self")]
        ).isEmpty)
    }

    func testConfirmedEvidenceOutweighsRevalidatedAdaptiveSamples() throws {
        let confirmedSelf = makeSample(
            embedding: unitVector(at: 0),
            proposedProfileId: nil,
            learnEligible: false,
            sessionId: "self-confirmed",
            speakerIndex: 0
        )
        let confirmedOther = makeSample(
            embedding: unitVector(at: 1),
            proposedProfileId: nil,
            learnEligible: false,
            sessionId: "other-confirmed",
            speakerIndex: 0
        )
        var adaptiveVector = [Float](repeating: 0, count: 256)
        adaptiveVector[0] = 0.9
        adaptiveVector[2] = sqrt(0.19)
        let adaptive = makeSample(
            embedding: adaptiveVector,
            proposedProfileId: "self",
            learnEligible: true,
            sessionId: "adaptive",
            speakerIndex: 0
        )
        let profiles = SpeakerProfileBuilder.build(
            samples: [confirmedSelf, confirmedOther, adaptive],
            mappings: [
                makeMapping(profileId: "self", sessionId: "self-confirmed"),
                makeMapping(profileId: "other", sessionId: "other-confirmed"),
            ]
        )
        let profile = try XCTUnwrap(profiles["self"])

        XCTAssertEqual(profile.adaptiveSampleCount, 1)
        XCTAssertLessThan(
            try XCTUnwrap(SpeakerVector.cosineDistance(profile.centroid, confirmedSelf.embedding)),
            try XCTUnwrap(SpeakerVector.cosineDistance(profile.centroid, adaptive.embedding))
        )
    }

    func testResolverPrefersManualMappingOverAutomaticMatch() {
        let sample = makeSample(
            embedding: unitVector(at: 0),
            proposedProfileId: "automatic",
            learnEligible: true
        )
        let resolver = SpeakerProfileResolver(
            samples: [sample],
            mappings: [makeMapping(profileId: "manual")]
        )
        XCTAssertEqual(
            resolver.profileId(sessionId: "session", speakerIndex: 0, at: 1_000),
            "manual"
        )
    }

    func testResolverRevalidatesStoredAutomaticMatch() {
        let source = SpeakerEmbeddingMetadata.current
        let profiles = [
            "self": SpeakerProfile(
                id: "self",
                source: source,
                centroid: unitVector(at: 0),
                confirmedSampleCount: 1,
                adaptiveSampleCount: 0
            ),
            "other": SpeakerProfile(
                id: "other",
                source: source,
                centroid: unitVector(at: 1),
                confirmedSampleCount: 1,
                adaptiveSampleCount: 0
            ),
        ]
        let staleSample = makeSample(
            embedding: unitVector(at: 1),
            proposedProfileId: "self",
            learnEligible: true
        )
        let resolver = SpeakerProfileResolver(
            samples: [staleSample],
            mappings: [],
            profiles: profiles
        )

        XCTAssertNil(resolver.profileId(sessionId: "session", speakerIndex: 0, at: 1_000))
    }

    func testSavedSpansBackfillTranscriptionSpeaker() {
        let transcription = TranscriptionRecord(
            unixTimeMs: 1_000,
            endUnixTimeMs: 5_000,
            sessionId: "session",
            rms: nil,
            device: nil,
            speakerId: nil,
            text: "example"
        )
        let spans = [
            SpeakerSpanRecord(
                unixTimeMs: 1_000,
                endUnixTimeMs: 2_000,
                sessionId: "session",
                speakerId: "session_0",
                speakerIndex: 0,
                isFinal: true,
                source: .init(library: "FluidAudio", libraryVersion: "0.14.4", model: "sortformer", variant: "fastV2_1")
            ),
            SpeakerSpanRecord(
                unixTimeMs: 2_000,
                endUnixTimeMs: 5_000,
                sessionId: "session",
                speakerId: "session_1",
                speakerIndex: 1,
                isFinal: true,
                source: .init(library: "FluidAudio", libraryVersion: "0.14.4", model: "sortformer", variant: "fastV2_1")
            ),
        ]

        XCTAssertEqual(resolvedSpeakerIndex(for: transcription, spans: spans), 1)
    }

    func testSpeakerStoreRoundTrip() throws {
        let root = NSTemporaryDirectory() + "chronixd-speaker-tests-" + UUID().uuidString
        let store = SpeakerStore(dataDir: root)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sample = makeSample(
            embedding: unitVector(at: 0),
            proposedProfileId: nil,
            learnEligible: false
        )
        let mapping = makeMapping(profileId: "self")

        try store.append(sample: sample, timestamp: Date(timeIntervalSince1970: 1_000))
        try store.append(mapping: mapping, timestamp: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(try store.loadSamples().map(\.id), [sample.id])
        XCTAssertEqual(try store.loadMappings().map(\.id), [mapping.id])
    }

    func testStreamingProfileBuildMatchesInMemoryBuild() throws {
        let root = NSTemporaryDirectory() + "chronixd-speaker-tests-" + UUID().uuidString
        let store = SpeakerStore(dataDir: root)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let samples = [
            makeSample(
                id: "sample-a",
                embedding: unitVector(at: 0),
                proposedProfileId: nil,
                learnEligible: false,
                sessionId: "session-a"
            ),
            makeSample(
                id: "sample-b",
                embedding: unitVector(at: 1),
                proposedProfileId: nil,
                learnEligible: false,
                sessionId: "session-b"
            ),
        ]
        let mappings = [
            makeMapping(id: "mapping-a", profileId: "self", sessionId: "session-a"),
            makeMapping(id: "mapping-b", profileId: "other", sessionId: "session-b"),
        ]
        for sample in samples {
            try store.append(sample: sample, timestamp: Date(timeIntervalSince1970: 1_000))
        }
        for mapping in mappings {
            try store.append(mapping: mapping, timestamp: Date(timeIntervalSince1970: 1_000))
        }

        let memoryProfiles = SpeakerProfileBuilder.build(samples: samples, mappings: mappings)
        let streamingProfiles = try SpeakerProfileBuilder.build(store: store, mappings: mappings)
        XCTAssertEqual(streamingProfiles.keys.sorted(), memoryProfiles.keys.sorted())
        XCTAssertEqual(streamingProfiles["self"]?.centroid, memoryProfiles["self"]?.centroid)
        XCTAssertEqual(streamingProfiles["other"]?.centroid, memoryProfiles["other"]?.centroid)
    }

    func testSpeakerStoreReportsInvalidNDJSON() throws {
        let root = NSTemporaryDirectory() + "chronixd-speaker-tests-" + UUID().uuidString
        let store = SpeakerStore(dataDir: root)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try store.setup()
        let path = root + "/speakers/embeddings/invalid.ndjson"
        try Data("{invalid}\n".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try store.loadSamples()) { error in
            guard case let SpeakerStoreError.invalidRecord(recordPath, line, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(recordPath.hasSuffix("invalid.ndjson"))
            XCTAssertEqual(line, 1)
        }
    }

    func testForgetRemovesMappingsAndAssociatedEmbeddings() throws {
        let root = NSTemporaryDirectory() + "chronixd-speaker-tests-" + UUID().uuidString
        let store = SpeakerStore(dataDir: root)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let selfConfirmed = makeSample(
            id: "self-confirmed",
            embedding: unitVector(at: 0),
            proposedProfileId: nil,
            learnEligible: false,
            sessionId: "self-session"
        )
        let selfAdaptive = makeSample(
            id: "self-adaptive",
            embedding: unitVector(at: 0),
            proposedProfileId: "self",
            learnEligible: true,
            sessionId: "adaptive-session"
        )
        let other = makeSample(
            id: "other-confirmed",
            embedding: unitVector(at: 1),
            proposedProfileId: nil,
            learnEligible: false,
            sessionId: "other-session"
        )
        let selfMapping = makeMapping(id: "self-mapping", profileId: "self", sessionId: "self-session")
        let otherMapping = makeMapping(id: "other-mapping", profileId: "other", sessionId: "other-session")
        for sample in [selfConfirmed, selfAdaptive, other] {
            try store.append(sample: sample, timestamp: Date(timeIntervalSince1970: 1_000))
        }
        for mapping in [selfMapping, otherMapping] {
            try store.append(mapping: mapping, timestamp: Date(timeIntervalSince1970: 1_000))
        }

        let result = try store.forget(profileId: "self")

        XCTAssertEqual(result.removedEmbeddingCount, 2)
        XCTAssertEqual(result.removedMappingCount, 1)
        XCTAssertEqual(try store.loadSamples().map(\.id), [other.id])
        XCTAssertEqual(try store.loadMappings().map(\.id), [otherMapping.id])
    }

    private func unitVector(at index: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: 256)
        vector[index] = 1
        return vector
    }

    private func makeSample(
        id: String = "sample",
        embedding: [Float],
        proposedProfileId: String?,
        learnEligible: Bool,
        sessionId: String = "session",
        speakerIndex: Int = 0,
        source: SpeakerEmbeddingSource = SpeakerEmbeddingMetadata.current
    ) -> SpeakerEmbeddingSample {
        SpeakerEmbeddingSample(
            id: id,
            unixTimeMs: 1_000,
            endUnixTimeMs: 5_000,
            sessionId: sessionId,
            speakerId: "\(sessionId)_\(speakerIndex)",
            speakerIndex: speakerIndex,
            device: "Test Microphone",
            durationSec: 4,
            rms: 0.1,
            embedding: embedding,
            proposedProfileId: proposedProfileId,
            matchDistance: proposedProfileId == nil ? nil : 0.1,
            matchMargin: proposedProfileId == nil ? nil : 0.5,
            learnEligible: learnEligible,
            source: source
        )
    }

    private func makeMapping(
        id: String = "mapping",
        profileId: String,
        sessionId: String = "session",
        speakerIndex: Int = 0
    ) -> SpeakerMappingRecord {
        SpeakerMappingRecord(
            id: id,
            createdUnixTimeMs: 2_000,
            sessionId: sessionId,
            speakerId: "\(sessionId)_\(speakerIndex)",
            speakerIndex: speakerIndex,
            profileId: profileId,
            fromUnixTimeMs: nil,
            toUnixTimeMs: nil,
            source: "manual"
        )
    }
}
