# Pedidos para llevar sin cuenta

El propietario activa **Pedidos para llevar sin cuenta** en Configuración del restaurante, junto a Mercado Pago. La opción está apagada por defecto. Se requieren Mercado Pago conectado, pagos en línea activos, restaurante aceptando pedidos y horario abierto. El menú público/QR conserva su consulta sin cuenta aunque esta opción esté desactivada.

## Flujo

1. El visitante agrega productos en `menu-publico.html?id=RESTAURANTE`, indica nombre para recoger y continúa al pago. No se crea un usuario de Auth ni un perfil ficticio.
2. El navegador guarda una clave aleatoria de 256 bits antes de solicitar el pedido. El servidor almacena solo su hash, valida disponibilidad/cantidades y calcula el total desde los precios de la base de datos. El pedido es exclusivamente online/pickup/Mercado Pago, inicialmente pendiente.
3. El servicio de preferencias existente comprueba la sesión del cliente autenticado o la clave privada del pedido invitado. Reutiliza preferencias existentes y la clave de idempotencia por pedido. Los pedidos autenticados y de delivery mantienen su flujo.
4. El webhook existente verifica la firma y consulta el pago con Mercado Pago. La referencia, importe y moneda deben corresponder al pedido. Solo al aprobarlo aparece una comanda en cocina. Una URL de regreso que diga `payment=success` no confirma nada por sí misma.
5. La pantalla pública muestra el estado con sondeo y actualización manual. El acceso privado dura siete días, puede copiarse y utiliza el fragmento URL (no se envía como query ni al proveedor). El navegador conserva también recibos por número de pedido para regresar a pagos anteriores sin confundirlos con el último carrito.

El pago pendiente vence en 20 minutos. Desactivar la opción impide pedidos nuevos; no invalida pedidos ya iniciados ni accesos de seguimiento. El cierre/stock se valida al crear el pedido; no se descarta un pedido ya aceptado porque el producto se marque agotado después. Mercado Pago puede pedir datos propios para procesar el pago, aunque ServeYourself no exija registro.

## Seguridad y recuperación

- `guest_checkout_requests` tiene RLS y ninguna concesión a anon/authenticated. La función SQL de creación solo es ejecutable por service_role. La vista pública conserva únicamente SELECT para clientes.
- Los servicios Edge públicos validan el cuerpo y la clave; cambiar únicamente orderId no autoriza acceso. No se exponen correo, credenciales del comercio ni datos de otros compradores.
- El mismo token y payload reutiliza el pedido. Otro payload con el mismo token se rechaza. Se bloquea el doble toque en la interfaz y una respuesta ambigua permite reintentar la misma solicitud.
- Hay límites transaccionales: 10 pedidos nuevos por huella de dirección en 20 minutos y 100 pagos pendientes por restaurante en esa ventana. La dirección depende del encabezado proporcionado por el proxy; esto es un límite básico, no una protección completa contra bots, proxies distribuidos o abuso. Los reintentos idempotentes no consumen nuevas solicitudes.
- Las respuestas no se almacenan en caché. El acceso privado es una credencial: quien lo tenga puede ver el nombre, contenido, total y estado de ese pedido y retomar su pago pendiente. No debe compartirse.
- El endpoint de preferencias valida internamente usuario JWT o acceso invitado; por eso verify_jwt del gateway está desactivado. El resto de funciones conserva su configuración.

## Validación

75 pruebas Node aprobadas: incluyen 12 pruebas del acceso/pago y 6 del menú invitado. Se ejecutan handlers reales con dependencias del proveedor simuladas; no son cobros reales.

6 suites SQL con rollback aprobadas: permisos del catálogo/API, favoritos/cuenta compartida, cocina, fiabilidad de pagos y guest_pickup. Esta última comprueba opción apagada, falta de pago online, nombre vacío, cantidad cero, agotados, precio manipulado, idempotencia, aislamiento, límite de solicitudes y una sola comanda después de confirmación válida simulada.

No se ha realizado un cobro real ni un recorrido de extremo a extremo con una cuenta de pruebas de Mercado Pago. Esa aceptación requiere un comercio conectado y un pago de prueba; no se inventa una confirmación del proveedor. La opción queda apagada para todos los comercios existentes hasta que el propietario la active.
