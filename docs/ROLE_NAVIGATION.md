# Role navigation without dropdowns

Customer navigation keeps Inicio, Favoritos and Cuenta. Profile identity, installation,
notifications, work-mode links, personal orders and sign-out are visible inside Cuenta.
Restaurant detail, order tracking and related authenticated customer flows have the same
three destinations through the shared renderer. Query destinations restore the requested
customer section after authentication/profile initialization.

Restaurant navigation is shared by owner, waiter, kitchen, cashier and manager. It has
Inicio, up to two permitted operational shortcuts, Funciones and Cuenta (maximum five
items). Funciones is a full page, not a dropdown, with every permitted secondary module.
The owner retains products, settings, team, inventory, reports, promotions and QR links.
Account actions live in a full Cuenta page. Existing database and page permission checks
remain in force. The navigation model is not a replacement for authorization.

Driver navigation retains Inicio, Pedidos, Ganancias and Cuenta with active-page semantics.
The driver account includes installation, notifications, personal account/privacy and
sign-out. Platform administration has its own bounded footer and remains server checked.

Bottom navigation is appended outside sticky/backdrop-filter headers, rendered once,
keyboard accessible, and reserved in body padding including device safe areas. Kitchen
supports dark navigation. Toasts reserve footer height, layouts wrap on narrow devices,
and all footers are hidden for printed tickets and reports. New full-page hubs are in
the PWA shell cache, version 21. No authentication or database permissions were broadened.

Validation includes Node behavior tests for all six work roles, permission-filtered
feature reachability, maximum/unique destinations, active/dark states, removal of old
menu handlers, account-action reachability and the existing regression suite. Authenticated
mobile/device acceptance should still be performed with actual operating accounts.
