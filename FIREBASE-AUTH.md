# Autenticación de HAVIT

## Implementado

- Correo y contraseña, registro y recuperación de contraseña.
- Alternativa «Recibir enlace de acceso de uso único», envío con Firebase Auth y confirmación al pegar el enlace completo recibido. El correo usado para solicitarlo se guarda localmente; nunca se añade al enlace.
- Manejadores de URL y universal links preparados. Un enlace abierto en otro dispositivo solicita confirmar el correo.
- Teléfono: formato internacional, reCAPTCHA, callbacks de SwiftUI y APNs preparados, código SMS e ID de verificación conservado temporalmente (10 minutos).
- No se han enviado correos ni SMS como parte de la compilación. Falta verificar los flujos reales con los datos del usuario.

## Configuración comprobada

Proyecto Firebase: havit-c8c1d.
Dominio autorizado: havit-c8c1d.firebaseapp.com (verificado con la configuración pública del proyecto).
Bundle ID del GoogleService-Info.plist actual: XTL-JZ3VFWY86W.com.example.Havit. Configuración de HAVIT Desarrollo integrada.
Bundle ID de la instalación firmada con xtool: XTL-JZ3VFWY86W.com.example.Havit.

## Pasos pendientes en Firebase

1. COMPLETADO: HAVIT Desarrollo registrada con XTL-JZ3VFWY86W.com.example.Havit en el mismo proyecto Firebase.
2. COMPLETADO: nuevo GoogleService-Info.plist integrado y esquemas de retorno de Google y Firebase actualizados. Configuración anterior conservada en diagnostics/firebase-production-config/GoogleService-Info.plist.
3. Authentication > Configuración > Política de regiones de SMS: permitir México si se usarán números +52, y las demás regiones que decida el producto.
4. Para probar sin enviar SMS reales, registrar un número ficticio propio de pruebas con su código en Authentication > Teléfono. No utilizar el número de ejemplo mostrado como placeholder.
5. Verificar que la configuración de facturación/cuotas del proyecto permita SMS reales antes de probar con números reales. No se ha activado facturación desde esta tarea.

## Cuenta gratuita de Apple

La instalación actual no tiene capacidades de APNs ni Associated Domains. El flujo telefónico recurre a reCAPTCHA. Para el enlace de correo se ofrece pegar el enlace dentro de la app durante el desarrollo, sin depender de la apertura automática desde Mail.

Para producción, configurar Associated Domains, Firebase Hosting/AASA y una firma que admita esa capacidad. Después, conectar APNs para reducir la necesidad de reCAPTCHA en el teléfono. La recepción de esos callbacks ya está preparada en el código.

## Referencias oficiales

- https://firebase.google.com/docs/auth/ios/email-link-auth?hl=es-419
- https://firebase.google.com/docs/auth/ios/phone-auth?hl=es-419