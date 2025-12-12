#!/bin/bash

ENV_FILE="/usr/local/etc/telegram/secrets.env"
[ -r "$ENV_FILE" ] || exit 1
source "$ENV_FILE"

ACTION="$1"
IP="$2"
BAN_TIME="$(( $3 / 86400 )) days"
HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')

if [ "$ACTION" = "ban" ]; then
MESSAGE="⚠️ SSH jail notify (ban)

🖥️ Host: $HOSTNAME
⌚ Time: $DATE
💀 Banned for: $BAN_TIME in jail
🏴‍☠️ From: $IP
💾 Logfile: /var/log/fail2ban.log"
else
MESSAGE="⚠️ SSH jail notify (unban)

🖥️ Host: $HOSTNAME
⌚ Time: $DATE
💀 Unbanned after: $BAN_TIME in jail
🏴‍☠️ From: $IP
💾 Logfile: /var/log/fail2ban.log"
fi

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$MESSAGE" \
    > /dev/null 2>&1

exit 0