# ServeYourself

Suite web para restaurantes con menú público por QR, pedidos en mesa, para recoger y a domicilio. El equipo opera con POS, Caja, Cocina y despacho. Los dueños administran catálogo, horarios, personal con permisos y reportes.

[Aplicación](https://serveyourself-app.vercel.app/)

## Componentes

| Ruta | Contenido |
| --- | --- |
| `*.html`, `*.js`, `*.css` | Frontend estático, con Tailwind compilado. `sw.js` y `manifest.webmanifest` permiten instalarlo como PWA. |
| `supabase/migrations/` | Historial completo de PostgreSQL, permisos y políticas RLS. |
| `supabase/functions/` | Edge Functions de pedidos públicos, Mercado Pago y notificaciones. |
| `tests/`, `supabase/tests/` | Pruebas de flujos, permisos y regresiones en JavaScript y PostgreSQL. |
| `scripts/`, `.github/workflows/` | Compilación, validación, exportación cifrada y automatización de GitHub. |

Supabase aloja Auth, PostgreSQL, Storage y Realtime. Vercel publica el frontend. En local, Preview y producción se configuran por separado las integraciones externas.

## Desarrollo local

Instala Node.js 22, Docker y la CLI de Supabase. Usa los valores del Supabase **local** que devuelve `supabase status` para compilar.

```bash
npm ci
supabase start
supabase status
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_PUBLISHABLE_KEY='CLAVE_PUBLICA_LOCAL' npm run build
python3 -m http.server 8080 --bind 127.0.0.1 --directory dist
```

Abre `http://127.0.0.1:8080`. Para servir las Edge Functions usa `supabase functions serve --env-file /ruta/local/functions.env` con `APP_URL=http://127.0.0.1:8080`. El buzón indicado por `supabase status` recibe los correos locales de Auth.

```bash
npm test
bash scripts/test-database.sh
```

El script SQL usa el PostgreSQL local de Supabase por defecto y revierte los datos de prueba. Usa una base local o desechable para esta suite. Si cambias las clases de Tailwind, regenera la hoja compilada con el comando siguiente.

```bash
npx tailwindcss@3.4.17 -i tailwind-source.css -o tailwind.generated.css --minify --content './*.html' './*.js'
```

## Flujos de operación

- **POS y Caja.** Las rondas de una mesa comparten una cuenta y generan comandas independientes. Caja controla turnos, cuentas divididas, cobros manuales, devoluciones y conciliación.
- **Cocina.** Las comandas se reordenan automáticamente. El modelo aprende de tiempos reales de preparación y usa tiempos configurados cuando faltan mediciones adecuadas. Consulta [Cocina automática y llegada del cliente](docs/kitchen-training.md).
- **Pedidos para recoger.** Los clientes pueden pedir con cuenta o desde el menú público. Los pedidos con pago pendiente siguen el flujo de confirmación de [pedidos sin cuenta](docs/GUEST_PICKUP.md). Los pagos en línea sujetos a vencimiento tienen un plazo de cinco minutos.
- **Delivery.** El negocio define cobertura y despacho. El repartidor usa su propia vista y cierra la entrega con el código del pedido.
- **Catálogo.** El restaurante administra [variantes](docs/PRODUCT_VARIATIONS.md), disponibilidad por producto y estaciones.

## Configuración y publicación

- [Instalador de ServeYourself para Windows](docs/WINDOWS.md).
- [Android y actualizaciones sin reinstalar](docs/ANDROID.md).
- [Integraciones con Supabase, Google, Mercado Pago y OneSignal](docs/INTEGRACIONES.md).
- [Publicación, validación del turno, alertas y recuperación](docs/OPERACION.md).
