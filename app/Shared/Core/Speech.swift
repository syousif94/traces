import AVFoundation
import Foundation
import Observation
import Speech

/// Hold-to-talk with on-device recognition. The transcript lands in the input; `finish()` returns
/// it so the caller can show it for a moment before sending (and let the user cancel).
@Observable @MainActor
final class SpeechInput {
    var listening = false
    var transcript = ""
    var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func start() {
        guard !listening else { return }
        transcript = ""
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.error = "Speech recognition is not allowed. Enable it in Settings."; return }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition is unavailable."; return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { self.error = error.localizedDescription; return }
        listening = true
        task = recognizer.recognitionTask(with: req) { result, _ in
            if let t = result?.bestTranscription.formattedString {
                Task { @MainActor in self.transcript = t }
            }
        }
    }

    func finish() -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        listening = false
        return transcript
    }
}
