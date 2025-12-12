#!/usr/bin/env bash
set -euo pipefail

# ---------------- НАСТРОЙКИ ----------------

CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/xray/xray"
INBOUND_TAG="Vless"         # tag из твоего инбаунда
DEFAULT_FLOW="xtls-rprx-vision"

# -------------- ПРОВЕРКА АРГУМЕНТОВ --------

if [ "$#" -ne 1 ]; then
  echo "Использование: $0 <username>" >&2
  exit 1
fi

USERNAME="$1"

if [ ! -f "$CONFIG" ]; then
  echo "Не найден конфиг Xray: $CONFIG" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Нужен jq (sudo apt install jq)" >&2
  exit 1
fi

# -------------- ГЕНЕРАЦИЯ UUID --------------

if [ -x "$XRAY_BIN" ]; then
  UUID="$("$XRAY_BIN" uuid | tr -d '\r\n')"
elif command -v uuidgen >/dev/null 2>&1; then
  UUID="$(uuidgen)"
else
  echo "Нужен либо $XRAY_BIN, либо uuidgen для генерации UUID" >&2
  exit 1
fi

# -------------- ПРОВЕРКА INBOUND ------------

HAS_INBOUND="$(jq --arg tag "$INBOUND_TAG" '
  any(.inbounds[]?; .tag == $tag and .protocol == "vless")
' "$CONFIG")"

if [ "$HAS_INBOUND" != "true" ]; then
  echo "В конфиге нет vless-inbound с tag=\"$INBOUND_TAG\"" >&2
  exit 1
fi

# -------------- ДОБАВЛЯЕМ ЮЗЕРА В CONFIG ----

TMP_CFG="$(mktemp)"

# берём flow из первого клиента, если есть, иначе DEFAULT_FLOW
jq --arg tag "$INBOUND_TAG" \
   --arg id "$UUID" \
   --arg email "$USERNAME" \
   --arg dflow "$DEFAULT_FLOW" '
  (.inbounds[] | select(.tag==$tag) | .settings.clients[0].flow // $dflow) as $flow
  | .inbounds = (.inbounds | map(
      if .tag == $tag and .protocol == "vless" then
        .settings.clients += [{
          "id": $id,
          "email": $email,
          "flow": $flow
        }]
      else .
      end
    ))
' "$CONFIG" > "$TMP_CFG"

# опционально можно проверить конфиг через xray run -test
if [ -x "$XRAY_BIN" ]; then
  if ! "$XRAY_BIN" run -test -c "$TMP_CFG" >/dev/null 2>&1; then
    echo "Новый конфиг не прошёл xray run -test, изменения не применены" >&2
    rm -f "$TMP_CFG"
    exit 1
  fi
fi

mv "$TMP_CFG" "$CONFIG"

# -------------- ВЫТАСКИВАЕМ REALITY ПАРАМЫ --

PORT="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .port
' "$CONFIG")"

REALITY_DEST="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.dest // ""
' "$CONFIG")"

REALITY_SNI="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.serverNames[0] // ""
' "$CONFIG")"

PRIVATE_KEY="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.privateKey // ""
' "$CONFIG")"

SHORT_ID="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.shortIds[0] // ""
' "$CONFIG")"

if [ -z "$PRIVATE_KEY" ]; then
  echo "Не найден privateKey в realitySettings данного inbound" >&2
  exit 1
fi

if [ -z "$SHORT_ID" ]; then
  echo "Не найден shortIds[0] в realitySettings данного inbound" >&2
  exit 1
fi

# -------------- ПОЛУЧАЕМ pbk ИЗ privateKey --

if [ ! -x "$XRAY_BIN" ]; then
  echo "Для получения pbk нужен $XRAY_BIN (xray x25519 -i)" >&2
  exit 1
fi

XRAY_X25519_OUT="$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY")"

# В разных версиях в выводе может быть "Public key:" или "Password:"
PBK="$(printf '%s\n' "$XRAY_X25519_OUT" | awk -F': ' '/Public key:|Password:/ {print $2}' | tail -n1)"

if [ -z "$PBK" ]; then
  echo "Не удалось вытащить pbk (publicKey/password) из вывода xray x25519" >&2
  exit 1
fi

# -------------- ОПРЕДЕЛЯЕМ АДРЕС СЕРВЕРА ----

SERVER_HOST=""

if command -v curl >/dev/null 2>&1; then
  SERVER_HOST="$(curl -4 -s https://ifconfig.io || curl -4 -s https://ipinfo.io/ip || echo "")"
fi

if [ -z "$SERVER_HOST" ]; then
  SERVER_HOST="SERVER_IP"  # плейсхолдер, если не смогли определить
fi

# -------------- СБОРКА VLESS URI ------------

# небольшая helper-функция для URL-энкодинга через jq
uri_encode() {
  printf '%s' "$1" | jq -sRr @uri
}

FLOW="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .settings.clients[0].flow // "'$DEFAULT_FLOW'"
' "$CONFIG")"

[ -z "$FLOW" ] && FLOW="$DEFAULT_FLOW"

QUERY="encryption=none"
QUERY="${QUERY}&flow=$(uri_encode "$FLOW")"
QUERY="${QUERY}&security=reality"
QUERY="${QUERY}&type=tcp"

if [ -n "$REALITY_SNI" ]; then
  QUERY="${QUERY}&sni=$(uri_encode "$REALITY_SNI")"
fi

# fingerprint для uTLS, обычно chrome
QUERY="${QUERY}&fp=$(uri_encode "chrome")"

# pbk (password/publicKey) и sid (shortId)
QUERY="${QUERY}&pbk=$(uri_encode "$PBK")"
QUERY="${QUERY}&sid=$(uri_encode "$SHORT_ID")"

NAME_ENC="$(uri_encode "$USERNAME")"

VLESS_URI="vless://${UUID}@${SERVER_HOST}:${PORT}?${QUERY}#${NAME_ENC}"

# -------------- ПЕРЕЗАПУСК XRAY -------------

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart xray || echo "Внимание: systemctl restart xray завершился с ошибкой, проверь статус" >&2
fi

# -------------- ВЫВОД -----------------------

echo "Добавлен пользователь:"
echo "  Name: $USERNAME"
echo "  UUID: $UUID"
echo
echo "VLESS REALITY ссылка:"
echo "$VLESS_URI"
echo
echo "Примечание:"
echo "  Address в ссылке: $SERVER_HOST (если там SERVER_IP — замени на реальный IP/домен своего сервера при необходимости)."
echo "  SNI: $REALITY_SNI, dest: $REALITY_DEST"
