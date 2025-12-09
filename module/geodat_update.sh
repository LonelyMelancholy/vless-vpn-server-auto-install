#!/bin/bash

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# enable logging
readonly DATE=$(date +"%Y-%m-%d")
readonly UPDATE_LOG="/var/log/xray/update.${DATE}.log"
exec >>"$UPDATE_LOG" 2>&1

# start logging message
readonly DATE_START=$(date "+%Y-%m-%d %H:%M:%S")
echo "   ########## update started - $DATE_START ##########   "

# error exit log message for end log
trap 'exit_fail' EXIT
RC=1

# exit log message function
exit_fail() {
    if [ "$RC" = "0" ]; then
        echo "   ########## update ended - $DATE_END ##########   "
    else
        DATE_FAIL=$(date "+%Y-%m-%d %H:%M:%S")
        echo "   ########## update failed - $DATE_FAIL ##########   "
    fi
}

# root checking
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: you are not root user, exit"
    exit 1
fi

# check another instanse script running
readonly LOCK_FILE="/var/run/geodat_update.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "❌ Error: another instance is running, exit"
    exit 1
fi

# main variables
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
readonly ASSET_DIR="/usr/local/share/xray"
readonly XRAY_DIR="/usr/local/bin"
readonly GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
readonly XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
readonly HOSTNAME=$(hostname)
readonly MAX_ATTEMPTS=3
STAGE="0"

# check secret file
if [ ! -r "$ENV_FILE" ]; then
    echo "❌ Error: env file $ENV_FILE not found or not readable, exit"
    exit 1
fi
source "$ENV_FILE"

# Check token from secret file
if [[ -z "$BOT_TOKEN" ]]; then
    echo "❌ Error: telegram bot token is missing in $ENV_FILE, exit"
    exit 1
fi

# Check id from secret file
if [[ -z "$CHAT_ID" ]]; then
    echo "❌ Error: telegram chat id is missing in $ENV_FILE, exit"
    exit 1
fi

# pure telegram message function
tg_m() {
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${MESSAGE}" \
        > /dev/null
}

# telegram message with logging and retry
telegram_message() {
# reset attempt for next while
    local attempt=1
# call telegramm post funct 
    while true; do
        if ! tg_m; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                echo "❌ Error: failed to sent telegram message after $attempt attempts, exit"
                RC=1
                return 1
            fi
            sleep 10
            attempt=$((attempt + 1))
            continue
        else
            echo "✅ Success: message was sent to telegram after $attempt attempts"
            break
        fi
    done
}

# exit cleanup and log message function
cleanup() {
    if rm -rf "$TMP_DIR"; then
        echo "✅ Success: temporary directory $TMP_DIR deleted"
        DATE_DEL_SUCCESS=$(date "+%Y-%m-%d %H:%M:%S")
        echo "   ########## cleanup ended - $DATE_DEL_SUCCESS ##########   "
    else
        echo "❌ Error: temporary directory $TMP_DIR was not deleted"
        DATE_DEL_ERROR=$(date "+%Y-%m-%d %H:%M:%S")
        echo "   ########## cleanup fail - $DATE_DEL_ERROR ##########   "
        MESSAGE="🖥️ Host: $HOSTNAME
⌚ Time error: $DATE_DEL_ERROR
❌ Error: temporary directory $TMP_DIR for xray update was not deleted"
    RC=1
    telegram_message
    fi
}

# create working directory
readonly TMP_DIR="$(mktemp -d)" || {
    echo "❌ Error: failed to create temporary directory, exit"
    exit 1
}

# rewrite trap exit, now error exit log message for end log and cleanup temp directory
trap 'exit_fail; cleanup' EXIT

# download function
dl() { curl -fsSL "$1" -o "$2"; }

# download and check checksum function
download_and_verify() {
    local url="$1"
    local outfile="$2"
    local name="$3"
    local sha256sum_file="${outfile}.sha256sum"
    local dgst_file="${outfile}.dgst"
    local attempt=1
    local next_file=$4
    local expected_sha_dgst actual_sha_zip
    local expected_sha_dat actual_sha_dat
    UNPACK_DIR="$TMP_DIR/xray-unpacked"

# Increase stage count
    STAGE=$((STAGE+1))

# download main file
    while true; do
        if ! dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                echo "❌ Error: stage ${STAGE}, failed to download $outfile after $attempt attempts${next_file}, exit"
                return 1
            fi
            sleep 10
            attempt=$((attempt + 1))
            continue
        else
            echo "✅ Success: stage ${STAGE}, successful download $outfile after $attempt attempts${next_file}"
            break
        fi
    done

# reset attempt for next while
    attempt=1
# Increase stage count
    STAGE=$((STAGE+1))

# download checksum depending on the name there are two ways
    while true; do
# download .dgst checksum if name xray
        if [ "$name" = "xray" ]; then
            if ! dl "${url}.dgst" "$dgst_file"; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    echo "❌ Error: stage ${STAGE}, failed to download ${name} after $attempt attempts, exit"
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                echo "✅ Success: stage ${STAGE}, successful download ${name} after $attempt attempts"
                break
            fi
# download checksum if other name (geoip.dat, geosite.dat)
        else
            if ! dl "${url}.sha256sum" "$sha256sum_file"; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    echo "❌ Error: stage ${STAGE}, failed to download ${name}.sha256sum after $attempt attempts, exit" 
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                echo "✅ Success: stage ${STAGE}, successful download ${name}.sha256sum after $attempt attempts"
                break
            fi
        fi
    done

# Increase stage count
    STAGE=$((STAGE+1))

# extract sha256sum from .dgst or .sha256sum depending on the name there are two ways
# reset sha
        expected_sha_dgst=""
        expected_sha_dat=""
# extract sha256sum from .dgst if name xray
        if [ "$name" = "xray" ]; then
            expected_sha_dgst="$(awk '/^SHA2-256/ {print $2}' "$dgst_file")"
            if [ -z "$expected_sha_dgst" ]; then
                echo "❌ Error: stage ${STAGE}, failed to parse SHA256 from ${dgst_file}, exit"
                return 1
            else
                echo "✅ Success: stage ${STAGE}, successful parse SHA256 from ${dgst_file}"
            fi
# extract sha256sum from .sha256sum if other name (geoip.dat, geosite.dat)
        else
            expected_sha_dat="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null)"
            if [ -z "$expected_sha_dat" ]; then
                echo "❌ Error: stage ${STAGE}, failed to parse SHA256 from ${sha256sum_file}, exit"
                return 1
            else
                echo "✅ Success: stage ${STAGE}, successful parse SHA256 from ${sha256sum_file}"
            fi
        fi

# Increase stage count
    STAGE=$((STAGE+1))

# extract actual sha256sum from .zip or .dat depending on the name there are two ways
# reset sha
        actual_sha_zip=""
        actual_sha_dat=""
# extract sha256sum from .zip if name xray
        if [ "$name" = "xray" ]; then
            actual_sha_zip="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha_zip" ]; then
                echo "❌ Error: stage ${STAGE}, failed to extract SHA256 from ${outfile}, exit"
                return 1
            else
                echo "✅ Success: stage ${STAGE}, successful extraction SHA256 from ${outfile}"
            fi
# extract sha256sum from .dat if other name (geoip.dat, geosite.dat)
        else
            actual_sha_dat="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha_dat" ]; then
                echo "❌ Error: stage ${STAGE}, failed to extract SHA256 from ${outfile}, exit"
                return 1
            else
                echo "✅ Success: stage ${STAGE}, successful extraction SHA256 from ${outfile}"
            fi
        fi

# Increase stage count
    STAGE=$((STAGE+1))

# compare sha256sum checksum depending on the name there are two ways
# compare sha256sum checksum if name xray
    if [ "$name" = "xray" ]; then
        if [ "$expected_sha_dgst" != "$actual_sha_zip" ]; then
            echo "📢 Info: stage ${STAGE}, expected sha from .dgst=$expected_sha_dgst"
            echo "📢 Info: stage ${STAGE}, actual sha from .zip=$actual_sha_zip"
            echo "❌ Error: stage ${STAGE}, failed to compare, actual and expected SHA256 do not match for ${name}, exit"
            return 1
        else
            echo "📢 Info: stage ${STAGE}, expected sha from .dgst=$expected_sha_dgst"
            echo "📢 Info: stage ${STAGE}, actual sha from .zip=$actual_sha_zip"
            echo "✅ Success: stage ${STAGE}, actual and expected SHA256 match for ${name}"

        fi
# compare sha256sum checksum if other name (geoip.dat, geosite.dat)
    else
        if [ "$expected_sha_dat" != "$actual_sha_dat" ]; then
            echo "📢 Info: stage ${STAGE}, expected sha from .sha256sum=$expected_sha_dat"
            echo "📢 Info: stage ${STAGE}, actual sha from .dat=$actual_sha_dat"
            echo "❌ Error: stage ${STAGE}, failed to compare, actual and expected SHA256 do not match for ${name}, exit"
            return 1
        else
            echo "📢 Info: stage ${STAGE}, expected sha from .sha256sum=$expected_sha_dat"
            echo "📢 Info: stage ${STAGE}, actual sha from .dat=$actual_sha_dat"
            echo "✅ Success: stage ${STAGE}, actual and expected SHA256 match for ${name}"
        fi
    fi

# unzip archive if name=xray
    if [ "$name" = "xray" ]; then
# Increase stage count
        STAGE=$((STAGE+1))
# unpack archive
        if ! mkdir -p "$UNPACK_DIR"; then
            echo "❌ Error: stage ${STAGE}, failed to create directory for unpacking ${outfile}, exit"
            return 1
        else
            echo "✅ Success: stage ${STAGE}, the directory for unpacking ${outfile} has been created"
        fi
        if ! unzip -o "$outfile" -d "$UNPACK_DIR" >/dev/null 2>&1; then
            echo "❌ Error: stage ${STAGE}, failed to extract ${outfile}, exit"
            return 1
        else
            echo "✅ Success: stage ${STAGE}, ${outfile} successfully extracted"
        fi
# check xray binary
        if [ ! -f "$UNPACK_DIR/xray" ]; then
            echo "❌ Error: stage ${STAGE}, xray binary is missing from folder after unpacking ${outfile}, exit"
            return 1
        else
            echo "✅ Success: stage ${STAGE}, xray binary exists in the folder after unpacking ${outfile}"
        fi
    fi

    return 0
}

install_xray() {
    XRAY_NEW_VER=""
    XRAY_OLD_VER=""

# increase stage count
    STAGE=$((STAGE+1))
# check xray version
    if [ -x "$UNPACK_DIR/xray" ]; then
        XRAY_NEW_VER="$("$UNPACK_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        echo "❌ Error: stage ${STAGE}, unknown new xray version, exit"
        return 1
    fi

    if [ -x "$XRAY_DIR/xray" ]; then
        XRAY_OLD_VER="$("$XRAY_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        XRAY_OLD_VER=""
        echo "❌ Error: stage ${STAGE}, unknown old xray version, exit"
        return 1
    fi

    if [ -n "$XRAY_NEW_VER" ] && [ -n "$XRAY_OLD_VER" ] && [ "$XRAY_NEW_VER" = "$XRAY_OLD_VER" ]; then
        echo "📢 Info: stage ${STAGE}, xray already up to date ($XRAY_NEW_VER), skip xray update"
        XRAY_UP_TO_DATE=1
    else
        echo "📢 Info: stage ${STAGE}, current xray version $XRAY_OLD_VER, actual ($XRAY_NEW_VER) get ready for the update"
        XRAY_UP_TO_DATE=0
    fi

# increase stage count
    STAGE=$((STAGE+1))
# old file backup
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        if cp "$XRAY_DIR/xray" "$XRAY_DIR/xray.${DATE}.bak"; then
            echo "✅ Success: stage ${STAGE}, xray bin backup completed"
        else
            echo "❌ Error: stage ${STAGE}, xray bin backup failed, exit"
            return 1
        fi
    else
        echo "📢 Info: stage ${STAGE}, xray already up to date, backup not needed"
    fi

    if cp "$ASSET_DIR/geoip.dat" "$ASSET_DIR/geoip.dat.${DATE}.bak"; then
        echo "✅ Success: stage ${STAGE}, geoip.dat backup completed"
    else
        echo "❌ Error: stage ${STAGE}, geoip.dat backup failed"
        return 1
    fi

    if cp "$ASSET_DIR/geosite.dat" "$ASSET_DIR/geosite.dat.${DATE}.bak"; then
        echo "✅ Success: stage ${STAGE}, geosite.dat backup completed"
    else
        echo "❌ Error: stage ${STAGE}, geosite.dat backup failed"
        return 1
    fi

# increase stage count
    STAGE=$((STAGE+1))
# stop xray service
    if systemctl stop xray.service > /dev/null 2>&1; then
        echo "✅ Success: stage ${STAGE}, xray.service stopped, starting the update"
    else
        echo "❌ Error: stage ${STAGE}, xray.service failure to stop, canceling update"
        echo "📢 Info: stage ${STAGE}, checking status xray.service "
        if systemctl status xray.service > /dev/null 2>&1; then
            echo "✅ Success: stage ${STAGE}, xray.service running, try updating again later"
            return 1
        else
            echo "❌ Error: stage ${STAGE}, xray.service status failed, trying to start"
            if systemctl start xray.service > /dev/null 2>&1; then
                echo "✅ Success: stage ${STAGE}, xray.service started, try updating again later."
                return 1
            else
                echo "❌ Critical Error: stage ${STAGE}, xray.service does not start"
                return 1
            fi
        fi 
    fi

# increase stage count
    STAGE=$((STAGE+1))
# install bin and geo*.dat
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        if install -m 755 -o xray -g xray "$UNPACK_DIR/xray" "$XRAY_DIR/xray"; then
            echo "✅ Success: stage ${STAGE}, xray binary installed"
        else
            echo "❌ Error: stage ${STAGE}, xray binary not installed, trying rollback"
            if ! cp "$XRAY_DIR/xray.${DATE}.bak" "$XRAY_DIR/xray"; then
                echo "❌ Error: stage ${STAGE}, xray binary rollback failed"
            else
                echo "✅ Success: stage ${STAGE}, xray binary rollback successfully"
            fi
            if systemctl start xray.service > /dev/null 2>&1; then
                echo "✅ Success: stage ${STAGE}, xray.service started, try updating again later, exit."
                return 1
            else
                echo "❌ Critical Error: stage ${STAGE}, xray.service does not start, exit"
                return 1
            fi
        fi
    else
        echo "📢 Info: stage ${STAGE}, xray binary skip installation"
    fi

    if install -m 644 -o xray -g xray "$TMP_DIR/geoip.dat" "$ASSET_DIR/geoip.dat"; then
        echo "✅ Success: stage ${STAGE}, geoip.dat installed"
    else
        echo "❌ Error: stage ${STAGE}, geoip.dat not installed, trying rollback"
        if ! cp "$ASSET_DIR/geoip.dat.${DATE}.bak" "$ASSET_DIR/geoip.dat"; then
            echo "❌ Error: stage ${STAGE}, geoip.dat rollback failed"
        else
            echo "✅ Success: stage ${STAGE}, geoip.dat rollback successfully"
        fi
        if systemctl start xray.service > /dev/null 2>&1; then
            echo "✅ Success: stage ${STAGE}, xray.service started, try updating again later, exit."
            return 1
        else
            echo "❌ Critical Error: stage ${STAGE}, xray.service does not start, exit"
            return 1
        fi
    fi

    if install -m 644 -o xray -g xray "$TMP_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"; then
        echo "✅ Success: stage ${STAGE}, geosite.dat installed"
    else
        echo "❌ Error: stage ${STAGE}, geosite.dat not installed, trying rollback"
        if ! cp "$ASSET_DIR/geosite.dat.${DATE}.bak" "$ASSET_DIR/geosite.dat"; then
            echo "❌ Error: stage ${STAGE}, geosite.dat rollback failed"
        else
            echo "✅ Success: stage ${STAGE}, geosite.dat rollback successfully"
        fi
        if systemctl start xray.service > /dev/null 2>&1; then
            echo "✅ Success: stage ${STAGE}, xray.service started, try updating again later, exit."
            return 1
        else
            echo "❌ Critical Error: stage ${STAGE}, xray.service does not start, exit"
            return 1
        fi
    fi

# increase stage count
    STAGE=$((STAGE+1))
# start xray
    if systemctl start xray.service > /dev/null 2>&1; then
        echo "✅ Success: stage ${STAGE}, xray.service updated and started"
    else
        echo "❌ Critical Error: stage ${STAGE}, xray.service does not start"
        return 1
    fi

    return 0
}

# main logic start here
# update xray
if ! download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray" ", skip download geoip.dat, geosite.dat"; then
    XRAY_DOWNLOAD=false
    STATUS_XRAY_MESSAGE="[↻] Xray download failed"
else
    STATUS_XRAY_MESSAGE="[↻] Xray binary download success"
    XRAY_DOWNLOAD=true
fi

# update geoip if xray success
if [ "$XRAY_DOWNLOAD" = "true" ]; then
    if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat" ", skip download geosite.dat"; then
        GEOIP_DOWNLOAD=false
        STATUS_GEOIP_MESSAGE="[↻] geoip.dat download failed"
    else
        STATUS_GEOIP_MESSAGE="[↻] Xray geoip.dat download success"
        GEOIP_DOWNLOAD=true
    fi
else
    GEOIP_DOWNLOAD=false
    STATUS_GEOIP_MESSAGE="[↻] geoip.dat download skip"
fi

# update geosite if geoip success
if [ "$XRAY_DOWNLOAD" = "true" ] && [ "$GEOIP_DOWNLOAD" = "true" ]; then
    if ! download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"; then
        GEOSITE_DOWNLOAD=false
        STATUS_GEOSITE_MESSAGE="[↻] geosite.dat download failed"
    else
        STATUS_GEOSITE_MESSAGE="[↻] Xray geosite.dat download success"
        GEOSITE_DOWNLOAD=true
    fi
else
    GEOSITE_DOWNLOAD=false
    STATUS_GEOSITE_MESSAGE="[↻] geosite.dat download skip"
fi

if [ "$XRAY_DOWNLOAD" = "true" ] && [ "$GEOIP_DOWNLOAD" = "true" ] && [ "$GEOSITE_DOWNLOAD" = "true" ]; then
    if ! install_xray; then
        STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install failed"
        XRAY_INSTALL=false
    else
        if [ "$XRAY_UP_TO_DATE" = "1" ]; then
            STATUS_INSTALL_MESSAGE="[↻] geo*.dat install success"$'\n'
            STATUS_INSTALL_MESSAGE+="[↻] Xray already up to date $XRAY_OLD_VER"
            XRAY_INSTALL=true
        else
            STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install success"$'\n'
            STATUS_INSTALL_MESSAGE+="[↻] Xray updated from $XRAY_OLD_VER to $XRAY_NEW_VER"
            XRAY_INSTALL=true
        fi
    fi
else
    XRAY_INSTALL=false
    STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install skip"
fi

# check final xray status
if systemctl status xray.service > /dev/null 2>&1; then
    STATUS_XRAY="✅ Success: xray.service running"
else
    STATUS_XRAY="❌ Critical Error: xray.service does not start"
fi

readonly DATE_END=$(date "+%Y-%m-%d %H:%M:%S")

# select a title for the telegramm message
if [ "$XRAY_DOWNLOAD" = "true" ] && [ "$GEOIP_DOWNLOAD" = "true" ] && [ "$GEOSITE_DOWNLOAD" = "true" ] && [ "$XRAY_INSTALL" = "true" ]; then
    MESSAGE_TITLE="✅ Upgrade report"
    RC=0
else
    MESSAGE_TITLE="❌ Upgrade error"
    RC=1
fi

# collecting report for telegram message
MESSAGE="$MESSAGE_TITLE

🖥️ Host: $HOSTNAME
⌚ Time start: $DATE_START
⌚ Time end: $DATE_END
${STATUS_XRAY_MESSAGE}
${STATUS_GEOIP_MESSAGE}
${STATUS_GEOSITE_MESSAGE}
${STATUS_INSTALL_MESSAGE}
${STATUS_XRAY}
💾 Logfile: ${UPDATE_LOG}"

telegram_message

exit $RC