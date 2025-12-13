#!/bin/bash
# done

echo "📢 Info: starting the procedure for preparing the system for installation"

# root checking
if [[ "$EUID" -ne 0 ]]; then
    sleep 1
    echo "❌ Error: you are not root user, exit"
    exit 1
else
    sleep 1
    echo "✅ Success: you are root user, continue"
fi

[[ -r /etc/os-release ]] || { sleep 1; echo "❌ Error: '/etc/os-release' missing or you do not have read permissions, exit"; exit 1; }
source /etc/os-release
if [[ "$ID" != "ubuntu" ]] || [[ "${VERSION_ID%%.*}" -lt 20 ]]; then
    sleep 1
    echo "❌ Error: this script requires Ubuntu 20.04 or higher, exit"
    exit 1
else
    sleep 1
    echo "📢 Info: system version '$PRETTY_NAME'"
fi

# check another instance of the script is not running
readonly LOCK_FILE="/var/run/pred-install.lock"
exec 9> "$LOCK_FILE" || { sleep 1; echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { sleep 1; echo "❌ Error: another instance is running, exit"; exit 1; }

# create log dir and check writable
mkdir -p logs &> /dev/null || { sleep 1; echo "❌ Error: cannot create 'logs' directory, exit"; exit 1; }
[[ -d logs && -w logs && -x logs ]] || { sleep 1; echo "❌ Error: logs directory is not writable, exit"; exit 1; }

# all log files
LOG_UBUNTU_PRO="logs/ubuntu_pro.log"
LOG_UPDATE_LIST="logs/update_list.log"
LOG_INSTALL_UTILITIES="logs/install_utilities.log"
LOG_UPDATE_DIST="logs/update_dist.log"
LOG_CLEANUP="logs/cleanup.log"

# check configuration file
CFG_CHECK="module/cfg_check.sh"
[[ -r "$CFG_CHECK" ]] || { sleep 1; echo "❌ Error: check '$CFG_CHECK' it's missing or you do not have read permissions, exit"; exit 1; }
source "$CFG_CHECK"

# update system
if [[ -n "$UBUNTU_PRO_TOKEN" ]]; then
    if command -v pro &> /dev/null; then
        sleep 1
        echo "📢 Info: try to activate Ubuntu Pro, please wait"
        if pro attach "$UBUNTU_PRO_TOKEN" &>> "$LOG_UBUNTU_PRO"; then
            sleep 1
            echo "✅ Success: Ubuntu Pro activated"
        else
            sleep 1
            echo "⚠️  Non-critical error: Ubuntu Pro activation error, check '$LOG_UBUNTU_PRO' for more info, continue"
        fi
    else
        sleep 1
        echo "⚠️  Non-critical error: 'pro' command not found, skipping Ubuntu Pro attach"
    fi
fi

# function for install utilities an update
install_and_update() {
    local action="$1"
    local log="$2"
    shift 2
    local attempt=1
    local max_attempt=3

    while true; do
        sleep 1
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        # $@ passes all remaining arguments (after the first two)
        if "$@" &>> "$log"; then
            sleep 1
            echo "✅ Success: $action completed"
            return 0
        fi
        if [[ "$attempt" -lt "$max_attempt" ]]; then
            sleep 60
            echo "⚠️  Non-critical error: $action failed, trying again"
            ((attempt++))
            continue
        else
            sleep 1
            echo "❌ Error: $action failed, attempts ended, check '$log', exit"
            exit 1
        fi
    done
}

# utilities check
missing_pkgs=()
for utility in curl unzip; do
    if ! command -v "$utility" &> /dev/null; then
        missing_pkgs+=("$utility")
    fi
done

# set command for $@
cmd_update=(apt-get update)
cmd_install=(env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew install)
cmd_dist=(env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew dist-upgrade)

# start main logic
install_and_update "update packages list" "$LOG_UPDATE_LIST" "${cmd_update[@]}"
if [[ "${#missing_pkgs[@]}" -gt 0 ]]; then
    sleep 1
    echo "📢 Info: required utilities '${missing_pkgs[*]}' not found, prepare for installation"
    install_and_update "install required utilities: '${missing_pkgs[*]}'" "$LOG_INSTALL_UTILITIES" \
        "${cmd_install[@]}" "${missing_pkgs[@]}"
fi
install_and_update "updating packages" "$LOG_UPDATE_DIST" "${cmd_dist[@]}"

# clean apt cache
sleep 1
echo "📢 Info: cleaning up package cache, please wait"
if apt-get clean &>> "$LOG_CLEANUP"; then
    sleep 1
    echo "✅ Success: cleaned package cache"
else
    sleep 1
    echo "⚠️  Non-critical error: failed to clean cache, check '$LOG_CLEANUP' for more info, continue"
fi

# countdown before reboot
sleep 1
countdown() {
    local sec=$1
    while [[ "$sec" -gt 0 ]]; do
        printf "\r✅ Success: system will reboot after %2d sec, Ctrl+C to interrupt" "$sec"
        sleep 1
        ((sec--))
    done
    printf "\r✅ Success: launch server reboot                                      \n"
}
countdown 10

# reboot after pause
reboot &> /dev/null || { echo "❌ Error: reboot command failed, exit"; exit 1; }