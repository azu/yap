import Darwin
import Foundation

enum NDJSONFileAppender {
    static func append(_ data: Data, to path: String) throws {
        guard !data.isEmpty else { return }
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }

        let written = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, baseAddress, bytes.count)
        }
        guard written == data.count else {
            let code = written < 0 ? Int(errno) : Int(EIO)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Incomplete NDJSON append to \(path) (\(written)/\(data.count) bytes)"]
            )
        }
    }
}

// MARK: - CaptureStore

final class CaptureStore: Sendable {
    let dataDir: String
    let sessionID: String
    private let writeLock = NSLock()

    var capturesDir: String { dataDir + "/captures/" }
    var tmpDir: String { NSTemporaryDirectory() + "chronixd-capture/" + sessionID + "/" }
    var screenshotsDir: String { tmpDir + "screenshots/" }
    var camerasDir: String { tmpDir + "cameras/" }

    /// Base directory for all chronixd-capture tmp files. Used to search for files by ID across sessions.
    static var tmpBaseDir: String { NSTemporaryDirectory() + "chronixd-capture/" }

    init(dataDir: String, sessionID: String = UUID().uuidString) {
        self.dataDir = dataDir
        self.sessionID = sessionID
    }

    /// Create required directories.
    func setup() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: capturesDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: screenshotsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: camerasDir, withIntermediateDirectories: true)
    }

    /// Short hostname used to partition NDJSON files per machine, avoiding git merge conflicts.
    /// Normalized to lowercase alphanumeric and hyphens only.
    static let currentDevice: String = {
        let raw = ProcessInfo.processInfo.hostName
        return normalizeDeviceName(raw)
    }()

    static func normalizeDeviceName(_ raw: String) -> String {
        let shortName = raw.components(separatedBy: ".").first ?? "unknown"
        let normalized = shortName.lowercased()
            .replacing(/[^a-z0-9\-]/, with: "-")
            .replacing(/\-{2,}/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "unknown" : normalized
    }

    /// Append records to the daily per-host NDJSON file (e.g. 2026-03-22_macbook.ndjson).
    func writeCapture(records: [any CaptureRecord], timestamp: Date) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let lines = try records.map { try CaptureRecordCoder.encode($0) }
        let content = lines.joined(separator: "\n") + "\n"
        let data = Data(content.utf8)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "\(formatter.string(from: timestamp))_\(Self.currentDevice).ndjson"
        let path = capturesDir + filename

        try NDJSONFileAppender.append(data, to: path)
    }

    /// Read all records from captures within a time range.
    func readRecords(
        from startMs: Int64,
        to endMs: Int64,
        devices: Set<String>? = nil
    ) throws -> [any CaptureRecord] {
        try readNDJSONFiles(
            in: capturesDir,
            from: startMs,
            to: endMs,
            devices: devices,
            sessionIds: nil
        )
    }

    /// Read capture records belonging to one process invocation across all daily files.
    func readRecords(sessionId: String) throws -> [any CaptureRecord] {
        try readRecords(sessionIds: [sessionId])
    }

    /// Read capture records for a set of process invocations with one file scan.
    func readRecords(
        sessionIds: Set<String>,
        devices: Set<String>? = nil
    ) throws -> [any CaptureRecord] {
        guard !sessionIds.isEmpty else { return [] }
        let records = try readNDJSONFiles(
            in: capturesDir,
            from: .min,
            to: .max,
            devices: devices,
            sessionIds: sessionIds
        )
        return records
    }

    /// Capture device hostnames encoded in per-host NDJSON filenames.
    func availableDevices() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: capturesDir) else {
            return []
        }
        return Array(Set(files.compactMap(Self.deviceName(from:)))).sorted()
    }

    /// Resolve a record ID to tmp file paths by searching across all sessions.
    /// Returns (screenshotPath, cameraPath) — each nil if not found.
    static func resolvePaths(for id: String) -> (screenshot: String?, camera: String?) {
        let fm = FileManager.default
        let base = tmpBaseDir
        guard let sessions = try? fm.contentsOfDirectory(atPath: base) else {
            return (nil, nil)
        }
        for session in sessions {
            let screenshotsDir = base + session + "/screenshots/"
            let camerasDir = base + session + "/cameras/"
            let pngPath = screenshotsDir + id + ".png"
            if fm.fileExists(atPath: pngPath) {
                return (pngPath, nil)
            }
            let camPath = camerasDir + id + ".png"
            if fm.fileExists(atPath: camPath) {
                return (nil, camPath)
            }
        }
        return (nil, nil)
    }

    private func readNDJSONFiles(
        in directory: String,
        from startMs: Int64,
        to endMs: Int64,
        devices: Set<String>?,
        sessionIds: Set<String>?
    ) throws -> [any CaptureRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        let dayRange = Self.dayRange(from: startMs, to: endMs)
        let sessionMarkers = sessionIds?.map { "\"sessionId\":\"\($0)\"" }
        var records: [any CaptureRecord] = []
        for file in files.sorted() where file.hasSuffix(".ndjson") {
            if let dayRange, let fileDay = Self.dayPrefix(from: file),
               fileDay < dayRange.start || fileDay > dayRange.end {
                continue
            }
            if let devices {
                guard let device = Self.deviceName(from: file), devices.contains(device) else { continue }
            }
            let path = directory + file
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") where !line.isEmpty {
                if let sessionMarkers,
                   line.contains("\"sessionId\":\""),
                   !sessionMarkers.contains(where: line.contains) {
                    continue
                }
                guard let record = try? CaptureRecordCoder.decode(line: line) else { continue }
                if let sessionIds,
                   !(Self.sessionId(of: record).map(sessionIds.contains) ?? false) {
                    continue
                }
                if isInRange(record: record, from: startMs, to: endMs) {
                    records.append(record)
                }
            }
        }
        return records
    }

    private static func dayRange(from startMs: Int64, to endMs: Int64) -> (start: String, end: String)? {
        guard startMs != .min, endMs != .max else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let startDate = Date(timeIntervalSince1970: Double(startMs) / 1_000)
        let endDate = Date(timeIntervalSince1970: Double(endMs) / 1_000)
        // A transcription can start before midnight and be flushed into the
        // next day's file. The one-day padding also tolerates synced devices
        // whose local calendar day differs from this Mac.
        let paddedStart = calendar.date(byAdding: .day, value: -1, to: startDate) ?? startDate
        let paddedEnd = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        return (
            formatter.string(from: paddedStart),
            formatter.string(from: paddedEnd)
        )
    }

    private static func dayPrefix(from filename: String) -> String? {
        guard let match = filename.prefix(10).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) else {
            return nil
        }
        return String(match.output)
    }

    private static func deviceName(from filename: String) -> String? {
        guard let match = filename.wholeMatch(
            of: /\d{4}-\d{2}-\d{2}_(?<device>[a-z0-9][a-z0-9\-]*)\.ndjson/
        ) else {
            return nil
        }
        return String(match.device)
    }

    private static func sessionId(of record: any CaptureRecord) -> String? {
        switch record {
        case let r as ScreenshotRecord: return r.sessionId
        case let r as TranscriptionRecord: return r.sessionId
        case let r as CameraRecord: return r.sessionId
        case let r as SpeakerSpanRecord: return r.sessionId
        case let r as DiarizationHealthRecord: return r.sessionId
        default: return nil
        }
    }

    private func isInRange(record: any CaptureRecord, from startMs: Int64, to endMs: Int64) -> Bool {
        switch record {
        case let r as ScreenshotRecord: return r.unixTimeMs >= startMs && r.unixTimeMs <= endMs
        case let r as TranscriptionRecord: return r.unixTimeMs >= startMs && r.unixTimeMs <= endMs
        case let r as CameraRecord: return r.unixTimeMs >= startMs && r.unixTimeMs <= endMs
        case let r as SpeakerSpanRecord: return r.endUnixTimeMs >= startMs && r.unixTimeMs <= endMs
        case let r as DiarizationHealthRecord: return r.unixTimeMs >= startMs && r.unixTimeMs <= endMs
        default: return false
        }
    }
}
