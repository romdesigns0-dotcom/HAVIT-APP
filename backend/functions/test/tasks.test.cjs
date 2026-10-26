const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {randomUUID,randomBytes}=require('node:crypto');
const {initializeApp,deleteApp}=require('firebase-admin/app');
const {getFirestore}=require('firebase-admin/firestore');
const {DeviceService,sha256}=require('../lib/service');
const {createApp}=require('../lib/app');
let db,app,service,server,base;
before(async()=>{
 assert.ok(process.env.FIRESTORE_EMULATOR_HOST,'Emulator required');
 app=initializeApp({projectId:'demo-havit-device'},'tasks');db=getFirestore(app);service=new DeviceService(db);
 server=createApp(service,async t=>{if(t==='alice')return 'http-alice';throw Error('unauthenticated')}).listen(0,'127.0.0.1');
 await new Promise(r=>server.once('listening',r));base='http://127.0.0.1:'+server.address().port;
});
after(async()=>{await new Promise(r=>server.close(r));await deleteApp(app)});
const field=(title='Actividad',dueAt=null)=>({title,detail:'Leer y preparar entrega',dueAt,status:'pending'});
const create=(task=field())=>({operationId:randomUUID(),taskId:randomUUID(),baseTaskVersion:0,kind:'create',task});
const code=c=>e=>e.code===c;
async function device(uid){const id='tasks-'+randomUUID(),token='hvt_dev_'+randomBytes(32).toString('base64url'),bindingId=randomUUID(),hash=sha256(token);
 await db.collection('havitV1Devices').doc(id).set({active:true,credentialHash:hash,ownerUid:uid,bindingId});
 await db.collection('havitV1DeviceCredentials').doc(hash).set({deviceId:id,revokedAtMs:null});return {id,token,bindingId};}
test('same account shares tasks with its device; another account cannot read or alter them',async()=>{
 const uid=randomUUID(),d=await device(uid),m=create();await service.tasks.mutate({uid},m);
 const own=await service.tasks.snapshot({token:d.token,bindingId:d.bindingId});assert.equal(own.tasks[0].id,m.taskId);
 assert.equal((await service.tasks.snapshot({uid:randomUUID()})).tasks.length,0);
 await assert.rejects(service.tasks.mutate({uid:randomUUID()},{...m,kind:'update',baseTaskVersion:1,operationId:randomUUID()}),code('TASK_VERSION_CONFLICT'));
});
test('writes deduplicate across lost responses and reject reusing an operation for different content',async()=>{
 const uid=randomUUID(),m=create(),a=await service.tasks.mutate({uid},m);assert.deepEqual(await service.tasks.mutate({uid},m),a);
 await assert.rejects(service.tasks.mutate({uid},{...m,task:field('Otra')}),code('IDEMPOTENCY_CONFLICT'));
 assert.equal((await service.tasks.snapshot({uid})).revision,1);
});
test('concurrent edits have exactly one winner; stale delete cannot erase the winner',async()=>{
 const uid=randomUUID(),m=create();await service.tasks.mutate({uid},m);
 const update=()=>({...m,kind:'update',baseTaskVersion:1,operationId:randomUUID()});
 const results=await Promise.allSettled([service.tasks.mutate({uid},update()),service.tasks.mutate({uid},update())]);
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 await assert.rejects(service.tasks.mutate({uid},{operationId:randomUUID(),taskId:m.taskId,baseTaskVersion:1,kind:'delete'}),code('TASK_VERSION_CONFLICT'));
});
test('deletion disappears from full snapshot and stale updates cannot resurrect it',async()=>{
 const uid=randomUUID(),m=create();await service.tasks.mutate({uid},m);
 const del={operationId:randomUUID(),taskId:m.taskId,baseTaskVersion:1,kind:'delete'};
 await service.tasks.mutate({uid},del);assert.equal((await service.tasks.snapshot({uid})).tasks.length,0);
 await assert.rejects(service.tasks.mutate({uid},{...m,operationId:randomUUID()}),code('TASK_VERSION_CONFLICT'));
 assert.equal((await service.tasks.mutate({uid},del)).revision,2);
});
test('old device binding cannot replay an event or read tasks after unlink and transfer',async()=>{
 const uid=randomUUID(),d=await device(uid),actor={token:d.token,bindingId:d.bindingId},m=create();
 await service.tasks.mutate(actor,m);await service.unlink(uid,d.id,d.bindingId,randomUUID());
 await assert.rejects(service.tasks.mutate(actor,m),code('DEVICE_NOT_LINKED'));
 const next=randomUUID(),nextUID=randomUUID();await db.collection('havitV1Devices').doc(d.id).update({ownerUid:nextUID,bindingId:next});
 await assert.rejects(service.tasks.snapshot(actor),code('BINDING_CHANGED'));
 assert.equal((await service.tasks.snapshot({token:d.token,bindingId:next})).tasks.length,0);
});
test('date validation, UTF-8 size and bounded device snapshot capacity',async()=>{
 const uid=randomUUID();await assert.rejects(service.tasks.mutate({uid},create(field('a','bad'))),code('INVALID_DUE_DATE'));
 await assert.rejects(service.tasks.mutate({uid},create(field('a','2026-02-30T12:00:00Z'))),code('INVALID_DUE_DATE'));
 await assert.rejects(service.tasks.mutate({uid},create(field('á'.repeat(81)))),code('INVALID_TASK'));
 await db.collection('havitV1Accounts').doc(uid).set({taskCount:64});
 await assert.rejects(service.tasks.mutate({uid},create()),code('TASK_LIMIT_REACHED'));
});
test('snapshot sorts actual due dates and calculates local day independently of UTC date',async()=>{
 const uid=randomUUID();const svc=new DeviceService(db,()=>Date.parse('2026-10-23T02:00:00Z'));
 await svc.tasks.preferences(uid,{timeZone:'America/Mexico_City'});
 for(const due of [null,'2026-11-01T12:00:00Z','2026-10-23T12:00:00Z'])await svc.tasks.mutate({uid},create(field('Entrega',due)));
 const s=await svc.tasks.snapshot({uid});assert.equal(s.localDate,'2026-10-22');assert.equal(s.utcOffsetSeconds,-21600);
 assert.equal(s.tasks[0].dueAt,'2026-10-23T12:00:00.000Z');assert.equal(s.tasks[2].dueAt,null);
 await svc.tasks.preferences(uid,{timeZone:'America/New_York'});
 const ny=await svc.tasks.snapshot({uid});
 const offsetAt=date=>ny.utcOffsetTransitions.filter(t=>t.at<=Date.parse(date)/1000).at(-1).offset;
 assert.equal(offsetAt('2026-07-01T12:00:00Z'),-14400);
 assert.equal(offsetAt('2026-12-01T12:00:00Z'),-18000);
 await assert.rejects(svc.tasks.preferences(uid,{timeZone:'invalid/zone'}),code('INVALID_TIME_ZONE'));
});
test('HTTP routes enforce user/device auth and use matching payloads for create update delete',async()=>{
 assert.equal((await fetch(base+'/v1/tasks')).status,401);
 const headers={Authorization:'Bearer alice','Content-Type':'application/json'},m=create();
 const body={operationId:m.operationId,taskId:m.taskId,baseTaskVersion:0,task:m.task};
 assert.equal((await fetch(base+'/v1/tasks',{method:'POST',headers,body:JSON.stringify(body)})).status,200);
 const updated=await fetch(base+'/v1/tasks/'+m.taskId,{method:'PATCH',headers,body:JSON.stringify({operationId:randomUUID(),baseTaskVersion:1,task:{...m.task,status:'completed'}})});
 assert.equal(updated.status,200);assert.equal((await updated.json()).task.status,'completed');
 assert.equal((await fetch(base+'/v1/tasks/'+m.taskId,{method:'DELETE',headers,body:JSON.stringify({operationId:randomUUID(),baseTaskVersion:2})})).status,200);
 assert.equal((await fetch(base+'/v1/device/events',{method:'POST',headers,body:'{}'})).status,401);
});
