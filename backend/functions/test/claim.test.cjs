const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {randomBytes,randomUUID}=require('node:crypto');
const {initializeApp,deleteApp}=require('firebase-admin/app');
const {getFirestore}=require('firebase-admin/firestore');
const {DeviceService,collections,sha256,claimHash}=require('../lib/service.js');
const {createApp}=require('../lib/app.js');
let db,app,service,server,base;
before(async()=>{
 assert.ok(process.env.FIRESTORE_EMULATOR_HOST,'Tests require Firestore emulator; never run against production');
 app=initializeApp({projectId:'demo-havit-device'});db=getFirestore(app);service=new DeviceService(db);
 server=createApp(service,async token=>{if(token==='test-user')return 'user-test';throw Error('invalid');}).listen(0,'127.0.0.1');
 await new Promise(r=>server.once('listening',r));base='http://127.0.0.1:'+server.address().port;
});
after(async()=>{if(server)await new Promise(r=>server.close(r));if(app)await deleteApp(app);});
async function fixture(){
 const id='test-'+randomUUID(),token='hvt_dev_'+randomBytes(32).toString('base64url'),hash=sha256(token),session=randomUUID(),secret=randomBytes(32).toString('base64url');
 await db.collection(collections.devices).doc(id).set({deviceId:id,credentialHash:hash,active:true,ownerUid:null,bindingId:null,pendingSessionId:null});
 await db.collection(collections.credentials).doc(hash).set({deviceId:id,revokedAtMs:null});
 return {id,token,hash,session,secret,publish:{protocol:1,claimSessionId:session,claimSecretHash:claimHash(id,session,secret)},claim:{deviceId:id,claimSessionId:session,claimSecret:secret}};
}
const code=(expected)=>e=>e.code===expected;
test('device token is mandatory and Firebase token is not a device credential',async()=>{
 await assert.rejects(service.link('test-user'),code('UNAUTHENTICATED'));
 await assert.rejects(service.link('hvt_dev_'+randomBytes(32).toString('base64url')),code('UNAUTHENTICATED'));
});
test('unclaimed -> publish -> claim -> linked, without another BLE exchange',async()=>{
 const f=await fixture();assert.equal((await service.link(f.token)).state,'unclaimed');
 assert.equal((await service.publish(f.token,f.publish)).created,true);
 const bound=await service.claim('owner',f.claim);assert.equal(bound.state,'linked');
 assert.equal((await service.link(f.token)).bindingId,bound.bindingId);
});
test('same publication and claim are idempotent and do not extend expiration',async()=>{
 const f=await fixture();const first=await service.publish(f.token,f.publish),second=await service.publish(f.token,f.publish);
 assert.deepEqual(first.body,second.body);assert.equal(second.created,false);
 assert.deepEqual(await service.claim('owner',f.claim),await service.claim('owner',f.claim));
 await assert.rejects(service.publish(f.token,{...f.publish,claimSecretHash:'a'.repeat(64)}),code('IDEMPOTENCY_CONFLICT'));
});
test('public identity and wrong proof cannot claim ownership',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 await assert.rejects(service.claim('attacker',{...f.claim,claimSecret:randomBytes(32).toString('base64url')}),code('CLAIM_PROOF_INVALID'));
 assert.equal((await service.link(f.token)).state,'unclaimed');
});
test('claim arriving before publication can retry',async()=>{
 const f=await fixture();await assert.rejects(service.claim('owner',f.claim),code('CLAIM_NOT_READY'));
 await service.publish(f.token,f.publish);assert.equal((await service.claim('owner',f.claim)).state,'linked');
});
test('expired proof rejected; retry of an already consumed proof remains idempotent',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const future=new DeviceService(db,()=>Date.now()+1801000);
 await assert.rejects(future.claim('owner',f.claim),code('CLAIM_EXPIRED'));
 const g=await fixture();await service.publish(g.token,g.publish);const bound=await service.claim('owner',g.claim);
 assert.deepEqual(await future.claim('owner',g.claim),bound);
});
test('concurrent claims by different accounts have exactly one winner',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const outcomes=await Promise.allSettled([service.claim('account-a',f.claim),service.claim('account-b',f.claim)]);
 assert.equal(outcomes.filter(x=>x.status==='fulfilled').length,1);
 assert.equal(outcomes.find(x=>x.status==='rejected').reason.code,'DEVICE_ALREADY_LINKED');
});
test('new physical session invalidates old proof; linked device cannot be re-owned',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const next=randomUUID();await service.publish(f.token,{...f.publish,claimSessionId:next,claimSecretHash:claimHash(f.id,next,f.secret)});
 await assert.rejects(service.claim('owner',f.claim),code('CLAIM_SUPERSEDED'));
 await service.claim('owner',{...f.claim,claimSessionId:next});
 await assert.rejects(service.publish(f.token,{...f.publish,claimSessionId:randomUUID()}),code('DEVICE_ALREADY_LINKED'));
});
test('owner unlink is authenticated, idempotent, invalidates old proof, and creates a new binding for another account',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const first=await service.claim('account-a',f.claim);
 await assert.rejects(service.unlink('account-b',f.id,first.bindingId,randomUUID()),code('DEVICE_NOT_FOUND_OR_NOT_OWNED'));
 const unlinkRequest=randomUUID();
 const removed=await service.unlink('account-a',f.id,first.bindingId,unlinkRequest);
 assert.equal(removed.state,'unlinked');assert.equal(removed.previousBindingId,first.bindingId);
 assert.equal(removed.ownershipEpoch,1);
 assert.deepEqual(await service.unlink('account-a',f.id,first.bindingId,unlinkRequest),removed);
 assert.equal((await service.link(f.token)).state,'unclaimed');
 await assert.rejects(service.claim('account-a',f.claim),code('CLAIM_SUPERSEDED'));
 const nextSession=randomUUID(),nextSecret=randomBytes(32).toString('base64url');
 const nextProof={protocol:1,claimSessionId:nextSession,claimSecretHash:claimHash(f.id,nextSession,nextSecret)};
 await service.publish(f.token,nextProof);
 const next=await service.claim('account-b',{deviceId:f.id,claimSessionId:nextSession,claimSecret:nextSecret});
 assert.equal(next.state,'linked');assert.notEqual(next.bindingId,first.bindingId);
 assert.equal((await service.link(f.token)).bindingId,next.bindingId);
 const delayedRetry=await service.unlink('account-a',f.id,first.bindingId,unlinkRequest);
 assert.equal(delayedRetry.previousBindingId,first.bindingId);
 assert.equal((await service.link(f.token)).bindingId,next.bindingId);
 await assert.rejects(service.unlink('account-b',f.id,first.bindingId,randomUUID()),code('BINDING_CHANGED'));
});
test('a delayed unlink retry cannot remove a later binding for the same account',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const first=await service.claim('account-a',f.claim),requestId=randomUUID();
 await service.unlink('account-a',f.id,first.bindingId,requestId);
 const session=randomUUID(),secret=randomBytes(32).toString('base64url');
 await service.publish(f.token,{protocol:1,claimSessionId:session,claimSecretHash:claimHash(f.id,session,secret)});
 const second=await service.claim('account-a',{deviceId:f.id,claimSessionId:session,claimSecret:secret});
 assert.notEqual(second.bindingId,first.bindingId);
 const retry=await service.unlink('account-a',f.id,first.bindingId,requestId);
 assert.equal(retry.previousBindingId,first.bindingId);
 assert.equal((await service.link(f.token)).bindingId,second.bindingId);
});
test('operator recovery requires the exact binding and invalidates the old proof',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const first=await service.claim('account-a',f.claim);
 await assert.rejects(service.operatorRecoveryUnlink(f.id,randomUUID(),'CASE-2026'),code('BINDING_CHANGED'));
 const recovered=await service.operatorRecoveryUnlink(f.id,first.bindingId,'CASE-2026');
 assert.equal(recovered.state,'unlinked');assert.equal(recovered.ownershipEpoch,1);
 await assert.rejects(service.claim('account-a',f.claim),code('CLAIM_SUPERSEDED'));
 assert.equal((await service.link(f.token)).state,'unclaimed');
});
test('full account A -> unlink while board is offline -> fresh BLE proof -> account B',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const first=await service.claim('account-a',f.claim);
 // The board makes no request during unlink; the signed-in owner changes backend state.
 const unlinked=await service.unlink('account-a',f.id,first.bindingId,randomUUID());
 await assert.rejects(service.publish(f.token,f.publish),code('CLAIM_SUPERSEDED'));
 const offlineBoardState=await service.link(f.token); // Its first poll after reconnect sees this state.
 assert.equal(offlineBoardState.state,'unclaimed');
 assert.equal(offlineBoardState.ownershipEpoch,unlinked.ownershipEpoch);
 const nextSession=randomUUID(),nextSecret=randomBytes(32).toString('base64url');
 await service.publish(f.token,{protocol:1,claimSessionId:nextSession,claimSecretHash:claimHash(f.id,nextSession,nextSecret)});
 const second=await service.claim('account-b',{deviceId:f.id,claimSessionId:nextSession,claimSecret:nextSecret});
 assert.equal(second.state,'linked');assert.notEqual(second.bindingId,first.bindingId);
 assert.equal((await service.link(f.token)).bindingId,second.bindingId);
});
test('revocation blocks device access and pending user claim',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 await db.collection(collections.credentials).doc(f.hash).update({revokedAtMs:Date.now()});
 await assert.rejects(service.link(f.token),code('DEVICE_CREDENTIAL_REVOKED'));
 await assert.rejects(service.claim('owner',f.claim),code('FORBIDDEN'));
});
test('rate limit persists and recovers next minute',async()=>{
 const key=randomUUID(),now=Date.now(),limited=new DeviceService(db,()=>now);
 await limited.rate(key,1);await assert.rejects(limited.rate(key,1),code('RATE_LIMITED'));
 await new DeviceService(db,()=>now+60000).rate(key,1);
});
test('HTTP requires correct auth, rejects unknown fields, sanitizes errors',async()=>{
 let r=await fetch(base+'/v1/devices/claim',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});assert.equal(r.status,401);
 r=await fetch(base+'/v1/devices/claim',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer invalid'},body:'{}'});assert.equal(r.status,401);
 const f=await fixture();r=await fetch(base+'/v1/device/claim-sessions',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+f.token},body:JSON.stringify({...f.publish,deviceId:'forged'})});assert.equal(r.status,400);
 r=await fetch(base+'/v1/device/claim-sessions',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+f.token},body:JSON.stringify(f.publish)});assert.equal(r.status,201);assert.equal(r.headers.get('cache-control'),'no-store');
 r=await fetch(base+'/v1/devices/claim',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer test-user'},body:JSON.stringify(f.claim)});assert.equal(r.status,200);
 assert.ok(!(await r.text()).includes(f.secret));
});
test('HTTP lists only the authenticated account\'s active linked HAVIT devices',async()=>{
 const existing=await service.ownedDevices('user-test');
 const first=await fixture(),second=await fixture();
 await service.publish(first.token,first.publish);await service.claim('user-test',first.claim);
 await service.publish(second.token,second.publish);await service.claim('another-user',second.claim);
 const url=base+'/v1/user/devices';
 let r=await fetch(url);assert.equal(r.status,401);
 r=await fetch(url,{headers:{Authorization:'Bearer invalid'}});assert.equal(r.status,401);
 r=await fetch(url,{headers:{Authorization:'Bearer test-user'}});
 assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');
 const body=await r.json();assert.equal(body.devices.length,existing.devices.length+1);
 const added=body.devices.find(d=>d.deviceId===first.id);assert.ok(added);
 assert.ok(!body.devices.some(d=>d.deviceId===second.id));
 assert.equal(added.bindingId,(await db.collection(collections.devices).doc(first.id).get()).get('bindingId'));
 assert.ok(!JSON.stringify(body).includes(first.token));
});
test('HTTP unlink requires Firebase owner auth and an exact current binding',async()=>{
 const f=await fixture();await service.publish(f.token,f.publish);
 const receipt=await service.claim('user-test',f.claim);
 const url=base+'/v1/devices/'+f.id+'/unlink';
 let r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({bindingId:receipt.bindingId,requestId:randomUUID()})});
 assert.equal(r.status,401);
 r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer invalid'},body:JSON.stringify({bindingId:receipt.bindingId,requestId:randomUUID()})});
 assert.equal(r.status,401);
 r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer test-user'},body:JSON.stringify({bindingId:randomUUID(),requestId:randomUUID()})});
 assert.equal(r.status,409);assert.equal((await r.json()).error.code,'BINDING_CHANGED');
 r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer test-user'},body:JSON.stringify({bindingId:receipt.bindingId,requestId:randomUUID()})});
 assert.equal(r.status,200);assert.equal((await r.json()).state,'unlinked');
});
