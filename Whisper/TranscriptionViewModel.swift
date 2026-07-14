import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    var english: String
    var spanish: String
    var isFinal: Bool
}

@MainActor
final class TranscriptionViewModel: ObservableObject {
    enum AudioSourceKind: String, CaseIterable, Identifiable {
        case microphone = "Micrófono"
        case systemAudio = "Audio del sistema"
        var id: String { rawValue }
    }

    @Published var segments: [TranscriptSegment] = []
    @Published var isRunning = false
    @Published var sourceKind: AudioSourceKind = .microphone
    @Published var status = "Listo. Elegí la fuente de audio y presioná Iniciar."
    /// Nivel de entrada (0…1) para el vúmetro, tanto en captura normal como
    /// en el modo de prueba de micrófono.
    @Published var inputLevel: Float = 0
    @Published var isMicTesting = false

    private var microphoneSource: MicrophoneSource?
    private var systemSource: SystemAudioSource?
    private var micTestSource: MicrophoneSource?
    private var transcriber: SpeechTranscriber?

    /// Estado de la segmentación local. El reconocedor entrega un único texto
    /// creciente por generación; los segmentos tipo subtítulo se cortan acá,
    /// llevando la cuenta de cuántos caracteres ya fueron "consumidos" por
    /// segmentos cerrados. Cortar un segmento no toca el motor de
    /// reconocimiento: solo mueve ese offset.
    private var currentGeneration: UUID?
    private var generationStartedAt: Date?
    private var consumedCharacters = 0
    private var lastFullText = ""
    private var openSegmentID: UUID?
    private var lastPartialAt: Date?
    private var segmentStartedAt: Date?
    private var monitorTask: Task<Void, Never>?

    /// Último nivel de entrada crudo, escrito desde los callbacks de audio
    /// (alta frecuencia) y publicado a `inputLevel` por `levelTask` a un ritmo
    /// bajo, para no inundar a SwiftUI con notificaciones desde el hilo de
    /// audio (eso provocaba "Publishing changes from within view updates").
    private var latestRawLevel: Float = 0
    private var levelTask: Task<Void, Never>?

    /// Pausa (en segundos) sin texto nuevo tras la cual se cierra el segmento.
    private let silenceThreshold: TimeInterval = 1.2
    /// Duración máxima de un segmento antes de forzar el corte (habla continua).
    private let maxSegmentDuration: TimeInterval = 20
    /// Edad a partir de la cual, aprovechando un silencio, se rota la tarea de
    /// reconocimiento para que no acumule minutos de audio.
    private let maxGenerationDuration: TimeInterval = 50

    /// Cola de traducción con coalescencia: cada segmento guarda solo su texto
    /// más reciente. Si el traductor va más lento que los parciales, las
    /// versiones intermedias se descartan en vez de encolarse, así la
    /// traducción nunca acumula atraso.
    private var pendingTranslations: [UUID: String] = [:]
    private var pendingOrder: [UUID] = []
    private let wakeups: AsyncStream<Void>
    private let wakeupsContinuation: AsyncStream<Void>.Continuation

    init() {
        (wakeups, wakeupsContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    // MARK: - Iniciar / detener

    func toggle() {
        if isRunning {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRunning else { return }
        if isMicTesting { stopMicTest() }
        status = "Pidiendo permisos…"

        let speechAuth = await requestSpeechAuthorization()
        guard speechAuth == .authorized else {
            status = "Permiso de reconocimiento de voz denegado. Activalo en Ajustes del Sistema → Privacidad y seguridad → Reconocimiento de voz."
            return
        }

        do {
            let transcriber = try SpeechTranscriber()
            if !transcriber.supportsOnDeviceRecognition {
                status = "El reconocimiento en el dispositivo para inglés no está disponible todavía. Agregá inglés en Ajustes del Sistema → Teclado → Dictado y esperá a que se descargue el modelo."
                return
            }

            // SpeechTranscriber ya entrega los resultados en la cola principal;
            // assumeIsolated solo formaliza eso para el compilador.
            transcriber.onPartial = { [weak self] generation, fullText in
                MainActor.assumeIsolated {
                    self?.handlePartial(generation, fullText)
                }
            }
            transcriber.onTaskEnd = { [weak self] generation, fullText in
                MainActor.assumeIsolated {
                    self?.handleTaskEnd(generation, fullText)
                }
            }
            self.transcriber = transcriber

            switch sourceKind {
            case .microphone:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    status = "Permiso de micrófono denegado. Activalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
                    self.transcriber = nil
                    return
                }
                let microphone = MicrophoneSource()
                try microphone.start { [weak self] buffer in
                    transcriber.append(buffer)
                    let level = AudioLevelMeter.level(of: buffer)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.latestRawLevel = level }
                    }
                }
                microphoneSource = microphone

            case .systemAudio:
                let system = SystemAudioSource()
                system.onStopped = { [weak self] error in
                    Task { @MainActor in
                        self?.systemAudioStopped(error)
                    }
                }
                try await system.start { [weak self] sampleBuffer in
                    transcriber.append(sampleBuffer)
                    let level = AudioLevelMeter.level(of: sampleBuffer)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.latestRawLevel = level }
                    }
                }
                systemSource = system
            }

            transcriber.start()
            isRunning = true
            status = sourceKind == .microphone
                ? "Escuchando el micrófono… hablá en inglés."
                : "Capturando el audio del sistema… reproducí algo en inglés."
            startSegmentMonitor()
            startLevelMeter()
        } catch {
            status = "No se pudo iniciar: \(error.localizedDescription)"
            cleanUp()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cleanUp()
        closeOpenSegment(finalText: nil)
        resetGenerationTracking()
        status = "Detenido. Podés guardar la transcripción o volver a iniciar."
    }

    private func cleanUp() {
        monitorTask?.cancel()
        monitorTask = nil
        stopLevelMeter()
        microphoneSource?.stop()
        microphoneSource = nil
        if let system = systemSource {
            systemSource = nil
            Task { await system.stop() }
        }
        transcriber?.stop()
        transcriber = nil
    }

    // MARK: - Vúmetro

    /// Publica `inputLevel` a partir de `latestRawLevel` a ~12 fps, desde el
    /// runloop principal (nunca desde el hilo de audio ni durante un update
    /// de vista). Sube al instante y baja con inercia para que sea legible.
    private func startLevelMeter() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                let next = max(self.latestRawLevel, self.inputLevel * 0.7)
                // Solo publicar si cambió de forma perceptible; si no, se
                // evita invalidar la vista continuamente (incluso en silencio,
                // el decaimiento republicaba sin fin).
                if abs(next - self.inputLevel) > 0.01 {
                    self.inputLevel = next
                }
            }
        }
    }

    private func stopLevelMeter() {
        levelTask?.cancel()
        levelTask = nil
        latestRawLevel = 0
        inputLevel = 0
    }

    // MARK: - Prueba de micrófono

    /// Enciende solo el micrófono (sin reconocimiento ni traducción) y
    /// publica el nivel de entrada, para validar que la señal llega antes de
    /// arrancar una sesión de transcripción.
    func toggleMicTest() async {
        if isMicTesting {
            stopMicTest()
            return
        }
        guard !isRunning else { return }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            status = "Permiso de micrófono denegado. Activalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
            return
        }

        let microphone = MicrophoneSource()
        do {
            try microphone.start { [weak self] buffer in
                let level = AudioLevelMeter.level(of: buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.latestRawLevel = level }
                }
            }
        } catch {
            status = "No se pudo iniciar la prueba de micrófono: \(error.localizedDescription)"
            return
        }
        micTestSource = microphone
        isMicTesting = true
        startLevelMeter()
        status = "Prueba de micrófono: hablá y mirá el medidor. Si no se mueve, el micro no está captando."
    }

    func stopMicTest() {
        guard isMicTesting else { return }
        isMicTesting = false
        micTestSource?.stop()
        micTestSource = nil
        stopLevelMeter()
        status = "Prueba de micrófono terminada."
    }

    private func systemAudioStopped(_ error: Error?) {
        guard isRunning else { return }
        stop()
        if let error {
            status = "La captura del audio del sistema se detuvo: \(error.localizedDescription)"
        }
    }

    // MARK: - Resultados de reconocimiento

    /// El reconocedor entrega el texto acumulado de la generación entera; el
    /// segmento abierto muestra solo la parte que todavía no fue consumida
    /// por segmentos cerrados anteriores.
    private func handlePartial(_ generation: UUID, _ fullText: String) {
        guard isRunning, !fullText.isEmpty else { return }

        if generation != currentGeneration {
            // Cambió la generación (rotación o reinicio tras error): lo que
            // quedara abierto de la anterior se cierra con su texto actual.
            closeOpenSegment(finalText: nil)
            currentGeneration = generation
            generationStartedAt = Date()
            consumedCharacters = 0
            lastFullText = ""
        }

        lastFullText = fullText
        let delta = unconsumedText(of: fullText)
        guard !delta.isEmpty else { return }

        if openSegmentID == nil {
            let id = UUID()
            openSegmentID = id
            segmentStartedAt = Date()
            segments.append(TranscriptSegment(id: id, english: "", spanish: "", isFinal: false))
        }

        guard let id = openSegmentID, let index = index(of: id) else { return }
        segments[index].english = delta
        lastPartialAt = Date()

        // Traducción "en vivo": cada parcial se manda al traductor de
        // inmediato; la coalescencia de la cola descarta las versiones que
        // queden obsoletas antes de ser procesadas.
        enqueueTranslation(segmentID: id, text: delta)
    }

    /// Fin de una generación (rotación programada o error tipo "no speech").
    /// La siguiente arranca sola en SpeechTranscriber; acá solo se cierra lo
    /// que quedaba abierto con el texto final definitivo.
    private func handleTaskEnd(_ generation: UUID, _ fullText: String) {
        guard generation == currentGeneration else { return }
        if !fullText.isEmpty {
            lastFullText = fullText
        }
        closeOpenSegment(finalText: unconsumedText(of: lastFullText))
        resetGenerationTracking()
    }

    /// Corta los "subtítulos" vigilando pausas del habla y longitud. El corte
    /// es local (mover el offset de consumido); el motor de reconocimiento no
    /// se toca, salvo la rotación de higiene cuando la generación ya es vieja
    /// — y siempre aprovechando un silencio, cuando no se pierde nada.
    private func startSegmentMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                self?.checkSegmentBoundary()
            }
        }
    }

    private func checkSegmentBoundary() {
        guard isRunning, openSegmentID != nil else { return }
        let silence = lastPartialAt.map { Date().timeIntervalSince($0) } ?? 0
        let segmentAge = segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let generationAge = generationStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        if silence > silenceThreshold {
            cutSegmentLocally()
            if generationAge > maxGenerationDuration {
                transcriber?.rotate()
            }
        } else if segmentAge > maxSegmentDuration {
            cutSegmentLocally()
        }
    }

    /// Cierra el segmento abierto y marca todo el texto actual como consumido,
    /// de modo que el próximo parcial empiece un segmento nuevo con el delta.
    private func cutSegmentLocally() {
        let consumedNow = lastFullText.count
        closeOpenSegment(finalText: nil)
        consumedCharacters = consumedNow
    }

    /// Cierra el segmento abierto. `finalText` permite reemplazar su texto por
    /// una versión definitiva (fin de generación); con `nil` se queda el que
    /// ya mostraba.
    private func closeOpenSegment(finalText: String?) {
        guard let id = openSegmentID else { return }
        openSegmentID = nil
        segmentStartedAt = nil
        lastPartialAt = nil

        guard let index = index(of: id) else { return }
        var text = segments[index].english
        if let finalText, !finalText.isEmpty {
            text = finalText
        }
        if text.isEmpty {
            segments.remove(at: index)
            return
        }
        segments[index].english = text
        segments[index].isFinal = true
        enqueueTranslation(segmentID: id, text: text)
    }

    /// Parte del texto acumulado que aún no pertenece a ningún segmento
    /// cerrado. Si el reconocedor revisó el texto y quedó más corto que lo
    /// consumido, devuelve vacío hasta que vuelva a crecer.
    private func unconsumedText(of fullText: String) -> String {
        guard fullText.count > consumedCharacters else { return "" }
        return String(fullText.dropFirst(consumedCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetGenerationTracking() {
        currentGeneration = nil
        generationStartedAt = nil
        consumedCharacters = 0
        lastFullText = ""
    }

    // MARK: - Traducción

    /// Bucle de traducción: lo alimenta la vista a través de `.translationTask`,
    /// que es la manera soportada de obtener una `TranslationSession`. Mientras
    /// este bucle esté vivo, la sesión sigue siendo válida.
    func runTranslations(session: TranslationSession) async {
        do {
            // Descarga los modelos inglés→español si hace falta (con diálogo
            // del sistema). Después de esto, todo es local.
            try await session.prepareTranslation()
        } catch {
            status = "No se pudieron preparar los idiomas de traducción: \(error.localizedDescription)"
        }

        for await _ in wakeups {
            // Drenar todo lo pendiente; mientras un translate() está en vuelo
            // pueden llegar textos nuevos, que este mismo while recoge.
            while !pendingOrder.isEmpty {
                let id = pendingOrder.removeFirst()
                guard let text = pendingTranslations.removeValue(forKey: id) else { continue }
                do {
                    let response = try await session.translate(text)
                    if let index = index(of: id) {
                        segments[index].spanish = response.targetText
                    }
                } catch {
                    status = "Error de traducción: \(error.localizedDescription)"
                }
            }
        }
    }

    private func enqueueTranslation(segmentID: UUID, text: String) {
        // Si el segmento ya estaba en cola, solo se reemplaza su texto por el
        // más nuevo; no se duplica la entrada.
        if pendingTranslations.updateValue(text, forKey: segmentID) == nil {
            pendingOrder.append(segmentID)
        }
        wakeupsContinuation.yield()
    }

    // MARK: - Guardar

    func saveTranscript() {
        let panel = NSSavePanel()
        panel.title = "Guardar transcripción"
        panel.nameFieldStringValue = "transcripcion.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = [
            "Transcripción — \(Date().formatted(date: .long, time: .shortened))",
            String(repeating: "=", count: 40),
            ""
        ]
        for (index, segment) in segments.enumerated() {
            lines.append("[\(index + 1)]")
            lines.append("EN: \(segment.english)")
            lines.append("ES: \(segment.spanish)")
            lines.append("")
        }

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            status = "Transcripción guardada en \(url.lastPathComponent)."
        } catch {
            status = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    // MARK: - Auxiliares

    private func index(of id: UUID) -> Int? {
        segments.firstIndex { $0.id == id }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
