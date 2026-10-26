"""Inspect live sync or modify ONLY a temporary USB test activity. No token output."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import urllib.request
from uuid import UUID, uuid4
from datetime import datetime, timedelta, timezone


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--identity-backup', required=True, type=Path)
    p.add_argument('--idf', required=True, type=Path)
    p.add_argument('--device-id', required=True)
    p.add_argument('--binding-id', required=True)
    p.add_argument('--action', choices=['status', 'complete-test', 'delete-test'], default='status')
    p.add_argument('--task-id')
    args = p.parse_args()
    tool = args.idf / 'components/nvs_flash/nvs_partition_tool/nvs_tool.py'
    result = subprocess.run([sys.executable, str(tool), str(args.identity_backup), '-f', 'json', '-d', 'minimal'], capture_output=True)
    if result.returncode:
        raise RuntimeError('Cannot read private backup')
    rows = json.loads(result.stdout)
    identity = {r['key']: r['data'] for r in rows if r['namespace'] == 'havit_identity'}
    if identity.get('device_id') != args.device_id:
        raise RuntimeError('Different test unit')
    base = 'https://us-central1-havit-c8c1d.cloudfunctions.net/havitDeviceApiV1'
    def api(path, body=None):
        request = urllib.request.Request(base + path, data=json.dumps(body).encode() if body else None,
            headers={'Authorization': 'Bearer ' + identity['device_token'], 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    snapshot = api('/v1/device/sync?bindingId=' + str(UUID(args.binding_id)))
    if snapshot['deviceId'] != identity['device_id'] or snapshot['bindingId'] != args.binding_id:
        raise RuntimeError('Server identity/binding mismatch')
    print(json.dumps({key: snapshot[key] for key in ['deviceId', 'bindingId', 'revision', 'localDate', 'timeZone']}, ensure_ascii=False))
    print('taskCount=' + str(len(snapshot['tasks'])))
    for task in snapshot['tasks']:
        print(json.dumps({key: task[key] for key in ['id', 'taskVersion', 'status', 'dueAt']}))
    if args.action != 'status':
        task = next((t for t in snapshot['tasks'] if t['id'] == args.task_id), None)
        if not task or task['title'] != 'Prueba de sincronizacion' or task['detail'] != 'Actividad temporal de comprobacion USB':
            raise RuntimeError('Refusing to modify a non-test activity')
        event = dict(bindingId=args.binding_id, eventId=str(uuid4()), taskId=task['id'], baseTaskVersion=task['taskVersion'], kind='delete' if args.action == 'delete-test' else 'update')
        if args.action == 'complete-test':
            event['task'] = dict(title=task['title'], detail=task['detail'], status='completed', dueAt=(datetime.now(timezone.utc) + timedelta(hours=1)).isoformat(timespec='milliseconds').replace('+00:00', 'Z'))
        reply = api('/v1/device/events', event)
        print(json.dumps({key: reply[key] for key in ['id', 'taskVersion', 'revision']}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Live sync check failed; credentials and private response suppressed.', file=sys.stderr)
        sys.exit(1)
