# Whisper — Transcripción y traducción en vivo para macOS

App nativa (Swift + SwiftUI) que escucha audio en **inglés** —del micrófono o
del propio Mac— y muestra en tiempo real la **transcripción en inglés** y su
**traducción al castellano**, lado a lado, como subtítulos en vivo.
Todo el procesamiento es **100 % local**: no se envía nada a internet.

## Cómo funciona

| Pieza | Framework de Apple | Rol |
|---|---|---|
| Captura de micrófono | `AVAudioEngine` | Buffers PCM de lo que hablás |
| Captura del audio del sistema | `ScreenCaptureKit` (`SCStream` con `capturesAudio`) | Lo que suena en el Mac (videos, llamadas, etc.), sin BlackHole ni drivers |
| Transcripción (EN) | `Speech` / `SFSpeechRecognizer` con `requiresOnDeviceRecognition = true` | Reconocimiento continuo, en el dispositivo |
| Traducción (EN→ES) | `Translation` / `TranslationSession` | Traducción local con los modelos de Apple |

La app corta el texto en segmentos cuando detecta una pausa en el habla
(~1,2 s sin palabras nuevas): en ese momento el segmento se marca como final,
se traduce y empieza uno nuevo. Mientras hablás, el parcial se muestra en
cursiva y se traduce en vivo: cada actualización se manda al traductor de
inmediato, y una cola con coalescencia descarta las versiones que quedaron
viejas para que la traducción nunca se atrase respecto del habla. Al cerrarse
el segmento se traduce la frase completa definitiva.

## Requisitos

- **macOS 15 (Sequoia) o posterior.** Aunque el framework Translation existe
  desde macOS 14.4, en esa versión solo ofrece la hoja de traducción con
  interfaz propia; la API programática (`TranslationSession`), que es la que
  permite traducir texto dentro de la app en tiempo real, requiere macOS 15.
- **Xcode 16 o posterior** (el proyecto usa el formato de carpetas
  sincronizadas de Xcode 16).
- Mac con Apple Silicon recomendado (los modelos on-device rinden mejor).

## Abrir, compilar y ejecutar

1. Cloná el repo y abrí `Whisper.xcodeproj` con doble clic (o `File → Open…`
   en Xcode).
2. Seleccioná el target **Whisper** → pestaña **Signing & Capabilities** →
   en **Team** elegí tu Apple ID (sirve el *Personal Team* gratuito). No hace
   falta cambiar nada más: el sandbox y los entitlements ya están configurados.
3. Arriba a la izquierda elegí el esquema **Whisper → My Mac** y presioná
   **⌘R** (Run).
4. La primera vez que uses cada función, macOS te va a pedir los permisos
   (ver sección siguiente) y puede ofrecerte descargar los modelos de idioma
   de traducción (una única descarga; después todo es offline).

### Primer uso

- **Probar micro** (opcional): enciende solo el micrófono y muestra un
  vúmetro en la barra de estado, sin transcribir nada. Si la barra se mueve
  al hablar, la señal llega bien; si queda quieta, revisá el permiso de
  micrófono o el dispositivo de entrada seleccionado en Ajustes → Sonido.
  El mismo vúmetro se muestra también durante la captura normal (micrófono
  o audio del sistema), así siempre se ve si está entrando audio.
- Elegí la fuente en el selector: **Micrófono** o **Audio del sistema**.
- Presioná **Iniciar** (o ⌘Espacio). Hablá en inglés o reproducí un video
  en inglés.
- **Detener** cierra la sesión; **Guardar…** exporta un `.txt` con ambos
  idiomas, numerado por segmento.

## Permisos

La app los pide automáticamente, pero si rechazaste alguno tenés que
activarlo a mano en **Ajustes del Sistema → Privacidad y seguridad**:

| Permiso | Sección de Ajustes | Cuándo se usa |
|---|---|---|
| Micrófono | *Micrófono* | Fuente "Micrófono" |
| Reconocimiento de voz | *Reconocimiento de voz* | Siempre (transcripción) |
| Grabación de pantalla y audio del sistema | *Grabación de pantalla y audio del sistema* | Fuente "Audio del sistema" |

Notas:

- El permiso de grabación de pantalla aparece en la lista recién después del
  **primer intento** de captura; activá el interruptor de Whisper y, si macOS
  lo pide, relanzá la app. (Se usa solo para el audio: el video se captura al
  mínimo posible y se descarta.)
- En macOS 15, el sistema puede volver a pedir confirmación de la grabación
  de pantalla periódicamente; es comportamiento normal de Sequoia.
- Si la transcripción no arranca, verificá que el dictado en inglés esté
  disponible: **Ajustes del Sistema → Teclado → Dictado**, agregá *English
  (US)* y esperá a que termine la descarga del modelo.
- Los idiomas de traducción (inglés y español) se descargan una sola vez; la
  app lo ofrece al iniciarse. También se gestionan en **Ajustes del Sistema →
  Idioma y región → Idiomas de traducción**.

## Estructura del proyecto

```
Whisper.xcodeproj/          Proyecto Xcode (formato Xcode 16)
Whisper/
  WhisperApp.swift          Punto de entrada SwiftUI
  ContentView.swift         UI: controles + dos columnas con auto-scroll
  TranscriptionViewModel.swift  Orquestación: segmentos, pausas, traducción, guardado
  SpeechTranscriber.swift   SFSpeechRecognizer en modo streaming, on-device
  AudioSources.swift        MicrophoneSource (AVAudioEngine) y SystemAudioSource (ScreenCaptureKit)
  Whisper.entitlements      Sandbox + micrófono + guardado de archivos
```

El `Info.plist` se genera automáticamente (`GENERATE_INFOPLIST_FILE`) con las
claves `NSMicrophoneUsageDescription` y `NSSpeechRecognitionUsageDescription`
definidas en los build settings del target. La captura de pantalla/audio del
sistema no usa clave de Info.plist: se autoriza vía TCC (Ajustes del Sistema).

## Limitaciones conocidas

- El reconocimiento on-device de Apple es muy bueno para dictado, pero puede
  perder precisión con audio muy comprimido o con varias voces superpuestas.
- La traducción de los parciales (texto en cursiva) es aproximada; la
  traducción buena llega cuando el segmento se cierra.
- Solo se captura audio de un idioma por sesión (inglés → castellano). Es
  fácil de extender: los idiomas están centralizados en
  `ContentView.translationConfiguration` y en el locale de `SpeechTranscriber`.
