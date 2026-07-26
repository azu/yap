import ArgumentParser
import Foundation

struct Context: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Query captured context data by time range."
    )

    @Option(name: .long, help: "Data directory (required).")
    var dataDir: String?

    @Option(name: .long, help: "Start time (ISO 8601 or HH:mm for today).")
    var from: String?

    @Option(name: .long, help: "End time (ISO 8601 or HH:mm for today). Defaults to now.")
    var to: String?

    @Option(name: .long, help: "Duration like 30m, 1h, 2h30m, or seconds.")
    var last: String?

    @Option(
        name: .customLong("device"),
        help: "Capture device hostname to include. Repeat for multiple devices, or use 'current' for this Mac. Defaults to all."
    )
    var devices: [String] = []

    @Flag(name: .customLong("list-devices"), help: "List capture device hostnames found in data-dir.")
    var listDevices: Bool = false

    @Flag(name: .long, help: "Output all record types with full fields.")
    var detail: Bool = false

    @Flag(name: .long, help: "Print the output schema for AI consumption.")
    var schema: Bool = false

    func validate() throws {
        if schema { return }
        guard dataDir != nil else {
            throw ValidationError("--data-dir is required.")
        }
        if listDevices && !devices.isEmpty {
            throw ValidationError("--list-devices and --device are mutually exclusive.")
        }
        if listDevices { return }
        if last != nil && from != nil {
            throw ValidationError("--last and --from are mutually exclusive.")
        }
        if last == nil && from == nil {
            throw ValidationError("Specify either --last or --from.")
        }
    }

    func run() throws {
        if schema {
            print(Self.schemaText)
            return
        }

        guard let dataDir else { return }
        let store = CaptureStore(dataDir: dataDir)

        if listDevices {
            for device in store.availableDevices() {
                print(device)
            }
            return
        }

        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let endMs: Int64
        if let toStr = to {
            endMs = try Self.parseTime(toStr)
        } else {
            endMs = nowMs
        }

        let startMs: Int64
        if let lastStr = last {
            let durationSeconds = try Self.parseDuration(lastStr)
            startMs = endMs - Int64(durationSeconds * 1000)
        } else if let fromStr = from {
            startMs = try Self.parseTime(fromStr)
        } else {
            throw CleanExit.message("Specify either --last or --from.")
        }

        let selectedDevices = devices.isEmpty ? nil : Set(devices.map {
            $0 == "current" ? CaptureStore.currentDevice : CaptureStore.normalizeDeviceName($0)
        })
        var records = try store.readRecords(from: startMs, to: endMs, devices: selectedDevices)
        records.sort { lhs, rhs in
            timeMs(of: lhs) < timeMs(of: rhs)
        }

        if detail {
            for record in records {
                switch record {
                case let r as ScreenshotRecord:
                    let paths = CaptureStore.resolvePaths(for: r.id)
                    let detailRecord = ScreenshotDetailRecord(
                        id: r.id,
                        unixTimeMs: r.unixTimeMs,
                        sessionId: r.sessionId,
                        url: r.url,
                        app: r.app,
                        title: r.title,
                        isFocused: r.isFocused,
                        isPlayingMedia: r.isPlayingMedia,
                        appContext: r.appContext,
                        idleSeconds: r.idleSeconds,
                        scrollPosition: r.scrollPosition,
                        path: paths.screenshot,
                        available: paths.screenshot != nil
                    )
                    let line = try CaptureRecordCoder.encodeDetail(detailRecord)
                    print(line)
                case let r as CameraRecord:
                    let paths = CaptureStore.resolvePaths(for: r.id)
                    let detailRecord = CameraDetailRecord(
                        id: r.id,
                        unixTimeMs: r.unixTimeMs,
                        sessionId: r.sessionId,
                        path: paths.camera,
                        available: paths.camera != nil
                    )
                    let line = try CaptureRecordCoder.encodeDetail(detailRecord)
                    print(line)
                default:
                    let line = try CaptureRecordCoder.encode(record)
                    print(line)
                }
            }
        } else {
            // Index mode: all records but without tmp file paths
            for record in records {
                let line = try CaptureRecordCoder.encode(record)
                print(line)
            }
        }
    }

    // MARK: - Time Parsing

    static func parseTime(_ str: String) throws -> Int64 {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: str) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }

        let localISO = DateFormatter()
        localISO.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        localISO.timeZone = .current
        if let date = localISO.date(from: str) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }

        let timeOnly = DateFormatter()
        timeOnly.dateFormat = "HH:mm"
        timeOnly.timeZone = .current
        if let parsed = timeOnly.date(from: str) {
            let calendar = Calendar.current
            let now = Date()
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            let timeComponents = calendar.dateComponents([.hour, .minute], from: parsed)
            components.hour = timeComponents.hour
            components.minute = timeComponents.minute
            components.second = 0
            if let date = calendar.date(from: components) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }

        throw ValidationError("Invalid time format: \(str). Use ISO 8601 or HH:mm.")
    }

    // MARK: - Duration Parsing

    static func parseDuration(_ str: String) throws -> Double {
        if let seconds = Double(str) {
            return seconds
        }

        var remaining = str[str.startIndex...]
        var totalSeconds: Double = 0
        var matched = false

        while !remaining.isEmpty {
            let digits = remaining.prefix(while: { $0.isNumber || $0 == "." })
            guard !digits.isEmpty, let value = Double(digits) else {
                throw ValidationError("Invalid duration format: \(str). Use formats like 30m, 1h, 2h30m.")
            }
            remaining = remaining[digits.endIndex...]

            guard let unit = remaining.first else {
                throw ValidationError("Invalid duration format: \(str). Missing unit (h/m/s).")
            }
            switch unit {
            case "h": totalSeconds += value * 3600
            case "m": totalSeconds += value * 60
            case "s": totalSeconds += value
            default:
                throw ValidationError("Invalid duration unit '\(unit)' in: \(str). Use h, m, or s.")
            }
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
            matched = true
        }

        guard matched else {
            throw ValidationError("Invalid duration format: \(str).")
        }
        return totalSeconds
    }

    // MARK: - Schema

    static let schemaText = """
    chronixd-capture context outputs NDJSON (one JSON object per line). Each record has a "type" field.

    ## Common Fields

    All records (except summary written by external tools and one-shot snapshot) include:
    - sessionId: string? — 8-char hex identifying one chronixd-capture process invocation. Use to groupBy events from the same session. Resets every restart.

    ## Record Types

    ### screenshot
    Screen capture metadata. Taken periodically from each display.
    - type: "screenshot"
    - id: string — per-record ID (12-char hex), use with --detail to resolve image file path
    - unixTimeMs: number — capture timestamp (Unix ms)
    - sessionId: string? — see Common Fields
    - app: string — foreground app name
    - title: string? — window title
    - url: string? — browser URL (if applicable)
    - is_focused: boolean — whether this display had user focus
    - is_playing_media: boolean — whether media was detected
    - app_context: string? — output of {data-dir}/hooks/{appName} script (focused display only)
    - idle_seconds: number? — seconds since last keyboard/mouse input (focused display only)
    - scroll_position: number? — vertical scroll position 0.0–1.0 (focused display only)

    With --detail, adds:
    - path: string? — screenshot image file path
    - available: boolean — whether the image file exists

    ### transcription
    Speech-to-text from the microphone.
    - type: "transcription"
    - unixTimeMs: number — segment START timestamp (Unix ms), derived from audio time range
    - endUnixTimeMs: number — segment END timestamp (Unix ms)
    - sessionId: string? — see Common Fields
    - text: string — transcribed text
    - rms: number? — average RMS amplitude over the segment (0.0–1.0). Higher = louder = closer to mic, useful as a self-vs-others heuristic.
    - device: string? — input device name at capture time (e.g. "MacBook Air Microphone", "AirPods Pro")
    - speakerId: string? — session-scoped anonymous speaker ID in "{sessionId}_{N}" format (e.g. "a1b2c3d4_0"). Same N within a session = same speaker. Cross-session matching not supported (no global identity).

    ### camera
    Camera image metadata (when --camera is used with chronixd-capture capture).
    - type: "camera"
    - id: string — per-record ID
    - unixTimeMs: number — capture timestamp (Unix ms)
    - sessionId: string? — see Common Fields

    With --detail, adds:
    - path: string? — camera image file path
    - available: boolean — whether the image file exists

    ### summary
    Analysis results written by external tools to {data-dir}/summaries/.
    - type: "summary"
    - fromUnixTimeMs: number — analysis period start (Unix ms)
    - toUnixTimeMs: number — analysis period end (Unix ms)
    - sessionId: string? — Optional, written by external tools
    - text: string — analysis text

    ## Usage

    # Get last 30 minutes of activity
    chronixd-capture context --data-dir <path> --last 30m

    # Get full details including file paths
    chronixd-capture context --data-dir <path> --last 30m --detail

    # List capture devices available in the data directory
    chronixd-capture context --data-dir <path> --list-devices

    # Get context captured on this Mac only
    chronixd-capture context --data-dir <path> --last 30m --device current

    # Get context from one named device
    chronixd-capture context --data-dir <path> --last 30m --device work-laptop

    # Specific time range
    chronixd-capture context --data-dir <path> --from 10:00 --to 11:00

    # Filter by session (downstream)
    chronixd-capture context --data-dir <path> --last 1h | jq 'select(.sessionId == "a1b2c3d4")'

    ## Tips for analysis
    - Records are sorted by timestamp
    - When data from multiple Macs is synced into one data-dir, use --device to avoid mixing their timelines
    - --device values are normalized hostnames from capture filenames; use --list-devices to discover them
    - --device current selects the normalized hostname of the Mac running this command
    - screenshot records show what app/page the user was looking at
    - transcription records show what the user was saying
    - is_focused: true indicates the display the user was actively using
    - idle_seconds: high values (e.g. >60) suggest the user is away; low values mean active interaction
    - scroll_position changes between consecutive records indicate the user is reading/scrolling
    - speakerId stays stable within one session; "Speaker 0" today vs tomorrow are NOT the same person — use sessionId to scope
    - rms can hint at self-vs-others (装着マイクの場合、自分の発話は loud、他者は遠くで quiet)
    - Summarize activity in 1-2 sentences per time period
    """
}

private func timeMs(of record: any CaptureRecord) -> Int64 {
    switch record {
    case let r as ScreenshotRecord: return r.unixTimeMs
    case let r as TranscriptionRecord: return r.unixTimeMs
    case let r as CameraRecord: return r.unixTimeMs
    case let r as SummaryRecord: return r.fromUnixTimeMs
    default: return 0
    }
}
