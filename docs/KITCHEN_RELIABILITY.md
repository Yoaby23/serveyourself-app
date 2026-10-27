# Kitchen and manual availability

Product availability uses only products.is_available. Products start available and remain
available until an authorized restaurant user marks them out of stock. No quantities,
recipes, ingredient requirements or automatic inventory deductions are used.

New POS and customer orders validate current product availability on the server.
Already accepted kitchen tickets continue even if a product is subsequently unavailable.
Kitchen stations, strict manual priority, target ready time and historical preparation
estimates remain active. Station assignment is managed from Funciones → Estaciones.

The removal migration drops ingredient/recipe/movement tables and their functions and
triggers. Historical migrations are retained for reproducible database upgrades.
Legacy inventory_available (always true) and inventory_deducted columns remain only for
compatibility with cached clients and old financial split records; no active stock logic
uses them. The old inventario.html URL now contains only station configuration.

Validation: kitchen_priority_inventory.sql tests manual availability, rejected new orders,
continued preparation, reactivation, priority and unauthorized modification, with rollback.
