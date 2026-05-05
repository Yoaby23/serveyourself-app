// La conexión con Supabase la haremos en el siguiente paso
let userRole = '';

function renderAuth(role) {
    userRole = role;
    const content = document.getElementById('main-content');
    
    let businessFields = '';
    if (role === 'negocio') {
        businessFields = `
            <input type="text" id="biz_name" placeholder="Nombre del Negocio" class="w-full p-4 mb-3 bg-gray-50 rounded-xl border border-gray-200 outline-none focus:border-orange-500" required>
            <input type="text" id="biz_address" placeholder="Dirección / Ubicación" class="w-full p-4 mb-3 bg-gray-50 rounded-xl border border-gray-200 outline-none focus:border-orange-500" required>
            <textarea id="biz_desc" placeholder="Descripción del negocio" class="w-full p-4 mb-3 bg-gray-50 rounded-xl border border-gray-200 outline-none focus:border-orange-500" required></textarea>
        `;
    }

    content.innerHTML = `
        <div class="animate-in fade-in duration-500">
            <button onclick="location.reload()" class="text-gray-400 mb-4">← Volver</button>
            <h2 class="text-2xl font-bold mb-6">${role === 'negocio' ? 'Registro de Negocio' : 'Registro de Cliente'}</h2>
            <form id="auth-form" onsubmit="handleAuth(event)">
                <input type="text" id="full_name" placeholder="Nombre completo" class="w-full p-4 mb-3 bg-gray-50 rounded-xl border border-gray-200 outline-none focus:border-orange-500" required>
                <input type="email" id="email" placeholder="Correo electrónico" class="w-full p-4 mb-3 bg-gray-50 rounded-xl border border-gray-200 outline-none focus:border-orange-500" required>
                <input type="password" id="password" placeholder="Contraseña" class="w-full p-4 mb-3 bg-gray-50 rounded-xl border border-gray-200 outline-none focus:border-orange-500" required>
                <input type="tel" id="phone" placeholder="Teléfono" class="w-full p-4 mb-3 bg-gray-50 rounded-xl border border-gray-200 outline-none focus:border-orange-500" required>
                ${businessFields}
                <button type="submit" class="w-full bg-orange-500 text-white font-bold py-4 rounded-2xl mt-4">Continuar</button>
            </form>
        </div>
    `;
}

function handleAuth(event) {
    event.preventDefault();
    alert("¡Archivos creados! Ahora necesitamos conectar las credenciales de Supabase.");
}