# ServeYourself para Android

El proyecto de Capacitor empaqueta todas las pantallas de ServeYourself y usa el Supabase existente. El identificador de producción es `mx.serveyourself.app`. Conserva el identificador, el origen local configurado y el certificado de firma de cada actualización. Incrementa `versionCode` en `mobile/android/app/build.gradle` en cada publicación y usa un solo contador para los canales de distribución. Así Android conserva la instalación y sus datos locales.

## Distribuir el APK desde la web

1. Si es tu primera publicación, crea un almacén de claves para ServeYourself en Android Studio. Guarda el archivo y una copia cifrada fuera del repositorio. Guarda la contraseña por separado. Usa esa misma clave para todas las versiones públicas.
2. Genera un **APK de release firmado** con el identificador `mx.serveyourself.app`. Antes de distribuirlo, comprueba su firma con `apksigner verify --print-certs` y conserva la huella SHA-256 del certificado.
3. Publica ese APK en un enlace HTTPS, por ejemplo en la web de ServeYourself. Cada usuario abre el archivo en Android y confirma la instalación. El sistema puede pedir autorización a la aplicación desde la que se abrió la descarga.
4. En la siguiente publicación, sube `versionCode`, firma con la misma clave y coteja la huella SHA-256 con la anterior. Instala la actualización encima de la versión anterior en un teléfono de prueba y comprueba que conserva los datos locales. El usuario abre el nuevo APK y confirma **Actualizar**.

La descarga directa prescinde de la inscripción en Google Play Console. Google anunció una ampliación gradual de la verificación de desarrolladores a instalaciones externas en dispositivos certificados durante 2027. Consulta los [requisitos vigentes de distribución externa](https://developer.android.com/developer-verification) antes de ampliar la publicación.

## Generar el APK firmado

Usa Node.js 22 o posterior, Java 21 y Android SDK 36. Desde la raíz sincroniza la app:

```bash
npm ci
npm ci --prefix mobile
npm run sync --prefix mobile
```

Abre `mobile/android` en Android Studio. En **Build → Generate Signed Bundle / APK** elige **APK**, el módulo `app` y la variante `release`. En la primera compilación selecciona **Create new** para crear el almacén. En las siguientes selecciona ese mismo archivo y alias. El asistente indica la ruta del APK al terminar.

Para un build por comando, define `SY_ANDROID_UPLOAD_STORE` con la ruta absoluta al almacén de firma y las variables `SY_ANDROID_UPLOAD_PASSWORD`, `SY_ANDROID_UPLOAD_ALIAS` y `SY_ANDROID_UPLOAD_KEY_PASSWORD` fuera de Git. Después ejecuta dentro de `mobile/android`:

```bash
./gradlew :app:assembleRelease
apksigner verify --print-certs app/build/outputs/apk/release/app-release.apk
```

En Windows usa `gradlew.bat`. `apksigner` viene con Android SDK Build Tools. Con las cuatro variables presentes, Gradle firma el APK de release. Los APK de **Android QA** en GitHub usan un identificador distinto y están destinados a pruebas.

## Validación de la app móvil

Para el inicio con Google y la recuperación en Android agrega `mx.serveyourself.app://auth/*` a las URL permitidas de Supabase Auth. El retorno contiene un código PKCE que se procesa en la pantalla de origen. Mantén las URL vigentes para la web y Windows.

Antes de publicar comprueba en un teléfono el acceso con cuentas de prueba y el regreso desde Google y Mercado Pago. Verifica también la sincronización, la ubicación cuando se solicite y la impresión con el servicio instalado en el teléfono. Este paquete aún no configura el envío de notificaciones push nativas de Android.

## Avisos de actualización

Desde la versión `0.2.0`, la app avisa cuando hay una versión disponible. También puedes pulsar **Buscar actualizaciones** en Cuenta. Guarda los cambios del turno antes de ejecutar el instalador de la nueva versión.

Actualiza `native-releases.json` en `main` después de comprobar que el archivo de esa versión ya se descarga desde GitHub Releases. La portada usa ese registro para ofrecer la misma versión.
