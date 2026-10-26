import {randomBytes} from "node:crypto";
import {unlinkSync, mkdirSync, realpathSync, writeFileSync} from "node:fs";
import {isAbsolute, relative, resolve} from "node:path";
import {parseArgs} from "node:util";
import {localAdmin} from "./local-admin.js";
import {collections, sha256, validDeviceId} from "./service.js";

async function main() {
  const {values: v} = parseArgs({options: {
    project: {type: "string"},
    "device-id": {type: "string"},
    "expected-mac": {type: "string"},
    "output-dir": {type: "string"},
    "api-base-url": {type: "string"},
    "use-gcloud-session": {type: "boolean"}
  }});
  const deviceId = v["device-id"];
  const mac = v["expected-mac"]?.replaceAll(":", "").toLowerCase();
  if (!v.project || !deviceId || !validDeviceId(deviceId) || !mac || !v["output-dir"] || !v["api-base-url"])
    throw new Error("Required: --project --device-id --expected-mac --output-dir --api-base-url");
  if (deviceId !== `havit-${mac}`) throw new Error("Device ID does not match the confirmed ESP32 MAC");
  const url = new URL(v["api-base-url"]);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash)
    throw new Error("Invalid HTTPS API URL");

  const repo = realpathSync(resolve(__dirname, "../../.."));
  const outputDir = resolve(v["output-dir"]);
  mkdirSync(outputDir, {recursive: true, mode: 0o700});
  const canonicalOutput = realpathSync(outputDir);
  const rel = relative(repo, canonicalOutput);
  if (!rel || (!rel.startsWith("..") && !isAbsolute(rel)))
    throw new Error("Credential output must be outside the Havit repository");

  const token = `hvt_dev_${randomBytes(32).toString("base64url")}`;
  const nextCredentialHash = sha256(token);
  const csv = "key,type,encoding,value\n" +
    "havit_identity,namespace,,\n" +
    `device_id,data,string,${deviceId}\n` +
    `device_token,data,string,${token}\n` +
    `api_base_url,data,string,${url.href.replace(/\/$/, "")}\n`;
  const file = resolve(canonicalOutput, "identity.csv");
  writeFileSync(file, csv, {flag: "wx", mode: 0o600});

  try {
    const {db} = localAdmin(v.project, v["use-gcloud-session"]);
    const deviceRef = db.collection(collections.devices).doc(deviceId);
    const nextCredentialRef = db.collection(collections.credentials).doc(nextCredentialHash);
    const rotatedAtMs = Date.now();
    let ownerPresent = false;
    let bindingPresent = false;
    await db.runTransaction(async tx => {
      const deviceSnapshot = await tx.get(deviceRef);
      if (!deviceSnapshot.exists) throw new Error("Device is not registered");
      const device = deviceSnapshot.data()!;
      if (device.deviceId !== deviceId || device.active !== true)
        throw new Error("Device record changed or is not active; no rotation made");
      ownerPresent = typeof device.ownerUid === "string" && device.ownerUid.length > 0;
      bindingPresent = typeof device.bindingId === "string" && device.bindingId.length > 0;
      const oldHash = device.credentialHash;
      if (typeof oldHash !== "string" || !/^[a-f0-9]{64}$/.test(oldHash))
        throw new Error("Existing credential record is incomplete");
      const oldCredentialRef = db.collection(collections.credentials).doc(oldHash);
      const [nextCredentialSnapshot, oldCredentialSnapshot] = await tx.getAll(nextCredentialRef, oldCredentialRef);
      if (nextCredentialSnapshot.exists) throw new Error("Generated credential collision");
      if (oldCredentialSnapshot.exists && oldCredentialSnapshot.get("deviceId") !== deviceId)
        throw new Error("Existing credential belongs to another device");

      // Update only credential fields on the device. Any owner, binding, or pending
      // session fields remain byte-for-byte as they were before this rotation.
      tx.create(nextCredentialRef, {deviceId, revokedAtMs: null, createdAtMs: rotatedAtMs});
      if (oldCredentialSnapshot.exists && oldCredentialSnapshot.get("revokedAtMs") == null)
        tx.update(oldCredentialRef, {revokedAtMs: rotatedAtMs});
      tx.update(deviceRef, {credentialHash: nextCredentialHash, credentialRotatedAtMs: rotatedAtMs});
    });
    console.log(JSON.stringify({rotated: true, deviceId, ownerPresent, bindingPresent, credentialFile: file}));
  } catch (error) {
    try { unlinkSync(file); } catch { /* Keep the path private if cleanup is blocked. */ }
    throw error;
  }
}

main().catch(() => {
  console.error("Rotation failed. No credential is printed. Check operator access and device state.");
  process.exitCode = 1;
});
