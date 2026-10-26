// Local operator diagnostic. Reads an opaque envelope from stdin, verifies the
// registered device owner in Firestore, and returns only the encrypted reply.
// This is not an HTTP route and does not create or impersonate a Firebase login.
const {localAdmin}=require('../functions/lib/local-admin');
const {DeviceService}=require('../functions/lib/service');
const localRequire=require('node:module').createRequire(require('node:path').resolve(__dirname,'../functions/package.json'));
const {deleteApp}=localRequire('firebase-admin/app');
(async()=>{
 let raw='';for await(const part of process.stdin)raw+=part;
 const envelope=JSON.parse(raw);
 const [deviceId,bindingId,projectId='havit-c8c1d']=process.argv.slice(2);
 if(!deviceId||!bindingId)throw Error('Usage: node probe_relay.cjs <device-id> <binding-id> [firebase-project-id]');
 if(envelope.deviceId!==deviceId||envelope.bindingId!==bindingId)throw Error('Device identity or binding differs from the explicit operator selection');
 const {app,db}=localAdmin(projectId,true);
 try{const d=(await db.collection('havitV1Devices').doc(envelope.deviceId).get()).data();
 if(!d?.ownerUid||d.bindingId!==envelope.bindingId)throw Error('Owner or binding differs');
 const result=await new DeviceService(db).relay(d.ownerUid,envelope);process.stdout.write(JSON.stringify(result));
 }finally{await deleteApp(app)}
})().catch(()=>{console.error('Relay diagnostic failed; private output suppressed');process.exitCode=1});
