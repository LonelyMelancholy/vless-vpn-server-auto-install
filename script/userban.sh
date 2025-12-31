#!/usr/bin/env bash
set -euo pipefail

CFG="/usr/local/etc/xray/config.json"
INBOUND_TAG="Vless"
BLOCK_OUTBOUND_TAG="blocked"
RULE_TAG="manual-block-users"

usage() {
  echo "Usage: $0 <name> <block|unblock>"
  echo "Example: $0 melany block"
  echo "         $0 melany unblock"
}

err() { echo "Error: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || { usage; exit 1; }
NAME="$1"
ACTION="$2"

[[ -f "$CFG" ]] || err "Config not found: $CFG"
command -v jq >/dev/null 2>&1 || err "jq is required. Install: apt-get install -y jq (or your distro equivalent)"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="${CFG}.bak-${TS}"
cp -a "$CFG" "$BACKUP"

make_tmp() { mktemp "${CFG}.tmp.XXXXXX"; }

# For block: find client emails in inbound Vless that match NAME or NAME|
get_client_emails() {
  jq -r --arg tag "$INBOUND_TAG" --arg name "$NAME" '
    .inbounds[]?
    | select(.tag == $tag)
    | .settings.clients[]?
    | .email
    | select(. == $name or startswith($name + "|"))
  ' "$CFG" | awk 'NF' | sort -u
}

# For unblock: only from OUR tagged managed rule
get_blocked_emails_from_rule() {
  jq -r --arg tag "$INBOUND_TAG" --arg name "$NAME" --arg bot "$BLOCK_OUTBOUND_TAG" --arg rt "$RULE_TAG" '
    def is_managed_rule:
      (.type == "field")
      and (.outboundTag == $bot)
      and ((.inboundTag // []) | index($tag))
      and ((.ruleTag // "") == $rt)
      and has("user")
      and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

    (.routing.rules[]? | select(is_managed_rule) | .user[]?)
    | select(. == $name or startswith($name + "|"))
  ' "$CFG" | awk 'NF' | sort -u
}

# Ensure:
# - outbounds contains {"tag":"blocked","protocol":"blackhole"}
# - routing.rules exists
# - our managed rule exists at top:
#   {"type":"field","ruleTag":"manual-block-users","inboundTag":["Vless"],"outboundTag":"blocked","user":[]}
jq_common_preamble='
  .outbounds = (.outbounds // []) |
  if any(.outbounds[]?; .tag == $bot) then .
  else .outbounds += [{"tag": $bot, "protocol": "blackhole"}]
  end |
  .routing = (.routing // {}) |
  .routing.rules = (.routing.rules // []) |

  def is_managed_rule:
    (.type == "field")
    and (.outboundTag == $bot)
    and ((.inboundTag // []) | index($tag))
    and ((.ruleTag // "") == $rt)
    and has("user")
    and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

  if any(.routing.rules[]?; is_managed_rule) then .
  else .routing.rules |= ([{"type":"field","ruleTag":$rt,"inboundTag":[$tag],"outboundTag":$bot,"user":[]} ] + .)
  end
'

restart_xray() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -qE '^xray\.service'; then
      systemctl reload-or-restart xray || systemctl restart xray || true
      return 0
    fi
  fi
  if command -v service >/dev/null 2>&1; then
    if service --status-all 2>/dev/null | grep -qE '\bxray\b'; then
      service xray restart || true
      return 0
    fi
  fi
  return 1
}

case "$ACTION" in
  block)
    mapfile -t EMAILS < <(get_client_emails)
    [[ ${#EMAILS[@]} -gt 0 ]] || err "No client with name '$NAME' found in inbound tag '$INBOUND_TAG'"

    tmp="$(make_tmp)"
    jq --arg tag "$INBOUND_TAG" --arg bot "$BLOCK_OUTBOUND_TAG" --arg rt "$RULE_TAG" \
       --argjson emails "$(printf '%s\n' "${EMAILS[@]}" | jq -R . | jq -s .)" '
      '"$jq_common_preamble"' |

      def is_managed_rule:
        (.type == "field")
        and (.outboundTag == $bot)
        and ((.inboundTag // []) | index($tag))
        and ((.ruleTag // "") == $rt)
        and has("user")
        and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

      .routing.rules |= (
        map(
          if is_managed_rule then
            .user = (((.user // []) + $emails) | unique)
          else .
          end
        )
      )
    ' "$CFG" > "$tmp"

    chmod --reference="$CFG" "$tmp" || true
    chown --reference="$CFG" "$tmp" || true
    mv "$tmp" "$CFG"

    echo "Blocked (ruleTag=$RULE_TAG): ${EMAILS[*]}"
    if restart_xray; then
      echo "xray restarted."
    else
      echo "Note: couldn't auto-restart xray. Restart it manually to apply changes."
    fi
    ;;

  unblock)
    # ONLY remove from our tagged rule
    mapfile -t EMAILS < <(get_blocked_emails_from_rule || true)
    if [[ ${#EMAILS[@]} -eq 0 ]]; then
      echo "Nothing to unblock for '$NAME' in ruleTag=$RULE_TAG."
      exit 0
    fi

    tmp="$(make_tmp)"
    jq --arg tag "$INBOUND_TAG" --arg bot "$BLOCK_OUTBOUND_TAG" --arg rt "$RULE_TAG" \
       --argjson emails "$(printf '%s\n' "${EMAILS[@]}" | jq -R . | jq -s .)" '
      '"$jq_common_preamble"' |

      def is_managed_rule:
        (.type == "field")
        and (.outboundTag == $bot)
        and ((.inboundTag // []) | index($tag))
        and ((.ruleTag // "") == $rt)
        and has("user")
        and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

      .routing.rules |= (
        map(
          if is_managed_rule then
            .user = ((.user // []) - $emails)
          else .
          end
        )
        | map(
            if is_managed_rule and ((.user // []) | length == 0) then empty else .
            end
          )
      )
    ' "$CFG" > "$tmp"

    chmod --reference="$CFG" "$tmp" || true
    chown --reference="$CFG" "$tmp" || true
    mv "$tmp" "$CFG"

    echo "Unblocked (ruleTag=$RULE_TAG): ${EMAILS[*]}"
    if restart_xray; then
      echo "xray restarted."
    else
      echo "Note: couldn't auto-restart xray. Restart it manually to apply changes."
    fi
    ;;

  *)
    usage
    exit 1
    ;;
esac

