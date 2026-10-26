const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {randomUUID,randomBytes,createCipheriv,createDecipheriv}=require('node:crypto');
const {initializeApp,deleteApp}=require('firebase-admin/app');
const {getFirestore}=require('firebase-admin/firestore');
const {DeviceService,sha256}=require('../lib/service');
const {relayKey,relayAAD}=require('../lib/relay');
let app,db,service;
before(()=>{assert.ok(process.env.FIRESTORE_EMULATOR_HOST);app=initializeApp({projectId:'demo-havit-device'},'relay');db=getFirestore(app);service=new DeviceService(db)});
after(async()=>{await deleteApp(app)});
async function fixture(){
 const uid=randomUUID(),id='relay-'+randomUUID(),token='hvt_dev_'+randomBytes(32).toString('base64url'),bindingId=randomUUID(),hash=sha256(token);
 await db.collection('havitV1Devices').doc(id).set({active:true,ownerUid:uid,bindingId,credentialHash:hash});
 await db.collection('havitV1DeviceCredentials').doc(hash).set({deviceId:id,revokedAtMs:null});
 return {uid,id,token,bindingId,key:relayKey(hash),hash};
}
function request(f,pending=[]){
 const e={protocol:1,deviceId:f.id,bindingId:f.bindingId,nonce:randomBytes(32).toString('hex')};
 const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',f.key,iv);cipher.setAAD(relayAAD('request',e));
 const raw=Buffer.concat([cipher.update(JSON.stringify({protocol:1,pending})),cipher.final()]);
 return {...e,iv:iv.toString('hex'),tag:cipher.getAuthTag().toString('hex'),data:raw.toString('base64')};
}
function decrypt(f,e){const d=createDecipheriv('aes-256-gcm',f.key,Buffer.from(e.iv,'hex'));d.setAAD(relayAAD('response',e));d.setAuthTag(Buffer.from(e.tag,'hex'));return JSON.parse(Buffer.concat([d.update(Buffer.from(e.data,'base64')),d.final()]).toString())}
test('relay applies encrypted device events and returns an authenticated snapshot with ACKs',async()=>{
 const f=await fixture(),event={bindingId:f.bindingId,eventId:randomUUID(),taskId:randomUUID(),baseTaskVersion:0,kind:'create',task:{title:'BLE',detail:'Privado',dueAt:null,status:'pending'}};
 const r=request(f,[event]),reply=await service.relay(f.uid,r),plain=decrypt(f,reply);
 assert.equal(reply.nonce,r.nonce);assert.equal(plain.snapshot.deviceId,f.id);assert.deepEqual(plain.ackEventIds,[event.eventId]);assert.equal(plain.snapshot.tasks[0].title,'BLE');
 // Same event arriving by HTTPS after a lost BLE ACK must not execute twice.
 const {bindingId,eventId,...m}=event;
 const repeated=await service.tasks.mutate({token:f.token,bindingId},{...m,operationId:eventId});
 assert.equal(repeated.taskVersion,1);assert.equal(decrypt(f,await service.relay(f.uid,r)).snapshot.tasks.length,1);
});
test('another account and a modified encrypted payload cannot read or alter device tasks',async()=>{
 const f=await fixture(),e=request(f);
 await assert.rejects(service.relay(randomUUID(),e),err=>err.code==='BINDING_CHANGED');
 await assert.rejects(service.relay(f.uid,{...e,tag:'0'.repeat(32)}),err=>err.code==='INVALID_RELAY_PROOF');
 await assert.rejects(service.relay(f.uid,{...e,nonce:'0'.repeat(64)}),err=>err.code==='INVALID_RELAY_PROOF');
});
test('unlink while the device is offline blocks its previous bridge proof; B gets a different binding',async()=>{
 const f=await fixture(),old=request(f);await service.unlink(f.uid,f.id,f.bindingId,randomUUID());
 await assert.rejects(service.relay(f.uid,old),err=>err.code==='BINDING_CHANGED');
 const nextUID=randomUUID(),nextBinding=randomUUID();await db.collection('havitV1Devices').doc(f.id).update({ownerUid:nextUID,bindingId:nextBinding});
 await assert.rejects(service.relay(nextUID,old),err=>err.code==='BINDING_CHANGED');
 const next={...f,uid:nextUID,bindingId:nextBinding};const p=decrypt(next,await service.relay(next.uid,request(next)));
 assert.equal(p.snapshot.bindingId,nextBinding);assert.equal(p.snapshot.tasks.length,0);
});
test('revocation invalidates relay authorization even when device and binding still match',async()=>{
 const f=await fixture(),e=request(f);await db.collection('havitV1DeviceCredentials').doc(f.hash).update({revokedAtMs:Date.now()});
 await assert.rejects(service.relay(f.uid,e),err=>err.code==='DEVICE_CREDENTIAL_REVOKED');
});
