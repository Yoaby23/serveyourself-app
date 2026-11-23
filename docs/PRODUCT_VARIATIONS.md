# Variaciones de productos

En Productos, al agregar o editar un producto, usa **Agregar variación** para registrar opciones como Chico, Grande, Frío o Caliente. Cada opción requiere nombre único, precio final y disponibilidad. Se pueden configurar hasta 50 opciones; para combinaciones se usan nombres completos, por ejemplo «Grande · Frío».

Al tener variaciones se oculta el precio general: se muestra el precio desde la opción disponible más económica. Todas las opciones comparten fotografía, categoría y estación de cocina del producto. Si no hay variaciones, se conserva el flujo habitual con un solo precio.

Cliente, menú QR, meseros y caja seleccionan una opción antes de agregar el producto. El carrito y las comandas muestran el producto y su variación. Cada presentación usa un ID vendible propio para conservar la separación de cantidades, precios, división de cuentas y aprendizaje de cocina. El servidor calcula el importe; rechaza opciones no disponibles, productos principales sin selección y variaciones de otros negocios.

Desactivar el producto bloquea todas sus variaciones sin alterar la disponibilidad individual de cada una. Retirar una variación o eliminar un producto desde el administrador lo archiva; conserva sus IDs y los datos de pedidos pendientes e históricos. Los pedidos guardan el nombre y precio seleccionados aunque después cambie el catálogo.

El guardado del producto y sus opciones es atómico y reutiliza los IDs en reintentos. Los permisos de edición continúan restringidos al propietario del negocio.

Validación del 23 de noviembre de 2026: 243 pruebas de JavaScript y 24 suites de base de datos aprobadas. Las pruebas SQL usan usuarios temporales y transacciones revertidas; no realizan cargos reales.
