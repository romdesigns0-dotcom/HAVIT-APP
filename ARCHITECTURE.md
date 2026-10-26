# HAVIT: arquitectura y desarrollo

HAVIT combina una app nativa para iPhone, un firmware para ESP32-S3 y un
backend compartido. El teléfono permite editar actividades y configurar la
cuenta; el dispositivo muestra su copia aunque la app esté cerrada. Ambos
acceden a los mismos datos mediante la API HAVIT y una cuenta autenticada.

## Repositorios y herramientas

- **HAVIT-APP**: app iOS, integración Firebase, API, herramientas de operador y
  esta documentación. El proyecto de Windows está en XTOOL/Havit.
- **HAVIT-DEVICE**: firmware ESP-IDF para ESP32-S3, pantalla/táctil, provisión
  BLE/Wi-Fi, almacenamiento local y sincronización.
- **Figma**: referencia visual. Las pantallas se recrean nativamente en
  SwiftUI o LVGL; no se usan capturas como interfaz final.
- **XTOOL CLI**: compilación e instalación local de iOS. En este entorno corre
  en WSL junto con Swift y el SDK de Apple configurado para xtool. Windows aloja
  el código; WSL compila y se comunica con el iPhone.
- **Firmware**: ESP-IDF 5.4.2, C/C++, FreeRTOS y LVGL 9.5.

## Componentes

| Componente | Tecnología | Responsabilidad |
| --- | --- | --- |
| HAVIT iOS | SwiftUI, Swift, ESPProvision | Cuenta, configuración BLE/Wi-Fi, actividades, caché y puente BLE |
| HAVIT ESP32 | ESP-IDF, FreeRTOS, LVGL, NimBLE | Interfaz autónoma, provisión, copia/cola local y sincronización |
| API | Firebase Cloud Functions 2, Node.js 22, TypeScript, Express | Autorización, vínculo, tareas, eventos, relay y restablecimiento |
| Datos | Firestore | Propiedad, sesiones de reclamación, actividades y operaciones |
| Identidad | Firebase Authentication | Inicio de sesión móvil y tokens ID que valida el servidor |

URL base de la API v1:

    https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1

El backend está en backend/functions/src. No se versionan
GoogleService-Info.plist, credenciales de unidad, claves privadas, tokens ni
archivos de identidad generados.

## Vinculación del dispositivo

1. iOS descubre HAVIT por BLE, abre Espressif Security 1 y valida el código de
   posesión de seis dígitos que muestra la placa.
2. Antes de enviar la contraseña Wi-Fi, iOS lee havit-info y valida la identidad
   completa y identity_provisioned.
3. iOS solicita prepare_claim en havit-claim, guarda la prueba en Keychain con
   acceso solo a este dispositivo y comprueba que puede leerla.
4. iOS calcula el hash acordado, envía ack_claim y espera acknowledged: true.
   Solo entonces envía las credenciales Wi-Fi por BLE.
5. La placa se conecta a Wi-Fi y publica la sesión con su credencial individual.
   Tras iniciar sesión, iOS presenta la prueba con un Firebase ID token.
6. El backend confirma la propiedad y crea un bindingId. App y placa muestran
   el estado vinculado solo tras verificarlo.

El código de seis dígitos se usa una vez durante la configuración. No se vuelve
a pedir para iniciar sesión o sincronizar. La identidad y la credencial privada
del ESP32 se instalan por USB en una partición dedicada. Restablecer Wi-Fi,
cerrar sesión y desvincular son operaciones distintas.

## Sincronización de actividades

- **ESP32 con Wi-Fi:** la app y la placa consultan la misma API HTTPS. La app
  usa su Firebase ID token; la placa usa su credencial individual y el
  bindingId activo.
- **ESP32 sin Wi-Fi:** con HAVIT iOS abierta en primer plano y Bluetooth
  disponible, la placa envía un sobre cifrado por BLE. El iPhone lo retransmite
  por Internet a la API y devuelve la respuesta cifrada. El teléfono no recibe
  la clave privada de la unidad.
- **Sin Internet en ambos:** iOS conserva caché y operaciones pendientes por
  cuenta; el ESP32 conserva snapshot y cola en su partición de tareas. Los
  cambios esperan conectividad para autorizarse y conciliarse.

La API valida propietario, dispositivo, bindingId, credencial revocable y
versión de las actividades. Los identificadores de operación hacen seguros los
reintentos. La autorización se deriva del token y no de un uid enviado en el
cuerpo.

## API y datos

Rutas principales:

- POST /v1/device/claim-sessions, POST /v1/devices/claim y GET /v1/device/link:
  prueba física y vínculo.
- GET /v1/user/devices y POST /v1/devices/{deviceId}/unlink: consulta y
  desvinculación autorizada.
- GET /v1/tasks, POST /v1/tasks, PATCH /v1/tasks/{taskId} y
  DELETE /v1/tasks/{taskId}: actividades.
- GET /v1/device/sync y POST /v1/device/events: snapshot y cambios desde HAVIT.
- POST /v1/devices/relay: relay cifrado cuando el ESP32 no tiene Wi-Fi.
- Rutas /v1/devices/{deviceId}/factory-reset: restablecimiento coordinado.

Firestore usa havitV1Devices, havitV1DeviceCredentials,
havitV1ClaimSessions, havitV1OwnershipEvents y
havitV1Accounts/{uid}. Las cuentas guardan tareas, preferencias y operaciones.
El servidor almacena el hash de cada credencial; el token individual vive en
la partición dedicada del ESP32.

Contratos: [backend/README.md](backend/README.md),
[sincronización de actividades](docs/TASK-SYNC-IMPLEMENTATION.md) y
[relay BLE](docs/TASK-BLE-RELAY.md).

## Restablecimiento y propiedad

Cerrar sesión conserva propietario y vínculo. Restablecer Wi-Fi borra la red
guardada, pero conserva identidad y vínculo. El restablecimiento iniciado en
Perfil coordina la limpieza local con un ticket del servidor; se completa por
Wi-Fi o, si la placa está offline, por relay BLE con el iPhone. Tras el acuse
del dispositivo, el backend confirma la desvinculación y limpia actividades y
operaciones de esa cuenta. La identidad de fábrica permanece para permitir una
nueva prueba física y un vínculo nuevo.

Las actualizaciones normales del firmware no borran NVS. No usar erase-flash
como actualización.

## Desarrollo iOS desde Windows

1. Abre XTOOL/Havit en Windows. GoogleService-Info.plist se conserva localmente
   en Sources/Havit/Resources/ y está excluido de Git.
2. En WSL instala Swift, xtool, rsync y configura el SDK de Apple y la firma.
3. Para compilar desde PowerShell:

    wsl.exe -e bash -lc "cd '<ruta-WSL>/XTOOL/Havit' && ./Scripts/build-wsl.sh build"

4. Para instalar en un iPhone conectado a Windows, define
   USBMUXD_SOCKET_ADDRESS en WSL con el host/puerto usbmuxd de esa instalación y
   ejecuta:

    wsl.exe -e bash -lc "cd '<ruta-WSL>/XTOOL/Havit' && ./Scripts/build-wsl.sh run"

build-wsl.sh sincroniza el código a ~/Havit (o HAVIT_WSL_WORK_ROOT), excluye
salidas locales y llama a Scripts/build.sh. Este último prepara el punto de
entrada WidgetKit y ejecuta xtool dev build o xtool dev run. El SDK de Apple,
la firma, Swift y xtool permanecen en el entorno local.

## Backend en desarrollo

Requiere Node.js 22 y Firebase CLI. Desde backend/functions:

    npm ci
    npm run build

Las pruebas usan Firestore Emulator; sigue backend/README.md y no apuntes las
pruebas a producción. Desplegar requiere una sesión de operador autorizada.
El alta USB genera archivos secretos fuera del repositorio. No publiques
identity.csv ni identity.bin.

## Repositorios

- App, API y documentación: https://github.com/romdesigns0-dotcom/HAVIT-APP
- Firmware ESP32: https://github.com/romdesigns0-dotcom/HAVIT-DEVICE/tree/havit-v2
- Diseño: https://www.figma.com/design/3bmX64I7Rt85DV3boqOlsc/Havit-Device-UI
