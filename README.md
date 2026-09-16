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
