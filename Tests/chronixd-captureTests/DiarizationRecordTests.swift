import Foundation
import XCTest
@testable import chronixd_capture

final class DiarizationRecordTests: XCTestCase {
    func testSpeakerSpanUsesCaptureSessionTimeline() {
        let record = makeSpeakerSpanRecord(
            segment: DiarizationSegmentRecord(startSec: 1.25, endSec: 2.5, speakerIndex: 2),
            engineStartUnixMs: 1_000,
            sessionId: "a1b2c3d4"
        )

        XCTAssertEqual(record.unixTimeMs, 2_250)
        XCTAssertEqual(record.endUnixTimeMs, 3_500)
        XCTAssertEqual(record.speakerId, "a1b2c3d4_2")
        XCTAssertEqual(record.source.libraryVersion, DiarizationMetadata.libraryVersion)
    }

    func testSpeakerSpanRoundTripsThroughCaptureRecordCoder() throws {
        let record = SpeakerSpanRecord(
            unixTimeMs: 1_000,
            endUnixTimeMs: 2_500,
            sessionId: "a1b2c3d4",
            speakerId: "a1b2c3d4_2",
            speakerIndex: 2,
            isFinal: true,
            source: .init(
                library: "FluidAudio",
                libraryVersion: "0.14.4",
                model: "sortformer",
                variant: "fastV2_1"
            )
        )

        let line = try CaptureRecordCoder.encode(record)
        let decoded = try XCTUnwrap(try CaptureRecordCoder.decode(line: line) as? SpeakerSpanRecord)

        XCTAssertEqual(decoded.unixTimeMs, 1_000)
        XCTAssertEqual(decoded.endUnixTimeMs, 2_500)
        XCTAssertEqual(decoded.sessionId, "a1b2c3d4")
        XCTAssertEqual(decoded.speakerId, "a1b2c3d4_2")
        XCTAssertEqual(decoded.speakerIndex, 2)
        XCTAssertTrue(decoded.isFinal)
        XCTAssertEqual(decoded.source.library, "FluidAudio")
        XCTAssertEqual(decoded.source.libraryVersion, "0.14.4")
        XCTAssertEqual(decoded.source.model, "sortformer")
        XCTAssertEqual(decoded.source.variant, "fastV2_1")
    }

    func testHealthRecordCalculatesTimelineDifferences() throws {
        let record = makeDiarizationHealthRecord(
            unixTimeMs: 10_000,
            engineStartUnixMs: -110_000,
            sessionId: "a1b2c3d4",
            status: "running",
            startupError: nil,
            startupErrorUnixTimeMs: nil,
            asr: ASRProgressSnapshot(
                lastResultEndSec: 118,
                lastResultUnixTimeMs: 9_900,
                resultCount: 20,
                errorCount: 1,
                lastErrorUnixTimeMs: 8_000,
                lastError: "ASR example"
            ),
            diarization: DiarizationHealthSnapshot(
                audioInputEndSec: 120,
                syntheticSilenceSec: 1.25,
                diarizationProcessedEndSec: 115.5,
                processCallCount: 60,
                updateCount: 50,
                finalizedSpanCount: 12,
                addAudioErrorCount: 1,
                processErrorCount: 2,
                lastDiarizationUpdateUnixTimeMs: 9_800,
                lastErrorUnixTimeMs: 9_000,
                lastError: "example"
            )
        )

        XCTAssertEqual(try XCTUnwrap(record.asrDiarizationLagSec), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(record.audioDiarizationBacklogSec), 4.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(record.audioWallClockLagSec), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(record.diarizationSyntheticSilenceSec), 1.25, accuracy: 0.0001)
        XCTAssertEqual(record.asrResultCount, 20)
        XCTAssertEqual(record.asrErrorCount, 1)
        XCTAssertEqual(record.diarizationProcessCallCount, 60)
        XCTAssertEqual(record.diarizationUpdateCount, 50)
        XCTAssertEqual(record.diarizationFinalizedSpanCount, 12)
        XCTAssertEqual(record.lastASRError, "ASR example")
        XCTAssertEqual(record.lastDiarizationError, "example")
    }

    func testHealthRecordPreservesInitializationFailure() throws {
        let record = makeDiarizationHealthRecord(
            unixTimeMs: 10_000,
            engineStartUnixMs: -10_000,
            sessionId: "a1b2c3d4",
            status: "initialization_failed",
            startupError: "model load failed",
            startupErrorUnixTimeMs: 9_000,
            asr: ASRProgressSnapshot(
                lastResultEndSec: 20,
                lastResultUnixTimeMs: 9_500,
                resultCount: 2,
                errorCount: 0,
                lastErrorUnixTimeMs: nil,
                lastError: nil
            ),
            diarization: nil
        )

        let line = try CaptureRecordCoder.encode(record)
        let decoded = try XCTUnwrap(try CaptureRecordCoder.decode(line: line) as? DiarizationHealthRecord)
        XCTAssertEqual(decoded.status, "initialization_failed")
        XCTAssertEqual(decoded.lastDiarizationError, "model load failed")
        XCTAssertEqual(decoded.lastDiarizationErrorUnixTimeMs, 9_000)
        XCTAssertNil(decoded.diarizationProcessedEndSec)
    }

    func testRecordedFluidAudioVersionMatchesPackageResolved() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Package.resolved"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(object["pins"] as? [[String: Any]])
        let fluidAudio = try XCTUnwrap(pins.first { ($0["identity"] as? String) == "fluidaudio" })
        let state = try XCTUnwrap(fluidAudio["state"] as? [String: Any])
        XCTAssertEqual(state["version"] as? String, DiarizationMetadata.libraryVersion)
    }

    func testPendingSpansAreAcknowledgedOnlyFromSavedSnapshot() {
        let first = DiarizationSegmentRecord(startSec: 0, endSec: 1, speakerIndex: 0)
        let second = DiarizationSegmentRecord(startSec: 1, endSec: 2, speakerIndex: 1)
        let arrivedDuringWrite = DiarizationSegmentRecord(startSec: 2, endSec: 3, speakerIndex: 0)
        var pending = PendingDiarizationSegments()
        pending.append(first)
        pending.append(second)
        let snapshot = pending.snapshot()

        pending.append(arrivedDuringWrite)
        pending.acknowledge(count: snapshot.count)

        XCTAssertEqual(pending.snapshot().map(\.startSec), [2])
    }
}
