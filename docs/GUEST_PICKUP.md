# Pedidos para llevar sin cuenta

El propietario activa **Pedidos para llevar sin cuenta** en Configuración del restaurante. Debe habilitar efectivo o Mercado Pago (este último requiere cuenta conectada). La opción está apagada por defecto; las preferencias existentes no se reinician. El menú público muestra únicamente las formas de pago habilitadas y sigue siendo consultable aunque no se permita pedir.

## Flujo del cliente

1. Agrega productos en `menu-publico.html?id=RESTAURANTE`, indica su nombre y elige forma de pago. No se crea un usuario ni un perfil ficticio.
2. El navegador guarda una clave aleatoria de 256 bits antes de solicitar el pedido. El servidor almacena su hash, comprueba horario, disponibilidad y cantidades, y calcula el total desde los precios de la base de datos. El pedido comienza pendiente, con `payment_before_kitchen=true`.
3. **Efectivo:** permanece en la pantalla del pedido con la indicación de pasar a caja. No abre Mercado Pago y no crea ninguna comanda todavía. El cajero encuentra el pedido por número/nombre en las cuentas pendientes, registra el importe completo y el efectivo recibido. El sistema calcula cambio, registra el pago en el turno abierto y crea una sola comanda. Se utiliza el mismo RPC y formulario de cobro; el invitado no puede cambiar su estado de pago.
4. **Mercado Pago:** el servicio de preferencias verifica la sesión del cliente o el acceso privado del invitado. El webhook comprueba firma, referencia, importe y moneda antes de aprobar y generar la comanda. `payment=success` en la URL no confirma el pago.
5. El cliente consulta el estado con sondeo o actualización manual. Puede copiar su acceso privado, válido por siete días. Los recibos se conservan en el navegador por número de pedido, evitando confundir el regreso de un pago anterior con el carrito más reciente.

El pago en línea vence en 20 minutos; el efectivo no utiliza ese vencimiento. Desactivar la opción impide solicitudes nuevas, pero no borra las existentes. Los pedidos de efectivo ya aceptados se pueden cobrar aunque después se desactive ese método. Un cambio de disponibilidad no descarta automáticamente pedidos ya aceptados.

## Corte de caja

**Cerrar turno** cancela automáticamente los pedidos para llevar sin ningún pago registrado, anteriores al inicio del cierre, de ese restaurante: solicitudes del menú público (efectivo/Mercado Pago), otros pedidos web sin pagar y cuentas POS para llevar sin abonos. Desaparecen de los pendientes y sus comandas, si existían, quedan canceladas.

No se borran físicamente: se conserva la orden y un evento de auditoría vinculado al turno. El acceso privado muestra «Pedido cancelado». **Corte previo / imprimir** no cancela nada. Un nuevo intento de cierre sobre un turno cerrado no vuelve a cancelar pedidos.

Los pedidos pagados o a crédito se conservan. Las cuentas POS con abonos pendientes o mesas abiertas bloquean el cierre hasta liquidarse o resolverse. Un cierre fallido revierte todas las cancelaciones de esa operación. El efectivo cobrado a invitados se incluye en ventas, efectivo esperado y diferencia del turno.

Si Mercado Pago confirma un pago después de que el corte canceló su pedido, la conciliación transaccional devuelve `refund_required`. El webhook tramita el reembolso idempotente existente, incluso si había leído el pedido antes del corte. No lo reactiva ni lo manda a cocina. Si falla el proveedor, devuelve error para permitir reintentar; no se anuncia un reembolso completado sin confirmación.

## Seguridad y recuperación

- `guest_checkout_requests` tiene RLS y ninguna concesión a anon/authenticated. Las dos firmas de creación son exclusivas de service_role; la firma antigua delega en la nueva con Mercado Pago para clientes almacenados en caché.
- El token se guarda como hash en servidor y se comparte mediante fragmento URL, no como query ni con el proveedor. Es una credencial: permite consultar y retomar únicamente ese pedido; no debe compartirse.
- Precios, pago aprobado y acceso a cocina no se aceptan del navegador. El método elegido se valida contra la configuración. Una repetición con el mismo token y payload reutiliza el pedido; cambiar el método con ese token se rechaza.
- Solo personal autorizado para caja cobra, con turno abierto, efectivo suficiente e importe completo en pedidos invitados. Los dobles envíos no duplican pagos ni comandas.
- Los pedidos sin customer_id no autorizan a extraños a cancelarlos. La cancelación del invitado pendiente está permitida al dueño o caja del restaurante; un pedido ya pagado requiere resolver el reembolso.
- Límites básicos: 10 solicitudes nuevas por huella de dirección en 20 minutos y 100 pendientes por restaurante en esa ventana. La dirección depende del proxy; no constituye una defensa completa contra bots o proxies distribuidos.
- Respuestas Edge sin caché. El endpoint de preferencias autentica internamente por JWT de usuario o acceso privado; no concede acceso por conocer el número del pedido.

## Validación

87 pruebas Node aprobadas, incluidas selección de efectivo, recuperación, tarjetas de caja, bloqueos de corte y reembolso después del cierre. Los handlers del proveedor se prueban con dependencias simuladas.

7 suites SQL con rollback aprobadas: catalog_security, api_security, favorites_single_table, kitchen_priority_inventory, qa_reliability, guest_pickup y guest_cash_and_cut. La última prueba permisos reales, caja cerrada, pago completo/cambio, no duplicación, corte con fuentes mixtas, conservación de abonos/pagados y rechazo de una aprobación tardía que intentaría reactivar un pedido.

No se han realizado cobros reales, reembolsos reales ni una prueba física de entrega de efectivo. Falta la aceptación por rol/dispositivo y la integración completa con una cuenta de prueba de Mercado Pago. Los fixtures de SQL se revierten al finalizar.

### Aviso y entrega en caja

Al quedar lista una comanda para llevar, Caja muestra el número de pedido, nombre de quien recoge y artículos en «Listos para entregar». Consulta las comandas del restaurante con RLS, se actualiza por Realtime y recupera cambios al reconectar, volver a la pantalla o cada 15 segundos. La lista se conserva al fallar una consulta; no depende del permiso de notificaciones.

El aviso push existente también se dirige al dueño y al personal activo con permiso de caja. Abre Caja en la sección de entrega. Requiere suscripción push y permiso del dispositivo; es un canal complementario, no una cola de entrega garantizada. No se notifica a caja mientras falten estaciones por terminar. No se cambió el flujo de reparto ni de mesas.

«Confirmar entrega» pide verificar número y nombre y utiliza la misma operación del POS. La base de datos bloquea la comanda, exige permisos vigentes, rechaza pedidos cancelados y segundas entregas, y registra una sola entrega en la auditoría. La actualización se refleja en las demás cajas. Los pedidos web en efectivo siguen entrando a cocina únicamente después del cobro.

Validación: pruebas automatizadas de restauración y errores de la lista, doble clic, reintentos, destinatarios push y permisos; prueba SQL con pedido invitado, cobro, cocina, caja y entrega repetida dentro de una transacción revertida. La recepción push en un dispositivo físico requiere una prueba operativa con notificaciones habilitadas.

### Organización de Caja y pedidos de mostrador

Caja separa Para llevar, Cuentas de mesa, Pagos en línea, Crédito y Turno y movimientos. Para llevar contiene las cuentas por cobrar, pedidos pagados en cocina y comandas listas con confirmación de entrega. El aviso de pedidos listos permanece accesible desde cualquier sección. Las acciones secundarias de cada cuenta están agrupadas bajo Administrar cuenta.

Nuevo pedido para llevar abre el catálogo existente del POS en modo Caja, solicita el nombre y vuelve a Caja al terminar. Se reutilizan las operaciones de pedidos y entrega: no hay un segundo catálogo ni una segunda implementación del carrito. El permiso de caja autoriza únicamente pedidos pickup; no concede acceso de creación de cuentas de mesa. Se mantiene el requisito de turno abierto, productos disponibles y precios calculados en servidor. Los pedidos de mostrador conservan el flujo POS (se envían a cocina y quedan pendientes de cobro); los pedidos web en efectivo siguen esperando el pago antes de entrar a cocina.

Pruebas: clasificación sin duplicar cuentas, navegación por sección y enlace de aviso, regreso desde POS, permisos de caja, turno cerrado, nombre obligatorio, cobro, entrega, rechazo de entrega repetida y personal desactivado.

Validación visual adicional: Chromium con datos simulados, escritorio 1440 px y móvil 390 px; se comprobó cambio de secciones, enlace a listos, confirmación de entrega, ausencia de desbordamiento horizontal y registro desde caja con regreso a la sección Para llevar. Las operaciones reales se verificaron por separado con pruebas SQL revertidas.
