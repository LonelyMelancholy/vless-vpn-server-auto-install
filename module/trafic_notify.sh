#!/bin/bash
# 0 1 * * * /usr/local/bin/trafic_notify.sh &> /dev/null

ENV_FILE="/etc/telegram-bot.env"
[ -r "$ENV_FILE" ] || exit 0
source "$ENV_FILE"

XRAY="/usr/local/bin/xray"
APISERVER="127.0.0.1:8080"

# сбрасываем счётчики только 1-го числа
RESET_ARG=""
[ "$(date +%d)" = "01" ] && RESET_ARG="--reset"

# получаем JSON со статистикой
RAW="$("$XRAY" api statsquery --server="$APISERVER" $RESET_ARG 2>/dev/null)"

# парсим JSON -> строки вида: kind:id->dir\tvalue   (dir: uplink|downlink)
DATA="$(echo "$RAW" | awk '
  /"name"[[:space:]]*:/ {
    if (match($0, /"name"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      name=m[1]; have=0
    }
  }
  /"value"[[:space:]]*:/ {
    if (name!="" && match($0, /"value"[[:space:]]*:[[:space:]]*([0-9]+)/, v)) {
      split(name, p, ">>>"); kind=p[1]; id=p[2]; dir=p[4];
      printf "%s:%s->%s\t%s\n", kind, id, dir, v[1]; have=1
    }
  }
  /}/ {
    if (name!="" && !have) { split(name, p, ">>>"); kind=p[1]; id=p[2]; dir=p[4];
      printf "%s:%s->%s\t0\n", kind, id, dir
    }
    name=""; have=0
  }
')"

# суммы по inbound/outbound (считаем, но не печатаем по отдельности)
read IN_UP IN_DOWN OUT_UP OUT_DOWN <<EOF
$(echo "$DATA" | awk -F'\t' '
$1 ~ /^inbound:/  { if ($1 ~ /->uplink$/)   iu+=$2; else if ($1 ~ /->downlink$/)   id+=$2 }
$1 ~ /^outbound:/ { if ($1 ~ /->uplink$/)   ou+=$2; else if ($1 ~ /->downlink$/)   od+=$2 }
END { printf "%s %s %s %s\n", iu+0, id+0, ou+0, od+0 }')
EOF
TOTAL=$((IN_UP + IN_DOWN + OUT_UP + OUT_DOWN))

# трафик по пользователям (только total)
USERS="$(echo "$DATA" | awk -F'\t' '
$1 ~ /^user:/{
  name=$1; val=$2; sub(/^user:/,"",name); split(name,a,"->"); email=a[1];
  sum[email]+=val
}
END{
  PROCINFO["sorted_in"]="@ind_str_asc";
  for (e in sum) print e "\t" sum[e]+0;
}')"

# форматирование байтов (numfmt опционален)
fmt(){ numfmt --to=iec --suffix=B "$1"; }

# собираем сообщение
DATE=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)
MSG="📢 Daily traffic report

🖥️ Host: $HOSTNAME
🖥 Host total: $(fmt "$TOTAL")"
# умножаем пользовательский total на 2 перед выводом
while IFS=$'\t' read -r EMAIL T; do
  T2=$(( T * 2 ))
  MSG="$MSG
🧑🏿‍💻 User total: $EMAIL - $(fmt "$T2")"
done <<< "$USERS"

MSG="$MSG
⌚ Time: $DATE"

# отправка в Telegram
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$MSG"