import struct
import unittest
from flash_identity import identity_partition_offset

def entry(name, start, size, kind=1, subtype=2):
    return struct.pack('<HBBII16sI', 0x50AA, kind, subtype, start, size, name, 0)

class IdentityPartitionTests(unittest.TestCase):
    def test_dedicated_partition_after_existing_application(self):
        table = entry(b'nvs', 0x9000, 0x6000) + entry(b'factory', 0x10000, 12*1024*1024, 0, 0) + entry(b'havit_identity', 0xC10000, 0x6000)
        self.assertEqual(identity_partition_offset(table), 0xC10000)
    def test_current_firmware_without_identity_partition_is_refused(self):
        with self.assertRaises(ValueError): identity_partition_offset(entry(b'nvs', 0x9000, 0x6000))
    def test_wrong_address_duplicate_or_overlap_is_refused(self):
        cases = [entry(b'havit_identity', 0x9000, 0x6000), entry(b'havit_identity', 0xC10000, 0x6000)*2,
                 entry(b'havit_identity', 0xC10000, 0x6000)+entry(b'other', 0xC11000, 0x1000)]
        for table in cases:
            with self.assertRaises(ValueError): identity_partition_offset(table)

if __name__ == '__main__': unittest.main()
