import AVFoundation
import Speech

/// Transcripción continua de inglés hablado, 100 % en el dispositivo
/// (`requiresOnDeviceRecognition = true`, sin llamadas a internet).
///
/// Diseño: una sola tarea de reconocimiento de larga duración ("generación")
/// que entrega el texto acumulado en cada parcial. El corte en segmentos tipo
/// subtítulo NO ocurre acá: lo hace el view model partiendo ese texto
/// creciente, sin detener nunca el motor — reiniciar el reconocimiento en
/// cada pausa era lo que producía huecos y bloqueos.
///
/// La tarea solo se rota de vez en cuando (ver `rotate`), y nunca hay dos
/// tareas activas a la vez: el audio que llega mientras la vieja termina se
/// guarda en un buffer y se vuelca en la nueva al crearse.
final class SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var currentGeneration: UUID?
    private(set) var isRunning = false

    private var bufferedPCM: [AVAudioPCMBuffer] = []
    private var bufferedSamples: [CMSampleBuffer] = []

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

    /// Cierra la generación actual para abrir una nueva (higiene periódica:
    /// evita que una única tarea acumule minutos de audio). Llamar solo
    /// durante un silencio; el audio que llegue en la transición se guarda en
    /// buffer, así que no se pierde nada.
    func rotate() {
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

        // Vuelca lo acumulado mientras la generación anterior terminaba.
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
                        self.onTaskEnd?(generation, lastText)
                        self.startNextIfNeeded(after: generation)
                        return
                    }
                    if self.currentGeneration == generation {
                        self.onPartial?(generation, lastText)
                    }
                    return
                }

                if error != nil {
                    // Errores como "no speech detected" terminan la
                    // generación con lo que hubiera; se reabre sola.
                    self.onTaskEnd?(generation, lastText)
                    self.startNextIfNeeded(after: generation)
                }
            }
        }
    }

    /// Arranca la generación siguiente si nadie lo hizo ya y seguimos activos.
    private func startNextIfNeeded(after generation: UUID) {
        guard isRunning, request == nil, currentGeneration == generation else { return }
        beginRequest()
    }
}
