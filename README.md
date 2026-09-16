# ServeYourself

Aplicación web para consultar restaurantes, ordenar comida para recoger y administrar pedidos en tiempo real.

## Funciones actuales

- Registro e inicio de sesión con Supabase Auth.
- Cuentas de cliente y de negocio.
- Buscador de restaurantes y productos.
- Menús, carrito e historial de pedidos.
- Panel para administrar productos y avanzar el estado de cada pedido.
- Actualizaciones de pedidos con Supabase Realtime.

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

Configura estos secretos en Supabase Functions:

```text
MERCADO_PAGO_ACCESS_TOKEN
APP_URL=https://serveyourself-app.vercel.app
```

Despliega las funciones:

```bash
supabase functions deploy create-mercado-pago-preference
supabase functions deploy send-order-notification
supabase functions deploy mercado-pago-webhook --no-verify-jwt
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` son proporcionadas automáticamente por Supabase Functions. Nunca coloques el Access Token de Mercado Pago, la REST API Key de OneSignal o la clave `service_role` en archivos públicos.

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
