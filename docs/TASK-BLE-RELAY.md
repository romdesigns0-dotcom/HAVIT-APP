# HAVIT: puente de actividades por BLE

Implementación del 22/10/2026. Complementa `TASK-SYNC-IMPLEMENTATION.md`.

## Funcionamiento

El ESP32 sigue usando HTTPS por Wi-Fi. Con HAVIT iOS activa y Bluetooth disponible, la app también puede transportar solicitudes cifradas del ESP32 al backend usando la conexión a Internet del iPhone. La placa recibe la misma copia canónica y los mismos ACK de eventos que por HTTPS. Sin Internet en ambos extremos permanecen las copias y colas locales; este protocolo requiere Internet en el teléfono para autorizar cada intercambio.

La app reintenta en primer plano con espera creciente, hasta 60 s entre búsquedas. Al suspenderse o cambiar de cuenta cancela el enlace. La ejecución de iOS en segundo plano no se considera garantizada. Cerrar sesión y restablecer Wi-Fi conservan la asociación de propietario.

Instalación física confirmada en ambos clientes. En la prueba con iPhone real, el ESP32 sin Wi-Fi envió una tarea temporal al servidor y recibió su completado y borrado; quedaron la actividad original y cero cambios pendientes. Después de reiniciar la placa, recuperó la copia y reanudó el bridge automáticamente en unos44 segundos. El reinicio espera hasta25 segundos si había una solicitud BLE en vuelo antes de volver a buscar; no requiere PIN. Los dos controladores se inicializan antes de la UI para reservar memoria interna contigua.

## Autorización y cifrado

No se conserva ni reutiliza el PIN de aprovisionamiento. Tampoco se distribuyen tokens de unidad al iPhone ni se crean claves administrativas nuevas. La credencial de unidad existente y su hash de Firestore son secretos; el hash no debe exponerse por herramientas, reglas de cliente o logs.

La clave de aplicación es `SHA256(UTF8("havit-relay-v1:" + SHA256_HEX(device_token)))`, 256 bits. Firmware calcula el hash localmente; el backend usa el hash privado registrado. El teléfono no recibe esta clave. Una rotación de credencial cambia la clave derivada, y la revocación se verifica también en servidor.

Solicitudes y respuestas usan AES-256-GCM, IV aleatorio de 12 bytes y etiqueta de 16 bytes. Envoltorio JSON exacto:

```json
{"protocol":1,"deviceId":"...","bindingId":"...","nonce":"64 hex","iv":"24 hex","tag":"32 hex","data":"base64 estándar"}
```

AAD: `havit-relay-v1|request|deviceId|bindingId|nonce` o la misma cadena con `response`. La placa genera un nonce aleatorio por intercambio; acepta una sola respuesta, con su identidad/binding exactos, durante 300 segundos medidos por reloj monotónico. Desconectar BLE descarta el intercambio incompleto y su nonce. Una respuesta vieja, alterada o de otro binding no se aplica. El periodo de 300 segundos acota la validez de una respuesta que ya hubiera sido emitida antes de un unlink; el servidor no emite respuestas nuevas después del unlink.

El cuerpo de solicitud cifrado contiene `protocol: 1` y `pending`, hasta 32 eventos canónicos del ESP32. El backend exige Firebase ID token vigente en `POST /v1/devices/relay`, comprueba propietario, binding y credencial revocable, aplica eventos idempotentes con el mismo actor del canal HTTPS, y vuelve a validar el vínculo transaccionalmente al obtener el snapshot. Devuelve cifrados `protocol`, `snapshot`, `ackEventIds` y `conflictEventIds`. La placa persiste antes de devolver confirmación. Los conflictos conservan el borrador y se resuelven con la UI existente.

La hora y zona provienen del snapshot autenticado del servidor. La placa puede recuperar fecha correcta por BLE aunque no tenga SNTP/Wi-Fi. Los snapshots repetidos sin cambio de revisión, zona ni ACK no reescriben flash.

## Servicio BLE de uso normal

`services/ble_relay.c` usa un servidor protocomm independiente del gestor de provisión. Nombre anunciado: `HAVIT-SYNC-XXXX`. Security 1 sin PoP cifra el transporte; no autentica propietario por sí sola. La autorización obligatoria de extremo a extremo es AES-GCM más Firebase en el backend. No se expone un endpoint de actividades en texto claro ni endpoints para cambiar Wi-Fi/propietario en este servicio.

UUID de servicio (orden convencional): `679188a3-724c-0a99-b142-8a1192efcc5d`. Descriptores: `prov-session`, `proto-ver`, `havit-relay`. El firmware detiene el servicio antes de abrir la provisión explícita con PoP y lo recupera al terminarla si conserva binding.

`havit-relay` usa paquetes acotados, secuenciales, bajo la sesión protocomm:

| Operación | Solicitud | Respuesta útil tras byte de estado |
| --- | --- | --- |
| 1 | byte 1 | longitud total uint32 little endian de solicitud cifrada |
| 2 | byte 2 + offset uint32 LE | hasta 160 bytes de solicitud |
| 3 | byte 3 + longitud uint32 LE | reserva de respuesta cifrada |
| 4 | byte 4 + offset uint32 LE + hasta 160 bytes | escritura secuencial |
| 5 | byte 5 | verificar AEAD y nonce/binding; persistir operaciones normales. Para reset, espera a que termine el borrado físico y responde estado 2 solo si todas las particiones objetivo se borraron correctamente |
| 6 | byte 6 | longitud uint32 LE de la prueba cifrada generada por la placa tras un reset correcto |
| 7 | byte 7 + offset uint32 LE | lee hasta 160 bytes de esa prueba para que iOS pueda confirmar el borrado al backend |

Cada respuesta empieza con estado 0 en éxito o 1 en rechazo. El máximo de envoltorio es 300000 bytes; ciphertext descifrado máximo de servidor: 196608 bytes. Se permite una conexión/intercambio simultáneo. Ante corte se conservan eventos; el próximo ciclo genera nonce nuevo y el backend deduplica por eventId.

## Propiedad y limpieza

El bridge nunca cambia el binding. Unlink y transferencia de propietario utilizan las rutas y prueba física existentes. La cuenta A no puede usar una prueba cifrada para recibir datos de B, y la cuenta B no puede procesar la prueba del binding A. Firmware elimina la copia/cola del binding anterior cuando recibe el cambio de propietario por la ruta de vinculación existente; iOS cancela el bridge al cambiar uid/binding. No es necesario borrar actividades ni cuentas para activar este transporte.

### Restablecimiento de fábrica desde Perfil

El dueño inicia `POST /v1/devices/{deviceId}/factory-reset` con Firebase y el binding actual. El backend crea un requestId pendiente, pero no desvincula ni purga datos todavía. En el siguiente relay autorizado incluye dentro del AES-GCM una orden `factoryReset.requestId`; iOS solo transporta el sobre cifrado. Tras validarlo, el ESP encola el reset y responde con el byte de estado 2. El worker borra las credenciales de Wi‑Fi del NVS normal, el namespace `havit_claim` y la partición `havit_tasks`; conserva `havit_identity` (deviceId, token de dispositivo y URL fija) para permitir alta/vinculación posterior, y abre de nuevo la provisión Bluetooth.

Solo después del ACK de la placa, iOS lee la prueba de éxito creada por ESP32 con AES-256-GCM, la conserva en Keychain local del dispositivo y llama `POST /v1/devices/{deviceId}/factory-reset/complete`. Si falla la red o se cierra la app, la copia permite reintentar al volver a abrir HAVIT; el endpoint acepta de forma idempotente el mismo `requestId`. El backend verifica esa prueba con la credencial existente antes de invalidar la sesión pendiente, aumentar `ownershipEpoch`, desvincular al propietario y purgar físicamente `tasks` y `operations` de la cuenta. Bloquea temporalmente consultas/escrituras a tareas mientras borra, y el estado permite reintentar una purga incompleta. La cuenta Firebase y preferencias generales se conservan; el registro de dispositivo/credencial y eventos de auditoría se conservan. Si la placa no está cerca/encendida, la orden queda pendiente y no se purga Firebase.

## Validación

`backend/functions/test/relay.test.cjs`: AEAD, propietario distinto, ciphertext/nonce alterados, revocación, reintento cruzado BLE/HTTPS y A→unlink offline→B. El diagnóstico `tools/probe_ble_relay.py` comprueba el canal físico usando el servicio de backend local con acceso de operador a Firestore; no sustituye la aceptación iPhone→API desplegada→placa. No imprime credenciales ni contenido de tareas. El reset compiló en los tres componentes; backend desplegado, firmware instalado preservando particiones protegidas y app instalada. No se ha ejecutado el borrado físico. La aceptación real del flujo de reset aún está pendiente.
