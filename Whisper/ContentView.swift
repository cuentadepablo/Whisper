import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()

    /// Inglés → Español (España). Al estar fija, la sesión de traducción se
    /// crea una sola vez y vive mientras la ventana exista.
    @State private var translationConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "es-ES")
    )

    /// Última cantidad de caracteres vista, para saber si hay contenido nuevo
    /// que justifique hacer scroll (ver `transcript`).
    @State private var lastScrolledLength = 0

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            columnHeaders
            Divider()
            transcript
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 460)
        .translationTask(translationConfiguration) { session in
            await viewModel.runTranslations(session: session)
        }
    }

    // MARK: - Controles

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Fuente", selection: $viewModel.sourceKind) {
                ForEach(TranscriptionViewModel.AudioSourceKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(viewModel.isRunning)

            Spacer()

            Button {
                viewModel.saveTranscript()
            } label: {
                Label("Guardar…", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.segments.isEmpty)

            Button {
                viewModel.toggle()
            } label: {
                Label(
                    viewModel.isRunning ? "Detener" : "Iniciar",
                    systemImage: viewModel.isRunning ? "stop.circle.fill" : "record.circle"
                )
                .frame(minWidth: 90)
            }
            .keyboardShortcut(.space, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRunning ? .red : .accentColor)
        }
        .padding(12)
    }

    private var columnHeaders: some View {
        HStack(spacing: 12) {
            Text("English — transcripción")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Español — traducción")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.headline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Transcripción

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.segments) { segment in
                        segmentRow(segment)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(16)
            }
            .overlay {
                if viewModel.segments.isEmpty {
                    ContentUnavailableView(
                        "Sin transcripción todavía",
                        systemImage: "waveform",
                        description: Text("Elegí la fuente de audio y presioná Iniciar. El inglés aparece a la izquierda y la traducción al castellano a la derecha, como subtítulos en vivo.")
                    )
                }
            }
            .task {
                // Con la traducción en vivo, el array de segmentos puede
                // mutar muchas veces por frame; enganchar el scroll a
                // onChange en ese régimen dispara el diagnóstico de SwiftUI
                // "tried to update multiple times per frame". En cambio, este
                // bucle vigila el contenido a un ritmo propio, desacoplado de
                // cuántas veces mute el modelo.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    let length = viewModel.segments.reduce(0) { $0 + $1.english.count + $1.spanish.count }
                    guard length != lastScrolledLength else { continue }
                    lastScrolledLength = length
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.english)
                .italic(!segment.isFinal)
                .foregroundStyle(segment.isFinal ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(segment.spanish.isEmpty ? "…" : segment.spanish)
                .italic(!segment.isFinal)
                .foregroundStyle(segment.isFinal ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 15))
        .textSelection(.enabled)
    }

    // MARK: - Estado

    private var statusBar: some View {
        HStack {
            if viewModel.isRunning {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.red)
            }
            Text(viewModel.status)
                .lineLimit(2)
            Spacer()
            if !viewModel.segments.isEmpty {
                Text("\(viewModel.segments.count) segmentos")
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

#Preview {
    ContentView()
}
