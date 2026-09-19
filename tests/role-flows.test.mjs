import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const app = read('app.js');
const admin = read('admin.html');
const pos = read('pos.html');
const kitchen = read('cocina.html');
const team = read('equipo.html');
const migration = read('supabase/migrations/007_staff_permissions_and_cashier.sql');
const notification = read('supabase/functions/send-order-notification/index.ts');
const index = read('index.html');
const registration = read('registro.html');
const recovery = read('recuperar.html');
const socialAuth = read('supabase/migrations/011_social_auth_profiles.sql');

for (const file of fs.readdirSync(new URL('..', import.meta.url)).filter(file => file.endsWith('.html'))) {
    const html = read(file);
    const inlineScripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)];
    inlineScripts.forEach((match, index) => {
        assert.doesNotThrow(() => new Function(match[1]), `${file}: script ${index + 1} debe compilar`);
    });
}

assert.match(admin, /id="view-home"/, 'El dueño debe iniciar en el panel de funciones');
assert.match(admin, /id="view-pedidos" class="hidden/, 'Pedidos en vivo debe ser una opción secundaria');
assert.match(app, /renderRestaurantNavigation/, 'Debe existir navegación común');
assert.match(app, /persistSession: true/, 'La aplicación instalada debe conservar la sesión');
assert.match(app, /autoRefreshToken: true/, 'La sesión guardada debe renovar su token automáticamente');
assert.match(app, /getOrCreateProfile/, 'Las cuentas antiguas deben recuperar su perfil faltante al iniciar sesión');
assert.match(app, /created\.error\.code === '23505'/, 'La reparación del perfil debe tolerar la creación simultánea del trigger');
assert.match(index, /resumeSavedSession/, 'La portada debe reanudar una sesión existente al abrir la PWA');
assert.match(index, /getOrCreateProfile\(user\)/, 'El acceso debe reparar un perfil inexistente antes de redirigir');
assert.match(index, /getSession\(\)/, 'La portada debe consultar la sesión local antes de mostrar el acceso');
assert.match(read('sw.js'), /serveyourself-shell-v4/, 'La PWA debe renovar su caché para recibir los arreglos operativos');
for (const page of [pos, kitchen, team, read('qr.html')]) {
    assert.match(page, /id="restaurant-nav"/, 'Cada pantalla operativa debe incluir el menú común');
}

assert.match(migration, /'cashier'/, 'Debe existir el rol Capitán de caja');
assert.match(migration, /has_restaurant_permission/, 'Los permisos deben validarse en base de datos');
assert.match(migration, /Solo caja o el propietario pueden cerrar cuentas/, 'El mesero no debe poder cerrar cuentas');
assert.match(migration, /p_payment_method not in \('cash', 'transfer', 'card_terminal'\)/, 'Caja solo debe aceptar los tres métodos manuales');
assert.match(migration, /v_order\.status = 'pendiente' and p_status <> 'preparando'/, 'Cocina debe respetar el avance de estados');
assert.match(migration, /v_order\.status = 'preparando' and p_status <> 'listo'/, 'Cocina no debe saltar directamente a listo');
assert.match(migration, /v_order\.status = 'listo' and p_status <> 'entregado'/, 'Cocina debe cerrar la entrega en orden');
assert.match(pos, /!access\.can_close_accounts/, 'El POS debe ocultar controles de cobro sin permiso');
assert.match(pos, /PRECUENTA/, 'Caja debe poder imprimir antes de cobrar');
assert.doesNotMatch(pos, /id="modal-payment-method"|id="charge-button"/, 'La confirmación de cocina no debe mostrar cobro ni forma de pago');
assert.match(pos, /setTimeout\(closeSuccess, 3000\)/, 'La confirmación debe cerrarse sola después de tres segundos');
assert.match(pos, /create_or_append_pos_order/, 'El POS debe reutilizar automáticamente la cuenta abierta de la mesa');
assert.match(kitchen, /requireRestaurantPermission\('can_view_kitchen'\)/, 'Cocina debe exigir su permiso');
assert.match(kitchen, /class="kitchen-toolbar"/, 'Los controles de cocina deben usar una barra adaptable');
assert.match(read('styles.css'), /@media \(max-width: 767px\)[\s\S]*\.kitchen-toolbar[\s\S]*grid-template-columns/, 'La barra de cocina debe reorganizarse en teléfonos');
assert.match(read('styles.css'), /\.kitchen-screen[\s\S]*overflow-x: hidden/, 'Cocina no debe provocar desplazamiento horizontal');
assert.match(team, /set_staff_permissions/, 'El dueño debe poder editar permisos individuales');

assert.match(pos, /waiter-ready-/, 'El mesero debe escuchar comandas listas en tiempo real');
assert.match(pos, /Mis comandas listas/, 'El mesero debe ver comandas listas dentro del POS');
assert.match(notification, /created_by/, 'La notificación debe dirigirse al creador de la comanda');
assert.match(notification, /La comanda #\$\{order\.id\} está lista/, 'La notificación debe indicar qué comanda está lista');

function renderNavigation(access) {
    const container = { innerHTML: '', contains: () => false };
    const document = {
        getElementById: id => id === 'restaurant-nav' ? container : null,
        addEventListener: () => {},
        querySelector: () => null,
        createElement: () => ({ dataset: {}, set src(_value) {}, set defer(_value) {} }),
        head: { appendChild: () => {} }
    };
    const window = {
        location: { origin: 'https://example.test' },
        history: { length: 1 },
        addEventListener: () => {},
        supabase: { createClient: () => ({}) }
    };
    window.window = window;
    vm.runInNewContext(app, { window, document, navigator: {}, location: window.location, URL, fetch: () => {}, alert: () => {} });
    window.serveYourself.renderRestaurantNavigation({ business_name: 'Restaurante prueba', ...access });
    return container.innerHTML;
}

const ownerNav = renderNavigation({ staff_role: 'owner', can_create_orders: true, can_view_kitchen: true, can_close_accounts: true });
assert.match(ownerNav, /admin\.html/, 'El propietario debe regresar a su panel');
assert.match(ownerNav, /equipo\.html/, 'El propietario debe administrar su personal');
assert.match(ownerNav, /qr\.html/, 'El propietario debe acceder al QR');

const waiterNav = renderNavigation({ staff_role: 'waiter', can_create_orders: true, can_view_kitchen: false, can_close_accounts: false });
assert.match(waiterNav, /pos\.html/, 'El mesero debe acceder a comandas');
assert.doesNotMatch(waiterNav, /cocina\.html|equipo\.html|qr\.html/, 'El mesero no debe ver funciones administrativas o de cocina');

const kitchenNav = renderNavigation({ staff_role: 'kitchen', can_create_orders: false, can_view_kitchen: true, can_close_accounts: false });
assert.match(kitchenNav, /cocina\.html/, 'Cocina debe acceder a su tablero');
assert.doesNotMatch(kitchenNav, /pos\.html|equipo\.html|qr\.html/, 'Cocina no debe ver caja ni administración');

const cashierNav = renderNavigation({ staff_role: 'cashier', can_create_orders: false, can_view_kitchen: false, can_close_accounts: true });
assert.match(cashierNav, /caja\.html/, 'El capitán de caja debe acceder a cuentas pendientes');
assert.doesNotMatch(cashierNav, /cocina\.html|equipo\.html|qr\.html/, 'Caja no debe ver cocina ni administración');

const operations = read('supabase/migrations/008_restaurant_operations_suite.sql');
for (const feature of ['cash_shifts','order_payments','order_audit_logs','kitchen_stations','ingredients','product_recipes','coupons','reservations','loyalty_customers']) {
    assert.match(operations, new RegExp(`public\\.${feature}`), `La migración operativa debe incluir ${feature}`);
}
assert.match(operations, /register_pos_payment/, 'Debe soportar pagos parciales y combinados');
assert.match(operations, /split_pos_order/, 'Debe permitir dividir una cuenta por productos');
assert.match(operations, /deduct_order_inventory/, 'Debe descontar inventario mediante recetas');
assert.match(read('caja.html'), /CERRAR TURNO/, 'Caja debe permitir realizar el corte');
assert.match(read('inventario.html'), /Recetas/, 'Debe existir gestión de recetas');
assert.match(read('reportes.html'), /EXPORTAR CSV/, 'Los reportes deben poder exportarse');
assert.match(read('clientes.html'), /Clientes frecuentes/, 'Debe existir el programa de lealtad');

const paymentExpiration = read('supabase/migrations/010_online_payment_expiration.sql');
assert.match(paymentExpiration, /interval '20 minutes'/, 'El pago en línea debe vencer a los 20 minutos');
assert.match(paymentExpiration, /payment_status = 'expired'/, 'Los pedidos sin pago deben marcarse como vencidos');
assert.match(paymentExpiration, /protect_unpaid_online_order/, 'La base de datos debe impedir enviar pedidos sin pago a cocina');
assert.match(paymentExpiration, /mercado_pago_payment_id is null/, 'Un pago que Mercado Pago ya procesa no debe vencer como impago');
assert.match(read('cocina.html'), /payment_method\.neq\.mercado_pago,payment_status\.eq\.approved/, 'Cocina solo debe consultar pedidos en línea pagados');
assert.doesNotMatch(read('cocina.html'), /Esperando pago en línea/, 'Cocina no debe mostrar tarjetas de pagos pendientes');
assert.match(read('caja.html'), /Pagos en línea por confirmar/, 'Caja debe poder revisar pagos en línea pendientes');
assert.match(read('menu.html'), /Pago vencido · haz un pedido nuevo/, 'El cliente debe saber que necesita crear otro pedido');
assert.match(read('supabase/functions/create-mercado-pago-preference/index.ts'), /expiration_date_to/, 'La preferencia debe vencer junto con el pedido');
assert.match(read('supabase/functions/mercado-pago-webhook/index.ts'), /payment window expired/, 'El webhook debe rechazar pagos creados fuera del plazo');

const automaticAccounts = read('supabase/migrations/012_automatic_table_accounts.sql');
assert.match(automaticAccounts, /pg_advisory_xact_lock/, 'La cuenta automática por mesa debe evitar carreras entre meseros');
assert.match(automaticAccounts, /payment_status='pending' and status<>'cancelado'/, 'Solo debe reutilizar cuentas realmente abiertas');
assert.match(automaticAccounts, /was_appended/, 'El POS debe saber cuándo agregó una ronda a una cuenta existente');
assert.match(automaticAccounts, /kitchen_items=coalesce\(kitchen_items,'\[\]'::jsonb\)\|\|v_added/, 'Cocina debe conservar todas las rondas pendientes');
assert.match(kitchen, /order\.kitchen_items \|\| order\.items/, 'Cocina debe usar la cola de productos pendientes');
const pendingKitchenQueue = read('supabase/migrations/013_pending_kitchen_queue.sql');
assert.match(pendingKitchenQueue, /set kitchen_items=items[\s\S]*status in \('pendiente','preparando'\)/, 'La migracion debe recuperar comandas activas ocultadas');
assert.match(pendingKitchenQueue, /kitchen_items=coalesce\(kitchen_items,'\[\]'::jsonb\)\|\|v_added/, 'Las rondas nuevas deben acumularse en la cola de cocina');
assert.match(pendingKitchenQueue, /kitchen_items=case when p_status='entregado' then '\[\]'::jsonb else kitchen_items end/, 'La cola debe limpiarse al entregar la comanda');
assert.match(kitchen, /5000/, 'Cocina debe sincronizarse aunque Realtime se interrumpa en la PWA');
assert.match(kitchen, /visibilitychange/, 'Cocina debe actualizarse al volver a primer plano');

for (const provider of ['google', 'facebook', 'apple']) {
    assert.match(index, new RegExp(`signInWithProvider\\('${provider}'`), `El inicio debe ofrecer acceso con ${provider}`);
    assert.match(registration, new RegExp(`registerWithProvider\\('${provider}'`), `El registro debe ofrecer acceso con ${provider}`);
}
assert.match(index, /signInWithOAuth/, 'Los proveedores sociales deben usar OAuth de Supabase');
assert.match(registration, /completeOAuthRegistration/, 'El registro debe completar el retorno de OAuth');
assert.match(registration, /CREAR MI RESTAURANTE/, 'El registro social de negocio debe solicitar los datos del restaurante');
assert.doesNotMatch(index, /signInWithProvider\('github'/, 'GitHub no debe mostrarse como proveedor');
assert.match(socialAuth, /raw_user_meta_data ->> 'name'/, 'El perfil social debe aceptar el nombre del proveedor');
assert.match(socialAuth, /raw_user_meta_data ->> 'picture'/, 'El perfil social debe aceptar la imagen del proveedor');
assert.match(socialAuth, /split_part\(coalesce\(new\.email/, 'Apple debe tener un nombre alternativo si no comparte el nombre');
assert.match(index, /href="recuperar\.html"/, 'El inicio de sesión debe enlazar la recuperación de contraseña');
assert.match(index, /Pide fácil\./, 'La portada debe comunicar una experiencia sencilla para clientes');
assert.match(index, /Atiende mejor\./, 'La portada debe representar también al equipo del restaurante');
assert.match(index, /Pedidos · Punto de venta · Cocina/, 'La portada debe resumir las funciones principales');
assert.match(recovery, /resetPasswordForEmail/, 'La recuperación debe enviar el correo mediante Supabase Auth');
assert.match(recovery, /updateUser\(\{ password \}\)/, 'El enlace de recuperación debe permitir guardar la contraseña nueva');
assert.match(recovery, /PASSWORD_RECOVERY/, 'La pantalla debe reconocer el evento de recuperación de Supabase');
assert.match(recovery, /password !== confirmation/, 'Las dos contraseñas deben coincidir');

console.log('Validación de roles, navegación, caja, cocina y notificaciones: OK');
