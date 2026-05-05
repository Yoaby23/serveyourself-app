const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co/rest/v1/'; 
const SUPABASE_ANON_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY'; 
const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Detectar el rol desde la URL
const params = new URLSearchParams(window.location.search);
const userRole = params.get('role') || 'cliente';

// Configurar la interfaz
if (document.getElementById('registro-form')) {
    const bizSection = document.getElementById('biz-section');
    const title = document.getElementById('form-title');
    const subtitle = document.getElementById('form-subtitle');
    
    if (userRole === 'negocio') {
        title.innerText = "Registro Negocio";
        subtitle.innerText = "Configura tu establecimiento de Pickup.";
        bizSection.classList.remove('hidden');
        document.getElementById('biz_name').required = true;
        document.getElementById('biz_address').required = true;
    } else {
        title.innerText = "Nueva Cuenta";
        subtitle.innerText = "Pide sin filas desde hoy.";
    }

    document.getElementById('registro-form').onsubmit = handleSignUp;
}

async function handleSignUp(e) {
    e.preventDefault();
    const submitBtn = e.target.querySelector('button');
    submitBtn.innerText = "GUARDANDO...";
    submitBtn.disabled = true;
    
    const email = document.getElementById('email').value;
    const password = document.getElementById('password').value;
    const fullName = document.getElementById('full_name').value;

    console.log("Iniciando registro para:", email);

    // 1. Registro en la sección de Autenticación
    const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: { 
            data: { 
                full_name: fullName, 
                role: userRole 
            } 
        }
    });

    if (error) {
        alert("Error de Autenticación: " + error.message);
        submitBtn.innerText = "REINTENTAR";
        submitBtn.disabled = false;
        return;
    }

    console.log("Usuario creado en Auth:", data.user.id);

    // 2. Si es negocio, guardamos en la tabla pública 'shops'
    if (userRole === 'negocio' && data.user) {
        const { error: shopError } = await supabase
            .from('shops')
            .insert([
                {
                    owner_id: data.user.id,
                    name: document.getElementById('biz_name').value,
                    address: document.getElementById('biz_address').value
                }
            ]);

        if (shopError) {
            console.error("Error guardando en tabla shops:", shopError);
            alert("Usuario creado, pero hubo un error con los datos del negocio: " + shopError.message);
        }
    }

    alert("¡Registro completado! Bienvenido a serveyourself.");
    window.location.href = './index.html';
}