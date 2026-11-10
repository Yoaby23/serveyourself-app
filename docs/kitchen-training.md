# Cocina automática

La cocina viene preconfigurada en automático. El único interruptor **Entrenamiento** permite cambiar temporalmente a calibración, sin abrir formularios ni registrar ejemplos manualmente. Activado, usa los tiempos configurados y recopila duraciones reales. Al desactivarlo aplica los modelos validados y vuelve a agrupar comandas compatibles. El ajuste se guarda por restaurante y se sincroniza entre sus dispositivos.

Cada comanda con un inicio medido alimenta el modelo al marcarse Lista, también cuando la última estación termina. No incluye espera en cola, pedidos cancelados ni duraciones fuera de 1–240 minutos. El aprendizaje continúa en automático. No se crean datos ficticios para preentrenar.

El modelo de cada servicio requiere 10 mediciones y una validación temporal del error antes de usarse. También exige productos conocidos, cantidades dentro del rango observado y 3 muestras del horario correspondiente. Si aún no hay datos suficientes, se usan los tiempos configurados. Las comandas ya en preparación conservan la predicción capturada al comenzar.

La agrupación automática conserva el orden de prioridad. Reúne de 2 a 5 comandas consecutivas con un producto común de la misma estación, el mismo estado y prioridad, y horas de inicio/entrega dentro de cinco minutos. Excluye notas, modificaciones especiales y trabajo pospuesto. Muestra cantidades por comanda, permite Comenzar juntas y mantiene cuentas, pagos, notificaciones y finalización separados.

# Llegada de pickup

En Mis pedidos, un cliente con pickup programado y pagado puede pulsar **Voy en camino**, elegir auto, bicicleta o caminando y compartir su posición mientras la app está abierta. Puede detener la ubicación desde el mismo botón. No se solicita ubicación por el simple hecho de abrir el historial y no se vuelve a abrir un permiso nativo automáticamente al restaurar la sesión.

El servidor calcula una llegada aproximada con distancia geográfica, un factor de recorrido, velocidad orientativa por transporte y un margen de llegada. No incluye tráfico ni rutas reales y no promete un minuto exacto. Cocina resta el tiempo de preparación aprendido (o configurado) a la llegada estimada para recomendar cuándo empezar. El sistema no marca ni empieza a cocinar por sí solo: el equipo conserva el control de Comenzar y Listo.

Solo usa posiciones con precisión de hasta 100 metros y fechas recientes; deja de usar la estimación si la última posición tiene más de tres minutos. Entonces recupera el horario programado. Al detener la ubicación o entregar/cancelar el pedido borra las coordenadas y la llegada guardadas. Las coordenadas no se incluyen en la cola de cocina; esta solo recibe la hora y explicación de llegada.

# Verificación

Ejecutar `node --test --test-concurrency=4 tests/*.test.mjs`. Las pruebas de base de datos de cocina y pickup se ejecutan con datos aislados dentro de BEGIN/ROLLBACK. No se deben conservar fixtures. Las migraciones de modo de cocina y llegada de pickup deben aplicarse antes de publicar el frontend.
