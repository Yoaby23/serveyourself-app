# ServeYourself

Aplicación web para consultar restaurantes, ordenar comida para recoger y administrar pedidos en tiempo real.

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

El frontend es HTML, Tailwind CSS y JavaScript sin proceso de compilación. Supabase proporciona autenticación, PostgreSQL, políticas RLS y Realtime. La publicación actual se realiza con Vercel.

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
estaciones de cocina, inventario por recetas, cupones, reservaciones y clientes
frecuentes. Las nuevas pantallas son:

- `caja.html`: turnos, precuentas, abonos, división, traslado y cancelación.
- `inventario.html`: ingredientes, existencias, recetas y estaciones.
- `reportes.html`: ventas, meseros, productos, caja y exportación CSV/PDF.
- `clientes.html`: cupones, reservaciones y lealtad.

La aplicación incluye manifiesto y service worker para instalarse como PWA.

### Vencimiento de pagos en línea

Ejecuta después:

`supabase/migrations/010_online_payment_expiration.sql`

Los pedidos de Mercado Pago disponen de 20 minutos para iniciar el pago. Mientras
el cobro no esté aprobado se muestran únicamente en administración, caja y el
historial del cliente; nunca aparecen en cocina. Si el plazo termina sin que
Mercado Pago registre un cobro, la orden se cancela y el cliente debe crear una nueva.

Después de aplicar esta migración vuelve a desplegar las funciones de preferencia
y webhook para enviar el vencimiento a Mercado Pago y rechazar pagos fuera de plazo.

## Servicios externos

### Mapas

La vista de restaurantes usa Leaflet con los mosaicos estándar de OpenStreetMap.
No requiere clave ni cuenta de facturación. Debe conservarse la atribución visible
y respetarse la política de uso de mosaicos de OpenStreetMap. Para un volumen alto,
cambia el proveedor de mosaicos por uno con capacidad y SLA adecuados.

### OneSignal

1. Crea una Web App en OneSignal con el dominio de producción.
2. Coloca el App ID público en `app-config.js` como `oneSignalAppId`.
3. Configura estos secretos en Supabase Functions:

```text
ONESIGNAL_APP_ID
ONESIGNAL_REST_API_KEY
APP_URL=https://serveyourself-app.vercel.app
```

### Mercado Pago

Cada restaurante conecta su propia cuenta mediante OAuth de Mercado Pago Marketplace.
Configura estos secretos en Supabase Functions:

```text
MERCADO_PAGO_CLIENT_ID
MERCADO_PAGO_CLIENT_SECRET
MERCADO_PAGO_REDIRECT_URI=https://spbgledcjwtqmlqdlpyx.supabase.co/functions/v1/mercado-pago-oauth-callback
MERCADO_PAGO_FEE_PERCENT=0
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
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` son proporcionadas automáticamente por Supabase Functions. Nunca coloques Client Secret, tokens OAuth de vendedores, la App API Key de OneSignal o la clave `service_role` en archivos públicos.

## Ejecución local

Sirve la carpeta mediante HTTP; no abras los archivos con `file://`.

```bash
python -m http.server 8080
```

Después abre `http://localhost:8080`.

## Flujo de estados

`pendiente → preparando → listo → entregado`

También se admite el estado `cancelado`. Solo un negocio puede actualizar pedidos dirigidos a su propia cuenta.

## Seguridad

La clave `sb_publishable_...` del frontend es pública por diseño. No deben guardarse claves `service_role`, contraseñas ni secretos de APIs dentro del repositorio. Las operaciones sensibles se protegen con RLS y funciones de PostgreSQL.
