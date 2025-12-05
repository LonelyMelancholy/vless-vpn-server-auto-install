#!/bin/bash

# Check Ubuntu Pro Token
UBUNTU_PRO_TOKEN=$(awk -F'"' '/^Ubuntu Pro Token/ {print $2}' "$CFG_FILE")
if [[ -z "$UBUNTU_PRO_TOKEN" ]]; then
    echo "⚠️ Error: could not find 'Ubuntu Pro Token' in $CFG_FILE, skip"
else
    echo "✅ Ubuntu Pro Token accepted"
fi

export DEBIAN_FRONTEND=noninteractive
while true; do
    echo "⚠️ Updating packages list, wait"
    if apt-get update >/dev/null 2>&1; then
        echo "✅ Update packages list completed"
    else
        echo "❌ Updating package list failed, try again"
        sleep 5
        continue
    fi
    echo "⚠️ Updating packages, wait"
    if apt-get dist-upgrade -y >/dev/null 2>&1; then
        echo "✅ Package update completed"
    else
        echo "❌ Updating package failed, try again"
        sleep 5
        continue
    fi
        break
done

exit 0