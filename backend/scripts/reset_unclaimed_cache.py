"""Operator recovery for a server-unclaimed unit with a stale local claim cache.

Requires ESP-IDF Python, gcloud operator authentication, and explicit device ID.
Rewrites only havit_identity after checking the live identity against Firestore.
Keeps its three identity strings byte-for-byte equivalent; default NVS is untouched.
Never use this as an account-unlink operation.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from flash_identity import identity_partition_offset


def checked(command, **kwargs):
    result = subprocess.run(command, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError("Operator command failed; secret-bearing output suppressed")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--confirm-device-id", required=True)
    parser.add_argument("--idf-path", required=True, type=Path)
    args = parser.parse_args()
    if args.device_id != args.confirm_device_id:
        raise ValueError("Device confirmations differ")
    tools = args.idf_path / "components/nvs_flash"
    nvs_tool = tools / "nvs_partition_tool/nvs_tool.py"
    generator = tools / "nvs_partition_generator/nvs_partition_gen.py"
    backend = Path(__file__).resolve().parents[1] / "functions"
    recovery_parent = Path(os.environ["LOCALAPPDATA"]) / "Havit/OperatorRecovery"
    recovery_parent.mkdir(parents=True, exist_ok=True)
    recovery = Path(tempfile.mkdtemp(prefix="unclaimed-", dir=recovery_parent))
    esp = [sys.executable, "-m", "esptool", "--chip", "esp32s3", "--port", args.port]
    wrote = False

    def read_nvs(path):
        raw = checked([sys.executable, str(nvs_tool), str(path), "-f", "json", "-d", "minimal"])
        return json.loads(raw)

    def verify_backend(identity):
        # The hash stays on stdin/in memory. No token or stored identity is logged.
        code = """
const {localAdmin}=require('./lib/local-admin');
const {deleteApp}=require('firebase-admin/app');
(async()=>{let input='';for await(const c of process.stdin)input+=c;
const b=JSON.parse(input),{app,db}=localAdmin('havit-c8c1d',true);
try {await db.runTransaction(async tx=>{
const d=(await tx.get(db.collection('havitV1Devices').doc(b.id))).data();
const c=(await tx.get(db.collection('havitV1DeviceCredentials').doc(b.hash))).data();
if(!d||!d.active||d.ownerUid||d.bindingId||d.pendingSessionId||d.credentialHash!==b.hash||
!c||c.deviceId!==b.id||c.revokedAtMs!=null)throw Error('Not an idle, unclaimed unit');
});console.log('UNCLAIMED_IDENTITY_VERIFIED');}finally{await deleteApp(app)}})()
.catch(()=>{console.error('Backend precondition failed');process.exitCode=1});
"""
        payload = json.dumps({"id": args.device_id,
                              "hash": hashlib.sha256(identity["device_token"].encode()).hexdigest()})
        result = checked(["node", "-e", code], cwd=backend, input=payload.encode())
        if result.strip() != b"UNCLAIMED_IDENTITY_VERIFIED":
            raise ValueError("Backend identity verification did not complete")

    try:
        table, original = recovery / "partition-table.bin", recovery / "original.bin"
        checked(esp + ["--after", "no_reset", "read_flash", "0x8000", "0x1000", str(table)])
        offset = identity_partition_offset(table.read_bytes())
        checked(esp + ["--after", "no_reset", "read_flash", hex(offset), "0x6000", str(original)])
        rows = read_nvs(original)
        if any(r["namespace"] not in {"havit_identity", "havit_claim"} for r in rows):
            raise ValueError("Unexpected namespace; refusing to discard data")
        identity_rows = [r for r in rows if r["namespace"] == "havit_identity"]
        identity = {r["key"]: r["data"] for r in identity_rows}
        if (len(identity_rows) != 3 or set(identity) != {"device_id", "device_token", "api_base_url"}
                or any(r["encoding"] != "string" for r in identity_rows)
                or identity["device_id"] != args.device_id):
            raise ValueError("Unexpected live identity; no data written")
        verify_backend(identity)
        stale_binding = any(r["namespace"] == "havit_claim" and r["key"] == "binding_id"
                            and r["data"] for r in rows)
        print(f"Verified live unit {args.device_id}; server unclaimed; stale local binding={bool(stale_binding)}")
        source, binary = recovery / "identity.csv", recovery / "reset.bin"
        with source.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["key", "type", "encoding", "value"])
            writer.writerow(["havit_identity", "namespace", "", ""])
            for key, value in identity.items():
                writer.writerow([key, "data", "string", value])
        checked([sys.executable, str(generator), "generate", str(source), str(binary), "0x6000"])
        generated = read_nvs(binary)
        if ({r["key"]: r["data"] for r in generated} != identity
                or len(generated) != 3 or any(r["namespace"] != "havit_identity" for r in generated)):
            raise ValueError("Generated identity differs; no data written")
        verify_backend(identity)
        wrote = True
        checked(esp + ["--after", "no_reset", "write_flash", hex(offset), str(binary)])
        readback = recovery / "verified.bin"
        checked(esp + ["--after", "hard_reset", "read_flash", hex(offset), "0x6000", str(readback)])
        if readback.read_bytes() != binary.read_bytes():
            raise RuntimeError("Flash verification differs; retain private recovery files")
        shutil.rmtree(recovery)
        print("Verified: local claim cache removed, exact identity preserved, default NVS untouched.")
    except Exception:
        if wrote:
            print(f"Recovery backup retained privately at {recovery}", file=sys.stderr)
        else:
            shutil.rmtree(recovery)
            # Return to the original application if a read-only precondition failed.
            subprocess.run(esp + ["run"], capture_output=True)
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Recovery stopped; no credentials displayed. Check operator preconditions.", file=sys.stderr)
        sys.exit(1)
