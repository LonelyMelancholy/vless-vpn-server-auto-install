#!/bin/bash
# script for show user from xray config and URI_DB

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/user.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on xray configuration or URI DB, exit"; exit 1; }

# argument check
if ! [[ "$#" -eq 1 ]]; then
    echo "Use for show user from xray config and URI_DB, run: $0 <option>"
    echo "all - all user link and expiration info"
    echo "blk - blocked manually user"
    echo "exp - expired, auto blocked user"
    exit 1
fi

# main variables
OPTION="$1"
URI_PATH="/usr/local/etc/xray/URI_DB"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# change rule and act depending of option
[[ "$OPTION" == "blk" ]] && { BLOCK_RULE_TAG="manual-block-users"; ACT="blocked"; }
[[ "$OPTION" == "exp" ]] && { BLOCK_RULE_TAG="autoblock-expired-users"; ACT="expired"; }

# config and URI_DB check
if [[ ! -r "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

if [[ ! -r "$URI_PATH" ]]; then
  echo "❌ Error: check $URI_PATH it's missing or you do not have read permissions, exit"
  exit 1
fi

# search blocked user and print
find_blocked_user() {
    jq -r --arg tag "$BLOCK_RULE_TAG" '
        def parse_user($s):
            ($s | tostring | split("|")) as $p
            | ($p[0] // "") as $name
            | (reduce ($p[1:][]?) as $kv ({}; 
                if ($kv | contains("=")) then
                ($kv | split("=")) as $a
                | . + { ($a[0]): ($a[1:] | join("=")) }
                else . end
            )) as $m
            | "name: \($name), created: \($m.created // ""), days: \($m.days // ""), expiration: \($m.exp // $m.expiration // "")"
        ;

        .routing.rules[]?
        | select(.ruleTag == $tag)
        | (.user // [])[]?
        | parse_user(.)
        ' "$XRAY_CONFIG"
}

# chose path execution
case "$OPTION" in
    all)
        # just print database
        echo "####################################################################################################"
        echo ""
        cat "$URI_PATH"
        echo "####################################################################################################"
        exit 0
    ;;

    blk|exp)
        # count rule math, if not math, exit 
        rule_count="$(jq -r --arg tag "$BLOCK_RULE_TAG" '
        [ .routing.rules[]? | select(.ruleTag == $tag) ] | length
        ' "$XRAY_CONFIG")"

        if [[ "$rule_count" == "0" ]]; then
            echo "❌ Error: ruletag '$BLOCK_RULE_TAG' not found"
            exit 1
        fi

        # count user in ruletag if user not exist, exit
        users_len="$(jq -r --arg tag "$BLOCK_RULE_TAG" '
        [ .routing.rules[]? | select(.ruleTag == $tag) | (.user // [])[]? ] | length
        ' "$XRAY_CONFIG")"

        if [[ "$users_len" == "0" ]]; then
            echo "✅ Success: $ACT users not found"
            exit 0
        fi

        # find and print user in ruletag
        echo "####################################################################################################"
        echo ""
        find_blocked_user || { echo "❌ Error: find $ACT user, exit"; exit 1; }
        echo ""
        echo "####################################################################################################"
        exit 0
    ;;

    *)
    echo "❌ Error: wrong option, read help again, exit"
    exit 1
    ;;
esac