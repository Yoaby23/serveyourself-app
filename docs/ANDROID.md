# ServeYourself para Android

El proyecto de Capacitor empaqueta todas las pantallas de ServeYourself y usa el Supabase existente. El identificador de producción es `mx.serveyourself.app`. Conserva el identificador, el origen local configurado y el certificado de firma de cada actualización. Incrementa `versionCode` en `mobile/android/app/build.gradle` en cada publicación y usa un solo contador para los canales de distribución. Así Android conserva la instalación y sus datos locales.

## Publicar en Play y ofrecer un APK directo

1. Crea la aplicación en Google Play Console con el identificador `mx.serveyourself.app`. Usa **Play App Signing** y deja que Play administre la clave de firma si vas a descargar desde ahí los APK para tu web. Genera y guarda una clave de carga separada para entregar los AAB. Conserva la clave y su contraseña fuera de Git y de cualquier archivo distribuido.
2. Carga el AAB firmado con tu clave de carga en la pista de **pruebas internas**. Usa una pista de Play con Play App Signing. **Uso compartido interno de aplicaciones** usa otro certificado y no sirve para instalar la primera versión de producción.
3. En **Explorador de app bundles**, selecciona esa versión y descarga el **APK universal firmado**. Ese APK lleva la clave de firma de la misma aplicación en Play. Publica ese archivo en tu dominio HTTPS para ofrecer descarga directa.
4. Para la siguiente versión, incrementa `versionCode`, repite el proceso y prueba la instalación encima de la anterior. Comprueba el certificado de ambos APK con `apksigner verify --print-certs` y verifica que sobrevivan los datos locales.

## Compilar

Usa Node.js 22 o posterior, Java 21 y Android SDK 36. Ejecuta desde la raíz:

```bash
npm ci
npm ci --prefix mobile
npm run sync --prefix mobile
cd mobile/android
./gradlew :app:bundleRelease
```

El AAB queda en `mobile/android/app/build/outputs/bundle/release/`. Para firmarlo para Play, define las variables `SY_ANDROID_UPLOAD_STORE` (ruta absoluta), `SY_ANDROID_UPLOAD_PASSWORD`, `SY_ANDROID_UPLOAD_ALIAS` y `SY_ANDROID_UPLOAD_KEY_PASSWORD` antes de compilar. Al compilar sin las cuatro variables, el AAB se genera sin firma. En Windows usa `gradlew.bat` en lugar de `./gradlew`.

El flujo **Android** de GitHub verifica dos versiones del paquete aislado `mx.serveyourself.app.qa` en un emulador. Estos APK son para QA. Usa el APK universal con la firma de Play para cualquier instalación que deba actualizarse a producción sin reinstalar.

## Validación de la app móvil

Para el inicio con Google y la recuperación en Android agrega `mx.serveyourself.app://auth/*` a las URL permitidas de Supabase Auth. El retorno contiene un código PKCE que se procesa en la pantalla de origen. Mantén las URL vigentes para la web y Windows.

Antes de publicar comprueba en un teléfono el acceso con cuentas de prueba y el regreso desde Google y Mercado Pago. Verifica también la sincronización, la ubicación cuando se solicite y la impresión con el servicio instalado en el teléfono. Este paquete aún no configura el envío de notificaciones push nativas de Android.
