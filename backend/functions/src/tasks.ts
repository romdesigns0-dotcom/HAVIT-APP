import {createHash} from "node:crypto";
import {Firestore, Transaction, DocumentData} from "firebase-admin/firestore";
import {ApiError} from "./service.js";

export const TASK_LIMIT=64;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export type TaskFields={title:string;detail:string;dueAt:string|null;status:"pending"|"completed"};
export type TaskRecord=TaskFields & {id:string;taskVersion:number;createdAt:string;updatedAt:string};
type DeviceAuth=(tx:Transaction,token:string)=>Promise<{id:string;data:DocumentData}>;
export type RelayActor={relay:{uid:string;deviceId:string;bindingId:string;credentialHash:string}};
type Actor={uid:string}|{token:string;bindingId:string}|RelayActor;
type Mutation={operationId:string;taskId:string;baseTaskVersion:number;kind:"create"|"update"|"delete";task?:TaskFields};
const zoneOffsets=new Map<string,{at:number;offset:number}[]>();
function offsets(timeZone:string){
  const saved=zoneOffsets.get(timeZone);if(saved)return saved;
  const format=new Intl.DateTimeFormat('en',{timeZone,timeZoneName:'longOffset'});
  const offset=(at:number)=>{const name=format.formatToParts(at).find(p=>p.type==='timeZoneName')!.value;
    if(name==='GMT')return 0;const m=name.match(/^GMT([+-])(\d{2}):(\d{2})$/)!;return (m[1]==='-'?-1:1)*(+m[2]*3600 + +m[3]*60);};
  let prior=Date.UTC(2020,0,1),last=offset(prior);const result=[{at:prior/1000,offset:last}];
  // Weekly probes locate IANA transitions; binary search records the exact second.
  for(let next=prior+604800000;next<=Date.UTC(2100,0,8);next+=604800000){
    const value=offset(next);if(value!==last){let low=prior/1000,high=next/1000;
      while(high-low>1){const middle=Math.floor((low+high)/2);if(offset(middle*1000)===last)low=middle;else high=middle;}
      result.push({at:high,offset:value});last=value;
    }prior=next;
  }
  zoneOffsets.set(timeZone,result);return result;
}
function fields(input:unknown):TaskFields {
  if(!input||typeof input!=="object"||Array.isArray(input))throw new ApiError(400,"INVALID_TASK");
  const t=input as Record<string,unknown>;
  if(Object.keys(t).sort().join()!=="detail,dueAt,status,title"||typeof t.title!=="string"||
    !t.title.trim()||Buffer.byteLength(t.title.trim())>160||typeof t.detail!=="string"||
    Buffer.byteLength(t.detail)>2048||typeof t.status!=='string'||!['pending','completed'].includes(t.status))throw new ApiError(400,"INVALID_TASK");
  let dueAt:string|null=null;
  if(t.dueAt!==null){
    if(typeof t.dueAt!=="string"||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/.test(t.dueAt)||!Number.isFinite(Date.parse(t.dueAt)))throw new ApiError(400,"INVALID_DUE_DATE");
    dueAt=new Date(t.dueAt).toISOString();
    if(dueAt.slice(0,19)!==t.dueAt.slice(0,19))throw new ApiError(400,"INVALID_DUE_DATE");
    if(dueAt<"2020"||dueAt>="2100")throw new ApiError(400,"INVALID_DUE_DATE");
  }
  const result={title:t.title.trim(),detail:t.detail,dueAt,status:t.status as TaskFields['status']};
  if(Buffer.byteLength(JSON.stringify(result))>2400)throw new ApiError(400,'INVALID_TASK');
  return result;
}
export class TaskService {
  constructor(private db:Firestore,private deviceAuth:DeviceAuth,private now=()=>Date.now()){}
  private account(uid:string){return this.db.collection('havitV1Accounts').doc(uid);}
  private async scope(tx:Transaction,actor:Actor){
    if('relay'in actor){
      const r=actor.relay;
      const d=(await tx.get(this.db.collection('havitV1Devices').doc(r.deviceId))).data();
      const c=(await tx.get(this.db.collection('havitV1DeviceCredentials').doc(r.credentialHash))).data();
      if(!d?.active||d.credentialHash!==r.credentialHash||!c||c.revokedAtMs!=null||c.deviceId!==r.deviceId)throw new ApiError(401,'DEVICE_CREDENTIAL_REVOKED');
      if(d.ownerUid!==r.uid||d.bindingId!==r.bindingId)throw new ApiError(403,'BINDING_CHANGED');
      return {uid:r.uid,bindingId:r.bindingId,deviceId:r.deviceId};
    }
    if('uid'in actor)return {uid:actor.uid,bindingId:null,deviceId:null};
    const d=await this.deviceAuth(tx,actor.token);
    if(!d.data.ownerUid||!d.data.bindingId)throw new ApiError(409,'DEVICE_NOT_LINKED');
    if(d.data.bindingId!==actor.bindingId)throw new ApiError(409,'BINDING_CHANGED');
    return {uid:String(d.data.ownerUid),bindingId:String(d.data.bindingId),deviceId:d.id};
  }
  async preferences(uid:string,input:unknown){
    const b=input as {timeZone?:unknown};
    if(!b||Object.keys(b).join()!=='timeZone'||typeof b.timeZone!=='string'||b.timeZone.length>80)throw new ApiError(400,'INVALID_TIME_ZONE');
    try{new Intl.DateTimeFormat('en',{timeZone:b.timeZone}).format();}catch{throw new ApiError(400,'INVALID_TIME_ZONE');}
    await this.account(uid).set({timeZone:b.timeZone},{merge:true});return {timeZone:b.timeZone};
  }
  async snapshot(actor:Actor){
    return this.db.runTransaction(async tx=>{
      const scope=await this.scope(tx,actor),account=this.account(scope.uid);
      const meta=(await tx.get(account)).data()??{};
      if(meta.factoryResetInProgress===true)throw new ApiError(423,"ACCOUNT_RESET_IN_PROGRESS");
      const docs=await tx.get(account.collection('tasks').where('deleted','==',false).limit(TASK_LIMIT+1));
      if(docs.size>TASK_LIMIT)throw new ApiError(503,'TASK_CAPACITY_EXCEEDED');
      const tasks=docs.docs.map(d=>{const {deleted,...t}=d.data();return t as TaskRecord;});
      tasks.sort((a,b)=>(a.dueAt??'9999').localeCompare(b.dueAt??'9999')||a.createdAt.localeCompare(b.createdAt)||a.id.localeCompare(b.id));
      const now=this.now(),timeZone=String(meta.timeZone??'America/Mexico_City');
      const parts=new Intl.DateTimeFormat('en-CA',{timeZone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(new Date(now));
      const p=Object.fromEntries(parts.map(x=>[x.type,x.value]));
      const localDate=`${p.year}-${p.month}-${p.day}`;
      const localUTC=Date.UTC(+p.year,+p.month-1,+p.day,+p.hour,+p.minute,+p.second);
      return {protocol:1,...scope,revision:Number(meta.revision??0),serverTime:new Date(now).toISOString(),timeZone,
        utcOffsetSeconds:Math.round((localUTC-Math.floor(now/1000)*1000)/1000),utcOffsetTransitions:offsets(timeZone),localDate,taskLimit:TASK_LIMIT,tasks};
    });
  }
  async mutate(actor:Actor,input:unknown){
    if(!input||typeof input!=='object'||Array.isArray(input))throw new ApiError(400,'INVALID_REQUEST');
    const b=input as Mutation;
    const expected=b.kind==='delete'?'baseTaskVersion,kind,operationId,taskId':'baseTaskVersion,kind,operationId,task,taskId';
    if(Object.keys(b).sort().join()!==expected||typeof b.operationId!=='string'||typeof b.taskId!=='string'||!uuid.test(b.operationId)||!uuid.test(b.taskId)||
      !Number.isSafeInteger(b.baseTaskVersion)||b.baseTaskVersion<0||!['create','update','delete'].includes(b.kind))throw new ApiError(400,'INVALID_REQUEST');
    const value=b.kind==='delete'?undefined:fields(b.task);
    const hash=createHash('sha256').update(JSON.stringify({id:b.taskId,base:b.baseTaskVersion,kind:b.kind,task:value})).digest('hex');
    return this.db.runTransaction(async tx=>{
      // Revalidate the current owner/binding before checking any saved idempotent result.
      const scope=await this.scope(tx,actor),account=this.account(scope.uid);
      const operation=account.collection('operations').doc(b.operationId);
      const memo=(await tx.get(operation)).data();
      if(memo){if(memo.hash!==hash||memo.bindingId!==scope.bindingId||memo.deviceId!==scope.deviceId)throw new ApiError(409,'IDEMPOTENCY_CONFLICT');return memo.result;}
      const ref=account.collection('tasks').doc(b.taskId);
      const old=(await tx.get(ref)).data();
      const meta=(await tx.get(account)).data()??{};
      if(meta.factoryResetInProgress===true)throw new ApiError(423,"ACCOUNT_RESET_IN_PROGRESS");
      if(b.kind==='create'){
        if(old||b.baseTaskVersion!==0)throw new ApiError(409,'TASK_VERSION_CONFLICT');
        if(Number(meta.taskCount??0)>=TASK_LIMIT)throw new ApiError(409,'TASK_LIMIT_REACHED');
      }else if(!old||old.deleted||old.taskVersion!==b.baseTaskVersion)throw new ApiError(409,'TASK_VERSION_CONFLICT');
      const revision=Number(meta.revision??0)+1,version=Number(old?.taskVersion??0)+1;
      const timestamp=new Date(this.now()).toISOString();
      const task=b.kind==='delete'?null:{...value,id:b.taskId,taskVersion:version,createdAt:old?.createdAt??timestamp,updatedAt:timestamp};
      const result={revision,id:b.taskId,taskVersion:version,task};
      tx.set(ref,task?{...task,deleted:false}:{id:b.taskId,taskVersion:version,deleted:true,updatedAt:timestamp});
      tx.set(account,{revision,taskCount:Number(meta.taskCount??0)+(b.kind==='create'?1:b.kind==='delete'?-1:0)},{merge:true});
      tx.create(operation,{hash,bindingId:scope.bindingId,deviceId:scope.deviceId,result,createdAt:timestamp});
      return result;
    });
  }
}
