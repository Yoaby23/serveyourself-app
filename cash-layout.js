/* Preserve an active payment draft only while its server balance is unchanged. */
window.captureCashDraft = function captureCashDraft() {
    const active = document.activeElement;
    const card = active?.closest?.('[data-cash-draft-version]');
    if (!card || !active.id) return () => {};
    const id = card.id, version = card.dataset.cashDraftVersion, focused = active.id;
    const fields = [...card.querySelectorAll('input[id],select[id],textarea[id]')]
        .map(field => ({ id: field.id, value: field.value, checked: field.checked }));
    return () => {
        const replacement = document.getElementById(id);
        if (!replacement || replacement.dataset.cashDraftVersion !== version) return;
        for (const saved of fields) {
            const field = document.getElementById(saved.id);
            if (field && replacement.contains(field)) { field.value = saved.value; if (typeof saved.checked === 'boolean') field.checked = saved.checked; }
        }
        const field = document.getElementById(focused);
        field?.focus({ preventScroll: true });
        field?.dispatchEvent(new Event('input', { bubbles: true }));
        field?.dispatchEvent(new Event('change', { bubbles: true }));
    };
};
/* Hash navigation keeps cashier sections shareable and restores browser history. */
(() => {
    const tabs = [...document.querySelectorAll('[data-cash-tab]')];
    const panels = [...document.querySelectorAll('[data-cash-panel]')];
    function selectSection() {
        const requested = window.location.hash.slice(1);
        const section = tabs.some(tab => tab.dataset.cashTab === requested) ? requested : 'pickup';
        tabs.forEach(tab => {
            if (tab.dataset.cashTab === section) tab.setAttribute('aria-current', 'page');
            else tab.removeAttribute('aria-current');
        });
        panels.forEach(panel => { panel.hidden = panel.dataset.cashPanel !== section; });
        if (requested === 'ready-pickup') document.getElementById('ready-pickup').scrollIntoView({block:'start'});
    }
    window.addEventListener('hashchange', selectSection);
    selectSection();
})();
