import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const source=fs.readFileSync(new URL('../business-image.js',import.meta.url),'utf8');
function setup({role='negocio',profileError=null,uploadError=null}={}){
 const calls=[];let uploadFail=uploadError,saveFail=profileError;
 const window={};vm.runInNewContext(source,{window,crypto:{randomUUID:()=> 'image-id'},createImageBitmap:async()=>({close(){}})});
 const db={auth:{getUser:async()=>({data:{user:{id:'owner'}}})},storage:{from:()=>({upload:async(path,file,options)=>{calls.push({type:'upload',path,options});return{error:uploadFail};},getPublicUrl:path=>({data:{publicUrl:'https://images.invalid/'+path}})})},from:()=>({select:()=>({eq:()=>({single:async()=>({data:{role}})})}),update:data=>({eq:(key,id)=>({select:()=>({single:async()=>{calls.push({type:'profile',id,data});return{error:saveFail};}})})})})};
 return{api:window.BusinessImages,db,calls,setSaveError:error=>saveFail=error,setUploadError:error=>uploadFail=error};
}
const file={type:'image/png',size:200};
test('staging a selected image does not upload before there is an authenticated business session',async()=>{const s=setup();await s.api.stage('owner',file);assert.equal(s.calls.length,0);await s.api.applyPending(s.db,{id:'owner'});assert.equal(s.calls[0].path,'owner/business/image-id.png');assert.equal(s.calls[1].id,'owner');assert.equal(s.calls[0].options.upsert,false);});
test('client profiles cannot upload a pending business image before completing business registration',async()=>{const s=setup({role:'cliente'});await s.api.stage('owner',file);assert.equal(await s.api.applyPending(s.db,{id:'owner'}),null);assert.equal(s.calls.length,0);});
test('invalid files fail validation before any upload or profile write',async()=>{const s=setup();await assert.rejects(s.api.stage('owner',{type:'text/html',size:10}),/imagen/);assert.equal(s.calls.length,0);});
test('failed photo save keeps the same pending file for an idempotent retry',async()=>{const s=setup({profileError:Error('offline')});await s.api.stage('owner',file);await assert.rejects(s.api.applyPending(s.db,{id:'owner'}),/offline/);s.setSaveError(null);s.setUploadError({statusCode:'409'});const url=await s.api.applyPending(s.db,{id:'owner'});assert.equal(url,'https://images.invalid/owner/business/image-id.png');assert.equal(s.calls.filter(c=>c.type==='upload').length,2);assert.equal(await s.api.applyPending(s.db,{id:'owner'}),null);});
