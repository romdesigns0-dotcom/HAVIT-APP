# HAVIT Device API v1

Desplegada en Firebase `havit-c8c1d`, región `us-central1`, Node.js 22 / Cloud Functions 2 / Firestore.

**BASE_URL:** `https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1`

## Puente de actividades por BLE — 22/10/2026

`POST /v1/devices/relay` está desplegado en el mismo codebase. Exige Firebase ID token del propietario y un mensaje AES-256-GCM generado por la unidad. Comprueba deviceId, bindingId y credencial revocable; aplica eventos con la misma idempotencia de HTTPS y devuelve snapshot/ACK cifrados. Contrato y límites en `../../TASK-BLE-RELAY.md`. La clave se deriva del hash privado de la credencial; no se entrega al teléfono ni se imprime. El hash también debe tratarse como secreto.

29/29 pruebas Firestore Emulator pasaron, incluidas AEAD, cuentas diferentes, revocación y desvinculación offline. iPhone físico recibió respuestas 200; ESP32 sin Wi-Fi recibió el snapshot, envió una actividad temporal y recibió su completado y borrado. Se conserva la tarea real del usuario. La aceptación física de transferencia entre cuentas A/B es un caso distinto y sigue pendiente. Los apartados históricos siguientes conservan el contexto de entregas anteriores; el estado reciente está en `CONTEXTO_INTEGRACION_HAVIT.md` de la raíz compartida.

## Estado

Implementadas y comprobadas por HTTPS:

- `POST /v1/device/claim-sessions`: token propio del ESP32, sesión y hash de prueba; caducidad de 30 minutos y reintentos idempotentes.
- `POST /v1/devices/claim`: Firebase ID token validado con revocación + prueba aleatoria; transacción de dueño único.
- `GET /v1/device/link`: token propio, estado `unclaimed`/`linked`, identificador de vinculación.
- `GET /v1/user/devices`: Firebase ID token; devuelve únicamente los HAVIT activos vinculados a esa cuenta. iOS lo consulta al iniciar sesión o restaurar una sesión para decidir entre inicio y vinculación.
- `GET /v1/health`: comprobación pública de servicio, sin datos de dispositivos.

El registro por unidad y la revocación se ejecutan con herramientas de operador, no con endpoints públicos de autoalta. Firmware e iOS contienen el protocolo de reclamación. En la prueba física del 22/10/2026, el token de la partición instalada no coincidía con el archivo local y su publicación daba `401 UNAUTHENTICATED`. Se reconcilió el registro de Firestore con el token que ya estaba instalado, revocando el registro provisional equivocado. Tras reiniciar la placa, `POST /v1/device/claim-sessions` respondió `201`; luego el backend observó una reclamación confirmada (`state=linked`). La app consulta `GET /v1/user/devices` para reconocer el vínculo de la cuenta y omitir la vinculación al volver a iniciar sesión. Las rutas de tareas siguen fuera de esta entrega.

### Ciclo de propiedad en trabajo local

El backend local implementa `POST /v1/devices/{deviceId}/unlink`. Exige un Firebase ID token vigente, `bindingId` exacto y `requestId` UUID. El servidor deriva el dueño del token, compara el vínculo vigente dentro de una transacción, limpia el propietario y el vínculo, incrementa `ownershipEpoch`, invalida las sesiones de prueba de épocas anteriores y registra el cambio. Un reintento es idempotente mientras el dispositivo continúe sin propietario. Si alguien reclama antes del reintento, el `bindingId` esperado impide que la solicitud tardía afecte el vínculo nuevo. La ruta **no está desplegada** hasta publicar la revisión correspondiente de Functions.

La desvinculación no requiere que la placa esté online. Al volver a tener Wi-Fi, el firmware encuentra `unclaimed` y elimina su binding y cualquier prueba pendiente antigua antes de otra reclamación. Cerrar sesión y restablecer Wi-Fi no llaman al endpoint. La app borra solo el recibo, pruebas y estado local de sincronización asociado a `uid + deviceId + bindingId`; las actividades actuales guardadas globalmente en UserDefaults se conservan y no se presentan como caché del dispositivo. Aún no hay caché ni cola de tareas remotas en iOS o firmware.

Si la persona perdió acceso a Firebase, primero debe recuperar esa cuenta con los métodos de Firebase. Si no fuera posible, HAVIT Support verifica la compra/titularidad y la posesión física mediante una prueba BLE nueva; dos operadores revisan el caso y una persona autorizada ejecuta la recuperación administrativa auditada. Luego la cuenta nueva debe reclamar por BLE con una prueba física fresca. No existe un endpoint público para saltar estas verificaciones.

```powershell
node lib/recover-device-ownership.js --project havit-c8c1d --device-id "<DEVICE_ID>" --binding-id "<BINDING_ID_ACTUAL>" --support-case "<CASO_VERIFICADO>" --confirm-device-id "<MISMO_DEVICE_ID>" --use-gcloud-session
```

La herramienta exige ID y vínculo actuales, un expediente de soporte y repetir el ID como confirmación. Incrementa la época, invalida la prueba anterior y deja un evento administrativo en `havitV1OwnershipEvents`; no cambia Wi-Fi ni identidad del ESP32. Ejecutar la herramienta requiere permisos de operador y no se ejecutó contra producción en esta entrega.

Prueba de aceptación obligatoria antes de declarar terminada la función: A reclama → A desvincula con la placa sin conexión → la placa reconecta y ve `unclaimed` → B genera una prueba BLE nueva y reclama → el `bindingId` cambia; la prueba vieja falla y se purga el estado de sync de A. Comprobar además logout y restablecimiento Wi-Fi sin unlink. La prueba del emulador no sustituye esta prueba física.

Colecciones reservadas: `havitV1Devices`, `havitV1DeviceCredentials`, `havitV1ClaimSessions`, `havitV1RateLimits` y `havitV1OwnershipEvents`. Las reglas de Firestore revisadas deniegan acceso directo de clientes a esas colecciones; la prueba real lo comprobó con un Firebase ID token de usuario. Las funciones antiguas `startWatchPairing`, `claimWatchPairing`, `pollWatchPairing`, `syncWatch`, `unlinkWatch` y `dispatchTaskNotifications` pertenecen a otro código desplegado y siguen presentes. Esta entrega tiene el codebase separado `havit-device-v1`; no es una migración de sus datos.

## Comprobaciones realizadas

- TypeScript compila; auditoría de dependencias: 0 vulnerabilidades reportadas.
- `GET /v1/user/devices` se desplegó el 22/10/2026. La prueba HTTPS sin token devuelve `401 UNAUTHENTICATED` y `Cache-Control: no-store`.
- 16 pruebas contra Firestore Emulator: ciclo A → desvincular offline → B con binding nuevo, epoch y prueba vieja, reintentos tardíos seguros, recuperación de operador, autorización HTTP de propietario, además de posesión, caducidad, carrera, idempotencia, revocación y límites.
- 3 pruebas del verificador de tabla de particiones: partición dedicada válida, ausencia y direcciones/duplicados/solapamientos inválidos.
- Prueba real del despliegue mediante `functions/test/live-smoke.cjs`: alta con la herramienta de operador; `201` de publicación; `200` idempotente sin ampliar plazo; `403` para prueba incorrecta; reclamación válida; segunda cuenta rechazada; lectura del estado propio; Firestore directo denegado; revocación con la herramienta de operador y posterior `401`. Los fixtures y su archivo local se eliminaron.
- Prueba física 22/10/2026: tabla verificada sin reescribirla, identidad escrita solo en `0xC10000`, aplicación escrita solo en `0x10000` y arranque confirmado por monitor serie. Bleak detectó `HAVIT-95AA`, `havit-info`, `havit-claim` y Security 1 + PoP. La prueba de cuenta completa desde iOS queda pendiente.

Las pruebas reales requieren una sesión de operador `gcloud` autorizada y el archivo local de configuración Firebase de la app; no imprimen tokens, contraseñas de usuarios temporales ni secretos de reclamación.

## Alta USB por unidad (prototipo)

### Preparación del firmware

La tabla instalada y leída de la unidad tiene NVS en `0x9000`, la aplicación `factory` en `0x10000` con tamaño `12M` y `havit_identity` en `0xC10000` con tamaño `0x6000`. Coincide con la tabla del firmware; no hace falta reescribirla.

```csv
havit_identity, data, nvs, 0xC10000, 0x6000,
```

El firmware inicializa la partición mediante `nvs_flash_init_partition("havit_identity")`, abre el namespace `havit_identity` con `nvs_open_from_partition` y lee las cadenas:

| Clave | Contenido |
| --- | --- |
| `device_id` | Identificador exacto autorizado en el registro del backend |
| `device_token` | Credencial propia; nunca mostrar en pantalla ni logs |
| `api_base_url` | BASE_URL indicada arriba |

Mantener el estado de prueba pendiente en un namespace separado, por ejemplo `havit_claim`, dentro de la partición protegida que acuerde firmware. La acción «restablecer Wi-Fi» no borra esta partición ni llama a un borrado global de NVS. El método de cifrado/protección de flash para producción debe acordarse antes de fabricar; este procedimiento genera una imagen NVS de prototipo sin cifrar.

La herramienta de escritura comprueba la **tabla leída del ESP32** y rechaza escribir si falta la partición, si difiere de la dirección/tamaño/tipo esperados o si se solapa con otra. No sustituye la actualización de la tabla de particiones por firmware.

### Registro y archivo privado

Desde `Havit/backend/functions`, con autorización de operador en el proyecto:

```powershell
npm ci
npm run build
node lib/register-device.js --project havit-c8c1d --device-id "<DEVICE_ID_DE_HAVIT_INFO>" --output-dir "<CARPETA_PRIVADA_FUERA_DEL_REPO>" --api-base-url "https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1" --use-gcloud-session
```

La opción `--use-gcloud-session` toma un access token de corta duración de la sesión local de `gcloud` y lo conserva en memoria; no exporta claves administrativas. Alternativamente usar Application Default Credentials y omitir esa opción.

La herramienta crea `identity.csv` con una credencial única de 256 bits, registra solo su hash en Firestore y devuelve `registered: true`, el ID y la ruta del archivo. Rechaza un ID ya existente y un archivo que ya exista; no rota ni reemplaza silenciosamente una unidad. Si falla el registro, no flashear el archivo candidato local. Mantener la carpeta privada y eliminar de forma controlada los candidatos que no llegaron a registrarse.

No deducir el `device_id` a partir del nombre corto anunciado. Lee la identidad completa desde `havit-info`; esta puede usar la MAC Bluetooth y diferir de la MAC base que imprime `esptool read_mac`. Los IDs concretos de las unidades no se guardan en este repositorio.

### Generar imagen y escribir solo identidad

Usar el generador NVS de la instalación ESP-IDF de firmware:

```powershell
python "<ESP_IDF>\components\nvs_flash\nvs_partition_generator\nvs_partition_gen.py" generate "<CARPETA_PRIVADA>\identity.csv" "<CARPETA_PRIVADA>\identity.bin" 0x6000
```

Desde `Havit/backend`, con `esptool` instalado en ese Python y el puerto del **ESP32** identificado:

```powershell
python scripts/flash_identity.py --port "<PUERTO_ESP32>" --binary "<CARPETA_PRIVADA>\identity.bin"
```

Esta herramienta escribe únicamente la partición dedicada verificada. Las imágenes y CSV contienen la credencial y no deben adjuntarse a chats o al repositorio. Confirmar el registro solo mostrando el ID y el resultado HTTP de `GET /v1/device/link`, no el token.

### Revocar

```powershell
npm run revoke-device -- --project havit-c8c1d --device-id "<DEVICE_ID>" --use-gcloud-session
```

Después, las peticiones de esa credencial devuelven `401 DEVICE_CREDENTIAL_REVOKED`. El endpoint de revocación por usuario del contrato inicial no está implementado en esta entrega; se dispone de esta herramienta de operador. El proceso de rotación/recuperación de una credencial revocada queda pendiente de acordar; no se re-registra silenciosamente el mismo ID.

## Contrato de las llamadas

Los encabezados `Authorization` de dispositivo y de usuario son distintos. El servidor deriva el dispositivo de su token y al dueño de Firebase. No aceptar un `uid` del body. En la publicación no se envía `deviceId`; se deriva de la credencial.

Ejemplos con valores sustituidos, correspondientes a los formatos comprobados:

```http
POST /v1/device/claim-sessions
Authorization: Bearer <TOKEN_PROPIO_NO_REAL>
Content-Type: application/json

{"protocol":1,"claimSessionId":"77777777-7777-4777-8777-777777777777","claimSecretHash":"<SHA256_HEX_NO_REAL>"}
```

`201`, o `200` en repetición idéntica:

```json
{"claimSessionId":"77777777-7777-4777-8777-777777777777","deviceId":"havit-demo-device","state":"pending","expiresAt":"2026-10-21T20:30:00Z"}
```

```http
POST /v1/devices/claim
Authorization: Bearer <FIREBASE_ID_TOKEN_NO_REAL>
Content-Type: application/json

{"deviceId":"havit-demo-device","claimSessionId":"77777777-7777-4777-8777-777777777777","claimSecret":"<BASE64URL_32_BYTES_NO_REAL>"}
```

`200`:

```json
{"deviceId":"havit-demo-device","state":"linked","bindingId":"88888888-8888-4888-8888-888888888888","linkedAt":"2026-10-21T20:05:00Z"}
```

```http
GET /v1/device/link
Authorization: Bearer <TOKEN_PROPIO_NO_REAL>
```

```http
GET /v1/user/devices
Authorization: Bearer <FIREBASE_ID_TOKEN_NO_REAL>
Cache-Control: no-store
```

`200` devuelve solo los dispositivos activos propiedad del UID derivado del token. La app lo llama después del inicio de sesión y al restaurar sesión: lista no vacía abre el inicio; lista vacía abre el descubrimiento y vinculación del HAVIT.

```json
{"devices":[{"deviceId":"havit-demo-device","bindingId":"88888888-8888-4888-8888-888888888888","linkedAt":"2026-10-21T20:05:00Z"}]}
```

`200` antes y después de reclamar, respectivamente:

```json
{"deviceId":"havit-demo-device","state":"unclaimed","bindingId":null}
```

```json
{"deviceId":"havit-demo-device","state":"linked","bindingId":"88888888-8888-4888-8888-888888888888"}
```

Errores reales devuelven `{"error":{"code":"..."}}`; `CLAIM_NOT_READY` incluye `retryAfterSeconds: 5` y `Retry-After`. Un token ausente/inválido/revocado da `401`; prueba incorrecta `403 CLAIM_PROOF_INVALID`; otra cuenta `409 DEVICE_ALREADY_LINKED`; sesión anterior a una nueva ventana `409 CLAIM_SUPERSEDED`; caducidad `410 CLAIM_EXPIRED`; límites `429 RATE_LIMITED`. Publicación limitada a 60 llamadas/minuto por dispositivo (incluye consultas de estado); reclamación a 10/minuto por usuario. Consultar estado con backoff y respetar `Retry-After`.

Los cuerpos rechazan campos extra, requieren UUID de sesión en minúsculas, hash SHA-256 hexadecimal minúsculo y secreto base64url canónico sin relleno de exactamente 32 bytes. Fórmula de hash y protocolo BLE `prepare_claim`/`ack_claim`: `XTOOL/DEVICE-API-CONTRACT.md`, sección 4.

## Despliegue y pruebas de desarrollo

```powershell
firebase deploy --only functions:havit-device-v1 --project havit-c8c1d --non-interactive
```

Emulador con Firebase CLI actual requiere JDK 21+. Desde `Havit/backend`:

```powershell
firebase emulators:exec --config firebase.test.json --project demo-havit-device --only firestore "npm --prefix functions test"
python -m unittest discover -s scripts -p "test_*.py"
```

Las 11 pruebas también se comprobaron con el JAR Firestore 1.19.8 disponible localmente y Java 17, definiendo `FIRESTORE_EMULATOR_HOST=127.0.0.1:8686`. `npm test` se niega a ejecutar estas pruebas sin el emulador para evitar datos de prueba en producción.

Prueba real explícita, con fixtures transitorios y sin mostrar credenciales (desde `functions`):

```powershell
node test/live-smoke.cjs https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1
```
# Actividades compartidas (22/10/2026)

La API v1 incluye ahora tareas por cuenta y snapshot/eventos para ESP32. Contrato vigente, campos, límites, migración y pantallas: [TASK-SYNC-IMPLEMENTATION.md](../../TASK-SYNC-IMPLEMENTATION.md). El contexto de la raíz compartida registra por separado compilación, despliegue y aceptación física. Las secciones históricas inferiores pueden describir etapas anteriores de vinculación.
