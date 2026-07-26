import Foundation
import XCTest
@testable import chronixd_capture

final class CaptureStoreDeviceTests: XCTestCase {
    func testReadRecordsFiltersByDeviceFilename() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("chronixd-capture-tests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let store = CaptureStore(dataDir: temporaryDirectory.path)
        try fileManager.createDirectory(atPath: store.capturesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: store.summariesDir, withIntermediateDirectories: true)

        try write(
            transcription(timestamp: 1_000, sessionID: "air"),
            to: store.capturesDir + "2026-07-26_work-laptop.ndjson"
        )
        try write(
            transcription(timestamp: 2_000, sessionID: "pro"),
            to: store.capturesDir + "2026-07-26_personal-laptop.ndjson"
        )
        try write(
            transcription(timestamp: 3_000, sessionID: "legacy"),
            to: store.capturesDir + "2026-07-26.ndjson"
        )
        try write(
            SummaryRecord(fromUnixTimeMs: 4_000, toUnixTimeMs: 4_500, sessionId: "air", text: "summary"),
            to: store.summariesDir + "2026-07-26_work-laptop.ndjson"
        )
        try write(
            SummaryRecord(fromUnixTimeMs: 5_000, toUnixTimeMs: 5_500, sessionId: nil, text: "global"),
            to: store.summariesDir + "global.ndjson"
        )

        XCTAssertEqual(store.availableDevices(), ["personal-laptop", "work-laptop"])

        let allRecords = try store.readRecords(from: 0, to: 10_000)
        XCTAssertEqual(allRecords.count, 5)

        let airRecords = try store.readRecords(
            from: 0,
            to: 10_000,
            devices: ["work-laptop"]
        )
        XCTAssertEqual(airRecords.count, 2)
        XCTAssertTrue(airRecords.allSatisfy { record in
            switch record {
            case let record as TranscriptionRecord: return record.sessionId == "air"
            case let record as SummaryRecord: return record.sessionId == "air"
            default: return false
            }
        })

        let syncedDevices = try store.readRecords(
            from: 0,
            to: 10_000,
            devices: ["work-laptop", "personal-laptop"]
        )
        XCTAssertEqual(syncedDevices.count, 3)
    }

    func testNormalizeDeviceNameMatchesCaptureFilenameFormat() {
        XCTAssertEqual(CaptureStore.normalizeDeviceName("Work-Laptop.local"), "work-laptop")
        XCTAssertEqual(CaptureStore.normalizeDeviceName("Personal Laptop"), "personal-laptop")
    }

    private func transcription(timestamp: Int64, sessionID: String) -> TranscriptionRecord {
        TranscriptionRecord(
            unixTimeMs: timestamp,
            endUnixTimeMs: timestamp + 100,
            sessionId: sessionID,
            rms: nil,
            device: nil,
            speakerId: nil,
            text: sessionID
        )
    }

    private func write(_ record: any CaptureRecord, to path: String) throws {
        let line = try CaptureRecordCoder.encode(record) + "\n"
        try Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}
