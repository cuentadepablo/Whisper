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

El motor de reconocimiento corre de forma continua, sin detenerse nunca: los
"subtítulos" se cortan localmente, partiendo el texto que crece cuando se
detecta una pausa en el habla (~1,2 s sin palabras nuevas) o cuando el
segmento supera los ~15 s de habla continua. Cortar un segmento no reinicia
el reconocedor (reiniciarlo en cada pausa producía huecos y bloqueos); la
tarea de reconocimiento se rota cada ~15 s, pero **solo aprovechando una
pausa real** —el corte es invisible porque no se está diciendo nada en ese
instante—, con un tope de seguridad a los 45 s por si se habla sin parar. El
audio de la transición se guarda en buffer para no perder nada.

Mientras hablás, el parcial se muestra en cursiva y se traduce en vivo a
ritmo moderado (~2 por segundo): el modelo de traducción de Apple corre
pesado y bloquea el hilo principal mientras trabaja, así que traducir cada
parcial lo saturaría y congelaría la interfaz. El texto definitivo, en
cambio, se traduce sí o sí al cerrarse el segmento. Una cola con coalescencia
descarta las versiones que quedaron viejas para que la traducción no se
atrase, y cede el hilo entre traducciones para que la UI no se sienta
trabada.

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
- **Traducir** (interruptor): activado muestra las dos columnas (inglés y
  castellano) con traducción en vivo. Desactivado, la app **solo transcribe**
  —una sola columna, sin usar el framework Translation— lo que elimina la
  carga del traductor sobre el hilo principal. Podés cambiarlo en cualquier
  momento, incluso mientras corre.
- Presioná **Iniciar** (o ⌘Espacio). Hablá en inglés o reproducí un video
  en inglés.
- **Detener** cierra la sesión; **Guardar…** exporta un `.txt` con ambos
  idiomas, numerado por segmento.

### Usarla sin Xcode (app independiente)

Para tener `Whisper.app` como una app normal, sin la consola de Xcode:

1. En Xcode: **Product → Archive**.
2. En la ventana del organizador: **Distribute App → Custom → Copy App** y
   elegí una carpeta.
3. Arrastrá `Whisper.app` a `/Applications` y abrila desde ahí.

Notas: los permisos de Privacidad y seguridad se piden/aplican igual (si ya
los diste, se conservan, porque es el mismo bundle id). Correr fuera de Xcode
elimina el ruido de consola y la sobrecarga del debugger, pero el
comportamiento del reconocimiento es el mismo binario.

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
