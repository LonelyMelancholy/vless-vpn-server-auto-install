#!/bin/bash
# xray auto traffic notify via cron every day 1:01 night time
# all errors are logged, except the first three, for debug add debug log in cron
# 10 1 * * * /usr/local/bin/telegram/exp_notify.sh &> /dev/null
# exit codes work to tell Cron about success
# done work
# done test

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/telegram"
readonly NOTIFY_LOG="${LOG_DIR}/exp.${DATE_LOG}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 1; }
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## expiration notify started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local DATE_END="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## expiration notify ended - $DATE_END ##########"
    else
        local DATE_FAIL="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## expiration notify failed - $DATE_FAIL ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# main variables
readonly XRAY="/usr/local/bin/xray"
readonly APISERVER="127.0.0.1:8080"
readonly HOSTNAME="$(hostname)"
readonly MAX_ATTEMPTS="3"

# pure Telegram message function with checking the sending status
_tg_m() {
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${MESSAGE}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# Telegram message with logging and retry
telegram_message() {
    local attempt="1"
    while true; do
        if ! _tg_m; then
            if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
                echo "❌ Error: failed to send Telegram message after $attempt attempt, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: message was sent to Telegram after $attempt attempt"
            RC="0"
            break
        fi
    done
    return 0
}

# check secret file, if the file is ok, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -c '%U:%a' "$ENV_FILE" 2>/dev/null)" != "root:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 1; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 1; }

# main logic start here

# get stat json
readonly RAW="$("$XRAY" api statsquery --server="$APISERVER" 2> /dev/null)"

# parse 
USERS_LEFT=$(
  jq -r '
    def parse_date: strptime("%Y-%m-%d") | mktime;
    def today_midnight: (now | strftime("%Y-%m-%d") | parse_date);

    def parse_userstr:
      split("|") as $p
      | {
          user:   $p[0],
          created: ($p[1] // "" | split("=")[1] // null),
          days:    ($p[2] // "" | split("=")[1] // null),
          exp:     ($p[3] // "" | split("=")[1] // null)
        };

    def remaining($t):
      if (.days == "infinity") or (.exp == "never") then
        "infinity"
      else
        (
          if (.exp != null and (.exp|test("^\\d{4}-\\d{2}-\\d{2}$"))) then
            (.exp | parse_date)
          elif (.created != null and .days != null and (.days|test("^\\d+$"))) then
            ((.created | parse_date) + ((.days|tonumber) * 86400))
          else
            null
          end
        ) as $end
        | if $end == null then null else (($end - $t) / 86400 | floor) end
      end;

    [ .stat[].name
      | select(startswith("user>>>"))
      | sub("^user>>>";"")
      | split(">>>traffic")[0]
    ]
    | unique
    | map(parse_userstr | {key: .user, val: (remaining(today_midnight))})
    | .[]
    | "\(.key) \(.val)"
  ' <<< "$RAW"
)

# start collecting message
readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

MESSAGE="📢<b> Daily expiration report</b> 

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE"

while IFS=$' ' read -r EMAIL DAYS; do
  MESSAGE="$MESSAGE
🧑🏿‍💻 <b>User:</b> $EMAIL - $DAYS days left"
done <<< "$USERS_LEFT"

MESSAGE="$MESSAGE
💾 <b>Xray error log:</b> /var/log/xray/error.log
💾 <b>Xray access log:</b> /var/log/xray/access.log
💾 <b>Notify log:</b> $NOTIFY_LOG"

# logging message
echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC