import test from 'node:test';
import assert from 'node:assert/strict';
import { getValidMercadoPagoToken } from '../supabase/functions/_shared/mercado-pago.ts';
import { refundOrder } from '../supabase/functions/_shared/refunds.ts';
globalThis.Deno={env:{get:()=> 'test-only'}};
const account={access_token:'test-only',refresh_token:'test-only',token_expires_at:new Date(Date.now()+3600000).toISOString()};
const order={id:123,restaurant_id:'test-restaurant',total:100};
const payment={external_reference:'123',currency_id:'MXN',transaction_amount:100,status:'approved'};
function admin(operation, rpc) {
    const query = {
        select() { return this; }, eq() { return this; },
        update() { this.saving=true; return this; },
        async single() { return this.saving ? {error:new Error('Database unavailable')} : {data:operation}; }
    };
    return {rpc,from:()=>({...query})};
}
test('token persistence failure is surfaced instead of returning a credential that was never saved',async()=>{
    const previous=globalThis.fetch;
    globalThis.fetch=async()=>Response.json({access_token:'new-test-only',expires_in:3600});
    try {await assert.rejects(getValidMercadoPagoToken(admin({...account,token_expires_at:new Date(Date.now()-1000).toISOString()}),'restaurant'),/guardar la renovación/);} finally {globalThis.fetch=previous;}
});
test('successful refund with failed local commit recovers on retry without issuing another refund',async()=>{
    let refunded=false,posts=0,finish=0;const previous=globalThis.fetch;
    globalThis.fetch=async(url,options)=>{
        if(options?.method==='POST'){posts++;refunded=true;return Response.json({id:'refund-1',status:'approved'});}
        return Response.json({...payment,status:refunded?'refunded':'approved'});
    };
    const db=admin(account,async(name)=>{
        if(name==='begin_order_refund')return {data:{status:'pending'}};
        if(name==='finish_order_refund'){if(++finish===1)return {error:new Error('DB down')};return {data:{refunded:true}};}
        throw new Error(name);
    });
    try {
        await assert.rejects(refundOrder(db,order,'payment-1','Test reason'),/falta sincronizarlo/);
        assert.deepEqual(await refundOrder(db,order,'payment-1','Test reason'),{refunded:true});
        assert.equal(posts,1);assert.equal(finish,2);
    } finally {globalThis.fetch=previous;}
});
test('a provider-pending refund never marks the local order as refunded',async()=>{
    let finished=false;const previous=globalThis.fetch;
    globalThis.fetch=async(_,options)=>Response.json(options?.method==='POST'?{status:'pending'}:payment);
    const db=admin(account,async(name)=>{if(name==='finish_order_refund')finished=true;return {data:{status:'pending'}};});
    try {await assert.rejects(refundOrder(db,order,'payment-1','Test reason'),/procesando/);assert.equal(finished,false);}finally{globalThis.fetch=previous;}
});
test('completed refund is idempotent and does not contact the provider again',async()=>{
    const previous=globalThis.fetch;globalThis.fetch=()=>{throw new Error('Must not contact provider');};
    try {const result=await refundOrder(admin(account,async()=>({data:{status:'completed',refund_id:'refund-1'}})),order,'payment-1','Test reason');assert.equal(result.refunded,true);}
    finally{globalThis.fetch=previous;}
});
