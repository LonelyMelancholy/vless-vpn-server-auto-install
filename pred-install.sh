#!/bin/bash

echo "📢 Info: Starting System Update Procedure"

# Root checking
if [[ $EUID -ne 0 ]]; then
    sleep 1
    echo "❌ Error: you are not root user, exit"
    exit 1
else
    sleep 1
    echo "✅ Success: you are root user, continued"
fi

# Check configuration file
CFG_CHECK="module/cfg_check.sh"
[ -r "$CFG_CHECK" ] || { sleep 1; echo "❌ Error: check $CFG_CHECK it's missing or you not have right to read"; exit 1; }
source "$CFG_CHECK"

# Update system
if [[ -n "$UBUNTU_PRO_TOKEN" ]]; then
    if echo "📢 Info: try to activate Ubuntu pro, please wait" && \
    pro attach "$UBUNTU_PRO_TOKEN" > logs/ubuntu_pro.log 2>&1
    then
        echo "✅ Success: Ubuntu Pro activated"
    else
        echo "⚠️  Non-critical error: Warning: Ubuntu Pro activation error, check logs/ubuntu_pro.log for more info, continued"
    fi
fi

LOG_UPDATE_LIST="logs/update_list.log"
LOG_INSTALL_UTILITES="logs/install_utilites.log"
LOG_UPDATE_DIST="logs/update_dist.log"

install_and_update() {
    local action=$1
    local log=$2
    shift 2
    local attempt=1
    local max_attempt=3

    while true; do
        echo "📢 Info: ${action}, $attempt attempt, please wait"
        if "$@" >> "$log" 2>&1; then
            echo "✅ Success: $action completed"
            break
        fi
        if [ "$attempt" -lt "$max_attempt" ]; then
            sleep 10
            echo "⚠️ Non-critical error: $action failed, trying again"
            attempt=$((attempt+1))
            continue
        else
            echo "❌ Error: $action failed attempts ended, check $log, exit"
            exit 1
        fi
    done
}

# utilites check
for utilite in curl unzip; do
    if ! command -v "$utilite" &> /dev/null; then
        UTILITES_REQ+="$utilite "
        sleep 1
        echo "📢 Info: required utilites ${utilite} not found, prepare for installation"
    fi
done

# cut last space in variable if variable not empty
[ -z "$UTILITES_REQ" ] || UTILITES_REQ="${UTILITES_REQ% }"

install_and_update "update packages list" "$LOG_UPDATE_LIST" apt-get update
[ -z "$UTILITES_REQ" ] || install_and_update "install required utilites $UTILITES_REQ" "$LOG_INSTALL_UTILITES" apt-get -y install $UTILITES_REQ
install_and_update "Updating package" "dist-upgrade" "$LOG_UPDATE_DIST" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew dist-upgrade

echo "✅ Success: System will reboot"

# reboot after pause
sleep 1
reboot || { echo "❌ Error: reboot command failed, exit"; exit 1; }

exit 0