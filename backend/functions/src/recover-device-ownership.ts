import {parseArgs} from "node:util";
import {deleteApp} from "firebase-admin/app";
import {localAdmin} from "./local-admin.js";
import {DeviceService,validDeviceId} from "./service.js";

async function main() {
  const {values:v}=parseArgs({options:{
    project:{type:"string"},"device-id":{type:"string"},"binding-id":{type:"string"},
    "support-case":{type:"string"},"confirm-device-id":{type:"string"},"use-gcloud-session":{type:"boolean"}
  }});
  if(!v.project || !validDeviceId(v["device-id"]) || v["confirm-device-id"]!==v["device-id"] ||
     !v["binding-id"] || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v["binding-id"]) ||
     !v["support-case"] || !/^[A-Za-z0-9_-]{6,64}$/.test(v["support-case"])) {
    throw new Error("Required: --project --device-id --binding-id --support-case --confirm-device-id <same device id>");
  }
  const {app,db}=localAdmin(v.project,v["use-gcloud-session"]);
  try {
    const result=await new DeviceService(db).operatorRecoveryUnlink(v["device-id"],v["binding-id"],v["support-case"]);
    console.log(JSON.stringify({recoveryUnlink:result.state,deviceId:result.deviceId,ownershipEpoch:result.ownershipEpoch}));
  } finally {
    await deleteApp(app);
  }
}

main().catch(()=>{console.error("Ownership recovery failed. No account or device credential was changed unless the transaction completed.");process.exitCode=1;});
