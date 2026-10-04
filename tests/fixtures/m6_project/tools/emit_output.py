import sys


stdout_bytes = int(sys.argv[1])
stderr_bytes = int(sys.argv[2])

sys.stdout.write("o" * stdout_bytes)
sys.stdout.flush()
sys.stderr.write("e" * stderr_bytes)
sys.stderr.flush()
