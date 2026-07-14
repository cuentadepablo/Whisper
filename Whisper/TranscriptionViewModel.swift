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

    private var microphoneSource: MicrophoneSource?
    private var systemSource: SystemAudioSource?
    private var transcriber: SpeechTranscriber?

    private var currentSegmentID: UUID?
    private var lastPartialAt: Date?
    private var segmentStartedAt: Date?
    private var finishingSegment = false
    private var monitorTask: Task<Void, Never>?

    /// Pausa (en segundos) sin texto nuevo tras la cual se cierra el segmento.
    private let silenceThreshold: TimeInterval = 1.2
    /// Duración máxima de un segmento antes de forzar el cierre.
    private let maxSegmentDuration: TimeInterval = 45

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
            transcriber.onPartial = { [weak self] text in
                MainActor.assumeIsolated {
                    self?.handlePartial(text)
                }
            }
            transcriber.onSegmentEnd = { [weak self] text in
                MainActor.assumeIsolated {
                    self?.handleSegmentEnd(text)
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
                try microphone.start { buffer in
                    transcriber.append(buffer)
                }
                microphoneSource = microphone

            case .systemAudio:
                let system = SystemAudioSource()
                system.onStopped = { [weak self] error in
                    Task { @MainActor in
                        self?.systemAudioStopped(error)
                    }
                }
                try await system.start { sampleBuffer in
                    transcriber.append(sampleBuffer)
                }
                systemSource = system
            }

            transcriber.start()
            isRunning = true
            status = sourceKind == .microphone
                ? "Escuchando el micrófono… hablá en inglés."
                : "Capturando el audio del sistema… reproducí algo en inglés."
            startSegmentMonitor()
        } catch {
            status = "No se pudo iniciar: \(error.localizedDescription)"
            cleanUp()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cleanUp()

        // Cerrar el segmento parcial que quedara abierto.
        if let id = currentSegmentID, let index = index(of: id) {
            if segments[index].english.isEmpty {
                segments.remove(at: index)
            } else {
                segments[index].isFinal = true
                enqueueTranslation(segmentID: id, text: segments[index].english)
            }
        }
        currentSegmentID = nil
        lastPartialAt = nil
        status = "Detenido. Podés guardar la transcripción o volver a iniciar."
    }

    private func cleanUp() {
        monitorTask?.cancel()
        monitorTask = nil
        microphoneSource?.stop()
        microphoneSource = nil
        if let system = systemSource {
            systemSource = nil
            Task { await system.stop() }
        }
        transcriber?.stop()
        transcriber = nil
    }

    private func systemAudioStopped(_ error: Error?) {
        guard isRunning else { return }
        stop()
        if let error {
            status = "La captura del audio del sistema se detuvo: \(error.localizedDescription)"
        }
    }

    // MARK: - Resultados de reconocimiento

    private func handlePartial(_ text: String) {
        guard isRunning, !text.isEmpty else { return }

        let id: UUID
        if let current = currentSegmentID {
            id = current
        } else {
            id = UUID()
            currentSegmentID = id
            segmentStartedAt = Date()
            finishingSegment = false
            segments.append(TranscriptSegment(id: id, english: "", spanish: "", isFinal: false))
        }

        guard let index = index(of: id) else { return }
        segments[index].english = text
        lastPartialAt = Date()

        // Traducción "en vivo": cada parcial se manda al traductor de
        // inmediato; la coalescencia de la cola se encarga de descartar las
        // versiones que queden obsoletas antes de ser procesadas.
        enqueueTranslation(segmentID: id, text: text)
    }

    private func handleSegmentEnd(_ text: String) {
        finishingSegment = false
        lastPartialAt = nil

        guard let id = currentSegmentID else {
            if !text.isEmpty {
                let id = UUID()
                segments.append(TranscriptSegment(id: id, english: text, spanish: "", isFinal: true))
                enqueueTranslation(segmentID: id, text: text)
            }
            return
        }
        currentSegmentID = nil

        guard let index = index(of: id) else { return }
        let finalText = text.isEmpty ? segments[index].english : text
        if finalText.isEmpty {
            segments.remove(at: index)
            return
        }
        segments[index].english = finalText
        segments[index].isFinal = true
        enqueueTranslation(segmentID: id, text: finalText)
    }

    /// Vigila las pausas del habla: si no llegó texto nuevo por un rato (o el
    /// segmento se hizo demasiado largo), cierra el segmento para obtener el
    /// resultado final y arrancar uno nuevo. Así se forman los "subtítulos".
    private func startSegmentMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                self?.checkSegmentBoundary()
            }
        }
    }

    private func checkSegmentBoundary() {
        guard isRunning, !finishingSegment, currentSegmentID != nil else { return }
        let silence = lastPartialAt.map { Date().timeIntervalSince($0) } ?? 0
        let duration = segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if silence > silenceThreshold || duration > maxSegmentDuration {
            finishingSegment = true
            transcriber?.finishCurrentSegment()
        }
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
