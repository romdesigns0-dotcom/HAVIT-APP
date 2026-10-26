// Explicit opt-in integration test. Credentials stay in memory; fixtures are removed.
const assert=require('node:assert/strict');
const {readFileSync,mkdtempSync,existsSync,unlinkSync,rmdirSync}=require('node:fs');
const {tmpdir}=require('node:os');
const {execFileSync}=require('node:child_process');
const {randomBytes,randomUUID}=require('node:crypto');
const {resolve}=require('node:path');
const {initializeApp,applicationDefault,deleteApp}=require('firebase-admin/app');
const {getAuth}=require('firebase-admin/auth');
const {getFirestore}=require('firebase-admin/firestore');
const {collections,sha256,claimHash}=require('../lib/service.js');
let stage='initializing';
async function main(){
 const base=process.argv[2];if(!base?.startsWith('https://'))throw Error('Explicit deployed HTTPS URL required');
 const plist=readFileSync(resolve(__dirname,'../../../Sources/Havit/Resources/GoogleService-Info.plist'),'utf8');
 const apiKey=plist.match(/<key>API_KEY<\/key>\s*<string>([^<]+)<\/string>/)?.[1];if(!apiKey)throw Error('Firebase client config missing');
 const {app,db}=require('../lib/local-admin.js').localAdmin('havit-c8c1d',true);const auth=getAuth(app);
 const id='integration-'+randomUUID(),session=randomUUID(),secret=randomBytes(32).toString('base64url');
 const out=mkdtempSync(resolve(tmpdir(),'havit-registry-smoke-'));let token,hash;
 const sessionDoc=sha256(id+':'+session);const uids=[];
 async function call(path,method,credential,body){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(credential?{Authorization:'Bearer '+credential}:{})},...(body?{body:JSON.stringify(body)}:{})});return {status:r.status,body:await r.json()};}
 async function user(){
  const email='havit-integration-'+randomUUID()+'@example.invalid',password=randomBytes(32).toString('base64url');
  stage='create-firebase-user';const u=await auth.createUser({email,password});uids.push(u.uid);
  const r=await fetch('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+apiKey,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true})});
  const result=await r.json();stage='firebase-user-login-http-'+r.status;
  if(r.status!==200)console.log('Firebase login error code:',String(result.error?.message??'UNKNOWN').split(':')[0].replace(/[^A-Z_]/g,''));
  assert.equal(r.status,200,'Test user login failed');return result.idToken;
 }
 try{
  stage='register-device-cli';execFileSync(process.execPath,[resolve(__dirname,'../lib/register-device.js'),'--project','havit-c8c1d','--device-id',id,'--output-dir',out,'--api-base-url',base,'--use-gcloud-session'],{stdio:['ignore','pipe','pipe']});
  token=readFileSync(resolve(out,'identity.csv'),'utf8').match(/^device_token,data,string,(.+)$/m)[1];hash=sha256(token);
  console.log('PASS operator registration CLI -> unique credential file outside repository');
  const firebaseToken=await user(),otherToken=await user();
  assert.equal((await call('/v1/device/link','GET')).status,401);console.log('PASS missing device auth -> 401');
  const initial=await call('/v1/device/link','GET',token);assert.equal(initial.status,200);assert.equal(initial.body.state,'unclaimed');console.log('PASS own identity -> unclaimed');
  const publication={protocol:1,claimSessionId:session,claimSecretHash:claimHash(id,session,secret)};
  const published=await call('/v1/device/claim-sessions','POST',token,publication);assert.equal(published.status,201);console.log('PASS publish session -> 201');
  const repeated=await call('/v1/device/claim-sessions','POST',token,publication);assert.equal(repeated.status,200);assert.equal(repeated.body.expiresAt,published.body.expiresAt);console.log('PASS publish retry -> 200, fixed expiration');
  const claim={deviceId:id,claimSessionId:session,claimSecret:secret};
  const invalid=await call('/v1/devices/claim','POST',firebaseToken,{...claim,claimSecret:randomBytes(32).toString('base64url')});assert.equal(invalid.status,403);console.log('PASS wrong possession proof -> 403');
  const claimed=await call('/v1/devices/claim','POST',firebaseToken,claim);assert.equal(claimed.status,200);assert.equal(claimed.body.state,'linked');console.log('PASS Firebase user + proof -> linked');
  const retry=await call('/v1/devices/claim','POST',firebaseToken,claim);assert.deepEqual(retry.body,claimed.body);console.log('PASS claim retry -> same binding');
  const denied=await call('/v1/devices/claim','POST',otherToken,claim);assert.equal(denied.status,409);console.log('PASS second account -> 409');
  const linked=await call('/v1/device/link','GET',token);assert.equal(linked.body.bindingId,claimed.body.bindingId);console.log('PASS ESP32 polling -> linked');
  const direct=await fetch('https://firestore.googleapis.com/v1/projects/havit-c8c1d/databases/(default)/documents/'+collections.devices+'/'+id,{headers:{Authorization:'Bearer '+firebaseToken}});assert.equal(direct.status,403);console.log('PASS direct client Firestore access denied');
  stage='revoke-device-cli';execFileSync(process.execPath,[resolve(__dirname,'../lib/revoke-device.js'),'--project','havit-c8c1d','--device-id',id,'--use-gcloud-session'],{stdio:['ignore','pipe','pipe']});
  assert.equal((await call('/v1/device/link','GET',token)).status,401);console.log('PASS revoked device -> 401');
 }finally{
  for(const uid of uids){await auth.deleteUser(uid);await db.collection(collections.limits).doc(sha256('user:'+uid)).delete();}
  const registered=(await db.collection(collections.devices).doc(id).get()).data();
  await db.collection(collections.devices).doc(id).delete();if(registered?.credentialHash)await db.collection(collections.credentials).doc(registered.credentialHash).delete();
  await db.collection(collections.sessions).doc(sessionDoc).delete();await db.collection(collections.limits).doc(sha256('device:'+id)).delete();
  if(existsSync(resolve(out,'identity.csv')))unlinkSync(resolve(out,'identity.csv'));rmdirSync(out);
  await deleteApp(app);console.log('Temporary integration users, device records and credential file removed');
 }
}
main().catch(e=>{console.error('Live integration failed:',JSON.stringify({stage,kind:e?.constructor?.name,code:String(e?.code??'').replace(/[^A-Za-z0-9_/-]/g,'')}));process.exitCode=1;});
