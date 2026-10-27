/* Shared, dependency-free behavior used by the browser and regression tests. */
(function (root) {
    const api = {
        csvCell(value) {
            let text = String(value ?? '');
            if (/^[\s\u0000-\u001f]*[=+@-]/.test(text) || /^[\t\r\n]/.test(text)) text = "'" + text;
            return '"' + text.replaceAll('"', '""') + '"';
        },
        dateInZone(date, timezone) {
            const parts = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(date);
            const get = type => parts.find(part => part.type === type).value;
            return `${get('year')}-${get('month')}-${get('day')}`;
        },
        async allRows(makeQuery, size = 500) {
            const rows = [];
            for (let offset = 0; ; offset += size) {
                const { data, error } = await makeQuery().range(offset, offset + size - 1);
                if (error) throw error;
                rows.push(...(data || []));
                if (!data || data.length < size) return rows;
            }
        },
        async createOrderOnce(db, storage, storageKey, payload, randomUUID = () => crypto.randomUUID()) {
            const fingerprint = JSON.stringify(payload);
            let attempt;
            try { attempt = JSON.parse(storage.getItem(storageKey) || 'null'); } catch { /* Replace invalid state. */ }
            if (!attempt || attempt.fingerprint !== fingerprint) {
                attempt = { fingerprint, requestId: randomUUID() };
                // Persist BEFORE the request: a lost response must reuse the same server key.
                storage.setItem(storageKey, JSON.stringify(attempt));
            }
            const { data, error } = await db.rpc('create_customer_order_once', { p_request_id: attempt.requestId, p_payload: payload });
            if (error) throw error;
            return data;
        },
        async previewSound(audio) {
            await audio.play();
            audio.pause();
            audio.currentTime = 0;
        }
    };
    root.SYRuntime = api;
    if (typeof module !== 'undefined') module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
