# Inicio de sesión con Google

ServeYourself contiene únicamente el acceso externo con Google. Falta crear las credenciales en Google Cloud y copiarlas a Supabase. Nunca guardes secretos en el repositorio.

## Configuración común en Supabase

En **Authentication → URL Configuration**:

```text
Site URL: https://serveyourself-app.vercel.app
Redirect URL: https://serveyourself-app.vercel.app/index.html
Redirect URL: https://serveyourself-app.vercel.app/registro.html
Redirect URL: https://serveyourself-app.vercel.app/recuperar.html
```

La URL de retorno que debes registrar en Google Cloud es:

```text
https://spbgledcjwtqmlqdlpyx.supabase.co/auth/v1/callback
```

## Google

1. Abre Google Cloud Console y crea o elige un proyecto.
2. En Google Auth Platform configura Branding, Audience y Data Access. Solicita `openid`, `email` y `profile`.
3. Crea un OAuth Client de tipo **Web application**.
4. Agrega `https://serveyourself-app.vercel.app` como origen autorizado.
5. Agrega la URL de retorno de Supabase como redirect URI autorizado.
6. Copia Client ID y Client Secret en **Supabase → Authentication → Providers → Google** y activa el proveedor.

## Comprobación

1. Abre la aplicación en una ventana privada.
2. Prueba primero el registro y luego el inicio de sesión con Google.
3. Confirma que vuelve al dominio de producción, crea el perfil y conserva la sesión al cerrar y abrir la PWA.
4. Si aparece un error de redirect, compara literalmente las URLs: protocolo, dominio, ruta y barra final.

Documentación oficial:

- https://supabase.com/docs/guides/auth/social-login/auth-google
- https://supabase.com/docs/guides/auth/redirect-urls
