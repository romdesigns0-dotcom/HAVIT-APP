import {parseArgs} from "node:util";
import {randomBytes} from "node:crypto";
import {mkdirSync,writeFileSync,realpathSync} from "node:fs";
import {resolve,relative,isAbsolute} from "node:path";
import {localAdmin} from "./local-admin.js";
import {collections,sha256,validDeviceId} from "./service.js";

async function main(){
  const {values:v}=parseArgs({options:{project:{type:"string"},"device-id":{type:"string"},"output-dir":{type:"string"},"api-base-url":{type:"string"},"use-gcloud-session":{type:"boolean"}}});
  if(!v.project || !validDeviceId(v["device-id"]) || !v["output-dir"] || !v["api-base-url"])throw Error("Required: --project --device-id --output-dir --api-base-url");
  const url=new URL(v["api-base-url"]);if(url.protocol!=="https:" || url.username || url.password || url.search || url.hash)throw Error("Invalid HTTPS API URL");
  const repo=realpathSync(resolve(__dirname,"../../.."));
  const out=resolve(v["output-dir"]);mkdirSync(out,{recursive:true,mode:0o700});
  const canonicalOut=realpathSync(out), rel=relative(repo,canonicalOut);
  if(!rel || (!rel.startsWith("..")&&!isAbsolute(rel)))throw Error("Credential output must be outside the Havit repository");
  const token="hvt_dev_"+randomBytes(32).toString("base64url");
  const csv="key,type,encoding,value\nhavit_identity,namespace,,\ndevice_id,data,string,"+v["device-id"]+"\ndevice_token,data,string,"+token+"\napi_base_url,data,string,"+url.href.replace(/\/$/,"")+"\n";
  const file=resolve(canonicalOut,"identity.csv");
  // Exclusive creation keeps retries from silently replacing a unit's credential.
  writeFileSync(file,csv,{flag:"wx",mode:0o600});
  const {db}=localAdmin(v.project,v["use-gcloud-session"]);const credentialHash=sha256(token),createdAtMs=Date.now();
  await db.runTransaction(async tx=>{
    const ref=db.collection(collections.devices).doc(v["device-id"]!);
    if((await tx.get(ref)).exists)throw Error("Device already registered; no credential changed. Delete the unused local candidate file securely.");
    tx.create(ref,{deviceId:v["device-id"],credentialHash,active:true,ownerUid:null,bindingId:null,pendingSessionId:null,ownershipEpoch:0,createdAtMs});
    tx.create(db.collection(collections.credentials).doc(credentialHash),{deviceId:v["device-id"],revokedAtMs:null,createdAtMs});
  });
  console.log(JSON.stringify({registered:true,deviceId:v["device-id"],credentialFile:file}));
}
main().catch(()=>{console.error("Registration failed. No credential is printed. Check permissions, output path and whether the device is already registered.");process.exitCode=1;});
