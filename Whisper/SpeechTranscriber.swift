import AVFoundation
import Speech

/// Transcripción continua de inglés hablado, 100 % en el dispositivo
/// (`requiresOnDeviceRecognition = true`, sin llamadas a internet).
///
/// El reconocimiento on-device no emite resultados finales por sí solo, así
/// que el segmento en curso se cierra desde afuera (ver `finishCurrentSegment`)
/// cuando el view model detecta una pausa en el habla; ahí llega el resultado
/// final, se notifica y se abre una petición nueva para seguir escuchando.
final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isRunning = false

    /// Texto parcial del segmento en curso (se llama en el hilo principal).
    var onPartial: ((String) -> Void)?
    /// Texto final del segmento que acaba de cerrarse (hilo principal).
    var onSegmentEnd: ((String) -> Void)?

    init() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw WhisperError.speechUnavailable
        }
        self.recognizer = recognizer
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer.supportsOnDeviceRecognition
    }

    func start() {
        isRunning = true
        beginRequest()
    }

    func stop() {
        isRunning = false
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    /// Cierra el segmento en curso; el resultado final llega por `onSegmentEnd`
    /// y a continuación se abre una petición nueva automáticamente.
    func finishCurrentSegment() {
        request?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func beginRequest() {
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true
        newRequest.addsPunctuation = true
        newRequest.taskHint = .dictation
        request = newRequest

        var lastText = ""
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.request === newRequest else { return }

                if let result {
                    lastText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.request = nil
                        self.onSegmentEnd?(lastText)
                        if self.isRunning { self.beginRequest() }
                        return
                    }
                    self.onPartial?(lastText)
                    return
                }

                if error != nil {
                    // Errores como "no speech detected" cierran el segmento
                    // con lo que hubiera; si seguimos activos, reabrimos.
                    self.request = nil
                    self.onSegmentEnd?(lastText)
                    if self.isRunning { self.beginRequest() }
                }
            }
        }
    }
}
