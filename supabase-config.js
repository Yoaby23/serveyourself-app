const supabaseUrl = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const supabaseKey = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY';

// 2. Inicializar el cliente de Supabase
const supabase = supabaseOrigin.createClient(supabaseUrl, supabaseKey);

// Opcional: Verificar conexión en consola
console.log("Conexión con Supabase establecida.");