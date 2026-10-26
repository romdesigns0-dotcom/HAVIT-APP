import express from "express";
import {ApiError, DeviceService} from "./service.js";

export function createApp(service: DeviceService, verifyUser: (token:string)=>Promise<string>) {
  const app = express();
  app.disable("x-powered-by");
  app.use((_req,res,next)=>{res.set("Cache-Control","no-store");next();});
  app.use('/v1/devices/relay',express.json({limit:'384kb',strict:true}));
  app.use(express.json({limit:"8kb",strict:true}));
  const bearer = (value: string | undefined) => {
    const match = value?.match(/^Bearer ([A-Za-z0-9._-]+)$/);
    if (!match || match[1].length > 4096) throw new ApiError(401,"UNAUTHENTICATED");
    return match[1];
  };
  app.get("/v1/health",(_req,res)=>res.json({service:"havit-device-v1",protocol:1}));
  app.post("/v1/device/claim-sessions",async(req,res,next)=>{
    try {
      const token = bearer(req.header("authorization"));
      const id = await service.authenticateDevice(token);
      await service.rate("device:"+id,60);
      const result = await service.publish(token,req.body);
      res.status(result.created?201:200).json(result.body);
    } catch(e) {next(e);}
  });
  app.get("/v1/device/link",async(req,res,next)=>{
    try {
      const token = bearer(req.header("authorization"));
      const id = await service.authenticateDevice(token);
      await service.rate("device:"+id,60);
      res.json(await service.link(token));
    } catch(e) {next(e);}
  });
  app.get("/v1/user/devices",async(req,res,next)=>{
    try {
      const token = bearer(req.header("authorization"));
      let uid: string;
      try {uid=await verifyUser(token);} catch {throw new ApiError(401,"UNAUTHENTICATED");}
      await service.rate("user-devices:"+uid,60);
      res.json(await service.ownedDevices(uid));
    } catch(e) {next(e);}
  });
  app.post("/v1/devices/claim",async(req,res,next)=>{
    try {
      const token = bearer(req.header("authorization"));
      let uid: string;
      try {uid=await verifyUser(token);} catch {throw new ApiError(401,"UNAUTHENTICATED");}
      await service.rate("user:"+uid,10);
      res.json(await service.claim(uid,req.body));
    } catch(e) {next(e);}
  });
  app.post("/v1/devices/:deviceId/unlink",async(req,res,next)=>{
    try {
      const token = bearer(req.header("authorization"));
      let uid: string;
      try {uid=await verifyUser(token);} catch {throw new ApiError(401,"UNAUTHENTICATED");}
      await service.rate("user:"+uid,10);
      if (!req.body || typeof req.body !== "object" || Array.isArray(req.body) ||
          Object.keys(req.body).length !== 2 || typeof req.body.requestId !== "string" ||
          typeof req.body.bindingId !== "string")
        throw new ApiError(400,"INVALID_REQUEST");
      res.json(await service.unlink(uid,req.params.deviceId,req.body.bindingId,req.body.requestId));
    } catch(e) {next(e);}
  });
  app.post("/v1/devices/:deviceId/factory-reset",async(req,res,next)=>{try{
    const uid=await user(req);await service.rate('user:'+uid,10);
    if(!req.body||Object.keys(req.body).sort().join()!=="bindingId,requestId"||typeof req.body.bindingId!=="string"||typeof req.body.requestId!=="string")throw new ApiError(400,"INVALID_REQUEST");
    res.json(await service.requestFactoryReset(uid,req.params.deviceId,req.body.bindingId,req.body.requestId));
  }catch(e){next(e);}});
  app.post("/v1/devices/:deviceId/factory-reset/complete",async(req,res,next)=>{try{
    const uid=await user(req);await service.rate('user:'+uid,10);
    if(!req.body||Object.keys(req.body).sort().join()!=="bindingId,proof,requestId"||typeof req.body.bindingId!=="string"||typeof req.body.requestId!=="string")throw new ApiError(400,"INVALID_REQUEST");
    res.json(await service.completeFactoryReset(uid,req.params.deviceId,req.body.bindingId,req.body.requestId,req.body.proof));
  }catch(e){next(e);}});
  app.get("/v1/devices/:deviceId/factory-reset/:requestId",async(req,res,next)=>{try{
    const uid=await user(req);await service.rate('user:'+uid,60);
    if(typeof req.query.bindingId!=="string")throw new ApiError(400,"INVALID_REQUEST");
    res.json(await service.factoryResetStatus(uid,req.params.deviceId,req.query.bindingId,req.params.requestId));
  }catch(e){next(e);}});
  const user=async(req:express.Request)=>{
    try{return await verifyUser(bearer(req.header('authorization')));}catch{throw new ApiError(401,'UNAUTHENTICATED');}
  };
  app.post('/v1/devices/relay',async(req,res,next)=>{try{
    const uid=await user(req);await service.rate('relay:'+uid,30);
    res.json(await service.relay(uid,req.body));
  }catch(e){next(e);}});
  app.put('/v1/user/preferences',async(req,res,next)=>{try{const uid=await user(req);await service.rate('tasks:'+uid,120);res.json(await service.tasks.preferences(uid,req.body));}catch(e){next(e);}});
  app.get('/v1/tasks',async(req,res,next)=>{try{const uid=await user(req);await service.rate('tasks:'+uid,120);res.json(await service.tasks.snapshot({uid}));}catch(e){next(e);}});
  for(const [method,kind] of [['post','create'],['patch','update'],['delete','delete']] as const){
    app[method](method==='post'?'/v1/tasks':'/v1/tasks/:taskId',async(req,res,next)=>{try{
      const uid=await user(req);await service.rate('tasks:'+uid,120);
      const b=req.body;
      if(!b||typeof b!=='object'||Array.isArray(b)||Object.keys(b).sort().join()!==(kind==='delete'?'baseTaskVersion,operationId':'baseTaskVersion,operationId,task'+(kind==='create'?',taskId':'')))throw new ApiError(400,'INVALID_REQUEST');
      res.json(await service.tasks.mutate({uid},{...b,taskId:kind==='create'?b.taskId:(req.params as Record<string,string>).taskId,kind}));
    }catch(e){next(e);}});
  }
  app.get('/v1/device/sync',async(req,res,next)=>{try{
    const token=bearer(req.header('authorization')),id=await service.authenticateDevice(token);await service.rate('device:'+id,60);
    if(typeof req.query.bindingId!=='string')throw new ApiError(400,'INVALID_REQUEST');
    res.json(await service.deviceSync(token,req.query.bindingId));
  }catch(e){next(e);}});
  app.post('/v1/device/factory-reset/complete',async(req,res,next)=>{try{
    const token=bearer(req.header('authorization')),id=await service.authenticateDevice(token);await service.rate('device:'+id,60);
    if(!req.body||Object.keys(req.body).sort().join()!=="bindingId,requestId"||typeof req.body.bindingId!=="string"||typeof req.body.requestId!=="string")throw new ApiError(400,"INVALID_REQUEST");
    res.json(await service.completeFactoryResetFromDevice(token,req.body.bindingId,req.body.requestId));
  }catch(e){next(e);}});
  app.post('/v1/device/events',async(req,res,next)=>{try{
    const token=bearer(req.header('authorization')),id=await service.authenticateDevice(token);await service.rate('device:'+id,60);
    const b=req.body;
    if(!b||typeof b.bindingId!=='string'||typeof b.eventId!=='string')throw new ApiError(400,'INVALID_REQUEST');
    const {bindingId,eventId,...rest}=b;
    res.json(await service.tasks.mutate({token,bindingId},{...rest,operationId:eventId}));
  }catch(e){next(e);}});
  app.use((_req,res)=>res.status(404).json({error:{code:"NOT_FOUND"}}));
  app.use((err:unknown,_req:express.Request,res:express.Response,_next:express.NextFunction)=>{
    if (err instanceof ApiError) {
      if(err.retryAfterSeconds)res.set("Retry-After",String(err.retryAfterSeconds));
      res.status(err.status).json({error:{code:err.code,...(err.retryAfterSeconds?{retryAfterSeconds:err.retryAfterSeconds}:{})}});
    } else if ((err as {type?:string})?.type === "entity.parse.failed") res.status(400).json({error:{code:"INVALID_REQUEST"}});
    else if ((err as {type?:string})?.type === "entity.too.large") res.status(413).json({error:{code:"REQUEST_TOO_LARGE"}});
    else {console.error("havit-device-v1 request failed");res.status(503).json({error:{code:"TEMPORARILY_UNAVAILABLE"}});}
  });
  return app;
}
