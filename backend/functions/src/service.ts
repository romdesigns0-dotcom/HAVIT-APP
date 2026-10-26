import {createHash, createDecipheriv, randomUUID, timingSafeEqual} from "node:crypto";
import {Firestore, Transaction, FieldValue} from "firebase-admin/firestore";
import {TaskService} from "./tasks.js";
import {relayAAD, relayKey, relayTasks} from "./relay.js";

export const collections = {devices:"havitV1Devices", credentials:"havitV1DeviceCredentials", sessions:"havitV1ClaimSessions", limits:"havitV1RateLimits", ownershipEvents:"havitV1OwnershipEvents"};
export class ApiError extends Error {
  constructor(public status: number, public code: string, public retryAfterSeconds?: number) { super(code); }
}
export const sha256 = (text: string | Buffer) => createHash("sha256").update(text).digest("hex");
export const validDeviceId = (id: unknown): id is string => typeof id === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{2,95}$/.test(id);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hex = /^[a-f0-9]{64}$/;
export function claimHash(deviceId: string, sessionId: string, secret: string): string {
  const raw = Buffer.from(secret, "base64url");
  if (raw.length !== 32 || raw.toString("base64url") !== secret) throw new ApiError(400,"INVALID_REQUEST");
  return createHash("sha256").update("havit-claim-v1:").update(deviceId).update(Buffer.from([0]))
    .update(sessionId).update(Buffer.from([0])).update(raw).digest("hex");
}
function sameHash(a: string, b: string) { return hex.test(a) && hex.test(b) && timingSafeEqual(Buffer.from(a,"hex"),Buffer.from(b,"hex")); }
function shape(value: unknown, fields: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ApiError(400,"INVALID_REQUEST");
  const obj = value as Record<string,unknown>;
  if (Object.keys(obj).length !== fields.length || fields.some(k=>!(k in obj))) throw new ApiError(400,"INVALID_REQUEST");
  return obj;
}

export class DeviceService {
  async relay(uid:string,input:unknown){return relayTasks(this.db,this.tasks,uid,input);}
  readonly tasks: TaskService;
  constructor(private db: Firestore, private now = () => Date.now()) {
    this.tasks=new TaskService(db,(tx,token)=>this.device(tx,token),now);
  }
  private sessionRef(deviceId: string, sessionId: string) { return this.db.collection(collections.sessions).doc(sha256(deviceId+":"+sessionId)); }
  private async device(tx: Transaction, token: string) {
    if (!/^hvt_dev_[A-Za-z0-9_-]{43}$/.test(token)) throw new ApiError(401,"UNAUTHENTICATED");
    const hash = sha256(token);
    const credential = await tx.get(this.db.collection(collections.credentials).doc(hash));
    if (!credential.exists) throw new ApiError(401,"UNAUTHENTICATED");
    const c = credential.data()!;
    if (c.revokedAtMs != null) throw new ApiError(401,"DEVICE_CREDENTIAL_REVOKED");
    if (!validDeviceId(c.deviceId)) throw new ApiError(401,"UNAUTHENTICATED");
    const ref = this.db.collection(collections.devices).doc(c.deviceId);
    const d = (await tx.get(ref)).data();
    if (!d || !d.active || d.credentialHash !== hash) throw new ApiError(401,"DEVICE_CREDENTIAL_REVOKED");
    return {id:c.deviceId, data:d, ref};
  }
  async authenticateDevice(token: string): Promise<string> {
    return this.db.runTransaction(async tx=>(await this.device(tx,token)).id);
  }
  async deviceSync(token: string, bindingId: string) {
    const deviceId = await this.authenticateDevice(token);
    const snapshot = await this.tasks.snapshot({token,bindingId});
    const ref = this.db.collection(collections.devices).doc(deviceId);
    const device = (await ref.get()).data();
    const factoryResetRequestId = device?.active && device.ownerUid === snapshot.uid &&
      device.bindingId === bindingId && device.factoryResetOwnerUid === snapshot.uid &&
      device.factoryResetBindingId === bindingId && typeof device.factoryResetRequestId === "string"
      ? device.factoryResetRequestId : null;
    return {...snapshot,factoryResetRequestId};
  }
  async completeFactoryResetFromDevice(token: string, bindingId: string, requestId: string) {
    if (!uuid.test(bindingId) || !uuid.test(requestId)) throw new ApiError(400,"INVALID_REQUEST");
    const eventRef = this.db.collection(collections.ownershipEvents).doc(randomUUID());
    const state = await this.db.runTransaction(async tx=>{
      const device = await this.device(tx,token), d = device.data;
      if (d.lastFactoryResetRequestId === requestId && d.lastFactoryResetBindingId === bindingId) {
        const uid = d.lastFactoryResetOwnerUid;
        const account = typeof uid === "string" ? (await tx.get(this.db.collection("havitV1Accounts").doc(uid))).data() ?? {} : {};
        return {already:true,uid,revision:Number(account.revision ?? 0)};
      }
      if (!d.active || !d.ownerUid || d.bindingId !== bindingId || d.factoryResetOwnerUid !== d.ownerUid ||
          d.factoryResetBindingId !== bindingId || d.factoryResetRequestId !== requestId)
        throw new ApiError(409,"FACTORY_RESET_NOT_PENDING");
      const uid = d.ownerUid;
      const accountRef = this.db.collection("havitV1Accounts").doc(uid);
      const account = (await tx.get(accountRef)).data() ?? {};
      const pendingId = typeof d.pendingSessionId === "string" ? d.pendingSessionId : null;
      const pendingRef = pendingId ? this.sessionRef(device.id,pendingId) : null;
      const pending = pendingRef ? await tx.get(pendingRef) : null;
      const at = this.now(), epoch = Number(d.ownershipEpoch ?? 0) + 1, revision = Number(account.revision ?? 0) + 1;
      tx.update(device.ref,{ownerUid:null,bindingId:null,linkedAtMs:null,pendingSessionId:null,ownershipEpoch:epoch,
        factoryResetRequestId:null,factoryResetOwnerUid:null,factoryResetBindingId:null,
        lastFactoryResetRequestId:requestId,lastFactoryResetOwnerUid:uid,lastFactoryResetBindingId:bindingId,lastFactoryResetAtMs:at});
      if (pendingRef && pending?.exists) tx.update(pendingRef,{invalidatedAtMs:at,invalidatedReason:"factory_reset"});
      tx.set(accountRef,{factoryResetInProgress:true,revision},{merge:true});
      tx.create(eventRef,{deviceId:device.id,action:"owner_factory_reset_wifi",ownerUid:uid,previousBindingId:bindingId,
        ownershipEpoch:epoch,requestId,createdAtMs:at,source:"device_wifi"});
      return {already:false,uid,revision};
    });
    if (typeof state.uid === "string") await this.purgeAccountTaskData(state.uid,state.revision);
    return {deviceId:await this.authenticateDevice(token),requestId,state:"completed"};
  }
  async ownedDevices(uid: string) {
    const snapshot=await this.db.collection(collections.devices).where("ownerUid","==",uid).get();
    const devices=snapshot.docs.flatMap(doc=>{
      const d=doc.data();
      if(!d.active || typeof d.bindingId!=="string" || !d.bindingId || typeof d.linkedAtMs!=="number") return [];
      return [{deviceId:doc.id,bindingId:d.bindingId,linkedAt:new Date(d.linkedAtMs).toISOString()}];
    });
    return {devices};
  }
  async rate(key: string, maximum: number) {
    const minute = Math.floor(this.now()/60000);
    const ref = this.db.collection(collections.limits).doc(sha256(key));
    await this.db.runTransaction(async tx=>{
      const old = (await tx.get(ref)).data();
      const count = old?.minute === minute ? old.count : 0;
      if (count >= maximum) throw new ApiError(429,"RATE_LIMITED",60);
      tx.set(ref,{minute,count:count+1});
    });
  }
  async publish(token: string, input: unknown) {
    const b = shape(input,["claimSessionId","claimSecretHash","protocol"]);
    if (b.protocol !== 1 || typeof b.claimSessionId !== "string" || !uuid.test(b.claimSessionId) || typeof b.claimSecretHash !== "string" || !hex.test(b.claimSecretHash)) throw new ApiError(400,"INVALID_REQUEST");
    const sessionId = b.claimSessionId as string, digest = b.claimSecretHash as string;
    return this.db.runTransaction(async tx=>{
      const d = await this.device(tx,token);
      const sessionRef = this.sessionRef(d.id,sessionId);
      const session = (await tx.get(sessionRef)).data();
      if (session) {
        const ownershipEpoch = Number(d.data.ownershipEpoch ?? 0);
        if (Number(session.ownershipEpoch ?? 0) !== ownershipEpoch) throw new ApiError(409,"CLAIM_SUPERSEDED");
        if (!sameHash(session.claimSecretHash,digest)) throw new ApiError(409,"IDEMPOTENCY_CONFLICT");
        if (session.consumedBy) return {created:false, body:{claimSessionId:sessionId,deviceId:d.id,state:"linked",expiresAt:new Date(session.expiresAtMs).toISOString()}};
        if (session.expiresAtMs <= this.now()) throw new ApiError(410,"CLAIM_EXPIRED");
        if (d.data.ownerUid) throw new ApiError(409,"DEVICE_ALREADY_LINKED");
        if (d.data.pendingSessionId !== sessionId) throw new ApiError(409,"CLAIM_SUPERSEDED");
        return {created:false, body:{claimSessionId:sessionId,deviceId:d.id,state:"pending",expiresAt:new Date(session.expiresAtMs).toISOString()}};
      }
      if (d.data.ownerUid) throw new ApiError(409,"DEVICE_ALREADY_LINKED");
      const createdAtMs = this.now(), expiresAtMs = createdAtMs+1800000;
      tx.create(sessionRef,{deviceId:d.id,sessionId,claimSecretHash:digest,createdAtMs,expiresAtMs,consumedBy:null,ownershipEpoch:Number(d.data.ownershipEpoch ?? 0)});
      tx.update(d.ref,{pendingSessionId:sessionId});
      return {created:true,body:{claimSessionId:sessionId,deviceId:d.id,state:"pending",expiresAt:new Date(expiresAtMs).toISOString()}};
    });
  }
  async claim(uid: string, input: unknown) {
    const b = shape(input,["deviceId","claimSessionId","claimSecret"]);
    if (!validDeviceId(b.deviceId) || typeof b.claimSessionId !== "string" || !uuid.test(b.claimSessionId) || typeof b.claimSecret !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(b.claimSecret)) throw new ApiError(400,"INVALID_REQUEST");
    const id = b.deviceId, sessionId = b.claimSessionId;
    const digest = claimHash(id,sessionId,b.claimSecret);
    const bindingId = randomUUID();
    const ownershipEventRef = this.db.collection(collections.ownershipEvents).doc(randomUUID());
    return this.db.runTransaction(async tx=>{
      const ref = this.db.collection(collections.devices).doc(id);
      const d = (await tx.get(ref)).data();
      if (!d) throw new ApiError(409,"CLAIM_NOT_READY",5);
      const credential = (await tx.get(this.db.collection(collections.credentials).doc(d.credentialHash))).data();
      if (!d.active || !credential || credential.revokedAtMs != null || credential.deviceId !== id) throw new ApiError(403,"FORBIDDEN");
      const sessionRef = this.sessionRef(id,sessionId);
      const session = (await tx.get(sessionRef)).data();
      if (!session) throw new ApiError(409,"CLAIM_NOT_READY",5);
      if (Number(session.ownershipEpoch ?? 0) !== Number(d.ownershipEpoch ?? 0)) throw new ApiError(409,"CLAIM_SUPERSEDED");
      if (!sameHash(session.claimSecretHash,digest)) throw new ApiError(403,"CLAIM_PROOF_INVALID");
      if (session.consumedBy === uid && d.ownerUid === uid && session.bindingId === d.bindingId) return {deviceId:id,state:"linked",bindingId:d.bindingId,linkedAt:new Date(d.linkedAtMs).toISOString()};
      if (d.ownerUid || session.consumedBy) throw new ApiError(409,"DEVICE_ALREADY_LINKED");
      if (session.expiresAtMs <= this.now()) throw new ApiError(410,"CLAIM_EXPIRED");
      if (d.pendingSessionId !== sessionId) throw new ApiError(409,"CLAIM_SUPERSEDED");
      const linkedAtMs = this.now();
      tx.update(ref,{ownerUid:uid,bindingId,linkedAtMs,pendingSessionId:null,
        factoryResetRequestId:null,factoryResetOwnerUid:null,factoryResetBindingId:null});
      tx.update(sessionRef,{consumedBy:uid,bindingId,consumedAtMs:linkedAtMs});
      tx.create(ownershipEventRef,{deviceId:id,action:"linked",ownerUid:uid,bindingId,
        ownershipEpoch:Number(d.ownershipEpoch ?? 0),claimSessionId:sessionId,createdAtMs:linkedAtMs});
      return {deviceId:id,state:"linked",bindingId,linkedAt:new Date(linkedAtMs).toISOString()};
    });
  }
  async unlink(uid: string, deviceId: string, expectedBindingId: string, requestId: string) {
    if (!validDeviceId(deviceId) || typeof expectedBindingId !== "string" || !uuid.test(expectedBindingId) ||
        typeof requestId !== "string" || !uuid.test(requestId))
      throw new ApiError(400,"INVALID_REQUEST");
    const ref=this.db.collection(collections.devices).doc(deviceId);
    const ownershipEventRef=this.db.collection(collections.ownershipEvents).doc(randomUUID());
    return this.db.runTransaction(async tx=>{
      const d=(await tx.get(ref)).data();
      if(!d || !d.active) throw new ApiError(404,"DEVICE_NOT_FOUND_OR_NOT_OWNED");
      // A lost unlink response can be retried after a new account claims the device.
      // Return that historical result to the former owner without touching the new binding.
      if(d.lastUnlinkOwnerUid===uid && d.lastUnlinkRequestId===requestId && d.lastUnlinkBindingId===expectedBindingId) {
        const unlinkedAtMs=Number(d.lastUnlinkedAtMs ?? this.now());
        return {deviceId,state:"unlinked",previousBindingId:expectedBindingId,ownershipEpoch:Number(d.ownershipEpoch ?? 0),
          unlinkedAt:new Date(unlinkedAtMs).toISOString()};
      }
      if(d.ownerUid === uid && d.bindingId === expectedBindingId) {
        const previousBindingId=expectedBindingId;
        const ownershipEpoch=Number(d.ownershipEpoch ?? 0)+1;
        const unlinkedAtMs=this.now();
        const pendingId=typeof d.pendingSessionId === "string" ? d.pendingSessionId : null;
        const pendingRef=pendingId ? this.sessionRef(deviceId,pendingId) : null;
        const pending=pendingRef ? await tx.get(pendingRef) : null;
        tx.update(ref,{ownerUid:null,bindingId:null,linkedAtMs:null,pendingSessionId:null,
          ownershipEpoch, lastUnlinkRequestId:requestId,lastUnlinkOwnerUid:uid,
          lastUnlinkBindingId:previousBindingId,lastUnlinkedAtMs:unlinkedAtMs});
        if(pendingRef && pending?.exists) tx.update(pendingRef,{invalidatedAtMs:unlinkedAtMs,invalidatedReason:"owner_unlinked"});
        tx.create(ownershipEventRef,{deviceId,action:"owner_unlinked",ownerUid:uid,previousBindingId,
          ownershipEpoch,source:"account",createdAtMs:unlinkedAtMs});
        return {deviceId,state:"unlinked",previousBindingId,ownershipEpoch,unlinkedAt:new Date(unlinkedAtMs).toISOString()};
      }
      if(d.ownerUid === uid) throw new ApiError(409,"BINDING_CHANGED");
      throw new ApiError(404,"DEVICE_NOT_FOUND_OR_NOT_OWNED");
    });
  }
  async requestFactoryReset(uid:string,deviceId:string,bindingId:string,requestId:string){
    if(!validDeviceId(deviceId)||!uuid.test(bindingId)||!uuid.test(requestId))throw new ApiError(400,"INVALID_REQUEST");
    const ref=this.db.collection(collections.devices).doc(deviceId);
    return this.db.runTransaction(async tx=>{
      const d=(await tx.get(ref)).data();
      if(!d?.active||d.ownerUid!==uid||d.bindingId!==bindingId)throw new ApiError(404,"DEVICE_NOT_FOUND_OR_NOT_OWNED");
      const pending=d.factoryResetRequestId;
      if(pending&&pending!==requestId)throw new ApiError(409,"FACTORY_RESET_PENDING");
      if(d.lastFactoryResetRequestId===requestId)return {deviceId,requestId,state:"completed"};
      if(!pending)tx.update(ref,{factoryResetRequestId:requestId,factoryResetOwnerUid:uid,factoryResetBindingId:bindingId,factoryResetRequestedAtMs:this.now()});
      return {deviceId,requestId,state:"pending"};
    });
  }
  async factoryResetStatus(uid:string,deviceId:string,bindingId:string,requestId:string){
    if(!validDeviceId(deviceId)||!uuid.test(bindingId)||!uuid.test(requestId))throw new ApiError(400,"INVALID_REQUEST");
    const d=(await this.db.collection(collections.devices).doc(deviceId).get()).data();
    if(d?.lastFactoryResetRequestId===requestId&&d.lastFactoryResetOwnerUid===uid){
      const account=await this.db.collection("havitV1Accounts").doc(uid).get();
      return {deviceId,requestId,state:account.get("factoryResetInProgress")===true?"pending":"completed"};
    }
    if(d?.active&&d.ownerUid===uid&&d.bindingId===bindingId&&d.factoryResetOwnerUid===uid&&
       d.factoryResetBindingId===bindingId&&d.factoryResetRequestId===requestId)return {deviceId,requestId,state:"pending"};
    throw new ApiError(404,"FACTORY_RESET_NOT_FOUND");
  }
  async completeFactoryReset(uid:string,deviceId:string,bindingId:string,requestId:string,proof:unknown){
    if(!validDeviceId(deviceId)||!uuid.test(bindingId)||!uuid.test(requestId))throw new ApiError(400,"INVALID_REQUEST");
    if(!proof||typeof proof!=="object"||Array.isArray(proof))throw new ApiError(400,"INVALID_FACTORY_RESET_PROOF");
    const envelope=proof as Record<string,unknown>;
    if(Object.keys(envelope).sort().join()!=="bindingId,data,deviceId,iv,nonce,protocol,tag"||envelope.protocol!==1||
       envelope.deviceId!==deviceId||envelope.bindingId!==bindingId||typeof envelope.nonce!=="string"||!/^[a-f0-9]{64}$/.test(envelope.nonce)||
       typeof envelope.iv!=="string"||!/^[a-f0-9]{24}$/.test(envelope.iv)||typeof envelope.tag!=="string"||!/^[a-f0-9]{32}$/.test(envelope.tag)||
       typeof envelope.data!=="string"||envelope.data.length>4096)throw new ApiError(403,"INVALID_FACTORY_RESET_PROOF");
    const initial=(await this.db.collection(collections.devices).doc(deviceId).get()).data();
    if(initial?.lastFactoryResetRequestId===requestId&&initial.lastFactoryResetOwnerUid===uid){
      const accountRef=this.db.collection("havitV1Accounts").doc(uid),account=await accountRef.get();
      if(account.get("factoryResetInProgress")===true)
        await this.purgeAccountTaskData(uid,Number(account.get("revision")??0));
      return {deviceId,requestId,state:"completed"};
    }
    if(!initial?.active||initial.ownerUid!==uid||initial.bindingId!==bindingId||initial.factoryResetOwnerUid!==uid||
       initial.factoryResetBindingId!==bindingId||initial.factoryResetRequestId!==requestId||typeof initial.credentialHash!=="string"||!hex.test(initial.credentialHash))
      throw new ApiError(409,"FACTORY_RESET_NOT_CONFIRMED");
    try{
      const ciphertext=Buffer.from(envelope.data,"base64");
      if(ciphertext.toString("base64")!==envelope.data||ciphertext.length>2048)throw Error();
      const decipher=createDecipheriv("aes-256-gcm",relayKey(initial.credentialHash),Buffer.from(envelope.iv,"hex"));
      decipher.setAAD(relayAAD("request",envelope));decipher.setAuthTag(Buffer.from(envelope.tag,"hex"));
      const body=JSON.parse(Buffer.concat([decipher.update(ciphertext),decipher.final()]).toString("utf8"));
      if(!body||body.protocol!==1||body.factoryResetAck!==requestId||Object.keys(body).sort().join()!=="factoryResetAck,protocol")throw Error();
    }catch{throw new ApiError(403,"INVALID_FACTORY_RESET_PROOF");}
    const ref=this.db.collection(collections.devices).doc(deviceId),eventRef=this.db.collection(collections.ownershipEvents).doc(randomUUID());
    const accountRef=this.db.collection("havitV1Accounts").doc(uid);
    const state=await this.db.runTransaction(async tx=>{
      const d=(await tx.get(ref)).data(),account=(await tx.get(accountRef)).data()??{};
      if(d?.lastFactoryResetRequestId===requestId&&d.lastFactoryResetOwnerUid===uid)return {already:true,revision:Number(account.revision??0)};
      if(!d?.active||d.ownerUid!==uid||d.bindingId!==bindingId||d.factoryResetOwnerUid!==uid||
         d.factoryResetBindingId!==bindingId||d.factoryResetRequestId!==requestId)throw new ApiError(409,"FACTORY_RESET_NOT_CONFIRMED");
      const unlinkedAtMs=this.now(),epoch=Number(d.ownershipEpoch??0)+1;
      const pendingId=typeof d.pendingSessionId==="string"?d.pendingSessionId:null;
      const pendingRef=pendingId?this.sessionRef(deviceId,pendingId):null;
      const pending=pendingRef?await tx.get(pendingRef):null;
      tx.update(ref,{ownerUid:null,bindingId:null,linkedAtMs:null,pendingSessionId:null,ownershipEpoch:epoch,
        factoryResetRequestId:null,factoryResetOwnerUid:null,factoryResetBindingId:null,
        lastFactoryResetRequestId:requestId,lastFactoryResetOwnerUid:uid,lastFactoryResetAtMs:unlinkedAtMs});
      if(pendingRef&&pending?.exists)tx.update(pendingRef,{invalidatedAtMs:unlinkedAtMs,invalidatedReason:"factory_reset"});
      tx.set(accountRef,{factoryResetInProgress:true,revision:Number(account.revision??0)+1},{merge:true});
      tx.create(eventRef,{deviceId,action:"owner_factory_reset",ownerUid:uid,previousBindingId:bindingId,ownershipEpoch:epoch,requestId,createdAtMs:unlinkedAtMs});
      return {already:false,revision:Number(account.revision??0)+1};
    });
    if(!state.already)await this.purgeAccountTaskData(uid,state.revision);
    else if((await accountRef.get()).get("factoryResetInProgress")===true)await this.purgeAccountTaskData(uid,state.revision);
    return {deviceId,requestId,state:"completed"};
  }
  private async purgeAccountTaskData(uid:string,revision:number){
    const account=this.db.collection("havitV1Accounts").doc(uid);
    for(const name of ["tasks","operations"]){
      const refs=await account.collection(name).listDocuments();
      for(let i=0;i<refs.length;i+=450){const batch=this.db.batch();for(const ref of refs.slice(i,i+450))batch.delete(ref);await batch.commit();}
    }
    await account.set({taskCount:0,revision,factoryResetInProgress:FieldValue.delete(),factoryResetAtMs:this.now()},{merge:true});
  }
  async operatorRecoveryUnlink(deviceId: string, expectedBindingId: string, supportCaseId: string) {
    if (!validDeviceId(deviceId) || !uuid.test(expectedBindingId) || !/^[A-Za-z0-9_-]{6,64}$/.test(supportCaseId))
      throw new ApiError(400,"INVALID_REQUEST");
    const ref=this.db.collection(collections.devices).doc(deviceId);
    const eventRef=this.db.collection(collections.ownershipEvents).doc(randomUUID());
    return this.db.runTransaction(async tx=>{
      const d=(await tx.get(ref)).data();
      if(!d || !d.active) throw new ApiError(404,"DEVICE_NOT_FOUND");
      if(d.lastRecoveryCaseId===supportCaseId && d.lastRecoveryBindingId===expectedBindingId)
        return {deviceId,state:"unlinked",ownershipEpoch:Number(d.ownershipEpoch ?? 0)};
      if(!d.ownerUid || d.bindingId!==expectedBindingId) throw new ApiError(409,"BINDING_CHANGED");
      const previousOwnerUid=d.ownerUid;
      const ownershipEpoch=Number(d.ownershipEpoch ?? 0)+1;
      const unlinkedAtMs=this.now();
      const pendingId=typeof d.pendingSessionId === "string" ? d.pendingSessionId : null;
      const pendingRef=pendingId ? this.sessionRef(deviceId,pendingId) : null;
      const pending=pendingRef ? await tx.get(pendingRef) : null;
      tx.update(ref,{ownerUid:null,bindingId:null,linkedAtMs:null,pendingSessionId:null,ownershipEpoch,
        lastRecoveryCaseId:supportCaseId,lastRecoveryBindingId:expectedBindingId,lastRecoveryAtMs:unlinkedAtMs});
      if(pendingRef && pending?.exists) tx.update(pendingRef,{invalidatedAtMs:unlinkedAtMs,invalidatedReason:"operator_recovery"});
      tx.create(eventRef,{deviceId,action:"operator_recovery_unlinked",previousOwnerUid,previousBindingId:expectedBindingId,
        ownershipEpoch,supportCaseId,createdAtMs:unlinkedAtMs});
      return {deviceId,state:"unlinked",ownershipEpoch,unlinkedAt:new Date(unlinkedAtMs).toISOString()};
    });
  }
  async link(token: string) {
    return this.db.runTransaction(async tx=>{
      const d = await this.device(tx,token);
      return {deviceId:d.id,state:d.data.ownerUid ? "linked" : "unclaimed",bindingId:d.data.bindingId ?? null,ownershipEpoch:Number(d.data.ownershipEpoch ?? 0)};
    });
  }
}
