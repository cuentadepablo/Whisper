import AVFoundation
import Speech

/// Transcripción continua de inglés hablado, 100 % en el dispositivo
/// (`requiresOnDeviceRecognition = true`, sin llamadas a internet).
///
/// Diseño: una tarea de reconocimiento por "generación", rotada
/// periódicamente, que entrega el texto acumulado en cada parcial. El corte
/// en segmentos tipo subtítulo lo hace el view model partiendo ese texto.
///
/// TODO el estado y TODAS las llamadas al reconocedor (append, endAudio,
/// crear la tarea) viven en una cola serial dedicada. Esto es crítico:
/// `SFSpeechAudioBufferRecognitionRequest.append` puede bloquearse cuando el
/// motor on-device se atasca, y si eso pasara en el hilo de audio se
/// congelaría toda la captura (vúmetro incluido). Con la cola dedicada, un
/// append lento solo retrasa el reconocimiento; el audio y la UI siguen
/// fluyendo.
final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private let queue = DispatchQueue(label: "whisper.speech-feed")

    // Estado tocado únicamente desde `queue`.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var currentGeneration: UUID?
    private var running = false
    private var bufferedPCM: [AVAudioPCMBuffer] = []
    private var bufferedSamples: [CMSampleBuffer] = []
    /// Tope del buffer de transición (~30 s de audio); si se supera, se
    /// descarta lo más viejo antes que crecer sin límite.
    private let maxBufferedChunks = 700

    /// Texto acumulado (parcial) de la generación activa (hilo principal).
    var onPartial: ((UUID, String) -> Void)?
    /// Texto final de una generación que terminó (hilo principal). Tras esto
    /// arranca sola la generación siguiente si seguimos corriendo.
    var onTaskEnd: ((UUID, String) -> Void)?

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
        queue.async {
            self.running = true
            self.beginRequestOnQueue()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.request?.endAudio()
            self.request = nil
            self.currentGeneration = nil
            self.bufferedPCM.removeAll()
            self.bufferedSamples.removeAll()
        }
    }

    /// Cierra la generación actual; la siguiente arranca cuando la vieja
    /// entrega su resultado final. El audio del ínterin queda en buffer.
    func rotate() {
        queue.async {
            guard self.running, self.request != nil else { return }
            self.request?.endAudio()
            self.request = nil
        }
    }

    /// Llamable desde cualquier hilo: encola y vuelve al instante. El hilo de
    /// audio nunca espera al reconocedor.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            if let request = self.request {
                request.append(buffer)
            } else if self.running {
                self.bufferedPCM.append(buffer)
                if self.bufferedPCM.count > self.maxBufferedChunks {
                    self.bufferedPCM.removeFirst()
                }
            }
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            if let request = self.request {
                request.appendAudioSampleBuffer(sampleBuffer)
            } else if self.running {
                self.bufferedSamples.append(sampleBuffer)
                if self.bufferedSamples.count > self.maxBufferedChunks {
                    self.bufferedSamples.removeFirst()
                }
            }
        }
    }

    private func beginRequestOnQueue() {
        let generation = UUID()
        currentGeneration = generation

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true
        newRequest.addsPunctuation = true
        newRequest.taskHint = .dictation
        request = newRequest

        // Vuelca lo acumulado mientras la generación anterior terminaba.
        for buffer in bufferedPCM { newRequest.append(buffer) }
        bufferedPCM.removeAll()
        for sample in bufferedSamples { newRequest.appendAudioSampleBuffer(sample) }
        bufferedSamples.removeAll()

        var lastText = ""
        recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let result {
                    lastText = result.bestTranscription.formattedString
                    let text = lastText
                    if result.isFinal {
                        DispatchQueue.main.async { self.onTaskEnd?(generation, text) }
                        self.startNextIfNeededOnQueue(after: generation)
                        return
                    }
                    if self.currentGeneration == generation {
                        DispatchQueue.main.async { self.onPartial?(generation, text) }
                    }
                    return
                }

                if error != nil {
                    // Errores como "no speech detected" terminan la
                    // generación con lo que hubiera; se reabre sola.
                    let text = lastText
                    DispatchQueue.main.async { self.onTaskEnd?(generation, text) }
                    self.startNextIfNeededOnQueue(after: generation)
                }
            }
        }
    }

    /// Arranca la generación siguiente si nadie lo hizo ya y seguimos activos.
    private func startNextIfNeededOnQueue(after generation: UUID) {
        guard running, request == nil, currentGeneration == generation else { return }
        beginRequestOnQueue()
    }
}
