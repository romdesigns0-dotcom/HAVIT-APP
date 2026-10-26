import {createHash,createCipheriv,createDecipheriv,randomBytes} from 'node:crypto';
import {Firestore} from 'firebase-admin/firestore';
import {ApiError,validDeviceId} from './service.js';
import {TaskService,RelayActor} from './tasks.js';

// The credential hash is private server data. It never leaves Firestore or the
// device. Domain separation prevents reusing the key for another protocol.
export function relayKey(hash:string){return createHash('sha256').update('havit-relay-v1:'+hash).digest();}
export function relayAAD(direction:string,e:Record<string,unknown>){return Buffer.from(`havit-relay-v1|${direction}|${e.deviceId}|${e.bindingId}|${e.nonce}`);}
export async function relayTasks(db:Firestore,tasks:TaskService,uid:string,input:unknown){
  const e=input as Record<string,unknown>;
  if(!e||typeof e!=='object'||Array.isArray(e)||Object.keys(e).sort().join()!=='bindingId,data,deviceId,iv,nonce,protocol,tag'||e.protocol!==1||
    !validDeviceId(e.deviceId)||typeof e.bindingId!=='string'||!/^[a-f0-9-]{36}$/.test(e.bindingId)||
    typeof e.nonce!=='string'||!/^[a-f0-9]{64}$/.test(e.nonce)||typeof e.iv!=='string'||!/^[a-f0-9]{24}$/.test(e.iv)||
    typeof e.tag!=='string'||!/^[a-f0-9]{32}$/.test(e.tag)||typeof e.data!=='string'||e.data.length>270000)throw new ApiError(400,'INVALID_RELAY');
  const d=(await db.collection('havitV1Devices').doc(e.deviceId).get()).data();
  if(!d?.active||d.ownerUid!==uid||d.bindingId!==e.bindingId)throw new ApiError(403,'BINDING_CHANGED');
  if(typeof d.credentialHash!=='string'||!/^[a-f0-9]{64}$/.test(d.credentialHash))throw new ApiError(401,'DEVICE_CREDENTIAL_REVOKED');
  const key=relayKey(d.credentialHash);
  let body:{protocol:number;pending:Record<string,unknown>[]};
  try{
    const ciphertext=Buffer.from(e.data,'base64');
    if(ciphertext.toString('base64')!==e.data||ciphertext.length>196608)throw Error();
    const decipher=createDecipheriv('aes-256-gcm',key,Buffer.from(e.iv,'hex'));
    decipher.setAAD(relayAAD('request',e));decipher.setAuthTag(Buffer.from(e.tag,'hex'));
    body=JSON.parse(Buffer.concat([decipher.update(ciphertext),decipher.final()]).toString('utf8'));
  }catch{throw new ApiError(403,'INVALID_RELAY_PROOF');}
  if(!body||body.protocol!==1||!Array.isArray(body.pending)||body.pending.length>32)throw new ApiError(400,'INVALID_RELAY');
  if(typeof d.factoryResetRequestId==='string'&&d.factoryResetOwnerUid===uid&&d.factoryResetBindingId===e.bindingId){
    const resetBody={protocol:1,factoryReset:{requestId:d.factoryResetRequestId}};
    const resetIv=randomBytes(12),resetCipher=createCipheriv('aes-256-gcm',key,resetIv);
    resetCipher.setAAD(relayAAD('response',e));
    const resetData=Buffer.concat([resetCipher.update(JSON.stringify(resetBody)),resetCipher.final()]);
    return {protocol:1,deviceId:e.deviceId,bindingId:e.bindingId,nonce:e.nonce,iv:resetIv.toString('hex'),
      tag:resetCipher.getAuthTag().toString('hex'),data:resetData.toString('base64'),factoryResetRequestId:d.factoryResetRequestId};
  }
  const actor:RelayActor={relay:{uid,deviceId:e.deviceId,bindingId:e.bindingId,credentialHash:d.credentialHash}};
  const ackEventIds:string[]=[],conflictEventIds:string[]=[];
  for(const event of body.pending){
    if(event.problem)continue;
    if(event.bindingId!==e.bindingId||typeof event.eventId!=='string')throw new ApiError(400,'INVALID_RELAY');
    const {bindingId,eventId,...mutation}=event;
    try{await tasks.mutate(actor,{...mutation,operationId:eventId});ackEventIds.push(eventId);}
    catch(error){
      if(error instanceof ApiError&&['TASK_VERSION_CONFLICT','TASK_LIMIT_REACHED','INVALID_TASK','INVALID_DUE_DATE'].includes(error.code))conflictEventIds.push(eventId);
      else throw error;
    }
  }
  // Transactional scope revalidation prevents an unlink during event processing
  // from yielding a snapshot for a former owner.
  const snapshot=await tasks.snapshot(actor);
  const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv);
  cipher.setAAD(relayAAD('response',e));
  const ciphertext=Buffer.concat([cipher.update(JSON.stringify({protocol:1,snapshot,ackEventIds,conflictEventIds})),cipher.final()]);
  if(ciphertext.length>196608)throw new ApiError(503,'RELAY_CAPACITY_EXCEEDED');
  return {protocol:1,deviceId:e.deviceId,bindingId:e.bindingId,nonce:e.nonce,iv:iv.toString('hex'),tag:cipher.getAuthTag().toString('hex'),data:ciphertext.toString('base64')};
}
