import {parseArgs} from "node:util";
import {localAdmin} from "./local-admin.js";
import {collections,validDeviceId} from "./service.js";
async function main(){
 const {values:v}=parseArgs({options:{project:{type:"string"},"device-id":{type:"string"},"use-gcloud-session":{type:"boolean"}}});
 if(!v.project || !validDeviceId(v["device-id"]))throw Error("Invalid arguments");
 const {db}=localAdmin(v.project,v["use-gcloud-session"]);
 await db.runTransaction(async tx=>{
  const ref=db.collection(collections.devices).doc(v["device-id"]!);const d=(await tx.get(ref)).data();
  if(!d)throw Error("Not registered");
  tx.update(ref,{active:false,pendingSessionId:null,revokedAtMs:Date.now()});
  tx.update(db.collection(collections.credentials).doc(d.credentialHash),{revokedAtMs:Date.now()});
 });console.log(JSON.stringify({revoked:true,deviceId:v["device-id"]}));
}
main().catch(()=>{console.error("Revocation failed");process.exitCode=1;});
