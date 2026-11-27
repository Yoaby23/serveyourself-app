# Publicación y operación

## Publicación

`main` es la rama de producción. Cada cambio entra por pull request y debe aprobar **JavaScript** y **PostgreSQL** del flujo **Calidad**. La protección de la rama bloquea el borrado y los force pushes. Vercel ejecuta `npm run build` y sirve `dist/`.

1. Si el cambio incluye migraciones, revisa `supabase migration list --linked` y `supabase db push --dry-run` contra el proyecto de destino. Aplica únicamente las migraciones pendientes de esa publicación. Conserva los archivos de `supabase/migrations/` para reconstruir la base en orden.
2. Si el cambio incluye Edge Functions, despliega las funciones afectadas después de sus migraciones y revisa la configuración `verify_jwt` en `supabase/config.toml`. Una modificación en `_shared/` puede requerir desplegar varias funciones.
3. Publica el frontend tras comprobar que el backend ya admite esa versión. Si una migración rompe la compatibilidad con clientes anteriores, coordina su publicación en etapas y valida ambas versiones según corresponda.
4. Confirma que Vercel muestra el commit publicado y ejecuta `node scripts/check-production.mjs`. El control comprueba portada, SDK y catálogo sin crear pedidos.

En Vercel, configura `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY` por entorno y expón la variable de sistema `VERCEL_ENV`. El build también admite `NEXT_PUBLIC_SUPABASE_URL` y `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`. Preview requiere un Supabase aislado. Si no existe ese entorno, verifica localmente y mediante los controles de **Calidad**. Usa credenciales propias de cada entorno para Mercado Pago y OneSignal.

Si falla el frontend después de publicarlo, restaura el despliegue estable en Vercel y ejecuta de nuevo el control de producción. Antes de restaurarlo, revisa que siga siendo compatible con la base y las funciones desplegadas.

## Validación de un turno

1. Abre un turno de Caja y usa otro equipo para Cocina. Registra una mesa en POS, imprime la comanda y verifica el folio, la mesa, los productos y sus variantes. Envía una segunda ronda y comprueba que Cocina muestra dos comandas y Caja mantiene una cuenta.
2. Escanea el QR en otro dispositivo y recorre un pedido para recoger. Comprueba que los pedidos que requieren confirmación de pago solo llegan a Cocina después de confirmarlo. Prueba Mercado Pago con credenciales de prueba en un entorno aislado.
3. Mezcla comandas de salón y pickup para verificar el orden automático, los tiempos límite y el comportamiento sin historial suficiente. Desconecta Cocina, registra un pedido desde Caja y vuelve a conectarla. El folio debe aparecer una sola vez y el indicador debe recuperar la sincronización.
4. Revisa **Pagos en línea → Historial de Mercado Pago**. Busca por folio o fecha y comprueba el registro separado de pago y reembolso. El detalle conserva comisión, IVA cuando el proveedor lo separa, neto y fecha de disponibilidad. Los campos ausentes aparecen como **Sin dato**. Para pagos históricos todavía aprobados, usa **Consultar detalle en Mercado Pago** cuando esté disponible.
5. Cierra las cuentas y el turno. Compara el corte con los movimientos y guarda los folios y resultados de la prueba. Confirma impresión física, alertas push y acceso por rol en los dispositivos del turno.

## Alertas y seguridad

**Salud de producción** comprueba el sitio público y abre o actualiza una incidencia asignada al dueño del repositorio si detecta un fallo. El ejercicio manual **Enviar una alerta de prueba al dueño del repositorio** crea una incidencia aparte. Úsalo al validar la entrega de alertas y cierra la incidencia cuando el destinatario confirme la recepción.

Las claves públicas de Supabase se inyectan en el frontend. Conserva `service_role`, tokens OAuth, firmas de webhook, claves privadas y contraseñas en los gestores de secretos correspondientes. Las tablas privadas y las operaciones por rol se validan en `supabase/tests/`. Las vistas públicas del catálogo tienen proyecciones limitadas. Los datos de transferencia se consultan mediante los flujos autorizados del pedido.

## Copias y recuperación

Una copia privada de GitHub permite recuperar el código, las migraciones y el historial Git. Verifica el commit de `main` y las ramas y etiquetas esperadas. Mantén GitHub Actions desactivado en la copia para evitar automatizaciones duplicadas. Los datos de Supabase, Storage, los secretos y la configuración de los servicios se gestionan por separado. La importación Git tampoco incluye incidencias, pull requests ni ajustes del repositorio.

### Exportación cifrada de PostgreSQL con Supabase Free

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
