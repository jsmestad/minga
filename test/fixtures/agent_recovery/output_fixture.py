"""Known ASCII bytes, larger than the shell tool's presentation limit."""
import sys
from process_fixture import record_identity

record_identity(sys.argv[1])

if len(sys.argv) > 2:
    with open(sys.argv[2], "ab") as counter:
        counter.write(b"once\n")

sys.stdout.buffer.write(b"0123456789abcdef retained-output\n" * 4096)
