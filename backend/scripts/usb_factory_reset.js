"use strict";

const crypto = require("node:crypto");
const { deleteApp } = require("../functions/node_modules/firebase-admin/lib/app");
const { FieldValue } = require("../functions/node_modules/firebase-admin/lib/firestore");
const { localAdmin } = require("../functions/lib/local-admin");

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

async function purgeCollection(account, name) {
  const docs = await account.collection(name).listDocuments();
  for (let i = 0; i < docs.length; i += 450) {
    const batch = account.firestore.batch();
    for (const doc of docs.slice(i, i + 450)) batch.delete(doc);
    await batch.commit();
  }
  return docs.length;
}

async function main() {
  const project = arg("project");
  const deviceId = arg("device-id");
  const bindingId = arg("binding-id");
  const confirmDeviceId = arg("confirm-device-id");
  const confirmBindingId = arg("confirm-binding-id");
  if (project !== "havit-c8c1d" || !/^[A-Za-z0-9][A-Za-z0-9_-]{2,95}$/.test(deviceId ?? "") ||
      !/^[0-9a-f-]{36}$/.test(bindingId ?? "") || deviceId !== confirmDeviceId || bindingId !== confirmBindingId) {
    throw new Error("Confirmation values do not match the exact HAVIT identity and binding.");
  }

  const { app, db } = localAdmin(project, true);
  try {
    const deviceRef = db.collection("havitV1Devices").doc(deviceId);
    const resetId = crypto.randomUUID();
    const now = Date.now();
    const state = await db.runTransaction(async tx => {
      const deviceSnap = await tx.get(deviceRef);
      const device = deviceSnap.data();
      if (!deviceSnap.exists || device?.active !== true || typeof device.ownerUid !== "string" ||
          device.bindingId !== bindingId) throw new Error("The active owner/binding changed; stopped before deleting account data.");
      const ownerUid = device.ownerUid;
      const accountRef = db.collection("havitV1Accounts").doc(ownerUid);
      const accountSnap = await tx.get(accountRef);
      const pendingId = typeof device.pendingSessionId === "string" ? device.pendingSessionId : null;
      const pendingRef = pendingId
        ? db.collection("havitV1ClaimSessions").doc(crypto.createHash("sha256").update(`${deviceId}:${pendingId}`).digest("hex"))
        : null;
      const pending = pendingRef ? await tx.get(pendingRef) : null;
      const epoch = Number(device.ownershipEpoch ?? 0) + 1;
      tx.update(deviceRef, {
        ownerUid: null,
        bindingId: null,
        linkedAtMs: null,
        pendingSessionId: null,
        ownershipEpoch: epoch,
        factoryResetRequestId: null,
        factoryResetOwnerUid: null,
        factoryResetBindingId: null,
        lastFactoryResetRequestId: resetId,
        lastFactoryResetOwnerUid: ownerUid,
        lastFactoryResetAtMs: now
      });
      if (pendingRef && pending?.exists) tx.update(pendingRef, { invalidatedAtMs: now, invalidatedReason: "usb_factory_reset" });
      tx.set(accountRef, { factoryResetInProgress: true, revision: Number(accountSnap.get("revision") ?? 0) + 1 }, { merge: true });
      tx.create(db.collection("havitV1OwnershipEvents").doc(crypto.randomUUID()), {
        deviceId, action: "owner_factory_reset_usb", ownerUid, previousBindingId: bindingId,
        ownershipEpoch: epoch, requestId: resetId, createdAtMs: now, source: "physical_usb"
      });
      return { ownerUid, revision: Number(accountSnap.get("revision") ?? 0) + 1 };
    });

    const account = db.collection("havitV1Accounts").doc(state.ownerUid);
    const [tasksDeleted, operationsDeleted] = await Promise.all([
      purgeCollection(account, "tasks"),
      purgeCollection(account, "operations")
    ]);
    await account.set({
      taskCount: 0,
      revision: state.revision,
      factoryResetInProgress: FieldValue.delete(),
      factoryResetAtMs: Date.now()
    }, { merge: true });
    console.log(JSON.stringify({
      deviceId,
      state: "unlinked_and_purged",
      tasksDeleted,
      operationsDeleted,
      factoryIdentityAndCredential: "preserved",
      firebaseAccountAndPreferences: "preserved"
    }));
  } finally {
    await deleteApp(app);
  }
}

main().catch(error => {
  console.error(error?.message || "USB factory reset failed; inspect the audited record before retrying.");
  process.exitCode = 1;
});
