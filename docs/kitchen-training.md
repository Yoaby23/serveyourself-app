# Entrenamiento de tiempos de cocina

En Cocina, **Entrenar tiempos** permite registrar una preparación medida, seleccionar servicio y productos con cantidades, e indicar duración real y si ocurrió en hora pico. **Guardar y entrenar** registra la medición y recalcula el modelo; no crea un pedido ni afecta caja. Las comandas reales siguen alimentando el mismo entrenamiento al pasar de Preparando a Listo.

**Probar estimación** usa los productos, cantidades, servicio y horario seleccionados sin guardar muestras. Muestra si se usó el modelo o el tiempo configurado y explica el motivo. **Reentrenar servicio** vuelve a procesar sus últimas 500 mediciones. El historial permite eliminar únicamente mediciones manuales incorrectas y recalcula el modelo.

Cada servicio tiene su modelo. Requiere al menos 10 mediciones, reserva el 20 % más reciente (mínimo 2) para validación y acepta un error medio de hasta el mayor entre 5 minutos y 35 % del tiempo observado. Para aplicar una estimación requiere al menos 3 muestras del horario seleccionado, productos conocidos y una cantidad dentro del rango observado. Hasta entonces se conserva el tiempo configurado. El modelo actual aprende efectos del volumen y la hora pico; no calcula tiempos individuales por receta o estación.

Registra ejemplos reales y variados. No repitas mediciones inventadas para completar el mínimo. Hora pico: 13:00–16:59 y 19:00–22:59 de la zona horaria del negocio. Las comandas pendientes usan el modelo validado al actualizarse la cola; una comanda ya en preparación conserva la predicción que tenía al comenzar.

## Seguridad y publicación

Se usa el permiso existente de operar cocina. Las operaciones verifican usuario y negocio en el servidor; los productos se validan contra el menú del negocio. El navegador no puede modificar coeficientes ni escribir directamente en muestras/modelos. Los reintentos de guardado tienen UUID para no duplicar una medición; las escrituras y reentrenamientos se serializan por negocio y servicio.

Antes de publicar el frontend debe aplicarse `supabase/migrations/20261110181450_manual_kitchen_training.sql`. La migración amplía las muestras con su contenido y admite mediciones manuales sin comanda. Conserva las observaciones existentes.

Validación automática de interfaz: `node --test tests/*.test.mjs`. La prueba de base de datos `supabase/tests/manual_kitchen_training.sql` debe ejecutarse dentro de `BEGIN; ... ROLLBACK;`: crea datos aislados, verifica aprendizaje y aplicación a la cola real, aislamiento de negocios, idempotencia, validación y aprendizaje automático. No se deben conservar los datos sintéticos.

## Aprendizaje automático y preparación conjunta

No hace falta abrir el panel ni pulsar Reentrenar: cada transición de Comenzar a Listo registra una medición y recalcula el modelo del servicio. Esto también ocurre al trabajar por estaciones, cuando la última estación queda lista. Los pedidos sin un inicio medido, cancelados o con duración fuera de 1–240 minutos no se utilizan. Nunca se sustituye el inicio por la fecha de creación: eso confundiría espera con preparación.

La cola agrupa automáticamente de dos a cinco comandas consecutivas que comparten al menos un producto en la misma estación, el mismo estado y la misma prioridad. Sus horas previstas de inicio y entrega deben caber en una ventana de cinco minutos; no se adelantan recogidas cuyo inicio aún queda lejos. No cruza otras comandas de la cola, no agrupa trabajo pospuesto ni preparaciones con notas o modificaciones especiales.

Cada grupo muestra el total del producto compartido y las cantidades por comanda. Comenzar juntas inicia todas las comandas del grupo en una sola transacción; el servidor vuelve a comprobar que la cola y las condiciones sigan siendo compatibles. Los números de cuenta, pagos, cantidades, entrega y notificaciones de cada pedido siguen separados. Cada comanda se marca Lista individualmente. Agrupar no aplica una reducción ficticia al tiempo estimado: el modelo seguirá aprendiendo de las duraciones realmente observadas.
