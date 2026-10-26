import {execFileSync} from "node:child_process";
import {initializeApp,applicationDefault} from "firebase-admin/app";
import {Firestore,getFirestore} from "firebase-admin/firestore";
import {OAuth2Client} from "google-auth-library";

// Explicit local operator option. The short-lived CLI token stays in memory.
export function localAdmin(projectId: string, useGcloud = false) {
  process.env.GOOGLE_CLOUD_QUOTA_PROJECT ??= projectId;
  if (!useGcloud) {
    const app=initializeApp({projectId,credential:applicationDefault()});
    return {app,db:getFirestore(app)};
  }
  const accessToken=execFileSync(process.platform==="win32"?"gcloud.cmd":"gcloud",["auth","print-access-token"],
    {encoding:"utf8",shell:process.platform==="win32",stdio:["ignore","pipe","pipe"]}).trim();
  const auth=new OAuth2Client({quotaProjectId:projectId});
  auth.setCredentials({access_token:accessToken,expiry_date:Date.now()+3500000});
  const app=initializeApp({projectId,credential:{getAccessToken:async()=>({access_token:accessToken,expires_in:3500})}});
  const db=new Firestore({projectId,preferRest:true,auth});
  return {app,db};
}
