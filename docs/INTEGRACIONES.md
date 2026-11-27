# Integraciones

## Supabase Auth y Google

Sigue la [guía de acceso con Google](AUTH_PROVIDERS.md) para configurar el proveedor, el sitio y las URL de retorno. Registra las URL de retorno específicas de cada entorno. Para la recuperación por correo, incluye `/recuperar.html` entre las redirecciones autorizadas. El enlace de recuperación usa PKCE y se abre en el navegador donde se solicitó.

## Mercado Pago

Cada restaurante conecta su cuenta mediante OAuth. **Pausar pagos en línea** detiene nuevos pedidos por ese método y mantiene la conexión para consultar pagos existentes y tramitar devoluciones.

Configura en **Supabase → Edge Functions → Secrets** `MERCADO_PAGO_CLIENT_ID`, `MERCADO_PAGO_CLIENT_SECRET`, `MERCADO_PAGO_REDIRECT_URI` y `MERCADO_PAGO_WEBHOOK_SECRET`. Si usas `MERCADO_PAGO_FEE_PERCENT`, define explícitamente el porcentaje de la plataforma. Un valor de `0` corresponde a una comisión de plataforma del 0 %. Mercado Pago puede aplicar su propia comisión al vendedor.

- Registra la URL `https://<ref>.supabase.co/functions/v1/mercado-pago-oauth-callback` como retorno OAuth y usa esa misma URL en `MERCADO_PAGO_REDIRECT_URI`.
- Registra `https://<ref>.supabase.co/functions/v1/mercado-pago-webhook` como URL de notificaciones de pago. Guarda la firma secreta de esa configuración en `MERCADO_PAGO_WEBHOOK_SECRET` del mismo entorno. La función valida la firma del proveedor.
- Configura `APP_URL` para el frontend del entorno. Si el entorno tiene alias, usa `APP_ALLOWED_ORIGINS` con los orígenes separados por comas. Consulta `supabase/config.toml` para conservar la política de JWT de cada función.

## OneSignal

Configura `ONESIGNAL_APP_ID` en el build de Vercel y `ONESIGNAL_APP_ID`, `ONESIGNAL_REST_API_KEY` y `APP_URL` en las Edge Functions del mismo entorno. Usa una Web App de OneSignal independiente si vas a probar el envío fuera de producción.

Los eventos se guardan en una cola. Si vas a habilitar envíos, registra la URL de la función del mismo entorno en la configuración privada tras aplicar las migraciones. Ejecuta lo siguiente desde una sesión administradora y sustituye `<ref>` por el proyecto correspondiente.

```sql
insert into sy_private.integration_settings (id, notification_url)
values (true, 'https://<ref>.supabase.co/functions/v1/send-order-notification')
on conflict (id) do update set notification_url = excluded.notification_url;
```

En el entorno Docker local, el endpoint interno admitido es `http://kong:8000/functions/v1/send-order-notification`.

## Mapas

Leaflet muestra los mapas con mosaicos de OpenStreetMap. Conserva la atribución visible del proveedor. La llegada de pickup usa una aproximación geográfica según el transporte, como se describe en [Cocina automática](kitchen-training.md).
