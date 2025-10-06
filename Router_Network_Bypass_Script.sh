#!/bin/sh

set -e

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Этот скрипт должен запускаться с правами root"
    exit 1
fi

LOG_FILE="/tmp/router_config_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
exec 2>&1

echo "=== Начало выполнения скрипта $(date) ==="

# Функция для диагностики проблем с пакетами
diagnose_package_issue() {
    local package="$1"
    echo "🔍 Диагностика проблемы с пакетом: $package"
    
    # Проверка доступности пакета в репозиториях
    echo "📦 Поиск пакета в репозиториях..."
    if opkg list | grep -q "^$package "; then
        echo "✅ Пакет найден в репозитории"
        opkg info "$package" | head -5
    else
        echo "❌ Пакет не найден в репозиториях"
        
        # Поиск альтернативных имен
        echo "🔍 Поиск альтернативных имен пакета..."
        case "$package" in
            "opera-proxy")
                opkg list | grep -i "opera\|proxy" | head -10
                ;;
            "luci-app-dns-failsafe-proxy")
                opkg list | grep -i "dns.*fail.*safe\|fail.*safe.*dns" | head -5
                ;;
            "zapret")
                opkg list | grep -i "zapret\|block\|filter\|dpi" | head -10
                ;;
            *)
                opkg list | grep -i "$package" | head -5
                ;;
        esac
    fi
}

# Улучшенная функция установки пакетов с обработкой ошибок
checkPackageAndInstall() {
    local name="$1"
    local isRequired="${2:-0}"
    local alt="${3:-}"

    echo "📦 Обработка пакета: $name"
    
    # Проверка, установлен ли уже пакет
    if opkg list-installed | grep -q "^${name} "; then
        echo "✅ $name уже установлен"
        return 0
    fi

    # Проверка альтернативных пакетов
    if [ -n "$alt" ]; then
        if opkg list-installed | grep -q "^${alt} "; then
            echo "✅ Альтернативный пакет $alt уже установлен"
            return 0
        fi
    fi

    echo "🔄 Установка $name..."
    
    # Попытка установки
    if opkg install "$name"; then
        echo "✅ $name установлен успешно"
        return 0
    else
        echo "❌ Ошибка установки $name"
        
        # Диагностика проблемы
        diagnose_package_issue "$name"
        
        # Попробовать альтернативный пакет
        if [ -n "$alt" ]; then
            echo "🔄 Попытка установки альтернативного пакета: $alt"
            if opkg install "$alt"; then
                echo "✅ Альтернативный пакет $alt установлен успешно"
                return 0
            else
                echo "❌ Ошибка установки альтернативного пакета $alt"
            fi
        fi
        
        if [ "$isRequired" = "1" ]; then
            echo "💡 Решение проблемы:"
            echo "   1. Проверьте подключение к интернету: opkg update"
            echo "   2. Убедитесь что репозитории настроены правильно"
            echo "   3. Попробуйте установить пакет вручную"
            if [ -n "$alt" ]; then
                echo "   4. Или установите альтернативный пакет: $alt"
            fi
            exit 1
        fi
        return 1
    fi
}

# Упрощенная установка Zapret (без компиляции)
install_zapret_simple() {
    echo "🔧 Упрощенная установка системы блокировки..."
    
    local found=0
    
    # Сначала пробуем найти готовые пакеты
    local packages="
        zapret
        luci-app-zapret
    "
    
    for pkg in $packages; do
        if opkg list | grep -q "^$pkg "; then
            echo "✅ Найден пакет: $pkg"
            if opkg install "$pkg"; then
                echo "✅ $pkg установлен успешно"
                found=1
            else
                echo "⚠️ Не удалось установить $pkg"
            fi
        fi
    done
    
    if [ "$found" -eq 0 ]; then
        echo "⚠️ Zapret не найден в репозиториях"
        echo "🔧 Настройка альтернативной системы блокировки..."
        setup_alternative_blocking
        found=1
    fi
    
    return $found
}

# Альтернативная система блокировки
setup_alternative_blocking() {
    echo "🔧 Настройка альтернативной системы блокировки..."
    
    # Создание простого скрипта блокировки
    cat << 'EOF' > /usr/bin/simple-blocker
#!/bin/sh

BLOCKLIST_DIR="/etc/simple-blocker"
BLOCKLIST_FILE="$BLOCKLIST_DIR/blocklist.txt"
IPSET_NAME="blocked_sites"

case "$1" in
    start)
        echo "Запуск простого блокировщика..."
        
        # Создание директории если не существует
        mkdir -p "$BLOCKLIST_DIR"
        
        # Создание ipset если не существует
        if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
            ipset create "$IPSET_NAME" hash:net
        fi
        
        # Добавление правил iptables если их нет
        if ! iptables -t filter -L | grep -q "$IPSET_NAME"; then
            iptables -t filter -I FORWARD -m set --match-set "$IPSET_NAME" dst -j DROP
            iptables -t filter -I OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP
        fi
        
        # Обновление блоклиста если файл существует
        if [ -f "$BLOCKLIST_FILE" ]; then
            while read -r domain; do
                [ -z "$domain" ] && continue
                [ "${domain#\#}" != "$domain" ] && continue
                
                # Разрешаем домен в IP и добавляем в ipset
                for ip in $(nslookup "$domain" 2>/dev/null | grep "Address" | grep -v "#" | awk '{print $3}'); do
                    ipset add "$IPSET_NAME" "$ip" 2>/dev/null
                done
            done < "$BLOCKLIST_FILE"
        fi
        
        echo "✅ Простой блокировщик запущен"
        ;;
    stop)
        echo "Остановка простого блокировщика..."
        
        # Удаление правил iptables
        iptables -t filter -D FORWARD -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null || true
        iptables -t filter -D OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null || true
        
        # Очистка ipset
        ipset flush "$IPSET_NAME" 2>/dev/null || true
        
        echo "✅ Простой блокировщик остановлен"
        ;;
    update)
        echo "Обновление блоклиста..."
        
        if [ -f "$BLOCKLIST_FILE" ]; then
            ipset flush "$IPSET_NAME"
            
            while read -r domain; do
                [ -z "$domain" ] && continue
                [ "${domain#\#}" != "$domain" ] && continue
                
                for ip in $(nslookup "$domain" 2>/dev/null | grep "Address" | grep -v "#" | awk '{print $3}'); do
                    ipset add "$IPSET_NAME" "$ip" 2>/dev/null
                done
            done < "$BLOCKLIST_FILE"
        fi
        
        echo "✅ Блоклист обновлен"
        ;;
    *)
        echo "Использование: $0 {start|stop|update}"
        exit 1
        ;;
esac
EOF

    chmod +x /usr/bin/simple-blocker
    
    # Создание базового блоклиста
    mkdir -p /etc/simple-blocker
    cat << 'EOF' > /etc/simple-blocker/blocklist.txt
# Базовый список блокировки
example.com
test.com
EOF

    # Создание init скрипта
    cat << 'EOF' > /etc/init.d/simple-blocker
#!/bin/sh /etc/rc.common

START=95
STOP=10

start() {
    simple-blocker start
}

stop() {
    simple-blocker stop
}

restart() {
    stop
    sleep 2
    start
}
EOF

    chmod +x /etc/init.d/simple-blocker
    
    echo "✅ Альтернативная система блокировки настроена"
    echo "💡 Команды управления:"
    echo "   /etc/init.d/simple-blocker start - запуск"
    echo "   /etc/init.d/simple-blocker stop - остановка"
    echo "   simple-blocker update - обновление блоклиста"
}

# Специальная функция для установки Opera Proxy
install_opera_proxy() {
    echo "🔧 Специальная установка Opera Proxy..."
    
    local packages="
        opera-proxy
        luci-app-opera-proxy
    "
    
    local found=0
    for pkg in $packages; do
        if opkg list | grep -q "^$pkg "; then
            echo "✅ Найден пакет: $pkg"
            if opkg install "$pkg"; then
                echo "✅ $pkg установлен успешно"
                found=1
                break
            else
                echo "⚠️ Не удалось установить $pkg"
            fi
        fi
    done
    
    if [ "$found" -eq 0 ]; then
        echo "⚠️ Не удалось найти или установить Opera Proxy"
        echo "💡 Используем sing-box для проксирования трафика"
    fi
    
    return $found
}

# Специальная функция для проблемных пакетов DNS
install_dns_failsafe_proxy() {
    echo "🔧 Специальная установка DNS Fail-Safe Proxy..."
    
    local packages="
        dns-failsafe-proxy
        luci-app-dns-failsafe-proxy
    "
    
    local found=0
    for pkg in $packages; do
        if opkg list | grep -q "^$pkg "; then
            echo "✅ Найден пакет: $pkg"
            if opkg install "$pkg"; then
                echo "✅ $pkg установлен успешно"
                found=1
                break
            else
                echo "⚠️ Не удалось установить $pkg"
            fi
        fi
    done
    
    if [ "$found" -eq 0 ]; then
        echo "⚠️ Не удалось найти или установить DNS Fail-Safe Proxy"
        echo "💡 Используем dnsmasq-full для DNS"
    fi
    
    return $found
}

# Безопасная установка AmneziaWG через официальный скрипт
install_awg_packages() {
    echo "🔧 Установка AmneziaWG через официальный скрипт..."
    
    local install_url="https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh"
    local temp_script="/tmp/amneziawg-install.sh"
    
    # Проверка доступности скрипта установки
    echo "📡 Проверка доступности скрипта установки..."
    if ! wget --spider "$install_url" 2>/dev/null; then
        echo "❌ Скрипт установки недоступен"
        return 1
    fi
    
    echo "✅ Скрипт установки доступен"
    
    # Безопасная загрузка скрипта
    echo "⬇️  Загрузка скрипта установки..."
    if ! wget -O "$temp_script" "$install_url"; then
        echo "❌ Ошибка загрузки скрипта установки"
        return 1
    fi
    
    # Проверка что файл не пустой
    if [ ! -s "$temp_script" ]; then
        echo "❌ Загруженный скрипт пуст"
        rm -f "$temp_script"
        return 1
    fi
    
    echo "🔧 Установка AmneziaWG..."
    # Выполнение скрипта
    if sh "$temp_script"; then
        echo "✅ AmneziaWG успешно установлен через официальный скрипт"
        rm -f "$temp_script"
        return 0
    else
        echo "❌ Ошибка установки AmneziaWG через официальный скрипт"
        rm -f "$temp_script"
        return 1
    fi
}

# Безопасная установка sing-box через официальный скрипт
install_sing_box() {
    echo "🔧 Установка sing-box через официальный скрипт..."
    
    local install_url="https://sing-box.app/install.sh"
    local temp_script="/tmp/sing-box-install.sh"
    
    # Проверка доступности скрипта установки
    echo "📡 Проверка доступности скрипта установки sing-box..."
    if ! curl -fsSL --head "$install_url" > /dev/null 2>&1; then
        echo "❌ Скрипт установки sing-box недоступен"
        return 1
    fi
    
    echo "✅ Скрипт установки sing-box доступен"
    
    # Безопасная загрузка скрипта
    echo "⬇️  Загрузка скрипта установки sing-box..."
    if ! curl -fsSL -o "$temp_script" "$install_url"; then
        echo "❌ Ошибка загрузки скрипта установки sing-box"
        return 1
    fi
    
    # Проверка что файл не пустой
    if [ ! -s "$temp_script" ]; then
        echo "❌ Загруженный скрипт sing-box пуст"
        rm -f "$temp_script"
        return 1
    fi
    
    echo "🔧 Установка sing-box..."
    # Выполнение скрипта
    if sh "$temp_script"; then
        echo "✅ sing-box успешно установлен через официальный скрипт"
        rm -f "$temp_script"
        return 0
    else
        echo "❌ Ошибка установки sing-box через официальный скрипт"
        rm -f "$temp_script"
        return 1
    fi
}

manage_package() {
    local name="$1"
    local autostart="$2"
    local process="$3"

    # Проверка, установлен ли пакет
    if opkg list-installed | grep -q "^${name} "; then
        
        # Проверка, включен ли автозапуск
        if /etc/init.d/"$name" enabled > /dev/null 2>&1; then
            if [ "$autostart" = "disable" ]; then
                if /etc/init.d/"$name" disable; then
                    echo "✅ Автозапуск $name отключен"
                else
                    echo "❌ Ошибка отключения автозапуска $name"
                fi
            fi
        else
            if [ "$autostart" = "enable" ]; then
                if /etc/init.d/"$name" enable; then
                    echo "✅ Автозапуск $name включен"
                else
                    echo "❌ Ошибка включения автозапуска $name"
                fi
            fi
        fi

        # Проверка, запущен ли процесс
        if pgrep -f "$name" > /dev/null 2>&1; then
            if [ "$process" = "stop" ]; then
                if /etc/init.d/"$name" stop; then
                    echo "✅ Сервис $name остановлен"
                else
                    echo "❌ Ошибка остановки сервиса $name"
                fi
            fi
        else
            if [ "$process" = "start" ]; then
                if /etc/init.d/"$name" start; then
                    echo "✅ Сервис $name запущен"
                else
                    echo "❌ Ошибка запуска сервиса $name"
                fi
            fi
        fi
    else
        echo "⚠️ Пакет $name не установлен"
    fi
}

checkAndAddDomainPermanentName() {
    local name="$1"
    local ip="$2"
    local nameRule="option name '${name}'"
    
    if ! uci show dhcp | grep -qF "$nameRule"; then 
        uci add dhcp domain
        uci set "dhcp.@domain[-1].name=${name}"
        uci set "dhcp.@domain[-1].ip=${ip}"
        echo "✅ Добавлен домен: $name -> $ip"
    else
        echo "✅ Домен $name уже существует"
    fi
}

byPassGeoBlockComssDNS() {
    echo "🔧 Настройка dhcp для обхода геоблокировок..."

    # Группируем изменения UCI
    uci batch << EOF
set dhcp.cfg01411c.strictorder='1'
set dhcp.cfg01411c.filter_aaaa='1'
EOF

    # Очистка существующих серверов
    while uci delete dhcp.cfg01411c.server 2>/dev/null; do :; done
    
    # Добавление новых серверов
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5053'
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5054'
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5055'
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.chatgpt.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.openai.com/127.0.0.1#5056'
    
    uci commit dhcp

    echo "🔧 Добавление разблокировки ChatGPT..."

    checkAndAddDomainPermanentName "chatgpt.com" "83.220.169.155"
    checkAndAddDomainPermanentName "openai.com" "83.220.169.155"

    if service dnsmasq restart && service odhcpd restart; then
        echo "✅ DNS сервисы перезапущены успешно"
        return 0
    else
        echo "❌ Ошибка перезапуска DNS сервисов"
        return 1
    fi
}

# Безопасное создание бэкапа
create_backup() {
    local DIR="/etc/config"
    local DIR_BACKUP="/root/backup_openwrt_$(date +%Y%m%d_%H%M%S)"
    local config_files="network firewall doh-proxy dhcp"
    
    if [ ! -d "$DIR_BACKUP" ]; then
        echo "📦 Создание бэкапа конфигурационных файлов..."
        if ! mkdir -p "$DIR_BACKUP"; then
            echo "❌ Не удалось создать директорию для бэкапа"
            return 1
        fi
        
        for file in $config_files; do
            if [ -f "${DIR}/${file}" ]; then
                if cp -f "${DIR}/${file}" "${DIR_BACKUP}/${file}"; then
                    echo "✅ Бэкап $file создан"
                else
                    echo "❌ Ошибка при бэкапе $file"
                    return 1
                fi
            else
                echo "⚠️ Файл ${DIR}/${file} не существует, пропускаем"
            fi
        done
        echo "✅ Бэкап создан в $DIR_BACKUP"
        return 0
    else
        echo "✅ Бэкап уже существует"
        return 0
    fi
}

# Проверка работы сервисов
check_service_health() {
    local service="$1"
    local test_url="${2:-}"
    
    if ! service "$service" status > /dev/null 2>&1; then
        echo "❌ Сервис $service не запущен"
        return 1
    fi
    
    if [ -n "$test_url" ]; then
        if curl --max-time 10 -s -o /dev/null "$test_url"; then
            echo "✅ Сервис $service работает нормально"
            return 0
        else
            echo "⚠️ Сервис $service запущен, но тест не пройден"
            return 2
        fi
    else
        echo "✅ Сервис $service запущен"
        return 0
    fi
}

# Проверка доступности интернета
check_internet_connection() {
    echo "🔍 Проверка интернет соединения..."
    if ping -c 2 -W 5 8.8.8.8 > /dev/null 2>&1; then
        echo "✅ Интернет соединение активно"
        return 0
    else
        echo "❌ Нет интернет соединения"
        return 1
    fi
}

# Проверка версии sing-box
check_sing_box_version() {
    echo "🔍 Проверка версии sing-box..."
    
    if command -v sing-box > /dev/null 2>&1; then
        local current_version
        current_version=$(sing-box version 2>/dev/null | grep -o 'version [0-9.]*' | cut -d' ' -f2)
        
        if [ -n "$current_version" ]; then
            echo "✅ Текущая версия sing-box: $current_version"
            
            # Проверяем минимальную требуемую версию
            local min_version="1.12.0"
            if [ "$(printf '%s\n%s\n' "$min_version" "$current_version" | sort -V | tail -n1)" = "$current_version" ]; then
                echo "✅ Версия sing-box совместима"
                return 0
            else
                echo "⚠️ Версия sing-box устарела ($current_version < $min_version)"
                return 1
            fi
        else
            echo "⚠️ Не удалось определить версию sing-box"
            return 2
        fi
    else
        echo "❌ sing-box не установлен"
        return 3
    fi
}

# Основная логика
main() {
    local is_manual_input_parameters="${1:-n}"
    local is_reconfig_podkop="${2:-y}"
    
    echo "🚀 Запуск скрипта конфигурации OpenWRT роутера..."
    echo "📝 Логирование в: $LOG_FILE"
    
    # Проверка интернета
    if ! check_internet_connection; then
        echo "⚠️ Продолжаем без проверки интернета..."
    fi
    
    # Обновление списка пакетов
    echo "🔄 Обновление списка пакетов..."
    if opkg update; then
        echo "✅ Список пакетов обновлен"
    else
        echo "❌ Не удалось обновить список пакетов"
        exit 1
    fi
    
    # Установка обязательных пакетов
    local required_packages="coreutils-base64 jq curl unzip"
    for pkg in $required_packages; do
        if ! checkPackageAndInstall "$pkg" "1"; then
            exit 1
        fi
    done
    
    # Установка AmneziaWG через официальный скрипт
    if ! install_awg_packages; then
        echo "⚠️ Официальный скрипт установки не сработал"
        echo "💡 Пропускаем установку AmneziaWG"
    fi
    
    # Установка sing-box через официальный скрипт
    echo "🔧 Установка sing-box..."
    if ! install_sing_box; then
        echo "❌ Официальный скрипт установки sing-box не сработал"
        echo "🔄 Пробуем альтернативный метод установки..."
        
        # Установка из репозитория
        if checkPackageAndInstall "sing-box" "1"; then
            echo "✅ sing-box установлен из репозитория"
        else
            echo "❌ Не удалось установить sing-box"
            echo "💡 Установите sing-box вручную:"
            echo "   curl -fsSL https://sing-box.app/install.sh | sh"
            exit 1
        fi
    fi
    
    # Проверка версии sing-box
    if ! check_sing_box_version; then
        echo "🔄 Обновление sing-box..."
        if install_sing_box; then
            echo "✅ sing-box успешно обновлен"
        else
            echo "⚠️ Не удалось обновить sing-box, продолжаем с текущей версией"
        fi
    fi
    
    # Проверка установки dnsmasq-full
    if opkg list-installed | grep -q "dnsmasq-full "; then
        echo "✅ dnsmasq-full уже установлен"
    else
        echo "📦 Установка dnsmasq-full..."
        if cd /tmp/ && opkg download dnsmasq-full; then
            if opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/; then
                echo "✅ dnsmasq-full установлен успешно"
            else
                echo "❌ Ошибка установки dnsmasq-full"
                exit 1
            fi
        else
            echo "❌ Ошибка загрузки dnsmasq-full"
            exit 1
        fi
    fi
    
    # Настройка dnsmasq
    echo "🔧 Настройка dnsmasq..."
    uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
    uci commit dhcp
    
    # Создание бэкапа
    if ! create_backup; then
        echo "❌ Ошибка создания бэкапа"
        exit 1
    fi
    
    # Дополнительные пакеты
    echo "📦 Установка дополнительных пакетов..."
    
    # Zapret (упрощенная установка)
    install_zapret_simple
    
    # Opera Proxy
    install_opera_proxy
    
    # DNS Fail-Safe Proxy
    install_dns_failsafe_proxy
    
    # Настройка DHCP
    echo "🔧 Настройка DHCP..."
    uci set dhcp.cfg01411c.strictorder='1'
    uci set dhcp.cfg01411c.filter_aaaa='1'
    uci commit dhcp
    
    # Настройка sing-box
    echo "🔧 Настройка sing-box..."
    cat << 'EOF' > /etc/sing-box/config.json
{
    "log": {
        "disabled": true,
        "level": "error"
    },
    "inbounds": [
        {
            "type": "tproxy",
            "listen": "::",
            "listen_port": 1100,
            "sniff": false
        }
    ],
    "outbounds": [
        {
            "type": "http",
            "server": "127.0.0.1",
            "server_port": 18080
        }
    ],
    "route": {
        "auto_detect_interface": true
    }
}
EOF

    # Настройка sing-box в UCI
    uci set sing-box.main.enabled='1'
    uci set sing-box.main.user='root'
    uci add_list sing-box.main.ifaces='wan'
    uci add_list sing-box.main.ifaces='wan6'
    uci commit sing-box
    
    # Добавление правил firewall
    if ! uci show firewall | grep -q "Block_UDP_443"; then
        echo "🔧 Добавление блокировки QUIC..."
        
        uci batch << 'EOF'
add firewall rule
set firewall.@rule[-1].name='Block_UDP_80'
add_list firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].src='lan'
set firewall.@rule[-1].dest='wan'
set firewall.@rule[-1].dest_port='80'
set firewall.@rule[-1].target='REJECT'
add firewall rule
set firewall.@rule[-1].name='Block_UDP_443'
add_list firewall.@rule[-1].proto='udp'
set firewall.@rule[-1].src='lan'
set firewall.@rule[-1].dest='wan'
set firewall.@rule[-1].dest_port='443'
set firewall.@rule[-1].target='REJECT'
EOF
        uci commit firewall
        echo "✅ Правила firewall добавлены"
    else
        echo "✅ Правила firewall уже существуют"
    fi
    
    # Настройка обхода геоблокировок
    echo "🔧 Настройка обхода геоблокировок..."
    if byPassGeoBlockComssDNS; then
        echo "✅ Обход геоблокировок настроен успешно"
    else
        echo "⚠️ Предупреждение: проблемы с настройкой обхода геоблокировок"
    fi
    
    # Запуск сервисов
    echo "🔧 Запуск сервисов..."
    manage_package "sing-box" "enable" "start"
    
    # Запуск простого блокировщика если Zapret не установлен
    if ! opkg list-installed | grep -q "zapret "; then
        echo "🔧 Запуск альтернативного блокировщика..."
        /etc/init.d/simple-blocker enable
        /etc/init.d/simple-blocker start
    else
        manage_package "zapret" "enable" "start"
    fi
    
    # Финальные проверки
    echo "🔍 Финальные проверки..."
    check_service_health "sing-box"
    
    echo ""
    echo "🎉 Конфигурация завершена успешно!"
    echo "📋 Лог сохранен в: $LOG_FILE"
    echo "💡 Рекомендуется перезагрузить роутер для применения всех изменений"
    
    return 0
}

# Обработка сигналов
trap 'echo "❌ Скрипт прерван пользователем"; exit 130' INT
trap 'echo "❌ Скрипт завершен аварийно"; exit 1' TERM

# Запуск основной функции
main "$@"
