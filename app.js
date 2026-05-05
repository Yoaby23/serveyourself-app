// 1. CONFIGURACIÓN DE CONEXIÓN
const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.com'; 
const SUPABASE_ANON_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY'; 

const supabase = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

let userRole = 'cliente'; 

// 2. FUNCIÓN PARA MOSTRAR FORMULARIOS (Se activa al dar clic en los botones)
function renderAuth(role) {
    userRole = role;
    const content = document.getElementById('main-content');
    
    content.innerHTML = `
        <div class="animate-in fade-in duration-500">
            <button onclick="location.reload()" class="text-[#F97316] font-bold mb-6 flex items-center gap-2">
                <span>←</span> Volver al inicio
            </button>
            
            <h2 class="text-3xl font-black mb-2">${role === 'negocio' ? 'Nuevo Negocio' : 'Nueva Cuenta'}</h2>
            <p class="text-gray-400 mb-8">Ingresa tus datos para continuar.</p>

            <form id="auth-form" class="space-y-4">
                <input type="text" id="full_name" placeholder="Nombre completo" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 outline-none focus:border-[#F97316] transition" required>
                <input type="email" id="email" placeholder="Correo electrónico" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 outline-none focus:border-[#F97316] transition" required>
                <input type="password" id="password" placeholder="Contraseña (6+ caracteres)" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 outline-none focus:border-[#F97316] transition" required>
                <input type="tel" id="phone" placeholder="Teléfono de contacto" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 outline-none focus:border-[#F97316] transition" required>
                
                ${role === 'negocio' ? `
                    <div class="pt-6 mt-6 border-t border-gray-100 space-y-4">
                        <p class="text-[#F97316] font-bold text-sm uppercase tracking-wider">Detalles del Local</p>
                        <input type="text" id="biz_name" placeholder="Nombre de tu establecimiento" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 outline-none focus:border-[#F97316] transition" required>
                        <input type="text" id="biz_address" placeholder="Dirección completa" class="w-full p-4 bg-gray-50 rounded-2xl border border-gray-200 outline-none focus:border-[#F97316] transition" required>
                    </div>
                ` : ''}

                <button type="submit" class="w-full bg-[#F97316] text-white font-black py-5 rounded-2xl shadow-lg shadow-orange-100 hover:bg-orange-600 transition-all mt-4">
                    CREAR MI CUENTA
                </button>
            </form>
        </div>
    `;

    // Escuchar el envío del formulario
    document.getElementById('auth-form').addEventListener('submit', handleAuth);
}

// 3. LÓGICA DE REGISTRO REAL
async function handleAuth(event) {
    event.preventDefault();
    
    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;
    const fullName = document.getElementById('full_name').value;
    const phone = document.getElementById('phone').value;

    console.log("Intentando registrar a:", email);

    // Registro en Supabase Auth
    const { data, error } = await supabase.auth.signUp({
        email: email,
        password: password,
        options: {
            data: { full_name: fullName, phone: phone, role: userRole }
        }
    });

    if (error) {
        alert("Error de registro: " + error.message);
        return;
    }

    // Si es negocio, guardar datos adicionales en la tabla 'shops'
    if (userRole === 'negocio' && data.user) {
        const { error: shopError } = await supabase.from('shops').insert([{
            owner_id: data.user.id,
            name: document.getElementById('biz_name').value,
            address: document.getElementById('biz_address').value,
            phone: phone
        }]);
        
        if (shopError) console.error("Error al guardar tienda:", shopError);
    }

    alert("¡Registro exitoso! Ya puedes usar la app.");
    location.reload();
}