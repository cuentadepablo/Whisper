import AVFoundation
import Speech

/// Transcripción continua de inglés hablado, 100 % en el dispositivo
/// (`requiresOnDeviceRecognition = true`, sin llamadas a internet).
///
/// El reconocimiento on-device no emite resultados finales por sí solo, así
/// que el segmento en curso se cierra desde afuera (ver `finishCurrentSegment`)
/// cuando el view model detecta una pausa en el habla. Cerrar una petición y
/// obtener su resultado final es asíncrono y puede tardar un par de segundos,
/// así que la petición nueva se abre de inmediato —no se espera esa
/// respuesta— para que el audio del micrófono nunca se quede sin destino
/// mientras la vieja termina en segundo plano.
///
/// Cada petición tiene su propio identificador ("generación"): los parciales
/// solo se reportan de la generación que sigue viva, pero el resultado final
/// de una generación que ya quedó atrás igual se entrega, para cerrar ese
/// segmento correctamente.
final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveGeneration: UUID?
    private(set) var isRunning = false

    /// Texto parcial de una generación (hilo principal). Solo se llama para
    /// la generación actualmente activa.
    var onPartial: ((UUID, String) -> Void)?
    /// Texto final de una generación, viva o ya retirada (hilo principal).
    var onSegmentEnd: ((UUID, String) -> Void)?

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
        liveRequest?.endAudio()
        liveRequest = nil
        liveGeneration = nil
    }

    /// Cierra la generación en curso y abre la siguiente en el mismo instante,
    /// así el audio que siga llegando nunca queda sin petición que lo reciba.
    func finishCurrentSegment() {
        guard isRunning else { return }
        liveRequest?.endAudio()
        beginRequest()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        liveRequest?.append(buffer)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        liveRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func beginRequest() {
        let generation = UUID()
        liveGeneration = generation

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true
        newRequest.addsPunctuation = true
        newRequest.taskHint = .dictation
        liveRequest = newRequest

        var lastText = ""
        recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let result {
                    lastText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.onSegmentEnd?(generation, lastText)
                        return
                    }
                    if self.liveGeneration == generation {
                        self.onPartial?(generation, lastText)
                    }
                    return
                }

                if error != nil {
                    // Errores como "no speech detected" cierran la generación
                    // con lo que hubiera; no dispara una petición nueva por sí
                    // solo, eso ya lo maneja finishCurrentSegment/stop.
                    self.onSegmentEnd?(generation, lastText)
                }
            }
        }
    }
}
