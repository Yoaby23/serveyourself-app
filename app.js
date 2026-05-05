const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co'; 
const SUPABASE_ANON_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY'; 
const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

let selectedRole = 'cliente';

// Función para cambiar de pantalla sin "inyectar" código
window.showForm = function(role) {
    selectedRole = role;
    
    // Ocultar inicio, mostrar formulario
    document.getElementById('home-screen').classList.add('hidden');
    document.getElementById('auth-screen').classList.remove('hidden');
    
    // Configurar si es negocio o cliente
    const bizFields = document.getElementById('business-fields');
    const title = document.getElementById('auth-title');
    
    if (role === 'negocio') {
        title.innerText = "Registro de Negocio";
        bizFields.classList.remove('hidden');
        document.getElementById('biz_name').required = true;
        document.getElementById('biz_address').required = true;
    } else {
        title.innerText = "Crear Cuenta";
        bizFields.classList.add('hidden');
    }
}

// Manejar el registro
document.getElementById('auth-form').onsubmit = async (e) => {
    e.preventDefault();
    
    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;
    const fullName = document.getElementById('full_name').value;
    const phone = document.getElementById('phone').value;

    const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: { data: { full_name: fullName, phone, role: selectedRole } }
    });

    if (error) return alert("Error: " + error.message);

    if (selectedRole === 'negocio' && data.user) {
        await supabase.from('shops').insert([{
            owner_id: data.user.id,
            name: document.getElementById('biz_name').value,
            address: document.getElementById('biz_address').value,
            phone: phone
        }]);
    }

    alert("¡Registro exitoso!");
    window.location.reload();
};