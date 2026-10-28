# Revisión de seguridad y experiencia — 27 de octubre de 2026

## Hallazgos corregidos

| Gravedad | Problema comprobado | Corrección y evidencia |
| --- | --- | --- |
| Crítica | Tres vistas públicas actualizables conservaban permisos INSERT/UPDATE/DELETE para anon y authenticated; ejecutaban con privilegios del propietario. | Revocados permisos de tabla y columna; únicamente SELECT para clientes. Una actualización anónima con WHERE false era aceptada antes. Ahora las cinco suites SQL comprueban denegación de INSERT/UPDATE/DELETE sin modificar datos reales. No se ha determinado si hubo explotación previa. |
| Media | Los roles del cliente tenían TRUNCATE/TRIGGER/REFERENCES en tablas públicas. RLS no protege TRUNCATE. | Revocados en tablas actuales y privilegios por defecto de postgres. Cero concesiones de estos tipos verificadas. Es una reducción de privilegios SQL; no se afirma que PostgREST expusiera TRUNCATE. |
| Media | Un mesero desactivado podía seguir leyendo comandas creadas por él debido a la condición created_by de RLS. | Se exige también permiso vigente create_orders. Prueba con personal desactivado y consultas bajo authenticated. |
| Media | Disponibilidad y eliminación de productos ignoraban errores y podían aparentar éxito. | Se exige una fila devuelta y se informa el fallo. Disponibilidad recarga el estado del servidor. |
| Media | Copiar una invitación usaba event.currentTarget después de await, cuando el navegador puede haberlo limpiado; un temporizador podía sobrescribir un código nuevo. | Referencia estable, control del código vigente y manejo de rechazo del portapapeles. Tres pruebas de comportamiento. |
| Baja | El botón para eliminar una mesa carecía de texto y nombre accesible. | Acción explícita Eliminar y estilo común de acción destructiva. Escaneo de las 26 páginas sin botones vacíos sin etiqueta. |
| Baja | Volver podía conducir al acceso/registro y producir una redirección en vez de un regreso útil. | Se excluyen acceso, registro y recuperación del historial elegible. Prueba de los tres casos. |
| Baja | Alta de mesas permitía solicitudes simultáneas; fallos de red y resultados sin filas no se manejaban uniformemente. | Bloqueo durante envío, validación de texto vacío, finally para restaurar control, comprobación de filas en edición/borrado. |

## Diseño compartido

Se mantienen los iconos SVG y las barras inferiores existentes. Se añade foco visible uniforme, acción destructiva legible, ajuste de nombres largos en equipo y tarjetas, y respeto de la preferencia de movimiento reducido. No se sustituyen funciones por accesos duplicados. Estos ajustes comparten styles.css; no constituyen una inspección visual autenticada de cada rol en dispositivos físicos.

## Alcance y validación

- 57 pruebas Node aprobadas: sesión inicial, favoritos, navegación por rol, POS, cocina, pagos, recuperación, PWA, viewport, regreso y portapapeles. Parte de la suite comprueba estructura del código; no equivale a 57 recorridos reales de navegador.
- 5 suites SQL en una transacción terminada con ROLLBACK: catalog_security, api_security, favorites_single_table, kitchen_priority_inventory y qa_reliability. Los fixtures no quedan guardados.
- Inspección de las políticas public/storage, concesiones, vistas y search_path de funciones privilegiadas; 37 tablas públicas con RLS, ninguna sin RLS. Ninguna función SECURITY DEFINER pública ejecutable por anon. Ninguna política examinada usa user_metadata para autorizar.
- Revisión estática de controles, navegación, entradas y de las comprobaciones de autenticación/firma presentes en las funciones de pagos y notificaciones. No se ha hecho una prueba de penetración completa ni una revisión manual exhaustiva de cada rama de las 66 RPC privilegiadas.
- Las migraciones históricas se conservan. Las dos nuevas migraciones cierran los permisos y actualizan las políticas sobre el estado actual.

## Pendientes y límites explícitos

1. Supabase mantiene desactivada la protección de contraseñas filtradas. No se modificó Auth ni el plan; requiere configuración disponible en el panel. Referencia: https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection
2. Siguen tres avisos de vistas con privilegios del propietario. Ahora son solo lectura y proyectan campos públicos elegidos, pero siguen omitiendo RLS por diseño. Incluyen datos de pago por transferencia usados por el checkout. Una separación de datos comerciales públicos y perfiles privados requiere una migración de arquitectura, no cambiar security_invoker a ciegas. Referencia: https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view
3. Siguen 66 avisos de RPC SECURITY DEFINER accesibles a usuarios autenticados y cinco tablas privadas con RLS sin políticas. No son una garantía de seguridad ni prueba automática de explotación: deben revisarse las autorizaciones de cada operación. Las tablas privadas no deben abrirse para eliminar un aviso.
4. CSP sigue siendo parcial (base-uri, object-src, frame-ancestors). Eliminar eventos y scripts inline y definir una política estricta requiere trabajo adicional y pruebas de mapas, OAuth, pagos y notificaciones.
5. POS y abonos manuales todavía necesitan idempotencia persistente del servidor para un resultado de red ambiguo. El bloqueo de doble toque no resuelve todos los reintentos después de una desconexión. Consultar la cuenta antes de repetir un cobro o envío.
6. Faltan pruebas de aceptación autenticadas por rol en Android/iOS, concurrencia real de múltiples dispositivos, pagos y reembolsos contra el proveedor, y verificación visual de todos los tamaños. No se garantiza ausencia total de fallos.
7. No se investigaron registros históricos suficientes para descartar uso indebido previo de los permisos de las vistas. Cerrar la vía no demuestra que los datos históricos no hayan cambiado.
