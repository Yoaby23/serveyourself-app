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
