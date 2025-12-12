#!/bin/bash

ENV_FILE="/usr/local/etc/telegram/secrets.env"
[ -r "$ENV_FILE" ] || exit 0
source "$ENV_FILE"

HOSTNAME=$(hostname)
IP=$PAM_RHOST
USER=$PAM_USER
DATE=$(date '+%Y-%m-%d %H:%M:%S')

if [ "$PAM_TYPE" = "open_session" ]; then
    ACTION="📢 Successful SSH login"
elif [ "$PAM_TYPE" = "close_session" ]; then
    ACTION="📢 Successful SSH logout"
else
    exit 0
fi

MESSAGE="$ACTION

🖥️ Host: $HOSTNAME
⌚ Time: $DATE
🧑🏿‍💻 User: $USER
🏴 From: $IP
💾 Logfile: /var/log/auth.log"

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
     -d chat_id="$CHAT_ID" \
     -d text="$MESSAGE"