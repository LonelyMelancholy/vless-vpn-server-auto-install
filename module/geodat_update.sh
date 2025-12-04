#!/usr/bin/env bash
set -euo pipefail

ASSET_DIR="/usr/local/share/xray"

ENV_FILE="/usr/local/etc/telegram/secrets.env"
[ -r "$ENV_FILE" ] || exit 0
source "$ENV_FILE"

# Loyalsoldier v2ray-rules-dat (релизы)
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

MAX_ATTEMPTS=3

# ----------------- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ -----------------

TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

send_telegram() {
  local text="$1"
  local url="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

  # --data-urlencode заодно аккуратно экранирует текст
  curl -s -X POST "$url" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=${text}" \
    >/dev/null 2>&1 || true
}

dl() { curl -fsSL "$1" -o "$2"; }


download_and_verify() {
  local url="$1"
  local outfile="$2"
  local name="$3"

  local attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    # скачиваем файл
    if ! dl "$url" "$outfile"; then
      # ошибка скачивания; если это последняя попытка — выходим с ошибкой
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        return 1
      fi
      attempt=$((attempt + 1))
      continue
    fi

    # скачиваем checksum
    if ! dl "${url}.sha256sum" "${outfile}.sha256sum"; then
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        return 1
      fi
      attempt=$((attempt + 1))
      continue
    fi

    # читаем ожидаемый и фактический sha256
    local expected actual
    expected="$(awk '{print $1}' "${outfile}.sha256sum" 2>/dev/null || true)"
    actual="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}' || true)"

    # если что-то пошло не так — считаем это ошибкой и пробуем ещё раз
    if [ -z "$expected" ] || [ -z "$actual" ]; then
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        return 1
      fi
      attempt=$((attempt + 1))
      continue
    fi

    # success
    if [ "$expected" = "$actual" ]; then
      return 0
    fi

    # checksum не совпала — пробуем ещё раз, если не исчерпали попытки
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      return 1
    fi

    attempt=$((attempt + 1))
  done

  # сюда по идее не дойдём
  return 1
}

# ----------------- ОСНОВНАЯ ЛОГИКА -----------------

success=true
error_reason=""

# 1. geoip.dat
if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat"; then
  success=false
  error_reason="geoip.dat: не получилось обновить за ${MAX_ATTEMPTS} попыток (checksum / загрузка)"
fi

# 2. geosite.dat — только если geoip прошёл успешно
if [ "$success" = true ]; then
  if ! download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"; then
    success=false
    error_reason="geosite.dat: не получилось обновить за ${MAX_ATTEMPTS} попыток (checksum / загрузка)"
  fi
fi

# Если оба файла ок — ставим их и перезапускаем Xray
if [ "$success" = true ]; then
  mkdir -p "$ASSET_DIR"

  # бэкапы старых файлов, если есть
  [ -f "$ASSET_DIR/geoip.dat" ]   && cp "$ASSET_DIR/geoip.dat"   "$ASSET_DIR/geoip.dat.bak"
  [ -f "$ASSET_DIR/geosite.dat" ] && cp "$ASSET_DIR/geosite.dat" "$ASSET_DIR/geosite.dat.bak"

  install -m 644 "$TMP_DIR/geoip.dat"   "$ASSET_DIR/geoip.dat"
  install -m 644 "$TMP_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"

  if ! systemctl restart xray >/dev/null 2>&1; then
    success=false
    error_reason="Не удалось перезапустить Xray (systemctl restart xray)"
  fi
fi

# ----------------- ОТЧЁТ В TELEGRAM -----------------

if [ "$success" = true ]; then
  send_telegram "Xray geodata update: УСПЕХ ✅
geoip.dat и geosite.dat обновлены и Xray перезапущен."
  exit 0
else
  send_telegram "Xray geodata update: ОШИБКА ❌
${error_reason}"
  exit 1
fi
