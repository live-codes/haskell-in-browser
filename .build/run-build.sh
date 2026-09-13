#!/usr/bin/env bash
# Wrapper run inside the Ubuntu container (see BUILD.md "Adding a package").
# Keeps the command line short so the mounts and quoting stay readable.
apt-get update -qq
apt-get install -y -qq build-essential git curl ca-certificates >/dev/null
cp /scripts/build-packages-linux.sh /tmp/build-packages.sh
WORK=/build OUT=/out DB=/db bash /tmp/build-packages.sh > /out/build.log 2>&1
status=$?
echo "build-packages.sh exited with $status"
echo "--- last 40 lines of /out/build.log ---"
tail -40 /out/build.log
exit $status
