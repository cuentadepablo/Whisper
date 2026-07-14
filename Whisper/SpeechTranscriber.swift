import AVFoundation
import Speech

/// Transcripción continua de inglés hablado, 100 % en el dispositivo
/// (`requiresOnDeviceRecognition = true`, sin llamadas a internet).
///
/// El reconocimiento on-device no emite resultados finales por sí solo, así
/// que el segmento en curso se cierra desde afuera (ver `finishCurrentSegment`)
/// cuando el view model detecta una pausa en el habla. Cerrar una petición y
/// obtener su resultado final es asíncrono y puede tardar un par de segundos.
///
/// Importante: nunca hay dos `SFSpeechRecognitionTask` activas al mismo
/// tiempo sobre el mismo `recognizer` —correr dos en simultáneo no es un
/// patrón soportado de forma fiable para reconocimiento on-device y en la
/// práctica puede dejar de producir resultados por completo—. Por eso, en
/// vez de abrir la petición siguiente mientras la vieja todavía termina, el
/// audio que llega en ese hueco se guarda en un buffer y se vuelca en la
/// petición nueva recién cuando la vieja ya devolvió su resultado final.
final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var currentGeneration: UUID?
    private(set) var isRunning = false

    private var bufferedPCM: [AVAudioPCMBuffer] = []
    private var bufferedSamples: [CMSampleBuffer] = []

    /// Texto parcial de una generación (hilo principal). Solo se llama para
    /// la generación actualmente activa.
    var onPartial: ((UUID, String) -> Void)?
    /// Texto final de una generación (hilo principal).
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
        request?.endAudio()
        request = nil
        currentGeneration = nil
        bufferedPCM.removeAll()
        bufferedSamples.removeAll()
    }

    /// Cierra la generación en curso. El audio que siga llegando mientras el
    /// resultado final está en camino se guarda en un buffer y se vuelca en
    /// la petición nueva apenas exista, sin llegar a correr dos peticiones al
    /// mismo tiempo.
    func finishCurrentSegment() {
        guard isRunning, request != nil else { return }
        request?.endAudio()
        request = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if let request {
            request.append(buffer)
        } else if isRunning {
            bufferedPCM.append(buffer)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        if let request {
            request.appendAudioSampleBuffer(sampleBuffer)
        } else if isRunning {
            bufferedSamples.append(sampleBuffer)
        }
    }

    private func beginRequest() {
        let generation = UUID()
        currentGeneration = generation

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true
        newRequest.addsPunctuation = true
        newRequest.taskHint = .dictation
        request = newRequest

        // Vuelca lo que se haya acumulado mientras la petición anterior
        // terminaba, para no perder el audio capturado en ese hueco.
        for buffer in bufferedPCM { newRequest.append(buffer) }
        bufferedPCM.removeAll()
        for sample in bufferedSamples { newRequest.appendAudioSampleBuffer(sample) }
        bufferedSamples.removeAll()

        var lastText = ""
        recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let result {
                    lastText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.onSegmentEnd?(generation, lastText)
                        self.startNextIfNeeded(after: generation)
                        return
                    }
                    if self.currentGeneration == generation {
                        self.onPartial?(generation, lastText)
                    }
                    return
                }

                if error != nil {
                    // Errores como "no speech detected" cierran la generación
                    // con lo que hubiera.
                    self.onSegmentEnd?(generation, lastText)
                    self.startNextIfNeeded(after: generation)
                }
            }
        }
    }

    /// Si nadie abrió ya una petición nueva (por ejemplo, `stop()` no se
    /// llamó mientras esta generación terminaba), arranca la siguiente.
    private func startNextIfNeeded(after generation: UUID) {
        guard isRunning, request == nil, currentGeneration == generation else { return }
        beginRequest()
    }
}
