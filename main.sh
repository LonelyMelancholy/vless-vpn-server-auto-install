#!/bin/bash
set -euo pipefail

# Проверка на root пользователя
if [[ $(whoami) != "root" ]]; then
  echo "❌ Not root user, exit"
  exit 1
else
  echo "✅ Root user, continued"
fi

CFG_FILE="configuration.cfg"

SECOND_USER=$(awk -F'"' '/^Server administrator username/ {print $2}' "$CFG_FILE")

if [[ -z "$SECOND_USER" ]]; then
    echo "Ошибка: не удалось найти 'Server administrator username' в $CFG_FILE"
    exit 1
fi

if [[ "$SECOND_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ ${#SECOND_USER} -le 32 ]]; then
    echo "OK: имя '$SECOND_USER' корректно"
else
    echo "Ошибка: имя '$SECOND_USER' не соответствует правилам Linux"
    exit 1
fi


PASS=$(awk -F'"' '/^Password for root and new user/ {print $2}' "$CFG_FILE")

if [[ -z "$SECOND_USER" ]]; then
    echo "Ошибка: не удалось найти 'Password for root and new user' в $CFG_FILE"
    exit 1
fi

echo -e "\n✅Password accepted"
trap 'unset -v PASS' EXIT

# Обновление пакетов
export DEBIAN_FRONTEND=noninteractive
while true; do
    echo "⚠️ Updating packages list, wait"
    if apt-get update >/dev/null 2>&1; then
        echo "✅ Update packages list completed"
    else
        echo "❌ Updating package list failed, try again"
        sleep 5
        continue
    fi
    echo "⚠️ Updating packages, wait"
    if apt-get dist-upgrade -y >/dev/null 2>&1; then
        echo "✅ Package update completed"
    else
        echo "❌ Updating package failed, try again"
        sleep 5
        continue
    fi
        break
done

# Настройка sshd группы
SSH_GROUP="ssh-users"
if ! getent group "$SSH_GROUP" >/dev/null 2>&1; then
    echo "⚠️ Adding group $SSH_GROUP"
    if addgroup "$SSH_GROUP" >/dev/null 2>&1; then
        echo "✅ Group $SSH_GROUP has been successfully added"
    else
        echo "❌ Ошибка: не удалось создать группу $SSH_GROUP"
    exit 1
else 
    echo "✅ Group $SSH_GROUP already exists"
fi

# Создание пользователя и добавление его в sshd группу
echo "⚠️ Сreate second user and add them to the $SSH_GROUP and sudo group"
useradd -m -s /bin/bash -G sudo,"$SSH_GROUP" "$SECOND_USER"
echo "✅ User has been created and added to $SSH_GROUP and sudo groups"

# Смена пароля root и нового пользователя
echo "root:$PASS" | chpasswd
echo "$SECOND_USER:$PASS" | chpasswd
echo "Root and $SECOND_USER passwords have been changed successfully"

#  Обьявление переменных sshd
SSH_CONF_FILE="/etc/ssh/sshd_config.d/99-custom_security.conf"
LOW="30000"
HIGH="40000"

# Генерация порта в диапазоне [30000,40000]
choose_port() {
  if command -v shuf >/dev/null 2>&1; then
    shuf -i "${LOW}-${HIGH}" -n 1
  else
    local span=$((HIGH - LOW + 1))
    local rnd=$(( ((RANDOM<<15) | RANDOM) % span ))
    echo $((LOW + rnd))
  fi
}
PORT="$(choose_port)"

# Очистка файлов конфигураций с высоким приоритетом во избежание конфликтов
if compgen -G "/etc/ssh/sshd_config.d/99*.conf" > /dev/null; then
    rm /etc/ssh/sshd_config.d/99*.conf
    echo "✅ Deletion of previous conflicting sshd configuration files completed"
else
    echo "✅ No conflicting sshd configurations files found"
fi

# Создаём файл конфигурации
install -m 644 /module/ssh.cfg "$SSH_CONF_FILE"
# меняем порт в конфиге
sed -i "s/{PORT}/$PORT/g" "$SSH_CONF_FILE"

# Проверка результата и вывод сообщения
if compgen -G $SSH_CONF_FILE; then
    echo "✅ Creating a new sshd configuration completed"
else
  echo "Ошибка: не удалось записать ${SSH_CONF_FILE}"
  exit 1
fi

rm /etc/ssh/ssh_host_ecdsa_key
rm /etc/ssh/ssh_host_ecdsa_key.pub
rm /etc/ssh/ssh_host_rsa_key
rm /etc/ssh/ssh_host_rsa_key.pub


# Находим домашний каталог пользователя
USER_HOME="$(getent passwd "$SECOND_USER" | cut -d: -f6 || true)"

SSH_DIR="$USER_HOME/.ssh"
KEY_NAME="authorized_keys"
PRIV_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_KEY_PATH="$PRIV_KEY_PATH.pub"

# Создаём .ssh folder
mkdir "$SSH_DIR"

# Генерируем ключ (без пароля)
ssh-keygen -t ed25519 -N "" -f "$PRIV_KEY_PATH" -q

# Права и владелец
chmod 700 "$SSH_DIR"
chmod 600 "$PRIV_KEY_PATH" "$PUB_KEY_PATH"
USER_GROUP="$(id -gn "$SECOND_USER")"
chown -R "$SECOND_USER:$USER_GROUP" "$SSH_DIR"

# Reboot SSH
systemctl daemon-reload
systemctl restart ssh.socket
systemctl restart ssh.service

# Disable message of the day
MOTD="/etc/pam.d/sshd"
# backup and commented 2 lines
sed -i.bak \
  -e '/^[[:space:]]*session[[:space:]]\{1,\}optional[[:space:]]\{1,\}pam_motd\.so[[:space:]]\{1,\}motd=\/run\/motd\.dynamic[[:space:]]*$/{
        /^[[:space:]]*#/! s/^[[:space:]]*/&# /
      }' \
  -e '/^[[:space:]]*session[[:space:]]\{1,\}optional[[:space:]]\{1,\}pam_motd\.so[[:space:]]\{1,\}noupdate[[:space:]]*$/{
        /^[[:space:]]*#/! s/^[[:space:]]*/&# /
      }' \
  "$MOTD"

# Install fail2ban
while true; do
    echo "⚠️ Install fail2ban, wait"
    if apt-get install fail2ban -y >/dev/null 2>&1; then
        echo "✅ Install fail2ban completed"
    else
        echo "❌ Install fail2ban failed, try again"
        sleep 5
        continue
    fi
        break
done

# Configuration fail2ban
F2B_CONF_FILE="/etc/fail2ban/jail.local"

# Создаём файл конфигурации
install -m 644 /module/f2b.cfg "$F2B_CONF_FILE"
# меняем порт в конфиге
sed -i "s/{PORT}/$PORT/g" "$F2B_CONF_FILE"

# Enable fail2ban
systemctl enable --now fail2ban

# Чтение token из файла и проверка присутствует ли он в файле

READ_BOT_TOKEN=$(awk -F'"' '/^Telegram Bot Token/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_BOT_TOKEN" ]]; then
    echo "Ошибка: не удалось найти 'Telegram Bot Token' в $CFG_FILE"
    exit 1
fi

# Чтение id из файла и проверка присутствует ли он в файле
READ_CHAT_ID=$(awk -F'"' '/^Telegram Chat id/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_CHAT_ID" ]]; then
    echo "Ошибка: не удалось найти 'Telegram Chat id' в $CFG_FILE"
    exit 1
fi

# Запись token и id в файл секретов
ENV_FILE="/etc/telegram-bot.env"
{
  printf 'BOT_TOKEN=%q\n' "$READ_BOT_TOKEN"
  printf 'CHAT_ID=%q\n'   "$READ_CHAT_ID"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Уведомления об успешном логине разлогине по ssh
SSH_ENTER_NOTIFY_SCRIPT="/usr/local/bin/ssh_enter_notify.sh"
install -m 700 module/ssh_enter_notify.sh "$SSH_ENTER_NOTIFY_SCRIPT"
echo -e "\n# Notify for success ssh login and logout via telegram bot" >> /etc/pam.d/sshd
echo "session optional pam_exec.so seteuid /usr/local/bin/ssh_enter_notify.sh" >> /etc/pam.d/sshd


#ssh ban brutforce notify

install -m 700 module/ssh_ban_notify.sh "/usr/local/bin/ssh_ban_notify.sh"

cat > "/etc/fail2ban/action.d/ssh_telegram.local" <<'EOF'
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/local/bin/ssh_ban_notify.sh ban <ip> <bantime>
actionunban = /usr/local/bin/ssh_ban_notify.sh unban <ip> <bantime>
EOF

systemctl restart fail2ban

# Уведомляшка по трафику
install -m 700 module/trafic_notify.sh "/usr/local/bin/trafic_notify.sh"

# Включаем скрипт в крон для авто выполнения в 1:00 ночи
cat > "/etc/cron.d/trafic_notify" <<'EOF'
0 1 * * * root /usr/local/bin/trafic_notify.sh >/dev/null 2>&1
EOF


# Включаем security обновления и перезагрузку по необходимости

apt-get install unattended-upgrades -y
# так и не доделал



# Установка Xray

useradd -r -s /usr/sbin/nologin xray

mkdir -p /usr/local/share/xray
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray
chown xray:xray /var/log/xray

wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip Xray-linux-64.zip

mv xray /usr/local/bin/xray
chmod 755 /usr/local/bin/xray

mv geosite.dat geoip.dat /usr/local/share/xray
chmod 644 /usr/local/share/xray/*

cat > "/etc/systemd/system/xray.service" <<'EOF'
[Unit]
Description=Xray-core VLESS server
After=network-online.target

[Service]
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# Закидываем конфиг
install -m 644 cfg/config.json "/usr/local/etc/xray/config.json"

# тут надо в конфиг добавить пароли


# Запускаем сервер
sudo systemctl daemon-reload
sudo systemctl enable --now xray.service





автообновления геолистов

  local download_link_geoip="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
  local download_link_geosite="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
  local file_ip='geoip.dat'
  local file_dlc='geosite.dat'
  local file_site='geosite.dat'












# Выводим оба ключа для копирования
echo
echo "=== PRIVATE KEY ($PRIV_KEY_PATH) ==="
cat "$PRIV_KEY_PATH"
echo
echo "=== PUBLIC KEY ($PUB_KEY_PATH) ==="
cat "$PUB_KEY_PATH"

# --- Показать пароль для копирования (НЕБЕЗОПАСНО) ---
echo
echo "======================================================================"
echo "Ssh port: ${PORT}"
echo "======================================================================"
echo "Подсказка: после копирования очистите историю/скролл терминала (напр., 'clear')."
echo



# Очистка переменной и завершение
unset -v PASS
trap - EXIT
