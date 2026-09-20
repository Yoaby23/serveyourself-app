# Inicio de sesión con Google, Facebook y Apple

ServeYourself ya contiene los botones y el flujo OAuth. Falta crear las credenciales en cada proveedor y copiarlas a Supabase. Nunca guardes secretos en el repositorio.

## Configuración común en Supabase

En **Authentication → URL Configuration**:

```text
Site URL: https://serveyourself-app.vercel.app
Redirect URL: https://serveyourself-app.vercel.app/index.html
Redirect URL: https://serveyourself-app.vercel.app/registro.html
Redirect URL: https://serveyourself-app.vercel.app/recuperar.html
```

La URL de retorno que debes registrar en las tres plataformas es:

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

## Facebook

1. Crea una app en Meta for Developers y agrega el producto **Facebook Login**.
2. En Facebook Login agrega la URL de retorno de Supabase a **Valid OAuth Redirect URIs**.
3. Configura el dominio `serveyourself-app.vercel.app`, correo de contacto y las URLs públicas que Meta solicite.
4. Copia App ID y App Secret en **Supabase → Authentication → Providers → Facebook**.
5. Cuando termines las validaciones, cambia la app de Meta a modo Live para aceptar usuarios que no sean testers.

## Apple ID

Apple requiere una membresía activa de Apple Developer.

1. Crea un App ID y habilita **Sign in with Apple**.
2. Crea un **Services ID**; ese identificador es el Client ID web.
3. Configura como dominio `spbgledcjwtqmlqdlpyx.supabase.co` y como Return URL la URL de retorno de Supabase.
4. Crea una clave privada con Sign in with Apple y conserva su archivo `.p8`, Key ID y Team ID fuera del repositorio.
5. En **Supabase → Authentication → Providers → Apple** agrega Services ID, Team ID, Key ID y la clave requerida por el panel.
6. Rota el secreto web cada seis meses; Apple exige esta renovación para OAuth web.

## Comprobación

1. Abre la aplicación en una ventana privada.
2. Prueba primero el registro y luego el inicio de sesión con cada proveedor.
3. Confirma que vuelve al dominio de producción, crea el perfil y conserva la sesión al cerrar y abrir la PWA.
4. Si aparece un error de redirect, compara literalmente las URLs: protocolo, dominio, ruta y barra final.

Documentación oficial:

- https://supabase.com/docs/guides/auth/social-login/auth-google
- https://supabase.com/docs/guides/auth/social-login/auth-facebook
- https://supabase.com/docs/guides/auth/social-login/auth-apple
- https://supabase.com/docs/guides/auth/redirect-urls
