// CONFIGURACIÓN DE CONEXIÓN (Mantenemos tus llaves)
const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co'; 
const SUPABASE_ANON_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY'; 
const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

let userRole = 'cliente';

// FUNCIÓN PARA RENDERIZAR LOS FORMULARIOS
window.renderAuth = function(role) {
    userRole = role;
    const content = document.getElementById('main-content');
    
    content.innerHTML = `
        <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
            <button onclick="window.location.reload()" class="text-orange-500 font-bold mb-6 flex items-center gap-2">
                <span>←</span> Volver al inicio
            </button>
            
            <h2 class="text-3xl font-black mb-2 text-slate-900">
                ${role === 'negocio' ? 'Registro de Negocio' : 'Crear Cuenta'}
            </h2>
            <p class="text-slate-500 mb-8">Completa los datos para empezar a usar la app.</p>

            <form id="auth-form" class="space-y-4">
                <div class="space-y-1">
                    <label class="text-xs font-bold text-slate-400 uppercase ml-2">Datos Personales</label>
                    <input type="text" id="full_name" placeholder="Tu nombre completo" class="w-full p-4 bg-slate-50 rounded-2xl border border-slate-200 outline-none focus:border-orange-500 transition-all" required>
                </div>
                
                <input type="email" id="email" placeholder="Correo electrónico" class="w-full p-4 bg-slate-50 rounded-2xl border border-slate-200 outline-none focus:border-orange-500 transition-all" required>
                
                <input type="password" id="password" placeholder="Contraseña (mínimo 6 caracteres)" class="w-full p-4 bg-slate-50 rounded-2xl border border-slate-200 outline-none focus:border-orange-500 transition-all" required>
                
                <input type="tel" id="phone" placeholder="Teléfono celular" class="w-full p-4 bg-slate-50 rounded-2xl border border-slate-200 outline-none focus:border-orange-500 transition-all" required>

                ${role === 'negocio' ? `
                    <div class="pt-4 mt-4 border-t border-slate-100 space-y-4">
                        <label class="text-xs font-bold text-orange-500 uppercase ml-2">Información del Negocio</label>
                        <input type="text" id="biz_name" placeholder="Nombre del establecimiento" class="w-full p-4 bg-slate-50 rounded-2xl border border-slate-200 outline-none focus:border-orange-500 transition-all" required>
                        <input type="text" id="biz_address" placeholder="Dirección para recoger (Pickup)" class="w-full p-4 bg-slate-50 rounded-2xl border border-slate-200 outline-none focus:border-orange-500 transition-all" required>
                        <textarea id="biz_desc" placeholder="¿Qué vendes? (Breve descripción)" class="w-full p-4 bg-slate-50 rounded-2xl border border-slate-200 outline-none focus:border-orange-500 transition-all h-24" required></textarea>
                    </div>
                ` : ''}

                <button type="submit" id="submit-btn" class="w-full bg-orange-500 text-white font-black py-5 rounded-3xl shadow-lg shadow-orange-200 hover:bg-orange-600 active:scale-95 transition-all mt-6 uppercase tracking-wider">
                    Registrarme ahora
                </button>
            </form>
        </div>
    `;

    document.getElementById('auth-form').onsubmit = handleAuth;
};

// LÓGICA DE REGISTRO EN SUPABASE
async function handleAuth(event) {
    event.preventDefault();
    const btn = document.getElementById('submit-btn');
    btn.innerText = "Procesando...";
    btn.disabled = true;

    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;
    const fullName = document.getElementById('full_name').value;
    const phone = document.getElementById('phone').value;

    // 1. Crear el usuario en Supabase Auth
    const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: {
            data: { full_name: fullName, phone, role: userRole }
        }
    });

    if (error) {
        alert("Error: " + error.message);
        btn.innerText = "Registrarme ahora";
        btn.disabled = false;
        return;
    }

    // 2. Si es negocio, guardar en la tabla 'shops'
    if (userRole === 'negocio' && data.user) {
        const { error: shopError } = await supabase.from('shops').insert([{
            owner_id: data.user.id,
            name: document.getElementById('biz_name').value,
            address: document.getElementById('biz_address').value,
            description: document.getElementById('biz_desc').value,
            phone: phone,
            business_email: email
        }]);

        if (shopError) {
            console.error("Error en tabla shops:", shopError);
        }
    }

    alert("¡Excelente! Registro completado con éxito.");
    window.location.reload();
}