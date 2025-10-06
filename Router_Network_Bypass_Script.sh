#!/bin/sh

set -e  # Выход при любой ошибке

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Этот скрипт должен запускаться с правами root"
    exit 1
fi

# Логирование
LOG_FILE="/tmp/router_config.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Начало выполнения скрипта $(date) ==="

# Универсальная функция установки пакетов
install_package() {
    local package="$1"
    local filename="$2"
    local url="$3"
    local temp_dir="$4"
    
    if opkg list-installed | grep -q "^${package} "; then
        echo "✅ $package уже установлен"
        return 0
    fi
    
    echo "📦 Установка $package..."
    
    if ! wget -q --timeout=30 -O "$temp_dir/$filename" "$url"; then
        echo "❌ Ошибка загрузки $package"
        return 1
    fi
    
    if ! opkg install "$temp_dir/$filename"; then
        echo "❌ Ошибка установки $package"
        return 1
    fi
    
    echo "✅ $package успешно установлен"
    return 0
}

install_awg_packages() {
    echo "🔧 Установка AmneziaWG пакетов..."
    
    if ! PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}'); then
        echo "❌ Не удалось определить архитектуру пакетов"
        return 1
    fi
    
    local TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    local SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    local VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    
    [ -z "$VERSION" ] && { echo "❌ Не удалось определить версию"; return 1; }
    
    local PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    local BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"
    local AWG_DIR="/tmp/amneziawg"
    
    mkdir -p "$AWG_DIR"
    
    # Установка пакетов через универсальную функцию
    install_package "kmod-amneziawg" "kmod-amneziawg${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/kmod-amneziawg${PKGPOSTFIX}" "$AWG_DIR" || return 1
    install_package "amneziawg-tools" "amneziawg-tools${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/amneziawg-tools${PKGPOSTFIX}" "$AWG_DIR" || return 1
    install_package "luci-app-amneziawg" "luci-app-amneziawg${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/luci-app-amneziawg${PKGPOSTFIX}" "$AWG_DIR" || return 1
    
    rm -rf "$AWG_DIR"
    echo "✅ AmneziaWG пакеты установлены успешно"
}

manage_package() {
    local name="$1"
    local autostart="$2"
    local process="$3"

    # Проверка, установлен ли пакет
    if opkg list-installed | grep -q "^$name "; then
        
        # Проверка, включен ли автозапуск
        if /etc/init.d/"$name" enabled; then
            if [ "$autostart" = "disable" ]; then
                /etc/init.d/"$name" disable
                echo "✅ Автозапуск $name отключен"
            fi
        else
            if [ "$autostart" = "enable" ]; then
                /etc/init.d/"$name" enable
                echo "✅ Автозапуск $name включен"
            fi
        fi

        # Проверка, запущен ли процесс
        if pgrep -f "$name" > /dev/null; then
            if [ "$process" = "stop" ]; then
                /etc/init.d/"$name" stop
                echo "✅ Сервис $name остановлен"
            fi
        else
            if [ "$process" = "start" ]; then
                /etc/init.d/"$name" start
                echo "✅ Сервис $name запущен"
            fi
        fi
    else
        echo "⚠️ Пакет $name не установлен"
    fi
}

checkPackageAndInstall() {
    local name="$1"
    local isRequired="${2:-0}"
    local alt=""

    if [ "$name" = "https-dns-proxy" ]; then
        alt="luci-app-doh-proxy"
    fi

    if [ -n "$alt" ]; then
        if opkg list-installed | grep -qE "^($name|$alt) "; then
            echo "✅ $name или $alt уже установлен"
            return 0
        fi
    else
        if opkg list-installed | grep -q "^$name "; then
            echo "✅ $name уже установлен"
            return 0
        fi
    fi

    echo "📦 $name не установлен. Установка $name..."
    if opkg install "$name"; then
        echo "✅ $name установлен успешно"
        return 0
    else
        echo "❌ Ошибка установки $name"
        if [ "$isRequired" = "1" ]; then
            echo "⚠️ Пожалуйста, установите $name вручную$( [ -n "$alt" ] && echo " или $alt") и запустите скрипт снова."
            exit 1
        fi
        return 1
    fi
}

checkAndAddDomainPermanentName() {
    local name="$1"
    local ip="$2"
    local nameRule="option name '$name'"
    
    if ! uci show dhcp | grep -q "$nameRule"; then 
        uci add dhcp domain
        uci set "dhcp.@domain[-1].name=$name"
        uci set "dhcp.@domain[-1].ip=$ip"
        uci commit dhcp
        echo "✅ Добавлен домен: $name -> $ip"
    else
        echo "✅ Домен $name уже существует"
    fi
}

byPassGeoBlockComssDNS() {
    echo "🔧 Настройка dhcp для обхода геоблокировок..."

    uci set dhcp.cfg01411c.strictorder='1'
    uci set dhcp.cfg01411c.filter_aaaa='1'
    
    # Очистка существующих серверов
    while uci delete dhcp.cfg01411c.server 2>/dev/null; do :; done
    
    # Добавление новых серверов
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5053'
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5054'
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5055'
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.chatgpt.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.oaistatic.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.oaiusercontent.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.openai.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.microsoft.com/127.0.0.1#5056'
    
    uci commit dhcp

    echo "🔧 Добавление разблокировки ChatGPT..."

    checkAndAddDomainPermanentName "chatgpt.com" "83.220.169.155"
    checkAndAddDomainPermanentName "openai.com" "83.220.169.155"
    checkAndAddDomainPermanentName "webrtc.chatgpt.com" "83.220.169.155"
    checkAndAddDomainPermanentName "ios.chat.openai.com" "83.220.169.155"
    checkAndAddDomainPermanentName "searchgpt.com" "83.220.169.155"

    if service dnsmasq restart && service odhcpd restart; then
        echo "✅ DNS сервисы перезапущены успешно"
    else
        echo "❌ Ошибка перезапуска DNS сервисов"
        return 1
    fi
}

# Безопасное создание бэкапа
create_backup() {
    local DIR="/etc/config"
    local DIR_BACKUP="/root/backup5"
    local config_files="network firewall doh-proxy zapret dhcp dns-failsafe-proxy"
    
    if [ ! -d "$DIR_BACKUP" ]; then
        echo "📦 Создание бэкапа конфигурационных файлов..."
        if ! mkdir -p "$DIR_BACKUP"; then
            echo "❌ Не удалось создать директорию для бэкапа"
            return 1
        fi
        
        for file in $config_files; do
            if [ -f "$DIR/$file" ]; then
                if ! cp -f "$DIR/$file" "$DIR_BACKUP/$file"; then
                    echo "❌ Ошибка при бэкапе $file"
                    return 1
                fi
                echo "✅ Бэкап $file создан"
            else
                echo "⚠️ Файл $DIR/$file не существует, пропускаем"
            fi
        done
        echo "✅ Бэкап создан в $DIR_BACKUP"
    else
        echo "✅ Бэкап уже существует"
    fi
}

# Проверка работы сервисов
check_service_health() {
    local service="$1"
    local test_url="$2"
    
    if ! service "$service" status > /dev/null 2>&1; then
        echo "❌ Сервис $service не запущен"
        return 1
    fi
    
    if [ -n "$test_url" ]; then
        if ! curl --max-time 10 -s -o /dev/null "$test_url"; then
            echo "⚠️ Сервис $service запущен, но тест не пройден"
            return 2
        fi
    fi
    
    echo "✅ Сервис $service работает нормально"
    return 0
}

# Основная логика
main() {
    local is_manual_input_parameters="${1:-n}"
    local is_reconfig_podkop="${2:-y}"
    
    echo "🚀 Запуск скрипта конфигурации OpenWRT роутера..."
    
    # Обновление списка пакетов
    echo "🔄 Обновление списка пакетов..."
    if ! opkg update; then
        echo "❌ Не удалось обновить список пакетов"
        exit 1
    fi
    
    # Установка обязательных пакетов
    local required_packages="coreutils-base64 jq curl unzip"
    for pkg in $required_packages; do
        checkPackageAndInstall "$pkg" "1" || exit 1
    done
    
    # Установка AmneziaWG
    if ! install_awg_packages; then
        echo "❌ Ошибка установки AmneziaWG пакетов"
        exit 1
    fi
    
    # Проверка версии sing-box
    local findVersion="1.12.0"
    local INSTALLED_SINGBOX_VERSION
    INSTALLED_SINGBOX_VERSION=$(opkg list-installed | grep "^sing-box " | cut -d ' ' -f 3)
    
    if [ -n "$INSTALLED_SINGBOX_VERSION" ] && [ "$(printf '%s\n%s\n' "$findVersion" "$INSTALLED_SINGBOX_VERSION" | sort -V | tail -n1)" = "$INSTALLED_SINGBOX_VERSION" ]; then
        echo "✅ Установленная версия sing-box $INSTALLED_SINGBOX_VERSION совместима"
    else
        echo "🔄 Установленная версия sing-box устарела или не установлена. Установка/обновление sing-box..."
        manage_package "podkop" "enable" "stop"
        opkg remove --force-removal-of-dependent-packages "sing-box" 2>/dev/null || true
        checkPackageAndInstall "sing-box" "1" || exit 1
    fi
    
    # Обновление пакетов
    echo "🔄 Обновление пакетов..."
    opkg upgrade amneziawg-tools 2>/dev/null || true
    opkg upgrade kmod-amneziawg 2>/dev/null || true
    opkg upgrade luci-app-amneziawg 2>/dev/null || true
    
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
    create_backup || exit 1
    
    # Дополнительные пакеты
    checkPackageAndInstall "luci-app-dns-failsafe-proxy" "0"
    checkPackageAndInstall "opera-proxy" "0"
    checkPackageAndInstall "zapret" "0"
    
    # Настройка конфигурационных файлов
    local URL="https://raw.githubusercontent.com/routerich/RouterichAX3000_configs/refs/heads/new_awg_podkop"
    
    # Настройка DHCP
    echo "🔧 Настройка DHCP..."
    uci set dhcp.cfg01411c.strictorder='1'
    uci set dhcp.cfg01411c.filter_aaaa='1'
    uci commit dhcp
    
    # Настройка sing-box
    echo "🔧 Настройка sing-box..."
    cat <<'EOF' > /etc/sing-box/config.json
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
    local nameRule="option name 'Block_UDP_443'"
    if ! uci show firewall | grep -q "$nameRule"; then
        echo "🔧 Добавление блокировки QUIC..."
        
        uci add firewall rule
        uci set firewall.@rule[-1].name='Block_UDP_80'
        uci add_list firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='wan'
        uci set firewall.@rule[-1].dest_port='80'
        uci set firewall.@rule[-1].target='REJECT'
        
        uci add firewall rule
        uci set firewall.@rule[-1].name='Block_UDP_443'
        uci add_list firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='wan'
        uci set firewall.@rule[-1].dest_port='443'
        uci set firewall.@rule[-1].target='REJECT'
        
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
    manage_package "opera-proxy" "enable" "start"
    
    # Финальные проверки
    echo "🔍 Финальные проверки..."
    check_service_health "sing-box"
    check_service_health "opera-proxy"
    
    echo ""
    echo "🎉 Конфигурация завершена успешно!"
    echo "📋 Лог сохранен в: $LOG_FILE"
    echo "💡 Рекомендуется перезагрузить роутер для применения всех изменений"
}

# Обработка сигналов
trap 'echo "❌ Скрипт прерван"; exit 1' INT TERM

# Запуск основной функции
main "$@"
