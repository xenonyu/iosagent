import Foundation
import Speech
import AVFoundation
import Combine

/// Converts speech to text using Apple's on-device Speech framework.
/// Does NOT send audio to any server — recognition is local.
final class SpeechService: NSObject, ObservableObject {

    // MARK: - Published

    @Published var isListening: Bool = false
    @Published var transcript: String = ""
    @Published var error: String?

    // MARK: - Private

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Init

    override init() {
        super.init()
        // Prefer Chinese (Simplified) recognizer; fall back to system locale
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
                    ?? SFSpeechRecognizer()
    }

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { micGranted in
                let granted = status == .authorized && micGranted
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    // MARK: - Start / Stop

    func startListening() {
        guard let recognizer, recognizer.isAvailable else {
            error = "语音识别暂不可用"
            return
        }

        SFSpeechRecognizer.authorizationStatus() == .authorized ? startSession() : ()
    }

    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil

        DispatchQueue.main.async { self.isListening = false }
    }

    // MARK: - Private

    private func startSession() {
        stopListening() // Clean up previous session

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "无法启动麦克风"
            return
        }

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        recognitionRequest?.requiresOnDeviceRecognition = true // On-device only

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async {
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            if let error {
                print("Speech recognition error: \(error)")
                self.stopListening()
            }
        }

        do {
            try engine.start()
            DispatchQueue.main.async { self.isListening = true }
        } catch {
            self.error = "音频引擎启动失败"
        }
    }
}
