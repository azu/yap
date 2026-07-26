import Foundation

// MARK: - CaptureStore

final class CaptureStore: Sendable {
    let dataDir: String
    let sessionID: String

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
        let lines = try records.map { try CaptureRecordCoder.encode($0) }
        let content = lines.joined(separator: "\n") + "\n"
        let data = Data(content.utf8)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "\(formatter.string(from: timestamp))_\(Self.currentDevice).ndjson"
        let path = capturesDir + filename

        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Read all records from captures within a time range.
    func readRecords(
        from startMs: Int64,
        to endMs: Int64,
        devices: Set<String>? = nil
    ) throws -> [any CaptureRecord] {
        try readNDJSONFiles(in: capturesDir, from: startMs, to: endMs, devices: devices)
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
        devices: Set<String>?
    ) throws -> [any CaptureRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var records: [any CaptureRecord] = []
        for file in files.sorted() where file.hasSuffix(".ndjson") {
            if let devices {
                guard let device = Self.deviceName(from: file), devices.contains(device) else { continue }
            }
            let path = directory + file
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") where !line.isEmpty {
                guard let record = try? CaptureRecordCoder.decode(line: line) else { continue }
                if isInRange(record: record, from: startMs, to: endMs) {
                    records.append(record)
                }
            }
        }
        return records
    }

    private static func deviceName(from filename: String) -> String? {
        guard let match = filename.wholeMatch(
            of: /\d{4}-\d{2}-\d{2}_(?<device>[a-z0-9][a-z0-9\-]*)\.ndjson/
        ) else {
            return nil
        }
        return String(match.device)
    }

    private func isInRange(record: any CaptureRecord, from startMs: Int64, to endMs: Int64) -> Bool {
        switch record {
        case let r as ScreenshotRecord: return r.unixTimeMs >= startMs && r.unixTimeMs <= endMs
        case let r as TranscriptionRecord: return r.unixTimeMs >= startMs && r.unixTimeMs <= endMs
        case let r as CameraRecord: return r.unixTimeMs >= startMs && r.unixTimeMs <= endMs
        default: return false
        }
    }
}
