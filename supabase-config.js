const supabaseUrl = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const supabaseKey = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY';

if (!window.supabase) {
    window.supabase = supabaseOrigin.createClient(supabaseUrl, supabaseKey);
}