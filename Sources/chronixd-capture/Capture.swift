import ApplicationServices
import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Noora
import ScreenCaptureKit
import Speech

private nonisolated(unsafe) var captureSignalWriteFD: Int32 = -1

private struct DiarizationAudioInput: Sendable {
    let startSample: Int64
    let samples: [Float]
}

// MARK: - Capture

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture transcription and screen context periodically to disk."
    )

    @Option(
        name: .long,
        help: "Persistent data directory (required)."
    ) var dataDir: String

    @Option(
        name: .long,
        help: "Capture interval in seconds (default: 30, minimum: 5)."
    ) var interval: Int = 30

    @Option(
        name: .long,
        help: "Camera device ID to capture. Can be specified multiple times."
    ) var camera: [String] = []

    @Option(
        name: .long,
        help: "App names to ignore (comma-separated). Displays with these apps are skipped.",
        transform: { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ) var ignoreApps: [String]?

    @Option(
        name: .long,
        help: "Title patterns to ignore (comma-separated). Displays with matching window titles are skipped.",
        transform: { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ) var ignoreTitles: [String]?

    @Option(
        name: .long,
        help: "URL patterns to ignore (comma-separated). Displays with matching URLs are skipped.",
        transform: { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ) var ignoreUrls: [String]?

    @Flag(
        name: .long,
        help: "Disable deduplication."
    ) var noDedup: Bool = false

    @Flag(
        name: .long,
        help: "Disable speaker diarization (FluidAudio Sortformer)."
    ) var noDiarize: Bool = false

    @Flag(
        name: .long,
        help: "Disable persistent speaker identification (FluidAudio WeSpeaker)."
    ) var noSpeakerIdentify: Bool = false

    @Option(
        name: .shortAndLong,
        help: "(default: current)",
        transform: Locale.init(identifier:)
    ) var locale: Locale = .init(identifier: Locale.current.identifier)

    func validate() throws {
        guard interval >= 5 else {
            throw ValidationError("--interval must be at least 5 seconds.")
        }
    }

    static func extractFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            let ptr = UnsafeBufferPointer(start: channelData[0], count: frames)
            // Normalize Int16 to Float32 in [-1.0, 1.0]
            let scale: Float = 1.0 / 32768.0
            var samples = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                samples[i] = Float(ptr[i]) * scale
            }
            return samples
        default:
            return nil
        }
    }

    @MainActor mutating func run() async throws {
        let captureInterval = interval

        // Permission checks
        guard SpeechTranscriber.isAvailable else {
            throw CaptureError.speechTranscriberNotAvailable
        }

        // Microphone permission (checked by trying to start audio engine)
        // Accessibility permission
        guard AXIsProcessTrusted() else {
            throw CaptureError.accessibilityPermissionDenied
        }

        // Screen recording permission
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenRecordingPermissionDenied
        }

        // Camera permission if needed
        if !camera.isEmpty {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw CameraCaptureError.permissionDenied
            }
        }

        // Locale check
        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw CaptureError.unsupportedLocale
        }

        for loc in await AssetInventory.reservedLocales {
            await AssetInventory.release(reservedLocale: loc)
        }
        try await AssetInventory.reserve(locale: locale)

        // Set up transcriber
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let modules: [any SpeechModule] = [transcriber]

        // Download assets if needed
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            let piped = isatty(STDOUT_FILENO) == 0
            struct DevNull: StandardPipelining { func write(content _: String) {} }
            let noora = if piped {
                Noora(standardPipelines: .init(output: DevNull()))
            } else {
                Noora()
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await noora.progressBarStep(
                    message: "Downloading required assets…"
                ) { @Sendable progressCallback in
                    struct ReportProgress: @unchecked Sendable {
                        let callAsFunction: (Double) -> Void
                    }
                    let reportProgress = ReportProgress(callAsFunction: progressCallback)
                    try await withThrowingDiscardingTaskGroup { group in
                        group.addTask {
                            while !Task.isCancelled, !request.progress.isFinished {
                                reportProgress.callAsFunction(request.progress.fractionCompleted)
                                try await Task.sleep(for: .seconds(0.1))
                            }
                        }
                        try await request.downloadAndInstall()
                        group.cancelAll()
                    }
                }
            }
        }

        let analyzer = SpeechAnalyzer(modules: modules)

        // Set up streaming input
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw CaptureError.noCompatibleAudioFormat
        }

        // Initialize speaker diarization (default-on, opt out with --no-diarize)
        let sessionId = String(UUID().uuidString.prefix(8).lowercased())
        let formatOK = targetFormat.sampleRate == 16000
            && targetFormat.channelCount == 1
            && (targetFormat.commonFormat == .pcmFormatFloat32 || targetFormat.commonFormat == .pcmFormatInt16)
        let diarization: DiarizationStream?
        let diarizationStatus: String
        let diarizationStartupError: String?
        let diarizationStartupErrorUnixTimeMs: Int64?
        if noDiarize {
            diarization = nil
            diarizationStatus = "disabled"
            diarizationStartupError = nil
            diarizationStartupErrorUnixTimeMs = nil
        } else if !formatOK {
            let message = "targetFormat is not 16kHz mono Float32/Int16 (sampleRate=\(targetFormat.sampleRate), channels=\(targetFormat.channelCount), format=\(targetFormat.commonFormat.rawValue))"
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data(
                    "[diarize] Skipped: \(message)\n".utf8
                ))
            }
            diarization = nil
            diarizationStatus = "unsupported_audio_format"
            diarizationStartupError = message
            diarizationStartupErrorUnixTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        } else {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[diarize] Initializing Sortformer (session=\(sessionId), model download on first run)…\n".utf8))
            }
            do {
                diarization = try await DiarizationStream(sessionId: sessionId)
                diarizationStatus = "running"
                diarizationStartupError = nil
                diarizationStartupErrorUnixTimeMs = nil
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("[diarize] Ready.\n".utf8))
                }
            } catch {
                let message = String(describing: error)
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("[diarize] Init failed (\(message)). Continuing without speaker diarization.\n".utf8))
                }
                diarization = nil
                diarizationStatus = "initialization_failed"
                diarizationStartupError = message
                diarizationStartupErrorUnixTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
        }

        // Persistent identity is optional and must never prevent normal capture.
        let speakerStore = SpeakerStore(dataDir: dataDir)
        let speakerIdentity: SpeakerIdentityStream?
        if diarization != nil, !noSpeakerIdentify {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[speaker] Initializing WeSpeaker (model download on first run)…\n".utf8))
            }
            do {
                try speakerStore.setup()
                speakerIdentity = try await SpeakerIdentityStream(store: speakerStore)
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("[speaker] Ready.\n".utf8))
                }
            } catch {
                speakerIdentity = nil
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("[speaker] Init failed (\(error)). Continuing without persistent speaker identification.\n".utf8))
                }
            }
        } else {
            speakerIdentity = nil
        }

        let capture = try MicrophoneCapture(
            targetFormat: targetFormat,
            inputContinuation: inputContinuation
        )

        var diarizationAudioContinuation: AsyncStream<DiarizationAudioInput>.Continuation?
        let diarizationAudioTask: Task<Void, Never>?
        if let diarization {
            let diarizationRef = diarization
            let sampleRate = targetFormat.sampleRate
            let (audioStream, audioContinuation) = AsyncStream.makeStream(
                of: DiarizationAudioInput.self,
                bufferingPolicy: .bufferingNewest(64)
            )
            diarizationAudioContinuation = audioContinuation
            var nextDiarizationSample: Int64 = 0
            capture.onConvertedBuffer = { buffer in
                guard let samples = Self.extractFloatSamples(from: buffer) else { return }
                let input = DiarizationAudioInput(
                    startSample: nextDiarizationSample,
                    samples: samples
                )
                nextDiarizationSample += Int64(samples.count)
                audioContinuation.yield(input)
            }
            diarizationAudioTask = Task.detached {
                var expectedSample: Int64 = 0
                for await input in audioStream {
                    do {
                        // If the bounded queue dropped audio while inference was busy, insert
                        // silence so Sortformer and Apple Speech keep the same audio timeline.
                        var missingSamples = max(0, input.startSample - expectedSample)
                        while missingSamples > 0 {
                            let chunkSize = Int(min(missingSamples, Int64(sampleRate)))
                            try await diarizationRef.addAudio(
                                [Float](repeating: 0, count: chunkSize),
                                sourceSampleRate: sampleRate,
                                isSyntheticSilence: true
                            )
                            expectedSample += Int64(chunkSize)
                            missingSamples -= Int64(chunkSize)
                        }
                        let alreadyConsumed = Int(max(0, expectedSample - input.startSample))
                        if alreadyConsumed < input.samples.count {
                            let remaining = Array(input.samples[Int(alreadyConsumed)...])
                            try await diarizationRef.addAudio(remaining, sourceSampleRate: sampleRate)
                            expectedSample = input.startSample + Int64(input.samples.count)
                        }
                    } catch {
                        if isatty(STDERR_FILENO) != 0 {
                            FileHandle.standardError.write(Data("[diarize] addAudio failed: \(error)\n".utf8))
                        }
                    }
                }
            }
        } else {
            diarizationAudioTask = nil
        }

        try capture.start()
        try await analyzer.start(inputSequence: inputSequence)
        let engineStartUnixMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Set up CaptureStore
        let store = CaptureStore(dataDir: dataDir)
        try store.setup()

        // Set up camera capture
        let cameraCapture: CameraCapture? = if !camera.isEmpty {
            try CameraCapture(deviceIDs: camera)
        } else {
            nil
        }

        // Set up signal handling
        var signalPipe: [Int32] = [0, 0]
        pipe(&signalPipe)
        let signalReadFD = signalPipe[0]
        captureSignalWriteFD = signalPipe[1]

        // Suppress ^C echo
        var originalTermios = termios()
        let hasTerminal = isatty(STDIN_FILENO) != 0
        if hasTerminal {
            tcgetattr(STDIN_FILENO, &originalTermios)
            var raw = originalTermios
            raw.c_lflag &= ~UInt(ECHOCTL)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }

        signal(SIGINT) { _ in
            _ = write(captureSignalWriteFD, "x", 1)
        }

        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Capturing… Press Ctrl+C to stop.\n".utf8))
        }

        // Thread-safe transcription buffer
        let transcriptionBuffer = TranscriptionBuffer()
        let asrProgressTracker = ASRProgressTracker()

        // Screen context capture
        let screenCapture = ScreenContextCapture()

        // Dedup state
        let dedupEnabled = !noDedup
        let dedupState = DedupState()

        // Copy ignore filters to local vars for closure capture
        let ignoreAppPatterns = ignoreApps
        let ignoreTitlePatterns = ignoreTitles
        let ignoreUrlPatterns = ignoreUrls

        // Background task: poll media playback state every 2 seconds
        // Mutes mic when media is actively playing (NowPlaying playbackRate > 0)
        let muteCaptureRef = capture
        let mediaCheckTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let shouldMute = await AudioOutputDetector.isMediaPlaying()
                if muteCaptureRef.isMuted != shouldMute {
                    muteCaptureRef.isMuted = shouldMute
                    if isatty(STDERR_FILENO) != 0 {
                        let msg = shouldMute
                            ? "[capture] Media playing, muting mic"
                            : "[capture] Media stopped, unmuting mic"
                        FileHandle.standardError.write(Data("\(msg)\n".utf8))
                    }
                }
            }
        }

        // Background task: drive Sortformer process() at 1 Hz
        let diarizationProcessTask: Task<Void, Never>? = if let diarization {
            Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    do {
                        try await diarization.processIfReady()
                    } catch {
                        if isatty(STDERR_FILENO) != 0 {
                            FileHandle.standardError.write(Data("[diarize] process failed: \(error)\n".utf8))
                        }
                    }
                }
            }
        } else {
            nil
        }

        // Background task: extract and persist cross-session speaker embeddings.
        let speakerEmbeddingTask: Task<Void, Never>? = if let diarization, let speakerIdentity {
            Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { break }
                    await persistSpeakerEmbeddingCandidates(
                        from: diarization,
                        identity: speakerIdentity,
                        store: speakerStore,
                        engineStartUnixMs: engineStartUnixMs,
                        sessionId: sessionId,
                        device: capture.currentDeviceName
                    )
                }
            }
        } else {
            nil
        }

        // Background task 1: consume transcriber results into buffer
        let consumeCapture = capture
        let consumeDiarization = diarization
        let consumeTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let startSec = result.range.start.seconds
                    let durSec = result.range.duration.seconds
                    let endSec = startSec + durSec
                    await asrProgressTracker.recordResult(endSec: endSec)
                    guard let text = normalizedTranscriptionText(String(result.text.characters)) else {
                        continue
                    }
                    let startMs = engineStartUnixMs + Int64(startSec * 1000)
                    let endMs = engineStartUnixMs + Int64(endSec * 1000)
                    let rms = consumeCapture.averageRMS(fromAudioTimeSec: startSec, toAudioTimeSec: endSec)
                    let device = consumeCapture.currentDeviceName
                    let speakerId = await consumeDiarization?.dominantSpeaker(from: startSec, to: endSec)
                    transcriptionBuffer.append(TranscriptionSegment(
                        startUnixMs: startMs,
                        endUnixMs: endMs,
                        text: text,
                        rms: rms,
                        device: device,
                        speakerId: speakerId
                    ))
                }
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                await asrProgressTracker.record(error: error)
            }
        }

        // Background task: save a progress/error snapshot every minute.
        let healthTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let asrSnapshot = await asrProgressTracker.snapshot()
                let diarizationSnapshot = await diarization?.healthSnapshot()
                let record = makeDiarizationHealthRecord(
                    unixTimeMs: nowMs,
                    engineStartUnixMs: engineStartUnixMs,
                    sessionId: sessionId,
                    status: diarizationStatus,
                    startupError: diarizationStartupError,
                    startupErrorUnixTimeMs: diarizationStartupErrorUnixTimeMs,
                    asr: asrSnapshot,
                    diarization: diarizationSnapshot
                )
                do {
                    try store.writeCapture(records: [record], timestamp: Date(timeIntervalSince1970: Double(nowMs) / 1000))
                } catch {
                    if isatty(STDERR_FILENO) != 0 {
                        FileHandle.standardError.write(Data("[diarize] Health write failed: \(error)\n".utf8))
                    }
                }
            }
        }

        // Background task 2: periodic capture timer
        let intervalSeconds = captureInterval
        let captureStore = store
        let hooksDataDir = dataDir
        let captureTimerTask = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }

                let now = Date()
                let nowMs = Int64(now.timeIntervalSince1970 * 1000)

                // Capture screen context
                let screenContext: ScreenContext?
                do {
                    screenContext = try await screenCapture.capture()
                } catch {
                    if isatty(STDERR_FILENO) != 0 {
                        FileHandle.standardError.write(Data("[capture] Screen capture failed: \(error)\n".utf8))
                    }
                    screenContext = nil
                }

                // Flush transcription buffer
                let segments = transcriptionBuffer.flush()
                let finalizedSpeakerSegments = await diarization?.finalizedSegmentsForPersistence() ?? []

                // Build records
                var records: [any CaptureRecord] = []

                // Screenshot records for each display (skip ignored + per-display dedup)
                for display in screenContext?.displays ?? [] {
                    if let ignoreAppPatterns, let appName = display.appName,
                       ignoreAppPatterns.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
                        continue
                    }
                    if let ignoreTitlePatterns, let title = display.windowTitle,
                       ignoreTitlePatterns.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                        continue
                    }
                    if let ignoreUrlPatterns, let url = display.url,
                       ignoreUrlPatterns.contains(where: { url.localizedCaseInsensitiveContains($0) }) {
                        continue
                    }
                    // Per-display dedup
                    if dedupEnabled {
                        let displayKey = DedupKey(
                            app: display.appName ?? "",
                            title: display.windowTitle ?? "",
                            url: display.url ?? ""
                        )
                        if dedupState.isDuplicate(displayID: display.displayID, key: displayKey) {
                            continue
                        }
                    }
                    let recordID = UUID().uuidString.prefix(12).lowercased()
                    if let path = display.screenshotPath {
                        let destPath = captureStore.screenshotsDir + "\(recordID).png"
                        try? FileManager.default.copyItem(atPath: path, toPath: destPath)
                    }
                    let hookContext: String? = if display.isFocused {
                        runAppContextHook(
                            dataDir: hooksDataDir,
                            appName: display.appName ?? "Unknown",
                            windowTitle: display.windowTitle ?? "",
                            pid: display.pid
                        )
                    } else {
                        nil
                    }

                    records.append(ScreenshotRecord(
                        id: String(recordID),
                        unixTimeMs: nowMs,
                        sessionId: sessionId,
                        url: normalizeURL(display.url),
                        app: display.appName ?? "Unknown",
                        title: display.windowTitle,
                        isFocused: display.isFocused,
                        isPlayingMedia: display.isPlayingMedia,
                        appContext: hookContext,
                        idleSeconds: display.idleSeconds.map { ($0 * 10).rounded() / 10 },
                        scrollPosition: display.scrollPosition.map { ($0 * 1000).rounded() / 1000 }
                    ))
                }

                // Transcription records
                for segment in segments {
                    records.append(TranscriptionRecord(
                        unixTimeMs: segment.startUnixMs,
                        endUnixTimeMs: segment.endUnixMs,
                        sessionId: sessionId,
                        rms: segment.rms,
                        device: segment.device,
                        speakerId: segment.speakerId,
                        text: segment.text
                    ))
                }

                // Raw finalized speaker intervals. Keep these independent from ASR result boundaries.
                for segment in finalizedSpeakerSegments {
                    records.append(makeSpeakerSpanRecord(
                        segment: segment,
                        engineStartUnixMs: engineStartUnixMs,
                        sessionId: sessionId
                    ))
                }

                // Camera records
                if let cameraCapture {
                    let cameraImages = await cameraCapture.captureAll()
                    for cam in cameraImages {
                        let recordID = UUID().uuidString.prefix(12).lowercased()
                        let destPath = captureStore.camerasDir + "\(recordID).png"
                        if let dest = CGImageDestinationCreateWithURL(
                            URL(fileURLWithPath: destPath) as CFURL, "public.png" as CFString, 1, nil
                        ) {
                            CGImageDestinationAddImage(dest, cam.image, nil)
                            if CGImageDestinationFinalize(dest) {
                                records.append(CameraRecord(
                                    id: String(recordID),
                                    unixTimeMs: nowMs,
                                    sessionId: sessionId
                                ))
                            }
                        }
                    }
                }

                // Write to store
                if !records.isEmpty {
                    do {
                        try captureStore.writeCapture(records: records, timestamp: now)
                        await diarization?.acknowledgePersistedFinalizedSegments(
                            count: finalizedSpeakerSegments.count
                        )
                        if isatty(STDERR_FILENO) != 0 {
                            let screenshotCount = records.filter { $0 is ScreenshotRecord }.count
                            let transcriptionCount = records.filter { $0 is TranscriptionRecord }.count
                            let cameraCount = records.filter { $0 is CameraRecord }.count
                            let speakerSpanCount = records.filter { $0 is SpeakerSpanRecord }.count
                            FileHandle.standardError.write(Data(
                                "[capture] Wrote \(records.count) records (screenshots: \(screenshotCount), transcriptions: \(transcriptionCount), cameras: \(cameraCount), speaker spans: \(speakerSpanCount))\n".utf8
                            ))
                        }
                    } catch {
                        if isatty(STDERR_FILENO) != 0 {
                            FileHandle.standardError.write(Data("[capture] Write failed: \(error)\n".utf8))
                        }
                    }
                }
            }
        }

        // Wait for SIGINT in background, then gracefully shut down
        nonisolated(unsafe) var savedTermios = originalTermios
        let restoreTerminal = hasTerminal
        let (shutdownStream, shutdownContinuation) = AsyncStream.makeStream(of: Void.self)
        Task.detached {
            var buf: UInt8 = 0
            _ = read(signalReadFD, &buf, 1)
            close(signalReadFD)
            close(captureSignalWriteFD)
            if restoreTerminal {
                tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            }
            capture.onConvertedBuffer = nil
            capture.stop()
            diarizationAudioContinuation?.finish()
            if let diarizationAudioTask {
                _ = await diarizationAudioTask.result
            }
            cameraCapture?.stop()
            if !capture.isMuted {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            if let diarizationProcessTask {
                diarizationProcessTask.cancel()
                _ = await diarizationProcessTask.result
            }
            try? await diarization?.finalize()
            if let speakerEmbeddingTask {
                speakerEmbeddingTask.cancel()
                _ = await speakerEmbeddingTask.result
            }
            if let diarization, let speakerIdentity {
                await persistSpeakerEmbeddingCandidates(
                    from: diarization,
                    identity: speakerIdentity,
                    store: speakerStore,
                    engineStartUnixMs: engineStartUnixMs,
                    sessionId: sessionId,
                    device: capture.currentDeviceName
                )
            }
            healthTask.cancel()
            _ = await healthTask.result
            captureTimerTask.cancel()
            _ = await captureTimerTask.result
            consumeTask.cancel()
            _ = await consumeTask.result
            mediaCheckTask.cancel()

            var finalRecords: [any CaptureRecord] = []
            for segment in transcriptionBuffer.flush() {
                finalRecords.append(TranscriptionRecord(
                    unixTimeMs: segment.startUnixMs,
                    endUnixTimeMs: segment.endUnixMs,
                    sessionId: sessionId,
                    rms: segment.rms,
                    device: segment.device,
                    speakerId: segment.speakerId,
                    text: segment.text
                ))
            }
            let finalSpeakerSegments = await diarization?.finalizedSegmentsForPersistence() ?? []
            for segment in finalSpeakerSegments {
                finalRecords.append(makeSpeakerSpanRecord(
                    segment: segment,
                    engineStartUnixMs: engineStartUnixMs,
                    sessionId: sessionId
                ))
            }
            let now = Date()
            let asrSnapshot = await asrProgressTracker.snapshot()
            let diarizationSnapshot = await diarization?.healthSnapshot()
            finalRecords.append(makeDiarizationHealthRecord(
                unixTimeMs: Int64(now.timeIntervalSince1970 * 1000),
                engineStartUnixMs: engineStartUnixMs,
                sessionId: sessionId,
                status: diarizationStatus,
                startupError: diarizationStartupError,
                startupErrorUnixTimeMs: diarizationStartupErrorUnixTimeMs,
                asr: asrSnapshot,
                diarization: diarizationSnapshot
            ))
            do {
                try store.writeCapture(records: finalRecords, timestamp: now)
                await diarization?.acknowledgePersistedFinalizedSegments(
                    count: finalSpeakerSegments.count
                )
            } catch {
                if isatty(STDERR_FILENO) != 0 {
                    FileHandle.standardError.write(Data("[capture] Final write failed: \(error)\n".utf8))
                }
            }
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("\nCapture stopped.\n".utf8))
            }
            shutdownContinuation.yield()
            shutdownContinuation.finish()
        }

        // Block until shutdown signal
        for await _ in shutdownStream {
            break
        }
    }
}

// MARK: - TranscriptionSegment

private struct TranscriptionSegment: Sendable {
    let startUnixMs: Int64
    let endUnixMs: Int64
    let text: String
    let rms: Float?
    let device: String?
    let speakerId: String?
}

// MARK: - TranscriptionBuffer

private final class TranscriptionBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [TranscriptionSegment] = []

    func append(_ segment: TranscriptionSegment) {
        lock.lock()
        segments.append(segment)
        lock.unlock()
    }

    func flush() -> [TranscriptionSegment] {
        lock.lock()
        let result = segments
        segments.removeAll()
        lock.unlock()
        return result
    }
}

func persistSpeakerEmbeddingCandidates(
    from diarization: DiarizationStream,
    identity: SpeakerIdentityStream,
    store: SpeakerStore,
    engineStartUnixMs: Int64,
    sessionId: String,
    device: String?
) async {
    let candidates = await diarization.drainEmbeddingCandidates()
    for candidate in candidates {
        do {
            let sample = try await identity.identify(
                candidate: candidate,
                engineStartUnixMs: engineStartUnixMs,
                sessionId: sessionId,
                device: device
            )
            try store.append(
                sample: sample,
                timestamp: Date(timeIntervalSince1970: Double(sample.unixTimeMs) / 1000)
            )
        } catch {
            if isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("[speaker] Embedding failed: \(error)\n".utf8))
            }
        }
    }
}

func makeSpeakerSpanRecord(
    segment: DiarizationSegmentRecord,
    engineStartUnixMs: Int64,
    sessionId: String
) -> SpeakerSpanRecord {
    SpeakerSpanRecord(
        unixTimeMs: engineStartUnixMs + Int64(segment.startSec * 1000),
        endUnixTimeMs: engineStartUnixMs + Int64(segment.endSec * 1000),
        sessionId: sessionId,
        speakerId: "\(sessionId)_\(segment.speakerIndex)",
        speakerIndex: segment.speakerIndex,
        isFinal: true,
        source: .init(
            library: DiarizationMetadata.library,
            libraryVersion: DiarizationMetadata.libraryVersion,
            model: DiarizationMetadata.model,
            variant: DiarizationMetadata.variant
        )
    )
}

func makeDiarizationHealthRecord(
    unixTimeMs: Int64,
    engineStartUnixMs: Int64,
    sessionId: String,
    status: String,
    startupError: String?,
    startupErrorUnixTimeMs: Int64?,
    asr: ASRProgressSnapshot,
    diarization: DiarizationHealthSnapshot?
) -> DiarizationHealthRecord {
    let processedEndSec = diarization?.diarizationProcessedEndSec
    let asrLagSec: Double? = if let asrEndSec = asr.lastResultEndSec, let processedEndSec {
        asrEndSec - processedEndSec
    } else {
        nil
    }
    let audioBacklogSec: Double? = if let audioInputEndSec = diarization?.audioInputEndSec, let processedEndSec {
        max(0, audioInputEndSec - processedEndSec)
    } else {
        nil
    }
    let audioWallClockLagSec: Double? = if let audioInputEndSec = diarization?.audioInputEndSec {
        max(0, Double(unixTimeMs - engineStartUnixMs) / 1000 - audioInputEndSec)
    } else {
        nil
    }
    return DiarizationHealthRecord(
        unixTimeMs: unixTimeMs,
        sessionId: sessionId,
        status: status,
        source: .init(
            library: DiarizationMetadata.library,
            libraryVersion: DiarizationMetadata.libraryVersion,
            model: DiarizationMetadata.model,
            variant: DiarizationMetadata.variant
        ),
        audioInputEndSec: diarization?.audioInputEndSec,
        diarizationSyntheticSilenceSec: diarization?.syntheticSilenceSec,
        asrLastResultEndSec: asr.lastResultEndSec,
        diarizationProcessedEndSec: processedEndSec,
        asrDiarizationLagSec: asrLagSec,
        audioDiarizationBacklogSec: audioBacklogSec,
        audioWallClockLagSec: audioWallClockLagSec,
        asrResultCount: asr.resultCount,
        asrErrorCount: asr.errorCount,
        diarizationProcessCallCount: diarization?.processCallCount ?? 0,
        diarizationUpdateCount: diarization?.updateCount ?? 0,
        diarizationFinalizedSpanCount: diarization?.finalizedSpanCount ?? 0,
        diarizationAddAudioErrorCount: diarization?.addAudioErrorCount ?? 0,
        diarizationProcessErrorCount: diarization?.processErrorCount ?? 0,
        lastASRResultUnixTimeMs: asr.lastResultUnixTimeMs,
        lastDiarizationUpdateUnixTimeMs: diarization?.lastDiarizationUpdateUnixTimeMs,
        lastASRErrorUnixTimeMs: asr.lastErrorUnixTimeMs,
        lastASRError: asr.lastError,
        lastDiarizationErrorUnixTimeMs: diarization?.lastErrorUnixTimeMs ?? startupErrorUnixTimeMs,
        lastDiarizationError: diarization?.lastError ?? startupError
    )
}

// MARK: - DedupKey

private struct DedupKey: Equatable {
    let app: String
    let title: String
    let url: String
}

// MARK: - DedupState

private final class DedupState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastKeys: [CGDirectDisplayID: (key: DedupKey, recordedAt: Date)] = [:]

    /// Returns true if this capture should be skipped.
    /// Dedup is suppressed (= record anyway) when the user has interacted since the last capture.
    func isDuplicate(displayID: CGDirectDisplayID, key: DedupKey) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastKeys[displayID], last.key == key else {
            // Different screen — always record
            lastKeys[displayID] = (key: key, recordedAt: now)
            return false
        }
        // Same screen — record if user has been active since last capture
        let elapsed = now.timeIntervalSince(last.recordedAt)
        if Self.hasUserActivity(within: elapsed) {
            lastKeys[displayID] = (key: key, recordedAt: now)
            return false
        }
        return true
    }

    /// Check if any user input (scroll, mouse move, click, or key press) occurred within the given interval.
    private static func hasUserActivity(within seconds: TimeInterval) -> Bool {
        let eventTypes: [CGEventType] = [.scrollWheel, .mouseMoved, .leftMouseDown, .keyDown]
        for eventType in eventTypes {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: eventType)
            if idle < seconds {
                return true
            }
        }
        return false
    }
}

// MARK: - App Context Hooks

/// Run a hook script at `{dataDir}/hooks/{appName}` if it exists and is executable.
/// Arguments: $1 = windowTitle, $2 = pid. Timeout: 2 seconds.
func runAppContextHook(dataDir: String, appName: String, windowTitle: String, pid: Int32) -> String? {
    let hookPath = (dataDir as NSString).appendingPathComponent("hooks/\(appName)")
    guard FileManager.default.isExecutableFile(atPath: hookPath) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: hookPath)
    process.arguments = [windowTitle, String(pid)]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    let deadline = DispatchTime.now() + .seconds(2)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        group.leave()
    }
    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return output?.isEmpty == true ? nil : output
}

// MARK: - Helpers

func normalizedTranscriptionText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "。" else { return nil }
    return trimmed
}

func normalizeURL(_ url: String?) -> String? {
    guard let url, !url.isEmpty else { return nil }
    if url.contains("://") { return url }
    return "https://" + url
}
