# HAVIT

App nativa para iPhone, complementaria al dispositivo HAVIT con ESP32. Permite configurar el dispositivo, acceder a una cuenta y usar herramientas de estudio.

## Estado actual

- Bienvenida e inicio de sesión basados en el diseño de Figma.
- Conexión Bluetooth LE opcional; la sincronización de tareas requiere definir el protocolo del ESP32.
- Correo y contraseña, registro, recuperación de contraseña, Google y teléfono con Firebase Authentication.
- Alternativa de enlace de acceso por correo. Con la firma gratuita de desarrollo se permite pegar el enlace recibido dentro de la app; la apertura automática desde Mail requiere configurar Universal Links y una firma compatible.
- Temporizador de estudio, Live Activity/Dynamic Island y notificaciones locales.
- Acceso a Cuenta, cierre de sesión y regreso a la bienvenida sin borrar datos.

## Estructura

- `Sources/Havit`: aplicación SwiftUI y controladores de iOS.
- `Sources/HavitWidget`: widget de Live Activity/Dynamic Island.
- `Sources/Shared`: modelos compartidos.
- `App-Info.plist` y `HavitWidget-Info.plist`: configuración de la app y la extensión.
- `xtool.yml`: productos y configuración de empaquetado.
- `Scripts`: compilación con xtool y ajuste del punto de entrada de WidgetKit.
- `FIREBASE-AUTH.md`: configuración y limitaciones de autenticación.

## Requisitos

- Swift 6.0 o posterior y SDK de iOS compatible con las dependencias resueltas.
- xtool configurado con SDK de Apple y credenciales de firma.
- Para Windows: WSL y conexión al iPhone mediante usbmuxd.
- iOS 17 o posterior. Los controles disponibles se adaptan a la versión instalada.

## Configuración de Firebase

1. Descarga el `GoogleService-Info.plist` de tu app iOS de Firebase y colócalo en `Sources/Havit/Resources/GoogleService-Info.plist`.
2. El ejemplo de estructura está en `Config/GoogleService-Info.example.plist`; sus valores son marcadores, no una configuración funcional.
3. Ajusta en `App-Info.plist` los esquemas de URL de Google (`REVERSED_CLIENT_ID`) y Firebase (`app-` seguido de `GOOGLE_APP_ID` sustituyendo `:` por `-`).
4. Habilita los proveedores necesarios en Firebase Authentication y las regiones de SMS que se utilizarán.
5. El bundle ID registrado en Firebase debe coincidir con la app firmada. xtool puede agregar un prefijo al bundle ID al firmar con una cuenta gratuita. El bundle base del proyecto es `com.example.Havit`.

La configuración personal de Firebase, los diagnósticos del teléfono y los productos compilados permanecen fuera del control de versiones.

## Compilar e instalar

Desde la raíz del proyecto, con Swift y xtool disponibles en `PATH`:

```bash
./Scripts/build.sh build
./Scripts/build.sh run
```

`run` instala la app en el dispositivo conectado. Si el iPhone está conectado a Windows y compilas desde WSL, configura primero el endpoint de usbmuxd de tu instalación:

```bash
export USBMUXD_SOCKET_ADDRESS="IP_DE_WINDOWS:27015"
./Scripts/build.sh run
```

El script conserva el punto de entrada de la extensión WidgetKit y el de Swift. Se incluye el flag `-ObjC` en el paquete para enlazar los componentes de Firebase Authentication.

Las dependencias se fijan en `Package.resolved`. No se incluyen el SDK de Apple ni los archivos de firma en el repositorio.

## Validación disponible

La app se compiló e instaló en un iPhone físico durante el desarrollo. El arranque fue confirmado en el dispositivo. La versión más reciente incorpora la configuración de Firebase Desarrollo; falta verificar de extremo a extremo los accesos reales con correo, Google y SMS y comparar visualmente todos los estados de los formularios.