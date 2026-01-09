#!/bin/bash
# script for collecting xray traffic stat via cron every 1m
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 0 * * * * telegram-gateway /usr/local/bin/service/xray_stat.sh &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/service"
readonly NOTIFY_LOG="${LOG_DIR}/xray_stat.${DATE_LOG}.log"
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## xray stat started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local DATE_END="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## xray stat ended - $DATE_END ##########"
    else
        local DATE_FAIL="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## xray stat failed - $DATE_FAIL ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# check another instanсe of the script is not running
readonly LOCK_FILE_3="/run/lock/tr_db.lock"
exec 10> "$LOCK_FILE_3" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_3', exit"; exit 1; }
# check another instance is not running (with retries)
wait_sec=10
readonly MAX_ATTEMPTS="3"
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if flock -n 10; then
    break
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "❌ Error: Lock busy ($LOCK_FILE_3). Waiting ${wait_sec}s... (attempt $attempt/$MAX_ATTEMPTS)"
    sleep "$wait_sec"
  else
    echo "❌ Error: lock ($LOCK_FILE_3) is still busy after $MAX_ATTEMPTS attempts, exit"
    exit 1
  fi
done

# helper func
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
        return 0
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

# main variable
readonly OUT_FILE_M="/var/log/xray/TR_DB_M"
readonly OUT_FILE_Y="/var/log/xray/TR_DB_Y"
TMP_NEW_COMMON="$(mktemp)"
TMP_OLD_M="$(mktemp)"
TMP_OLD_Y="$(mktemp)"
TMP_OUT_M="$(mktemp)"
TMP_OUT_Y="$(mktemp)"
trap 'on_exit; rm -f "$TMP_NEW_COMMON" "$TMP_OLD_M" "$TMP_OLD_Y" "$TMP_OUT_M" "$TMP_OUT_Y";' EXIT

# get stat and reset
fresh_stat() {
    xray api statsquery --reset > "$TMP_NEW_COMMON"
}
run_and_check "xray stat request and reset" fresh_stat

# if empty start stat from 0
if [[ ! -s "$TMP_NEW_COMMON" ]]; then
    printf '{"stat":[]}\n' > "$TMP_NEW_COMMON"
fi

# new JSON check valid, if not save and exit
if ! jq -e . &> /dev/null < "$TMP_NEW_COMMON"; then
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -f "$TMP_NEW_COMMON" "${OUT_FILE_M}.bad_new_${ts}.json"
    echo "❌ Error: cannot parse xray new stats JSON; saved raw to ${OUT_FILE_M}.bad_new_${ts}.json"
    cp -f "$TMP_NEW_COMMON" "${OUT_FILE_Y}.bad_new_${ts}.json"
    echo "❌ Error: cannot parse xray new stats JSON; saved raw to ${OUT_FILE_Y}.bad_new_${ts}.json"
    exit 1
fi

# if old M empty or not valid, start stat from 0
if [[ -s "$OUT_FILE_M" ]] && jq -e . &> /dev/null < "$OUT_FILE_M"; then
  cp -f "$OUT_FILE_M" "$TMP_OLD_M"
else
  printf '{"stat":[]}\n' >"$TMP_OLD_M"
fi

# if old Y empty or not valid, start stat from 0
if [[ -s "$OUT_FILE_Y" ]] && jq -e . &> /dev/null < "$OUT_FILE_Y"; then
  cp -f "$OUT_FILE_Y" "$TMP_OLD_Y"
else
  printf '{"stat":[]}\n' >"$TMP_OLD_Y"
fi

# merge old + new -> TMP_OUT_*
merge_old_new() {
    set -e
jq -s '
  def to_int:
    if . == null then 0
    elif type=="number" then .
    elif type=="string" then (tonumber? // 0)
    else 0 end;

  def stat_map:
    reduce (.stat[]? | select(.name? != null)) as $i
      ({};
       .[$i.name] = (.[$i.name] // 0) + (($i.value // 0) | to_int)
      );

  .[0] as $old
| .[1] as $new
| ($old | stat_map) as $o
| ($new | stat_map) as $n
| ( reduce ((($o|keys_unsorted)+($n|keys_unsorted))|unique[]) as $k
    ({};
     .[$k] = ($o[$k]//0) + ($n[$k]//0)
     )
    ) as $m
| {
    stat: (
      ($m|keys|sort)
      | map(
          . as $name
          | ($m[$name]) as $v
          | if $v == 0
            then {name:$name}
            else {name:$name, value:$v}
            end
        )
    )
  }
' "$1" "$2" >"$3"
}

run_and_check "start merge tmp_m file" merge_old_new "$TMP_OLD_M" "$TMP_NEW_COMMON" "$TMP_OUT_M"
run_and_check "start merge tmp_y file" merge_old_new "$TMP_OLD_Y" "$TMP_NEW_COMMON" "$TMP_OUT_Y"

# install new TR_DB
run_and_check "install new TR_DB_M file" install -m 644 -o telegram-gateway -g telegram-gateway "$TMP_OUT_M" "$OUT_FILE_M"
run_and_check "install new TR_DB_Y file" install -m 644 -o telegram-gateway -g telegram-gateway "$TMP_OUT_Y" "$OUT_FILE_Y"

RC=0