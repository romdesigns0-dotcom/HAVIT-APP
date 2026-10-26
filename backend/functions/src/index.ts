import {initializeApp} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import {getFirestore} from "firebase-admin/firestore";
import {onRequest} from "firebase-functions/v2/https";
import {createApp} from "./app.js";
import {DeviceService} from "./service.js";
initializeApp();
export const havitDeviceApiV1 = onRequest({region:"us-central1",maxInstances:4,timeoutSeconds:30,memory:"256MiB",invoker:"public"},
  createApp(new DeviceService(getFirestore()),async token=>(await getAuth().verifyIdToken(token,true)).uid));
