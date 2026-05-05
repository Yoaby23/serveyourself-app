// 1. CONFIGURACIÓN DE CONEXIÓN
const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co'; 
const SUPABASE_ANON_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY'; 

// Inicializamos el cliente
const supabase = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

let userRole = 'cliente'; 

// 2. FUNCIÓN PARA RENDERIZAR EL FORMULARIO
function renderAuth(role) {
    userRole = role;
    const content = document.getElementById('main-content');
    
    content.innerHTML = `
        <div class="animate-in fade-in duration-500 bg-white p-8 rounded-3xl shadow-sm border border-gray-100">
            <button onclick="location.reload()" class="text-orange-500 font-bold mb-6">← Volver</button>
            <h2 class="text-2xl font-black mb-6">${role === 'negocio' ? 'Registro de Negocio' : 'Registro de Cliente'}</h2>
            
            <form id="auth-form" class="space-y-4">
                <input type="text" id="full_name" placeholder="Nombre completo" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 focus:border-orange-500 outline-none" required>
                <input type="email" id="email" placeholder="Correo electrónico" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 focus:border-orange-500 outline-none" required>
                <input type="password" id="password" placeholder="Contraseña" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 focus:border-orange-500 outline-none" required>
                <input type="tel" id="phone" placeholder="Teléfono" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 focus:border-orange-500 outline-none" required>
                
                ${role === 'negocio' ? `
                    <input type="text" id="biz_name" placeholder="Nombre del Negocio" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 focus:border-orange-500 outline-none" required>
                    <input type="text" id="biz_address" placeholder="Ubicación" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 focus:border-orange-500 outline-none" required>
                ` : ''}
                
                <button type="submit" class="w-full bg-orange-500 text-white font-black py-4 rounded-2xl shadow-lg shadow-orange-100 mt-4">REGISTRARME</button>
            </form>
        </div>
    `;

    document.getElementById('auth-form').addEventListener('submit', handleAuth);
}

// 3. LÓGICA DE REGISTRO
async function handleAuth(event) {
    event.preventDefault();
    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;
    const fullName = document.getElementById('full_name').value;
    const phone = document.getElementById('phone').value;

    const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: { data: { full_name: fullName, phone, role: userRole } }
    });

    if (error) return alert("Error: " + error.message);

    if (userRole === 'negocio') {
        const { error: shopError } = await supabase.from('shops').insert([{
            owner_id: data.user.id,
            name: document.getElementById('biz_name').value,
            address: document.getElementById('biz_address').value,
            phone: phone
        }]);
        if (shopError) console.log(shopError);
    }

    alert("¡Registro exitoso! Ya puedes usar la app.");
    location.reload();
}