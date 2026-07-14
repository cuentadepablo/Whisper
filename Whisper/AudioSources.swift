import Accelerate
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Nivel de entrada (0…1) a partir del RMS de un buffer, mapeando el rango
/// útil de -50 dB…0 dB. Sirve para el vúmetro que valida que el audio llega.
enum AudioLevelMeter {
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(buffer.frameLength))
        return normalized(rms: rms)
    }

    static func level(of sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return 0 }
        let count = totalLength / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        var rms: Float = 0
        dataPointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        }
        return normalized(rms: rms)
    }

    private static func normalized(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (decibels + 50) / 50))
    }
}

enum WhisperError: LocalizedError {
    case noMicrophone
    case noDisplay
    case speechUnavailable

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No se encontró un micrófono disponible."
        case .noDisplay:
            return "No se encontró una pantalla para capturar el audio del sistema."
        case .speechUnavailable:
            return "El reconocimiento de voz en inglés no está disponible en este Mac."
        }
    }
}

/// Captura el micrófono con AVAudioEngine y entrega buffers PCM.
final class MicrophoneSource {
    private let engine = AVAudioEngine()

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WhisperError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Captura el audio de salida del sistema con ScreenCaptureKit (sin BlackHole
/// ni drivers de terceros). Requiere el permiso de grabación de pantalla y
/// audio del sistema.
final class SystemAudioSource: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "whisper.system-audio")
    private var onSample: ((CMSampleBuffer) -> Void)?

    var onStopped: ((Error?) -> Void)?

    func start(onSample: @escaping (CMSampleBuffer) -> Void) async throws {
        self.onSample = onSample

        // Pedir el contenido compartible dispara el aviso de permiso de
        // "Grabación de pantalla y audio del sistema" la primera vez.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw WhisperError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // El video no se usa: se pide el mínimo posible para no gastar CPU.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onSample?(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
