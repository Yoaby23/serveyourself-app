# ServeYourself

Aplicación web para consultar restaurantes, ordenar comida para recoger y administrar pedidos en tiempo real.

La operación actual de cocina y pickup se documenta en [Cocina automática](docs/kitchen-training.md). La última revisión está en [Revisión de calidad](docs/qa-review-2026-11-10.md).

## Funciones actuales

- Registro e inicio de sesión con Supabase Auth.
- Cuentas de cliente y de negocio.
- Buscador de restaurantes y productos.
- Menús, carrito e historial de pedidos.
- Panel para administrar productos y avanzar el estado de cada pedido.
- Actualizaciones de pedidos con Supabase Realtime.
- Punto de venta para pedidos en mesa o para llevar.
- Cobro manual en efectivo, transferencia o tarjeta en terminal.
- Tickets imprimibles y pantalla operativa de cocina.
- Mesas, personal por roles y menú público con QR imprimible.

## Arquitectura

El frontend es HTML, Tailwind CSS y JavaScript. El build copia los archivos estáticos e inyecta la configuración pública de cada entorno. Supabase proporciona autenticación, PostgreSQL, políticas RLS y Realtime. La publicación actual se realiza con Vercel.

## Configuración de Supabase

Antes de publicar esta versión, abre **SQL Editor** en el proyecto de Supabase y ejecuta:

`supabase/migrations/001_secure_core.sql`

La migración:

- Activa RLS en las tablas principales.
- Restringe cada perfil a su propietario.
- Protege productos y pedidos por restaurante.
- Crea la vista pública segura de restaurantes.
- Crea perfiles al registrar usuarios.
- Crea `create_order`, que valida productos y calcula el total en PostgreSQL.

El frontend de esta versión depende de esa migración. Debe aplicarse antes del despliegue.

### Versión 2

Ejecuta después:

`supabase/migrations/002_platform_features.sql`

Esta migración agrega ubicación, métodos de pago, cancelaciones, Supabase Storage para fotografías, estadísticas y calificaciones.

### Marketplace de pagos

Ejecuta después:

`supabase/migrations/003_mercado_pago_marketplace.sql`

Esta migración agrega la conexión OAuth privada de cada restaurante, valida que los
pagos en línea solo se usen con una cuenta conectada y registra el identificador del pago.

### Punto de venta, cocina y QR

Ejecuta al final:

`supabase/migrations/004_pos_kitchen_qr.sql`

Esta migración agrega mesas, roles de mesero/cocina/encargado, invitaciones de un solo
uso, pedidos creados desde el POS, permisos de cocina y vistas públicas seguras para
el menú QR. Los cobros del POS son manuales; Mercado Pago se conserva para pedidos en línea.

Después de aplicarla, el propietario puede:

1. Entrar a **Configuración → Mesas y personal** para crear mesas e invitaciones.
2. Abrir `pos.html` para registrar ventas y emitir tickets.
3. Abrir `cocina.html` en la pantalla de preparación.
4. Entrar a **Configuración → QR imprimible del menú** para imprimir el código.

El empleado debe tener una cuenta normal, iniciar sesión y abrir `unirse.html` para
capturar el código de invitación.

### Precuentas y cobro manual

Ejecuta después:

`supabase/migrations/005_pos_payment_lifecycle.sql`

Los pedidos del POS quedan pendientes de pago al enviarse a cocina. El mesero puede
imprimir una precuenta antes de cobrar y, después, marcar el pago como efectivo,
transferencia o tarjeta en la terminal del restaurante.

Si la instalación original tenía `orders.customer_id` como obligatorio, ejecuta al final:

`supabase/migrations/006_allow_pos_orders_without_customer.sql`

Esto permite que un mesero registre pedidos presenciales sin asociarlos a una cuenta de cliente.

### Roles y permisos del restaurante

Ejecuta después:

`supabase/migrations/007_staff_permissions_and_cashier.sql`

Esta migración agrega el rol **Capitán de caja** y permisos individuales para crear
comandas, operar cocina y cerrar cuentas. El propietario conserva acceso total y puede
cambiar estos permisos desde **Personal y permisos**. Meseros y cocina también pueden
cambiar temporalmente a su experiencia de cliente para consultar sus pedidos personales.

Las pantallas operativas comparten un menú de navegación con regreso, inicio de trabajo,
pedidos personales y cierre de sesión. Cuando cocina marca una comanda como lista, el
mesero que la creó recibe un aviso en tiempo real y, si autorizó notificaciones, también
una notificación push. Después de actualizar esta función vuelve a desplegar:

```bash
supabase functions deploy send-order-notification
```

La validación automatizada de roles y recorridos puede ejecutarse con:

```bash
node tests/role-flows.test.mjs
```

### Suite operativa del restaurante

Ejecuta después:

`supabase/migrations/008_restaurant_operations_suite.sql`

Esta migración agrega cuentas abiertas y divisibles, pagos parciales o combinados,
propinas, turnos y cortes de caja, movimientos de efectivo, cancelaciones auditadas,
estaciones de cocina, disponibilidad manual de productos, cupones, reservaciones y clientes
frecuentes. Las nuevas pantallas son:

- `caja.html`: turnos, precuentas, abonos, división, traslado y cancelación.
- `inventario.html`: estaciones de cocina y asignación de productos (ruta histórica).
- `reportes.html`: ventas, meseros, productos, caja y exportación CSV/PDF.
- `clientes.html`: cupones, reservaciones y lealtad.

La aplicación incluye manifiesto y service worker para instalarse como PWA en Android,
iPhone/iPad y computadoras. Desde la portada o el menú de trabajo usa **Instalar
ServeYourself**. En iPhone abre la app en Safari y elige **Compartir → Agregar a
pantalla de inicio**; en Android, Chrome y Edge usa **Instalar aplicación**.

### Vencimiento de pagos en línea

Ejecuta después:

`supabase/migrations/010_online_payment_expiration.sql`

Los pedidos de Mercado Pago disponen de 20 minutos para iniciar el pago. Mientras
el cobro no esté aprobado se muestran únicamente en administración, caja y el
historial del cliente; nunca aparecen en cocina. Si el plazo termina sin que
Mercado Pago registre un cobro, la orden se cancela y el cliente debe crear una nueva.

Después de aplicar esta migración vuelve a desplegar las funciones de preferencia
y webhook para enviar el vencimiento a Mercado Pago y rechazar pagos fuera de plazo.

### Cuentas automáticas por mesa

Ejecuta después:

`supabase/migrations/012_automatic_table_accounts.sql`

Cuando una mesa ya tiene una cuenta abierta, el POS agrega automáticamente las
nuevas rondas a esa misma cuenta. La operación se decide en PostgreSQL para evitar
que dos meseros creen cuentas duplicadas al mismo tiempo. Cocina mantiene Realtime
y una sincronización de respaldo cada cinco segundos para aplicaciones instaladas.

### Cola completa de cocina

Ejecuta después:

`supabase/migrations/013_pending_kitchen_queue.sql`

Esta corrección recupera de forma segura las comandas activas sin entregas anteriores
y acumula todas las rondas pendientes de una cuenta en cocina. La cola se limpia
cuando la comanda completa se marca como entregada; el historial se conserva.

### Comandas independientes por ronda

Ejecuta después:

`supabase/migrations/014_independent_kitchen_tickets.sql`

La mesa conserva una sola cuenta para caja, pero cada envío del mesero crea una
comanda independiente en cocina. Una ronda nueva permanece en **Nuevos** y no cambia
el estado de otra ronda que ya esté **Preparando** o **Lista**. Las notificaciones al
mesero también identifican la comanda y la cuenta correspondientes.

### Delivery y despacho

Ejecuta después:

`supabase/migrations/015_delivery_suite.sql`

Agrega cobertura y tarifas por distancia, direcciones guardadas, aceptación de pedidos,
despacho, rol de repartidor, ubicación en ruta, código de entrega, incidencias y métricas.
En delivery los únicos métodos disponibles son **Efectivo al entregar** y **Mercado Pago**.
Después de aplicar la migración vuelve a desplegar estas funciones:

```bash
supabase functions deploy create-mercado-pago-preference
supabase functions deploy send-order-notification
```

Para habilitar el marketplace independiente, la sincronización en tiempo real y las
correcciones de producción, ejecuta también en orden las migraciones `016` a `023`.
La `021_production_readiness.sql` limita al repartidor a una entrega activa, conserva
ofertas descartadas en su centro de pedidos, protege el código de entrega, agrega
liquidaciones, aprobación de altas, reembolsos y consumo de inventario por comanda.
La `022_driver_offer_scheduling.sql` anticipa la siguiente solicitud cuando faltan
como máximo 8 minutos de ruta estimada o 2.5 km, sin permitir aceptar una segunda
entrega hasta cerrar la actual.
La `023_account_privacy_requests.sql` agrega el flujo autenticado para solicitar o
cancelar la eliminación de una cuenta. La eliminación final debe procesarse después
de revisar los comprobantes y obligaciones de conservación correspondientes.

### Priorización inteligente de cocina

Ejecuta al final:

`supabase/migrations/024_ml_kitchen_priority.sql`

La cola utiliza tiempos configurados hasta contar con al menos diez muestras reales
por restaurante y tipo de servicio. El modelo estima cantidad, variedad y horario pico
sin sumar dos veces el mismo efecto. Se valida con el 20% más reciente de las muestras
antes de utilizarlo y vuelve al tiempo configurado cuando el error es alto, faltan datos
del horario o aparecen productos/cantidades no representados en el historial.

Para la lógica actual aplica también, después de las migraciones anteriores:

`supabase/migrations/20261027010052_kitchen_priority_inventory_model.sql`

`supabase/migrations/20261027010244_inventory_adjustment_precision.sql`

Aplica finalmente `supabase/migrations/20261027212458_remove_ingredient_inventory.sql`.
La disponibilidad depende únicamente de `products.is_available`: el restaurante marca
cada producto disponible o fuera de stock. No existen ingredientes, recetas ni descuentos
automáticos. Los pedidos nuevos validan disponibilidad en el servidor y las comandas
ya aceptadas pueden continuar. La prioridad manual, los tiempos estimados, las estaciones
y la planificación por hora de entrega siguen funcionando.

Los tiempos iniciales se ajustan en **Configuración de restaurante**. El cliente puede
elegir pickup inmediato o programado hasta con siete días de anticipación. No requiere
una API de IA ni envía información operativa fuera de Supabase.

## Servicios externos

### Inicio de sesión con Google

La guía completa, con los valores exactos de callback y las comprobaciones, está en
[`docs/AUTH_PROVIDERS.md`](docs/AUTH_PROVIDERS.md).

La portada usa Supabase Auth exclusivamente con Google. En **Supabase → Authentication → Providers**, habilita Google y agrega el Client ID y Client Secret de la aplicación web. Facebook, Apple y GitHub no se muestran como opciones.

En **Authentication → URL Configuration**, configura:

```text
Site URL: https://serveyourself-app.vercel.app
Redirect URLs:
https://serveyourself-app.vercel.app/index.html
https://serveyourself-app.vercel.app/registro.html
https://serveyourself-app.vercel.app/recuperar.html
```

En Google Cloud registra como URL de retorno del proveedor:

```text
https://spbgledcjwtqmlqdlpyx.supabase.co/auth/v1/callback
```

Google necesita una aplicación OAuth de tipo **Web application**.

Antes de habilitar el botón en producción, ejecuta `supabase/migrations/011_social_auth_profiles.sql` en el SQL Editor. La migración adapta los metadatos de Google al perfil de ServeYourself.

### Recuperación de contraseña

El acceso por correo incluye recuperación mediante Supabase Auth. Agrega esta dirección a **Authentication → URL Configuration → Redirect URLs** si no utilizas ya el comodín del dominio:

```text
https://serveyourself-app.vercel.app/recuperar.html
```

El enlace de recuperación usa PKCE. Ábrelo en el mismo navegador donde solicitaste el correo. Si usas un enlace enviado antes de este cambio o abres otro navegador, solicita uno nuevo. La sesión de recuperación tiene almacenamiento separado de la sesión normal.

### Mapas

Los mapas de entrega y seguimiento usan Leaflet con los mosaicos estándar de OpenStreetMap.
No requiere clave ni cuenta de facturación. Debe conservarse la atribución visible
y respetarse la política de uso de mosaicos de OpenStreetMap. Para un volumen alto,
cambia el proveedor de mosaicos por uno con capacidad y SLA adecuados.

### OneSignal

1. Crea una Web App en OneSignal con el dominio de producción.
2. Configura `ONESIGNAL_APP_ID` en el entorno de build de Vercel.
3. Configura estos secretos en Supabase Functions:

```text
ONESIGNAL_APP_ID
ONESIGNAL_REST_API_KEY
APP_URL=https://serveyourself-app.vercel.app
```

### Mercado Pago

Cada restaurante conecta su propia cuenta mediante OAuth de Mercado Pago Marketplace. **Pausar pagos en línea** deshabilita nuevas órdenes con ese método y conserva la conexión para verificar pagos existentes y procesar devoluciones. El restaurante puede reactivar el método desde su configuración.
Configura estos secretos en Supabase Functions:

```text
MERCADO_PAGO_CLIENT_ID
MERCADO_PAGO_CLIENT_SECRET
MERCADO_PAGO_REDIRECT_URI=https://spbgledcjwtqmlqdlpyx.supabase.co/functions/v1/mercado-pago-oauth-callback
MERCADO_PAGO_FEE_PERCENT=0
MERCADO_PAGO_WEBHOOK_SECRET=la_firma_secreta_configurada_en_webhooks
APP_URL=https://serveyourself-app.vercel.app
```

Despliega las funciones:

```bash
supabase functions deploy create-mercado-pago-preference
supabase functions deploy send-order-notification
supabase functions deploy mercado-pago-webhook --no-verify-jwt
supabase functions deploy mercado-pago-connect-url
supabase functions deploy mercado-pago-oauth-callback --no-verify-jwt
supabase functions deploy mercado-pago-disconnect
supabase functions deploy refund-mercado-pago-payment
```

En Mercado Pago configura la URL de notificaciones de la aplicación y copia su firma
secreta en `MERCADO_PAGO_WEBHOOK_SECRET`. Las notificaciones sin firma válida se rechazan.

`SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` son proporcionadas automáticamente por Supabase Functions. Nunca coloques Client Secret, tokens OAuth de vendedores, la App API Key de OneSignal o la clave `service_role` en archivos públicos.

## Ejecución local

Usa Docker y la CLI de Supabase para arrancar la base, Auth, Storage y Realtime. El build de la app requiere Node 22 o posterior. Sirve `dist` mediante HTTP.

```bash
npm ci
supabase start
supabase status
# Usa únicamente la clave local Publishable o anon que devuelve supabase status.
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_PUBLISHABLE_KEY='REEMPLAZAR_CON_CLAVE_LOCAL' node scripts/build.mjs
python -m http.server 8080 --bind 127.0.0.1 --directory dist
```

Abre `http://127.0.0.1:8080`. Configura `APP_URL=http://127.0.0.1:8080` en el archivo de entorno local de las Edge Functions y arráncalas con `supabase functions serve --env-file <archivo-local>`. Para iniciar sesión por correo y probar recuperación, usa el buzón local indicado por `supabase status`.

```bash
npm test
bash scripts/test-database.sh
```

### Entornos de Vercel y Supabase

- Vercel ejecuta `node scripts/build.mjs` y sirve `dist`. Asegúrate de exponer `VERCEL_ENV` como variable de sistema. Configura `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY` por entorno. Las variables `NEXT_PUBLIC_SUPABASE_URL` y `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` se admiten si ya existen. El build de Preview requiere acceso a un proyecto aislado. Una Preview sin ese proyecto falla antes de publicar.
- Las Edge Functions usan `APP_URL` como origen y destino de retornos. Si el entorno tiene alias adicionales, configúralos explícitamente en `APP_ALLOWED_ORIGINS` separados por comas y registra las URL permitidas de Auth para ese entorno. Usa credenciales independientes para Mercado Pago y OneSignal. El build local y Preview no usan el App ID de producción.
- Los avisos se encolan aunque el envío esté desactivado. En el SQL Editor de cada entorno, registra la URL de su función con una cuenta administradora después de aplicar la migración `isolate_integrations_and_catalog`. El cron existente reintenta los eventos pendientes. En local, el endpoint permitido dentro del entorno Docker es `http://kong:8000/functions/v1/send-order-notification`.

```sql
insert into sy_private.integration_settings(id, notification_url)
values (true, 'https://<ref-de-este-entorno>.supabase.co/functions/v1/send-order-notification')
on conflict (id) do update set notification_url = excluded.notification_url;
```

### Publicación de transferencias en dos etapas

`main` es la rama de producción. En GitHub, configura la protección de `main` para exigir pull request y ambos trabajos del flujo `Calidad` (`JavaScript` y `PostgreSQL`). Verifica primero que las 65 migraciones históricas ya aplicadas coincidan por versión.

1. Usa el commit de compatibilidad, que termina en `20261126173042_isolate_integrations_and_catalog.sql`. Revisa con `supabase db push --dry-run` que esa sea la única migración nueva antes de aplicarla. Configura el endpoint de avisos en la misma ventana, despliega las Edge Functions actualizadas y publica el frontend. Verifica en producción que los clientes puedan consultar la transferencia de su pedido desde **Mis pedidos**. Esta etapa mantiene el catálogo que usan las versiones anteriores.
2. Tras verificar el frontend y actualizar las pestañas abiertas que aún usen la versión anterior, aplica `restrict_public_transfer_details` como segunda migración. Comprueba que un visitante anónimo siga viendo el catálogo con los campos bancarios vacíos y que el cliente dueño del pedido pendiente siga viendo sus instrucciones privadas.

## CSS de producción

Las pantallas usan `tailwind.generated.css`; no dependen del compilador CDN. Después de
agregar o cambiar clases de Tailwind vuelve a generarlo con:

```bash
npx tailwindcss@3.4.17 -i tailwind-source.css -o tailwind.generated.css --minify --content './*.html' './*.js'
```

## Flujo de estados

`pendiente → preparando → listo → entregado`

También se admite el estado `cancelado`. Solo un negocio puede actualizar pedidos dirigidos a su propia cuenta.

## Seguridad

La clave `sb_publishable_...` del frontend es pública por diseño. No deben guardarse claves `service_role`, contraseñas ni secretos de APIs dentro del repositorio. Las operaciones sensibles se protegen con RLS y funciones de PostgreSQL.

Las pruebas de flujos y calidad se ejecutan automáticamente en cada pull request y
actualización de `main` mediante `.github/workflows/quality.yml`. Vercel aplica las
cabeceras defensivas configuradas en `vercel.json`.

### Prueba de operación antes de ampliar el piloto

- Con caja y cocina abiertas en dispositivos distintos, corta la conexión de cocina antes del cobro. Al volver, confirma que ve exactamente una comanda y que desaparece el aviso de desconexión. Simula también una respuesta perdida al confirmar un pedido y verifica que el reintento recupera el mismo pedido.
- Al publicar este cambio, aplica primero la migración `record_online_payment_events` y actualiza la función `guest-pickup`. El detalle de caja registra pagos y reembolsos por separado desde esa migración. Para órdenes anteriores solo se conserva el último evento disponible.
- En un Supabase separado con credenciales de prueba de Mercado Pago, recorre compra, confirmación tardía y reembolso. Comprueba que Caja distingue estados y conserva la referencia. En el local físico imprime un ticket y prueba las notificaciones con los equipos del turno.
- El flujo **Salud de producción** comprueba portada, SDK y catálogo sin crear pedidos. Los fallos quedan visibles en GitHub Actions. Configura la protección de `main` para exigir los trabajos **JavaScript** y **PostgreSQL** en cada PR.
- Si falla la nueva interfaz tras publicar, restaura en Vercel la última versión estable y vuelve a comprobar el dominio con `node scripts/check-production.mjs`. La tabla de eventos nueva es aditiva y se conserva para que el historial de caja siga disponible.

### Conciliación de Mercado Pago en Caja

En **Pagos en línea → Historial de Mercado Pago**, busca por folio o por fechas. Las fechas siguen la zona horaria del equipo de caja. El historial incluye reembolsos registrados fuera de un turno. **Ver detalle** del turno sigue mostrando los movimientos del intervalo del turno.

El desglose guarda la comisión que Mercado Pago atribuye al vendedor, el IVA cuando el proveedor lo identifica por separado, el neto informado y la fecha de disponibilidad. Un campo sin datos se muestra como **Sin dato**. El neto informado se utiliza para comparar con los movimientos de Mercado Pago. Para cobros anteriores todavía aprobados se puede intentar **Consultar detalle en Mercado Pago**. Una devolución conserva el desglose que se alcanzó a registrar antes del reembolso. Para devoluciones históricas con desglose incompleto, consulta el estado de cuenta del proveedor.

Para publicar, aplica primero la migración de conciliación, despliega `mercado-pago-webhook` con sus dependencias y publica el frontend al final.

### Prueba de un turno con el equipo del restaurante

1. Abre un turno en el equipo de Caja, abre Cocina en otro equipo, y anota la hora, el operador y las versiones de navegador.
2. Pon el POS en modo de impresión correspondiente al equipo. Crea una cuenta de mesa de prueba, imprime la comanda y verifica folio, mesa, productos y variantes en papel. Confirma que Cocina muestre el mismo folio una sola vez.
3. Escanea el QR con otro dispositivo. Completa un pedido de prueba por un método acordado con el restaurante y verifica el estado en los tres dispositivos. Si se usa una terminal física, coteja el importe y referencia antes de registrar el pago en caja.
4. Comprueba que Caja y Cocina muestran **Pedidos sincronizados** sin recargar. Desconecta Cocina, confirma el pedido de prueba desde Caja y vuelve a conectarla. Verifica una sola comanda y que reaparezca el indicador de sincronización. Prueba también un reembolso por folio en **Pagos en línea**.
5. Cierra las cuentas de prueba y el turno. Compara el corte con los movimientos y guarda los folios, los tiempos y el resultado de cada prueba. Marca como pendiente cualquier equipo que aún no se haya probado físicamente.

### Protección de la rama y entrega de alertas

Con una cuenta administradora, configura una regla para `main` que requiera pull requests y los controles **JavaScript** y **PostgreSQL** de GitHub Actions, y bloquee el borrado y el force push. Vercel Preview necesita un backend separado y queda fuera de estos controles obligatorios hasta que tenga uno configurado.

**Salud de producción** abre o actualiza una incidencia de GitHub asignada al dueño del repositorio ante un fallo. Confirma con esa persona que tenga habilitadas las notificaciones de GitHub. En la versión publicada, ejecuta **Run workflow** con **Enviar una alerta de prueba al dueño del repositorio** y verifica que la persona reciba el aviso. El ejercicio crea una incidencia de prueba separada, que debe cerrarse después de confirmarla. Una ejecución programada puede retrasarse. El flujo revisa disponibilidad pública y no genera cobros.

### Recuperación de datos y controles técnicos

- En Supabase, abre **Database → Backups**. Anota la fecha y retención del respaldo más reciente y confirma cuál fue el último respaldo cuyo contenido se comprobó. Si el proyecto requiere exportaciones lógicas, usa `supabase db dump` con la conexión autorizada y conserva la copia cifrada fuera del repositorio. No guardes respaldos, URLs de conexión ni credenciales en Git.
- Ensaya la restauración en un entorno separado siguiendo [la guía de restauración local de Supabase](https://supabase.com/docs/guides/local-development/restoring-downloaded-backup). Aísla la base y sus integraciones antes de arrancarla. Verifica acceso, configuración de un restaurante, turnos, pedidos, cobros y devoluciones. Anota el intervalo cubierto y el tiempo hasta que la aplicación vuelve a consultar los datos. Los objetos de Storage requieren una copia separada. Guarda también la referencia de las versiones del frontend y de las funciones.
- En GitHub, después de activar la protección de `main`, verifica que exija los controles **JavaScript** y **PostgreSQL** de **Calidad** y que bloquee force push y borrado. Para comprobar la entrega de avisos, ejecuta **Actions → Salud de producción → Run workflow** con la opción de alerta de prueba y pide confirmación desde la cuenta destinataria.
- En Supabase Auth revisa la protección contra contraseñas filtradas. Supabase la ofrece desde el plan Pro. El control se verifica desde el panel de Auth. Las suites SQL comprueban que las integraciones internas y las credenciales de proveedores sigan fuera del alcance de usuarios de la app.

#### Exportación cifrada con Supabase Free

En un equipo autorizado con **Bash**, **age** y el cliente **PostgreSQL 17 o compatible**, genera una identidad con `age-keygen -o /ruta/privada/identidad.age` o usa la clave pública de tu custodio de respaldos. Conserva el archivo de identidad en un lugar protegido y distinto al de los respaldos.

En **Supabase → Connect**, usa una conexión directa o el *Session pooler*. Define `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` y `PGSSLMODE=verify-full` con los datos del proyecto. Configura la CA de Supabase con `PGSSLROOTCERT` y la contraseña con un archivo `.pgpass` fuera del repositorio, con permisos `0600`. El script requiere la clave pública age y crea el archivo cifrado en la carpeta que indiques. El volcado se cifra al vuelo y el archivo final aparece solo si ambos pasos terminaron bien.

```bash
scripts/backup-database.sh /ruta/privada/de/respaldos CLAVE_PUBLICA_AGE
```

Comprueba que el archivo se descifra y tiene un índice PostgreSQL legible.

```bash
set -o pipefail
age --decrypt --identity /ruta/privada/identidad.age /ruta/privada/respaldo.dump.age | pg_restore --list > /dev/null
```

Para el ensayo completo, usa una copia aislada con versiones, roles y extensiones compatibles. Coteja pedidos, turnos, cobros y devoluciones después de restaurar. Conserva una copia cifrada fuera del equipo y fija la frecuencia según cuántos cambios puedes permitirte perder. El archivo contiene la base PostgreSQL. Los archivos de Storage, las Edge Functions, sus secretos y la configuración del proyecto necesitan su propio respaldo.
