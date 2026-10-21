import Foundation
import AVFoundation
import Speech
import CoreMedia
import PrototypeCore

struct AudioInputClock {
    private var next: CMTime = .invalid
    mutating func start(hostOffset: Double, frames: AVAudioFrameCount, sampleRate: Double) -> CMTime {
        let proposed = CMTime(seconds: max(0, hostOffset), preferredTimescale: 1_000_000_000)
        let start = next.isValid && CMTimeCompare(next, proposed) > 0 ? next : proposed
        next = CMTimeAdd(start, CMTime(value: Int64(frames), timescale: CMTimeScale(sampleRate)))
        return start
    }
}

struct SpeechReview {
    var segments: [SpokenSegment]
    var spans: [AudioSpan]
}

private final class RecordingClock {
    private let lock = NSLock()
    private var spans: [AudioSpan] = []
    private var nextFrame: Int64 = 0
    private var lost = false
    func append(frames: AVAudioFrameCount, sampleRate: Double, hostStart: Double) {
        lock.lock(); defer { lock.unlock() }
        let start = Double(nextFrame) / sampleRate
        nextFrame += Int64(frames)
        spans.append(AudioSpan(audioStart: start, audioEnd: Double(nextFrame) / sampleRate, hostStart: hostStart))
    }
    func markLost() { lock.lock(); lost = true; lock.unlock() }
    func snapshot() -> (spans: [AudioSpan], lost: Bool) {
        lock.lock(); defer { lock.unlock() }; return (spans, lost)
    }
}

final class SpeechCapture {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var outputContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var base: Double = 0
    private var recordingURL: URL?
    private var recordingClock = RecordingClock()

    static func recordingFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: format.settings,
                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func start(audioURL: URL, status: @escaping (String) -> Void,
               result: @escaping (SpokenSegment, Bool) -> Void,
               failure: @escaping (String) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey:"本机语音引擎不支持简体中文，需要更换识别方案。"])
        }
        status("正在准备中文语音模型，首次可能需要下载…")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        try Task.checkCancellation()
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        guard permission else {
            throw NSError(domain:"Capture", code:2, userInfo:[NSLocalizedDescriptionKey:"麦克风尚未授权。请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"])
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat),
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw NSError(domain:"Capture", code:3, userInfo:[NSLocalizedDescriptionKey:"无法建立麦克风与识别器的音频格式转换。"])
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(200))
        let (recordStream, recordContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(200))
        self.engine = engine; self.analyzer = analyzer; self.continuation = continuation
        self.outputContinuation = recordContinuation
        let audioFile = try Self.recordingFile(at: audioURL, format: format)
        let recordingClock = RecordingClock()
        self.recordingClock = recordingClock; self.recordingURL = audioURL
        writerTask = Task.detached {
            defer { audioFile.close() }
            do { for await buffer in recordStream { try audioFile.write(from: buffer) } }
            catch { recordingClock.markLost(); failure("音频原件保存失败：\(error.localizedDescription)") }
        }
        base = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let origin = base
        resultTask = Task {
            do {
                for try await item in transcriber.results {
                    var words: [TimedWord] = []
                    for run in item.text.runs {
                        if let range = run.audioTimeRange {
                            words.append(TimedWord(String(item.text[run.range].characters),
                                start: origin + range.start.seconds, end: origin + range.end.seconds))
                        }
                    }
                    let segment = SpokenSegment(id: String(format:"%.4f", item.range.start.seconds),
                        text: String(item.text.characters), start: origin + item.range.start.seconds,
                        end: origin + item.range.end.seconds, words: words)
                    result(segment, item.isFinal)
                }
            } catch { failure("语音转写中断：\(error.localizedDescription)") }
        }
        var audioClock = AudioInputClock()
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, time in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let conversion = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            if let error { failure("音频转换失败：\(error.localizedDescription)"); return }
            guard conversion != .error, output.frameLength > 0 else { return }
            let seconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            let sample = AnalyzerInput(buffer: output, bufferStartTime: audioClock.start(hostOffset: seconds - origin, frames: output.frameLength, sampleRate: format.sampleRate))
            if case .dropped = continuation.yield(sample) { failure("语音处理积压，部分音频未能识别，请结束本段并重试。") }
            switch recordContinuation.yield(output) {
            case .enqueued: recordingClock.append(frames: output.frameLength, sampleRate: format.sampleRate, hostStart: seconds)
            case .dropped: recordingClock.markLost(); failure("音频保存积压，原始录音存在缺口。")
            case .terminated: break
            @unknown default: recordingClock.markLost()
            }
        }
        try await analyzer.start(inputSequence: stream)
        engine.prepare()
        try engine.start()
        status("正在倾听，可以回到浏览器或 Finder")
    }

    func stop() async throws -> SpeechReview {
        let endingAnalyzer = analyzer, endingResultTask = resultTask, endingWriterTask = writerTask
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        continuation?.finish(); outputContinuation?.finish()
        self.analyzer = nil; continuation = nil; resultTask = nil; writerTask = nil
        if let endingAnalyzer { try await endingAnalyzer.finalizeAndFinishThroughEndOfInput() }
        await endingResultTask?.value; await endingWriterTask?.value
        let snapshot = recordingClock.snapshot()
        guard let recordingURL, !snapshot.lost else {
            throw NSError(domain: "Capture", code: 4, userInfo: [NSLocalizedDescriptionKey: "录音存在缺口，保留实时转写供核对。"])
        }
        let segments = try await Self.transcribeFile(recordingURL, origin: base, spans: snapshot.spans)
        return SpeechReview(segments: segments, spans: snapshot.spans)
    }

    /// Final-only decoding sees the complete utterance; volatile live captions are not the final request.
    static func transcribeFile(_ url: URL, origin: Double = 0, spans: [AudioSpan] = []) async throws -> [SpokenSegment] {
        let module = SpeechTranscriber(locale: Locale(identifier: "zh-CN"), preset: .timeIndexedTranscriptionWithAlternatives)
        let file = try AVAudioFile(forReading: url)
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [module], finishAfterFile: true)
        let deadline = Date().addingTimeInterval(12)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(12)); await analyzer.cancelAndFinishNow() }
            catch { /* Normal completion cancels this deadline. */ }
        }
        defer { timeout.cancel() }
        var segments: [SpokenSegment] = []
        for try await item in module.results {
            let host: (Double, Bool) -> Double = { RecordingTimeline.hostTime($0, spans: spans, fallbackOrigin: origin, endBoundary: $1) }
            let words = item.text.runs.compactMap { run -> TimedWord? in
                guard let range = run.audioTimeRange else { return nil }
                return TimedWord(String(item.text[run.range].characters), start: host(range.start.seconds, false), end: host(range.end.seconds, true))
            }
            segments.append(SpokenSegment(id: "final-\(segments.count)", text: String(item.text.characters),
                start: host(item.range.start.seconds, false), end: host(item.range.end.seconds, true), words: words))
        }
        withExtendedLifetime(analyzer) {}
        guard Date() < deadline else { throw NSError(domain: "Capture", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "完整录音复核超时，保留实时结果，请核对。"]) }
        return TranscriptAssembly.coalesced(segments)
    }
    func cancel() async {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        continuation?.finish(); outputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel(); writerTask?.cancel()
        analyzer = nil
    }
}
