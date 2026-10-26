"""Write only a verified dedicated NVS identity partition. Never erase default NVS."""
import argparse
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

def identity_partition_offset(raw):
    entries = []
    for offset in range(0, len(raw), 32):
        row = raw[offset:offset+32]
        if len(row) < 32: break
        magic, kind, subtype, start, size, label, flags = struct.unpack('<HBBII16sI', row)
        if magic == 0x50AA:
            entries.append((label.rstrip(b'\x00'), kind, subtype, start, size, flags))
    matches = [entry for entry in entries if entry[0] == b'havit_identity']
    if matches != [(b'havit_identity', 1, 2, 0xC10000, 0x6000, 0)]:
        raise ValueError('Dedicated havit_identity partition missing or different; no identity was written. Update the firmware partition table first.')
    for label, _, _, start, size, _ in entries:
        if label != b'havit_identity' and start < 0xC16000 and start + size > 0xC10000:
            raise ValueError('Identity partition overlaps another partition; no identity was written.')
    return 0xC10000

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--port', required=True)
    p.add_argument('--binary', required=True, type=Path)
    args = p.parse_args()
    binary = args.binary.resolve(strict=True)
    if binary.stat().st_size != 0x6000:
        raise ValueError('Expected an identity NVS image of exactly 0x6000 bytes')
    with tempfile.TemporaryDirectory(prefix='havit-partitions-') as tmp:
        table = Path(tmp) / 'partition-table.bin'
        subprocess.run([sys.executable, '-m', 'esptool', '--chip', 'esp32s3', '--port', args.port,
                        'read_flash', '0x8000', '0x1000', str(table)], check=True)
        target = identity_partition_offset(table.read_bytes())
        subprocess.run([sys.executable, '-m', 'esptool', '--chip', 'esp32s3', '--port', args.port,
                        'write_flash', hex(target), str(binary)], check=True)
        print('Identity partition written; default NVS and Wi-Fi were not overwritten.')

if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
