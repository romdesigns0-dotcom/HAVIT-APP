"""Upgrade application/table only after checking the connected identity and owner.

Default NVS and dedicated identity are read/verified, never written. Backups stay
outside the repository and contain private credentials; never print their data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def run(command, **kwargs):
    r = subprocess.run(command, capture_output=True, **kwargs)
    if r.returncode:
        if 'esptool' in command:
            # esptool prints transfer diagnostics, never NVS payloads. Keep
            # credential parsing and administrative subprocesses suppressed.
            for line in (r.stdout + r.stderr).decode('utf8', 'replace').splitlines():
                if any(word in line.lower() for word in ('fatal error', 'failed', 'timed out', 'permissionerror', 'serialexception')):
                    print(line, file=sys.stderr, flush=True)
        raise RuntimeError("Operator command failed; private output suppressed")
    return r.stdout


def entries(raw):
    result = {}
    for at in range(0, len(raw) - 31, 32):
        row = raw[at:at+32]
        magic, kind, subtype, start, size, name, flags = struct.unpack('<HBBII16sI', row)
        if magic == 0x50AA:
            result[name.rstrip(b'\x00').decode()] = (kind, subtype, start, size, flags)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', required=True)
    p.add_argument('--device-id', required=True)
    p.add_argument('--binding-id', required=True)
    p.add_argument('--build', required=True, type=Path)
    p.add_argument('--idf', required=True, type=Path)
    args = p.parse_args()
    parent = Path(os.environ['LOCALAPPDATA']) / 'Havit/OperatorRecovery'
    parent.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix='tasks-upgrade-', dir=parent))
    esp = [sys.executable, '-m', 'esptool', '--chip', 'esp32s3', '--port', args.port]
    build = args.build.resolve(strict=True)
    table = build / 'partition_table/partition-table.bin'
    app = build / 'havit_os_firmware.bin'
    if not app.is_file() or app.stat().st_size > 0xC00000:
        raise RuntimeError('Application image missing or oversized')
    def read(at, size, name):
        path = backup / name
        run(esp + ['--after', 'no_reset', 'read_flash', hex(at), hex(size), str(path)])
        return path
    try:
        live = entries(read(0x8000, 0x1000, 'table.bin').read_bytes())
        target = entries(table.read_bytes())
        if any(target.get(name) != value for name, value in live.items()):
            raise RuntimeError('Existing partition would move/change')
        if set(target) - set(live) not in (set(), {'havit_tasks'}):
            raise RuntimeError('Unexpected new partition')
        if target.get('havit_identity') != (1, 2, 0xC10000, 0x6000, 0) or target.get('havit_tasks') != (1, 2, 0xC16000, 0xC0000, 0):
            raise RuntimeError('Unexpected dedicated partition layout')
        identity = read(0xC10000, 0x6000, 'identity.bin')
        nvs = read(0x9000, 0x6000, 'wifi-nvs.bin')
        tool = args.idf / 'components/nvs_flash/nvs_partition_tool/nvs_tool.py'
        rows = json.loads(run([sys.executable, str(tool), str(identity), '-f', 'json', '-d', 'minimal']))
        values = {r['key']: r['data'] for r in rows if r['namespace'] == 'havit_identity'}
        binding = next((r['data'] for r in rows if r['namespace'] == 'havit_claim' and r['key'] == 'binding_id'), None)
        if values.get('device_id') != args.device_id or binding != args.binding_id:
            raise RuntimeError('Connected device identity/binding differs')
        code = """
const {localAdmin}=require('./lib/local-admin');const {deleteApp}=require('firebase-admin/app');
(async()=>{let raw='';for await(const x of process.stdin)raw+=x;const b=JSON.parse(raw);
const {app,db}=localAdmin('havit-c8c1d',true);try{const d=(await db.collection('havitV1Devices').doc(b.id).get()).data();
if(!d?.active||!d.ownerUid||d.bindingId!==b.binding||d.credentialHash!==b.hash)throw Error('Precondition');
console.log('OWNER_PRESERVED');}finally{await deleteApp(app)}})().catch(()=>{process.exitCode=1});
"""
        payload = json.dumps({'id': args.device_id, 'binding': binding, 'hash': hashlib.sha256(values['device_token'].encode()).hexdigest()})
        result = run(['node', '-e', code], cwd=Path(__file__).resolve().parents[1] / 'functions', input=payload.encode())
        if result.strip() != b'OWNER_PRESERVED':
            raise RuntimeError('Backend identity/binding not verified')
        print('Connected identity and current binding verified; owner association unchanged.', flush=True)
        run(esp + ['--after', 'no_reset', 'write_flash', '0x8000', str(table), '0x10000', str(app)])
        after_identity = read(0xC10000, 0x6000, 'identity-after.bin')
        after_nvs = read(0x9000, 0x6000, 'wifi-after.bin')
        if identity.read_bytes() != after_identity.read_bytes() or nvs.read_bytes() != after_nvs.read_bytes():
            raise RuntimeError('Protected partitions differ; retain private backups')
        run(esp + ['run'])
        print('Application/table installed; identity and Wi-Fi NVS verified byte for byte.')
        print('Private operator backup: ' + str(backup))
    except Exception:
        subprocess.run(esp + ['run'], capture_output=True)
        print('Upgrade stopped. Private backup retained: ' + str(backup), file=sys.stderr)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('No credential values displayed; inspect operator preconditions.', file=sys.stderr)
        sys.exit(1)
