const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const SUPABASE_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY';

window.serveYourself = {
    supabase: window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY),

    escapeHtml(value) {
        return String(value ?? '').replace(/[&<>'"]/g, character => ({
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            "'": '&#39;',
            '"': '&quot;'
        })[character]);
    },

    safeImageUrl(value) {
        if (!value) return '';
        try {
            const url = new URL(value, window.location.origin);
            return ['http:', 'https:'].includes(url.protocol) ? url.href : '';
        } catch {
            return '';
        }
    },

    async requireUser() {
        const { data: { user }, error } = await this.supabase.auth.getUser();
        if (error || !user) {
            window.location.replace('index.html');
            return null;
        }
        return user;
    }
};
