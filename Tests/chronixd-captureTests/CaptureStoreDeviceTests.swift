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

        try write(
            transcription(timestamp: 1_000, sessionID: "air"),
            to: store.capturesDir + "1970-01-01_work-laptop.ndjson"
        )
        try write(
            transcription(timestamp: 2_000, sessionID: "pro"),
            to: store.capturesDir + "1970-01-01_personal-laptop.ndjson"
        )
        try write(
            transcription(timestamp: 3_000, sessionID: "legacy"),
            to: store.capturesDir + "1970-01-01.ndjson"
        )
        XCTAssertEqual(store.availableDevices(), ["personal-laptop", "work-laptop"])

        let allRecords = try store.readRecords(from: 0, to: 10_000)
        XCTAssertEqual(allRecords.count, 3)

        let airRecords = try store.readRecords(
            from: 0,
            to: 10_000,
            devices: ["work-laptop"]
        )
        XCTAssertEqual(airRecords.count, 1)
        XCTAssertTrue(airRecords.allSatisfy { record in
            (record as? TranscriptionRecord)?.sessionId == "air"
        })

        let syncedDevices = try store.readRecords(
            from: 0,
            to: 10_000,
            devices: ["work-laptop", "personal-laptop"]
        )
        XCTAssertEqual(syncedDevices.count, 2)
    }

    func testNormalizeDeviceNameMatchesCaptureFilenameFormat() {
        XCTAssertEqual(CaptureStore.normalizeDeviceName("Work-Laptop.local"), "work-laptop")
        XCTAssertEqual(CaptureStore.normalizeDeviceName("Personal Laptop"), "personal-laptop")
    }

    func testSessionReadIncludesRecordsOutsideQueryWindow() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("chronixd-capture-tests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let store = CaptureStore(dataDir: temporaryDirectory.path)
        try fileManager.createDirectory(atPath: store.capturesDir, withIntermediateDirectories: true)
        let path = store.capturesDir + "1970-01-01_work-laptop.ndjson"
        let span = SpeakerSpanRecord(
            unixTimeMs: 1_000,
            endUnixTimeMs: 2_000,
            sessionId: "session",
            speakerId: "session_0",
            speakerIndex: 0,
            isFinal: true,
            source: .init(
                library: "FluidAudio",
                libraryVersion: "0.14.4",
                model: "sortformer",
                variant: "fastV2_1"
            )
        )
        try write(span, to: path)
        try append(transcription(timestamp: 10_000, sessionID: "session"), to: path)

        XCTAssertEqual(try store.readRecords(from: 1_500, to: 1_600).count, 1)
        XCTAssertEqual(try store.readRecords(from: 9_000, to: 11_000).count, 1)
        XCTAssertEqual(try store.readRecords(sessionIds: ["session"]).count, 2)
    }

    func testTimeOnlyParsingUsesReferenceDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 15,
            hour: 23
        )))
        let parsedMs = try Context.parseTime("14:30", relativeTo: reference)
        let parsed = Date(timeIntervalSince1970: Double(parsedMs) / 1_000)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
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


    private func append(_ record: any CaptureRecord, to path: String) throws {
        let line = Data((try CaptureRecordCoder.encode(record) + "\n").utf8)
        try NDJSONFileAppender.append(line, to: path)
    }
}
