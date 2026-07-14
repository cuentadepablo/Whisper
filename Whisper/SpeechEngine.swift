import AVFoundation
import Speech

/// Transcripción continua de inglés hablado, 100 % en el dispositivo, sobre
/// el framework `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+) —el
/// reemplazo de Apple para `SFSpeechRecognizer` en escenarios de
/// reconocimiento continuo. A diferencia de `SFSpeechRecognizer`, acá **no
/// hay que rotar tareas manualmente**: un único `SpeechAnalyzer` se mantiene
/// vivo durante toda la sesión, y `results` entrega el texto de a una frase
/// por vez (no el acumulado de toda la sesión), con `isFinal` marcando
/// cuándo esa frase está definitiva. Apple decide los cortes de frase por
/// prosodia/pausas reales, así que no existe la clase de bug que arrastramos
/// con el diseño anterior (cortar el reconocimiento a mitad de una oración).
///
/// `append(_:)` no es async y es seguro llamarlo desde el hilo de audio: solo
/// convierte el buffer al formato del analizador (con `AVAudioConverter`, una
/// operación liviana) y lo entrega a un `AsyncStream.Continuation`, que está
/// diseñado para eso —encolar desde cualquier hilo sin bloquear—.
final class SpeechEngine {
    private let locale: Locale
    private var transcriber: Speech.SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Texto de la frase en curso, todavía sujeto a revisión (hilo principal).
    var onPartial: ((String) -> Void)?
    /// Texto definitivo de una frase que Apple ya dio por terminada (hilo
    /// principal). La frase siguiente empieza sola, sin acción nuestra.
    var onSegmentFinal: ((String) -> Void)?
    /// Progreso/errores para mostrar en pantalla (descarga de modelo, fallas).
    var onStatus: ((String) -> Void)?

    init(locale: Locale) {
        self.locale = locale
    }

    /// Si el modelo on-device para `locale` ya está instalado o se puede
    /// instalar (existe soporte para el idioma en este dispositivo).
    var isLocaleSupported: Bool {
        get async {
            await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
        }
    }

    func start() async throws {
        let transcriber = Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        try await ensureModelInstalled(for: transcriber)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw WhisperError.speechUnavailable
        }
        targetFormat = format

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    DispatchQueue.main.async {
                        if isFinal {
                            self.onSegmentFinal?(text)
                        } else {
                            self.onPartial?(text)
                        }
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.onStatus?("Reconocedor: \(message)")
                }
            }
        }
    }

    func stop() async {
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        transcriber = nil
        converter = nil
        targetFormat = nil
    }

    /// Llamable desde el hilo de audio: convierte (si hace falta) y encola.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        inputContinuation?.yield(AnalyzerInput(buffer: converted))
    }

    /// Llamable desde el hilo de audio: convierte desde `CMSampleBuffer`
    /// (lo que entrega ScreenCaptureKit) antes de encolar.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm)
    }

    // MARK: - Instalación del modelo on-device

    private func ensureModelInstalled(for transcriber: Speech.SpeechTranscriber) async throws {
        let installed = await Speech.SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return
        }
        DispatchQueue.main.async { [onStatus] in
            onStatus?("Descargando el modelo de voz en inglés (una sola vez, después queda offline)…")
        }
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Conversión de formato de audio

    /// El analizador exige que el audio ya venga en su formato exacto (no
    /// convierte por su cuenta, para mantener los tiempos sample-accurate).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat else { return nil }
        if buffer.format.isEqual(targetFormat) { return buffer }

        if converter == nil || !(converter?.inputFormat.isEqual(buffer.format) ?? false) {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? output : nil
    }

    /// Convierte un `CMSampleBuffer` de audio (ScreenCaptureKit) a
    /// `AVAudioPCMBuffer`, para poder reusar el mismo camino de conversión.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let format = AVAudioFormat(streamDescription: streamDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let sourceData = audioBufferList.mBuffers.mData,
              let destinationData = buffer.audioBufferList.pointee.mBuffers.mData
        else { return nil }

        let byteCount = min(Int(audioBufferList.mBuffers.mDataByteSize), Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
        destinationData.copyMemory(from: sourceData, byteCount: byteCount)
        return buffer
    }
}
