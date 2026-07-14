import AVFoundation
import Speech

/// Transcripción continua de inglés hablado, 100 % en el dispositivo
/// (`requiresOnDeviceRecognition = true`, sin llamadas a internet).
///
/// Diseño: una tarea de reconocimiento por "generación", que entrega el texto
/// acumulado en cada parcial. El corte en segmentos lo hace el view model.
///
/// TODO el estado y TODAS las llamadas al reconocedor viven en una cola
/// serial dedicada: un `append` lento solo retrasa el reconocimiento, nunca
/// bloquea el hilo de audio ni la UI.
///
/// Los reinicios de tarea llevan un freno con backoff: si una generación
/// termina sin haber producido ningún resultado (falla instantánea), la
/// siguiente espera cada vez más (hasta 4 s) en vez de reintentar en caliente
/// — un bucle de creación de tareas fallidas martilla el motor de dictado y
/// puede tumbar el stack de audio del proceso. Los errores se reportan por
/// `onStatus` para que se VEAN, en vez de tragarse en silencio.
final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private let queue = DispatchQueue(label: "whisper.speech-feed")

    // Estado tocado únicamente desde `queue`.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var currentGeneration: UUID?
    private var running = false
    private var bufferedPCM: [AVAudioPCMBuffer] = []
    private var bufferedSamples: [CMSampleBuffer] = []
    private var consecutiveBarrenGenerations = 0
    /// Tope del buffer de transición (~30 s de audio).
    private let maxBufferedChunks = 700

    /// Texto acumulado (parcial) de la generación activa (hilo principal).
    var onPartial: ((UUID, String) -> Void)?
    /// Texto final de una generación que terminó (hilo principal).
    var onTaskEnd: ((UUID, String) -> Void)?
    /// Mensajes de diagnóstico/error del reconocedor (hilo principal).
    var onStatus: ((String) -> Void)?

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
            self.consecutiveBarrenGenerations = 0
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

    /// Llamable desde cualquier hilo: encola y vuelve al instante.
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
        var deliveredSomething = false
        recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let result {
                    deliveredSomething = true
                    lastText = result.bestTranscription.formattedString
                    let text = lastText
                    if result.isFinal {
                        DispatchQueue.main.async { self.onTaskEnd?(generation, text) }
                        self.scheduleNextOnQueue(after: generation, barren: text.isEmpty)
                        return
                    }
                    if self.currentGeneration == generation {
                        DispatchQueue.main.async { self.onPartial?(generation, text) }
                    }
                    return
                }

                if let error {
                    let nsError = error as NSError
                    // Al detener nosotros la tarea llega un "canceled": no es
                    // noticia. Todo lo demás se muestra, que se vea el porqué.
                    if self.running {
                        let message = "Reconocedor: \(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
                        DispatchQueue.main.async { self.onStatus?(message) }
                    }
                    let text = lastText
                    DispatchQueue.main.async { self.onTaskEnd?(generation, text) }
                    self.scheduleNextOnQueue(after: generation, barren: !deliveredSomething)
                }
            }
        }
    }

    /// Programa la generación siguiente. `barren` = la que terminó no produjo
    /// ningún resultado; reintentos yermos consecutivos esperan cada vez más.
    private func scheduleNextOnQueue(after generation: UUID, barren: Bool) {
        if barren {
            consecutiveBarrenGenerations += 1
        } else {
            consecutiveBarrenGenerations = 0
        }
        let delay: TimeInterval = barren
            ? min(0.5 * pow(2, Double(consecutiveBarrenGenerations - 1)), 4)
            : 0.1

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.running, self.request == nil, self.currentGeneration == generation else { return }
            self.beginRequestOnQueue()
        }
    }
}
