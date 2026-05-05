const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co'; 
const SUPABASE_ANON_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY'; 
const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Detectar el rol desde la URL (ej: registro.html?role=negocio)
const params = new URLSearchParams(window.location.search);
const userRole = params.get('role') || 'cliente';

// Configurar la interfaz si estamos en registro.html
if (document.getElementById('registro-form')) {
    const bizSection = document.getElementById('biz-section');
    const title = document.getElementById('form-title');
    
    if (userRole === 'negocio') {
        title.innerText = "Registro Negocio";
        bizSection.classList.remove('hidden');
        document.getElementById('biz_name').required = true;
        document.getElementById('biz_address').required = true;
    }

    document.getElementById('registro-form').onsubmit = handleSignUp;
}

async function handleSignUp(e) {
    e.preventDefault();
    
    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;
    const fullName = document.getElementById('full_name').value;

    const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: { data: { full_name: fullName, role: userRole } }
    });

    if (error) return alert("Error: " + error.message);

    if (userRole === 'negocio' && data.user) {
        await supabase.from('shops').insert([{
            owner_id: data.user.id,
            name: document.getElementById('biz_name').value,
            address: document.getElementById('biz_address').value
        }]);
    }

    alert("¡Registro exitoso!");
    window.location.href = 'index.html'; // Regresar al inicio tras éxito
}