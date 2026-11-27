# ServeYourself para Windows

El instalador x64 incluye las pantallas del mismo repositorio, con los recursos web empaquetados en un programa de escritorio. Las cuentas, los permisos, los pedidos, Realtime, los cobros y las devoluciones usan los servicios existentes. Para operar con datos actualizados requiere internet.

## Instalación de prueba

1. En GitHub, abre **Actions → Instalador de Windows** y descarga el artefacto `ServeYourself-Windows-x64` de la ejecución correspondiente.
2. Extrae el `.exe` del archivo ZIP y ejecútalo. Abre **ServeYourself** desde Inicio o el acceso directo.
3. Entra con una cuenta del restaurante. Comprueba POS, Caja, Cocina, administración, reportes y reparto con los permisos correspondientes. Abre la misma organización en un navegador y verifica que los cambios aparezcan en ambos.
4. Para validar impresoras, imprime un ticket en Caja y comprueba su formato en el modelo de impresora que usará el restaurante. Los enlaces externos y pagos que redirigen al proveedor se abren en el navegador predeterminado.

La compilación de prueba se genera sin certificado de firma. Firma el instalador antes de distribuirlo ampliamente.

## Inicio de sesión con Google y contraseña olvidada

En **Supabase → Authentication → URL Configuration → Redirect URLs**, agrega `http://127.0.0.1:47853/serveyourself/*` a las URL permitidas. Conserva las entradas vigentes de la versión web. El programa abre Google en el navegador predeterminado y recibe el código en el equipo mediante una ruta de un solo uso con PKCE. Para restablecer la contraseña, solicita el correo desde el programa y déjalo abierto mientras usas el enlace en esa misma PC.

## Compilación en Windows

Desde la raíz del repositorio, con Node.js 22 o posterior:

```powershell
npm ci
npm ci --prefix desktop
npm run package:windows --prefix desktop
```

El `.exe` queda en `desktop/out/`. La compilación obtiene la configuración pública del Supabase de producción y verifica el origen antes de empaquetar. Mantén los secretos de los servicios fuera del instalador. El instalador de escritorio y el sitio de Vercel se publican de manera independiente.
