# HAVIT: actividades compartidas v1

Revisión 22/10/2026. Este documento sustituye las propuestas de tareas anteriores. La API, autenticación y procedimientos para el operador se describen en [backend/README.md](../backend/README.md).

## Campos y pantallas

| Campo | iOS | ESP32 | Servidor |
| --- | --- | --- | --- |
| id | UUID persistente | UUID persistente | UUID inmutable |
| title | Crear/editar, tarjetas | Lista, detalle, editor | 160 bytes UTF-8, obligatorio |
| detail | Crear/editar | Detalle y editor desplazable | 2048 bytes UTF-8 |
| dueAt | Selector nativo opcional | Fecha opcional AAAA-MM-DD HH:MM | UTC ISO 8601 o null; 2020–2099 |
| status | Completar/reabrir | Completar/reabrir | pending/completed |
| taskVersion | Interno | Interno | Revisión por actividad, transaccional |
| createdAt/updatedAt | Orden y registro de cambios | Orden y registro de cambios | Hora del servidor |
| timeZone | Preferencia explícita de la cuenta | Consume misma zona | IANA, inicial America/Mexico_City |

Además de los límites individuales, el JSON de los campos admite hasta 2400 bytes para mantener acotada la respuesta del ESP32. El conjunto admite 64 actividades pendientes o completadas; eliminar libera espacio. Las listas ordenan pendientes antes de completadas, después fecha de entrega, creación e identificador. Las actividades sin vencimiento no reciben fechas inventadas. El calendario muestra las que sí tienen entrega. El resumen de Inicio cuenta completadas/total de todas las actividades, incluidas las de entrega futura y sin fecha; iOS lo llama TU PROGRESO y el ESP32 Tareas. La fecha de entrega solo filtra el calendario, no el resumen general.

iOS: lista, alta/edición/eliminación, calendario diario, zona horaria, estado remoto/cambios pendientes y resolución de conflictos. ESP32: Today y calendario consumen datos reales; lista completa, detalle, alta/edición/eliminación y revisión de conflictos. Los tres nombres en la órbita son un resumen; la lista diaria muestra todas.

## API HTTPS

Base: https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1

Todas las rutas requieren Authorization Bearer. Rutas user/tasks: Firebase ID token de la cuenta. Rutas device: credencial revocable propia de la unidad y bindingId vigente, verificados dentro de la transacción.

| Método/ruta | Cuerpo |
| --- | --- |
| GET /v1/tasks | Sin cuerpo |
| POST /v1/tasks | operationId, taskId, baseTaskVersion:0, task |
| PATCH /v1/tasks/:taskId | operationId, baseTaskVersion, task |
| DELETE /v1/tasks/:taskId | operationId, baseTaskVersion |
| PUT /v1/user/preferences | timeZone |
| GET /v1/device/sync?bindingId=UUID | Sin cuerpo |
| POST /v1/device/events | bindingId, eventId, taskId, baseTaskVersion, kind, task salvo delete |

task contiene exactamente title, detail, dueAt y status. kind es create/update/delete. Cada escritura retorna revision, id, taskVersion, task (null tras borrar). GET entrega snapshot completo protocol:1, uid, deviceId/bindingId (null para usuario), revision, serverTime, localDate, timeZone, utcOffsetSeconds, utcOffsetTransitions, taskLimit y tasks. Las transiciones IANA 2020–2099 permiten al firmware convertir fechas futuras sin confundir horario de verano. Una hora local inexistente se rechaza; en una hora repetida el firmware elige una ocurrencia determinista, mientras iOS permite fijar el instante con su selector.

GET usa snapshot completo acotado, sin paginación ni cursor. Una actividad ausente debe desaparecer de la caché canónica; los borradores locales pendientes se proyectan encima. Sondeo de 15 s, más actualización manual y envío al editar. La app requiere estar activa para sondear; el ESP32 usa su Wi-Fi independientemente del teléfono/Bluetooth.

## Persistencia, permisos y conflictos

Firestore: havitV1Accounts/{uid}, tasks/{id}, operations/{operationId}. Acceso mediante Admin SDK del backend; el ruleset desplegado no concede acceso cliente a esta nueva colección. No cambiar ni borrar las colecciones antiguas.

Cada cambio lleva UUID de operación y versión base. Repetir una operación idéntica retorna su resultado original; reutilizarla con contenido/actor distinto devuelve 409. Las versiones obsoletas devuelven 409 TASK_VERSION_CONFLICT, nunca sobrescriben silenciosamente. Los borrados conservan tombstones y el historial de operaciones se conserva sin TTL por ahora. Antes de escalar se necesita política de retención/métricas; no borrar historial sin definir ventana de reintentos.

iOS conserva caché y cola separadas por uid en UserDefaults; renueva Firebase ID token y verifica uid/generación tras cada await. Migra solo las actividades antiguas de esa misma cuenta, preservando UUID, título, detalle y estado; la hora de creación textual antigua no se convierte en vencimiento. Modo local permanece separado y no se importa a una cuenta automáticamente.

ESP32: partición nueva havit_tasks en 0xC16000, tamaño 0xC0000, sin mover identidad ni NVS Wi-Fi. Snapshot y cola de 32 eventos se guardan antes de indicar éxito local. La caché y los eventos llevan bindingId; al cambiar/desaparecer el vínculo se descartan los del propietario anterior. Cada evento vuelve a verificar propietario y binding en servidor. Cerrar sesión/restablecer Wi-Fi no hace unlink. Durante desconexión se muestran los últimos datos conocidos, con estado offline.

Conflictos: ambos clientes conservan el cambio rechazado y ofrecen conservar servidor o reaplicar el borrador sobre la versión vigente con otra operación. Si la actividad fue borrada, restaurarla crea otro id. Errores temporales conservan la misma operación para reintentar.

## Fuera de este contrato

Temporizador rápido, Equipos, miembros, adjuntos/PDF, IA, notificaciones y recurrencias no están sincronizados por esta entrega. Requieren modelos y permisos propios. Una cuenta autenticada, un dispositivo vinculado y actividades actualizadas son estados distintos.

## Comprobaciones

Suite Firestore Emulator: 25 pruebas de autenticación, aislamiento de cuentas, vínculo, revocación, idempotencia, conflictos concurrentes, borrados, límites y fechas/zona horaria. Build Swift mediante xtool y build ESP-IDF se registran por separado. Para aceptar el recorrido visual completo: crear/editar/completar/borrar en iPhone y placa, observar igualdad de id/versión, reiniciar sin BLE, probar cola offline y conflicto. No equiparar pruebas de servicio con una comprobación visual del iPhone.

Entrega física 22/10/2026: app instalada en iPhone; actividad real creada por usuario «Hola prueba» verificada en backend y ESP con el mismo id/v5. Firmware instalado preservando identidad/Wi-Fi y vínculo. Prueba temporal creada desde ESP, cambiada y borrada por API, recibida correctamente de vuelta; limpieza de prueba confirmada. Reinicio recuperó la actividad desde caché antes de recuperar Wi-Fi y luego confirmó servidor. No se recibió confirmación de que el teléfono estuviera cerrado/Bluetooth apagado durante ese reinicio; ese caso y la cola de cambios offline con conflictos requieren aceptación física adicional. El temporizador y Equipos continúan fuera del contrato.
