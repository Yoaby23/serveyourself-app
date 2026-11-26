import { strict as assert } from 'node:assert';
import test from 'node:test';
import { settlementFields } from '../supabase/functions/_shared/mercado-pago-settlement.ts';
import { reportProductionHealth } from '../scripts/report-production-health.mjs';

test('conserva los datos explícitos de Mercado Pago y diferencia impuestos de IVA', () => {
    const payment = {
        fee_details: [
            { type:'mercadopago', amount:5.22, fee_payer:'collector' },
            { type:'mercadopago', amount:4, fee_payer:'payer' },
            { type:'application_fee', amount:1, fee_payer:'collector' }
        ],
        charges_details: [
            { type:'tax', name:'mex_iva', accounts:{from:'collector'}, amounts:{original:0.84} },
            { type:'tax', name:'isr', accounts:{from:'collector'}, amounts:{original:1.5} }
        ],
        taxes_amount:2.34,
        transaction_details:{net_received_amount:28.94},
        money_release_date:'2026-11-26T10:00:00-06:00'
    };
    assert.deepEqual(settlementFields(payment), {
        provider_fee:5.22, provider_vat:0.84, provider_net:28.94, available_at:'2026-11-26T16:00:00.000Z'
    });
    assert.deepEqual(settlementFields({taxes_amount:0.84, fee_details:[], money_release_date:'desconocida'}), {});
    assert.deepEqual(settlementFields({transaction_details:{net_received_amount:0}}), {provider_net:0});
});

test('un fallo crea una incidencia asignada y un nuevo fallo actualiza la misma', async () => {
    const calls = [];
    const issues = {
        listForRepo() {},
        create(data) { calls.push(['create', data]); },
        update(data) { calls.push(['update', data]); }
    };
    const context = {repo:{owner:'dueno',repo:'app'},runId:91};
    let open = [];
    const github = {rest:{issues},paginate:async (_method,filters) => {
        assert.equal(filters.creator,'github-actions[bot]');
        return open;
    }};
    await reportProductionHealth(github,context);
    const incident = calls[0][1];
    assert.deepEqual(incident.assignees,['dueno']);
    assert.match(incident.body,/actions\/runs\/91/);
    open = [{number:4,title:incident.title}];
    await reportProductionHealth(github,{...context,runId:92});
    assert.equal(calls[1][1].issue_number,4);
    assert.match(calls[1][1].body,/actions\/runs\/92/);
    await reportProductionHealth(github,context,true);
    assert.match(calls[2][1].title,/prueba de alerta/);
});
