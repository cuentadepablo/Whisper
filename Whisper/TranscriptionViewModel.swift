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
    /// Traducción simultánea al castellano. Si se desactiva, la app solo
    /// transcribe (columna española vacía) y no usa el framework Translation,
    /// que es lo que carga el hilo principal.
    @Published var translationEnabled = true
    /// Contadores de diagnóstico visibles: si "audio" crece pero "resultados"
    /// no, el audio fluye y el que calla es el reconocedor.
    @Published var diagnostics = ""

    private var microphoneSource: MicrophoneSource?
    private var systemSource: SystemAudioSource?
    private var micTestSource: MicrophoneSource?
    private var engine: SpeechEngine?

    /// `SpeechEngine` entrega una frase por vez (no el acumulado de la
    /// sesión), con `isFinal` marcando cuándo está definitiva — Apple decide
    /// los cortes de frase por su cuenta, así que acá solo hace falta llevar
    /// cuál es la fila de la tabla que sigue abierta.
    private var openSegmentID: UUID?

    /// Último nivel de entrada crudo, escrito desde los callbacks de audio
    /// (alta frecuencia) y publicado a `inputLevel` por `levelTask` a un ritmo
    /// bajo, para no inundar a SwiftUI con notificaciones desde el hilo de
    /// audio (eso provocaba "Publishing changes from within view updates").
    private var latestRawLevel: Float = 0
    private var levelTask: Task<Void, Never>?

    /// Contadores crudos para `diagnostics` (solo hilo principal).
    private var buffersReceived = 0
    private var resultsReceived = 0

    /// Freno de la traducción de parciales (el texto final nunca se frena).
    private var lastPartialTranslationAt = Date.distantPast
    private let partialTranslationInterval: TimeInterval = 0.5

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

        let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
        guard await engine.isLocaleSupported else {
            status = "El reconocimiento en el dispositivo para inglés no está disponible en este Mac."
            return
        }

        // SpeechEngine ya entrega los resultados en la cola principal;
        // assumeIsolated solo formaliza eso para el compilador.
        engine.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.handlePartial(text) }
        }
        engine.onSegmentFinal = { [weak self] text in
            MainActor.assumeIsolated { self?.handleSegmentFinal(text) }
        }
        engine.onStatus = { [weak self] message in
            MainActor.assumeIsolated { self?.status = message }
        }

        do {
            try await engine.start()
        } catch {
            status = "No se pudo iniciar el reconocedor: \(error.localizedDescription)"
            return
        }
        self.engine = engine

        do {
            switch sourceKind {
            case .microphone:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    status = "Permiso de micrófono denegado. Activalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
                    await engine.stop()
                    self.engine = nil
                    return
                }
                let microphone = MicrophoneSource()
                try microphone.start { [weak self] buffer in
                    // Nivel primero: el vúmetro no depende del reconocedor.
                    let level = AudioLevelMeter.level(of: buffer)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.latestRawLevel = level
                            self?.buffersReceived += 1
                        }
                    }
                    // append() convierte el formato y encola; nunca bloquea
                    // el hilo de audio.
                    engine.append(buffer)
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
                    let level = AudioLevelMeter.level(of: sampleBuffer)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.latestRawLevel = level
                            self?.buffersReceived += 1
                        }
                    }
                    engine.append(sampleBuffer)
                }
                systemSource = system
            }

            buffersReceived = 0
            resultsReceived = 0
            diagnostics = ""
            isRunning = true
            status = sourceKind == .microphone
                ? "Escuchando el micrófono… hablá en inglés."
                : "Capturando el audio del sistema… reproducí algo en inglés."
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
        status = "Detenido. Podés guardar la transcripción o volver a iniciar."
    }

    private func cleanUp() {
        stopLevelMeter()
        microphoneSource?.stop()
        microphoneSource = nil
        if let system = systemSource {
            systemSource = nil
            Task { await system.stop() }
        }
        if let engine {
            self.engine = nil
            Task { await engine.stop() }
        }
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

    /// `SpeechEngine` ya entrega el texto de la frase en curso (no el
    /// acumulado de la sesión), así que solo hace falta reflejarlo en la fila
    /// abierta — sin offsets, sin rotación, sin temporizador de silencio.
    private func handlePartial(_ text: String) {
        resultsReceived += 1
        updateDiagnostics()
        guard isRunning, !text.isEmpty else { return }

        if openSegmentID == nil {
            let id = UUID()
            openSegmentID = id
            segments.append(TranscriptSegment(id: id, english: "", spanish: "", isFinal: false))
        }

        guard let id = openSegmentID, let index = index(of: id) else { return }
        segments[index].english = text

        // Traducción de los parciales a ritmo moderado: el modelo de Apple
        // corre pesado y bloquea el hilo principal mientras traduce, así que
        // traducir cada parcial (varios por segundo) lo satura. Se limita a
        // ~2/seg para dar sensación en vivo sin ahogar el hilo; el texto
        // definitivo se traduce sí o sí al cerrar el segmento.
        if Date().timeIntervalSince(lastPartialTranslationAt) > partialTranslationInterval {
            lastPartialTranslationAt = Date()
            enqueueTranslation(segmentID: id, text: text)
        }
    }

    /// Apple ya decidió que esta frase terminó (por prosodia/pausa real, no
    /// por un temporizador nuestro). Se cierra la fila con el texto
    /// definitivo; la frase siguiente arranca sola con el próximo parcial.
    private func handleSegmentFinal(_ text: String) {
        resultsReceived += 1
        updateDiagnostics()
        closeOpenSegment(finalText: text)
    }

    private func updateDiagnostics() {
        let summary = "audio \(buffersReceived) · resultados \(resultsReceived)"
        if summary != diagnostics {
            diagnostics = summary
        }
    }

    /// Cierra el segmento abierto. `finalText` reemplaza su texto por la
    /// versión definitiva; con `nil` (al detener manualmente) se queda con el
    /// último parcial mostrado.
    private func closeOpenSegment(finalText: String?) {
        guard let id = openSegmentID else { return }
        openSegmentID = nil

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
                // Cede el hilo principal entre traducciones para que el texto,
                // el vúmetro y el scroll puedan refrescarse y la UI no se sienta
                // congelada si hay varias traducciones encoladas.
                await Task.yield()
            }
        }
    }

    private func enqueueTranslation(segmentID: UUID, text: String) {
        // Modo "solo transcribir": no se encola nada y el framework Translation
        // no se toca.
        guard translationEnabled else { return }
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
            if !segment.spanish.isEmpty {
                lines.append("ES: \(segment.spanish)")
            }
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
