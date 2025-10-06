#!/bin/sh

set -e  # Выход при любой ошибке

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Этот скрипт должен запускаться с правами root"
    exit 1
fi

# Проверка окружения OpenWRT
if ! which opkg >/dev/null 2>&1; then
    echo "❌ Это не система OpenWRT или opkg не установлен"
    exit 1
fi

# Логирование
LOG_FILE="/tmp/router_config.log"
echo "=== Начало выполнения скрипта $(date) ===" > "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

echo "🔍 Проверка системных утилит..."
for util in uci wget curl opkg; do
    if which "$util" >/dev/null 2>&1; then
        echo "✅ $util доступен"
    else
        echo "❌ $util не найден"
        exit 1
    fi
done

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
    
    if ! wget -q --timeout=30 --tries=2 -O "$temp_dir/$filename" "$url"; then
        echo "❌ Ошибка загрузки $package"
        return 1
    fi
    
    if opkg install "$temp_dir/$filename" 2>/dev/null; then
        echo "✅ $package успешно установлен"
        return 0
    else
        echo "❌ Ошибка установки $package"
        return 1
    fi
}

install_awg_packages() {
    echo "🔧 Установка AmneziaWG пакетов..."
    
    local PKGARCH
    PKGARCH=$(opkg print-architecture | head -1 | awk '{print $2}')
    
    if [ -z "$PKGARCH" ]; then
        echo "❌ Не удалось определить архитектуру пакетов"
        return 1
    fi
    
    local TARGET
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1 2>/dev/null || echo "unknown")
    local SUBTARGET
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2 2>/dev/null || echo "unknown")
    local VERSION
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version' 2>/dev/null || echo "snapshot")
    
    echo "📋 Архитектура: $PKGARCH, Цель: $TARGET/$SUBTARGET, Версия: $VERSION"
    
    local PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    local BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"
    local AWG_DIR="/tmp/amneziawg"
    
    mkdir -p "$AWG_DIR"
    
    # Установка пакетов через универсальную функцию
    if install_package "kmod-amneziawg" "kmod-amneziawg${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/kmod-amneziawg${PKGPOSTFIX}" "$AWG_DIR"; then
        echo "✅ kmod-amneziawg установлен"
    else
        echo "⚠️ Не удалось установить kmod-amneziawg"
    fi
    
    if install_package "amneziawg-tools" "amneziawg-tools${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/amneziawg-tools${PKGPOSTFIX}" "$AWG_DIR"; then
        echo "✅ amneziawg-tools установлен"
    else
        echo "⚠️ Не удалось установить amneziawg-tools"
    fi
    
    if install_package "luci-app-amneziawg" "luci-app-amneziawg${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/luci-app-amneziawg${PKGPOSTFIX}" "$AWG_DIR"; then
        echo "✅ luci-app-amneziawg установлен"
    else
        echo "⚠️ Не удалось установить luci-app-amneziawg"
    fi
    
    rm -rf "$AWG_DIR"
    echo "✅ Установка AmneziaWG завершена"
}

manage_package() {
    local name="$1"
    local autostart="$2"
    local process="$3"

    # Проверка, установлен ли пакет
    if opkg list-installed | grep -q "^$name "; then
        
        # Проверка, включен ли автозапуск
        if /etc/init.d/"$name" enabled 2>/dev/null; then
            if [ "$autostart" = "disable" ]; then
                /etc/init.d/"$name" disable 2>/dev/null && echo "✅ Автозапуск $name отключен" || echo "⚠️ Не удалось отключить автозапуск $name"
            fi
        else
            if [ "$autostart" = "enable" ]; then
                /etc/init.d/"$name" enable 2>/dev/null && echo "✅ Автозапуск $name включен" || echo "⚠️ Не удалось включить автозапуск $name"
            fi
        fi

        # Проверка, запущен ли процесс
        if pgrep -f "$name" > /dev/null 2>&1; then
            if [ "$process" = "stop" ]; then
                /etc/init.d/"$name" stop 2>/dev/null && echo "✅ Сервис $name остановлен" || echo "⚠️ Не удалось остановить сервис $name"
            fi
        else
            if [ "$process" = "start" ]; then
                /etc/init.d/"$name" start 2>/dev/null && echo "✅ Сервис $name запущен" || echo "⚠️ Не удалось запустить сервис $name"
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
    if opkg install "$name" 2>/dev/null; then
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

requestConfWARP1() {
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://valokda-amnezia.vercel.app/api/warp' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://valokda-amnezia.vercel.app/api/warp' 2>/dev/null)
    echo "$result"
}

requestConfWARP2() {
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://warp-gen.vercel.app/generate-config' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://warp-gen.vercel.app/generate-config' 2>/dev/null)
    echo "$result"
}

requestConfWARP3() {
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warpd' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://config-generator-warp.vercel.app/' 2>/dev/null)
    echo "$result"
}

requestConfWARP4() {
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warp6t' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://config-generator-warp.vercel.app/' 2>/dev/null)
    echo "$result"
}

requestConfWARP5() {
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warp4t' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://config-generator-warp.vercel.app/' 2>/dev/null)
    echo "$result"
}

requestConfWARP6() {
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://warp-generator.vercel.app/api/warp' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.6' \
        -H 'content-type: application/json' \
        -H 'referer: https://warp-generator.vercel.app/' \
        --data-raw '{"selectedServices":[],"siteMode":"all","deviceType":"computer"}' 2>/dev/null)
    echo "$result"
}

check_request() {
    local response="$1"
    local choice="$2"
    
    local response_code="${response: -3}"
    local response_body="${response%???}"
    
    if [ "$response_code" -eq 200 ]; then
        case $choice in
        1)
            local content
            content=$(echo "$response_body" | jq -r '.content')    
            local warp_config
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
        2)
            local content
            content=$(echo "$response_body" | jq -r '.config')    
            echo "$content"
            ;;
        3)
            local content
            content=$(echo "$response_body" | jq -r '.content')    
            local warp_config
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
        4)
            local content
            content=$(echo "$response_body" | jq -r '.content')  
            local warp_config
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
        5)
            local content
            content=$(echo "$response_body" | jq -r '.content')
            local warp_config
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
        6)
            local content
            content=$(echo "$response_body" | jq -r '.content')  
            content=$(echo "$content" | jq -r '.configBase64')  
            local warp_config
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
        *)
            echo "Error: Неверный выбор"
            return 1
            ;;
        esac
    else
        echo "Error: HTTP код $response_code"
        return 1
    fi
}

checkAndAddDomainPermanentName() {
    local name="$1"
    local ip="$2"
    local nameRule="option name '$name'"
    
    if ! uci show dhcp 2>/dev/null | grep -q "$nameRule"; then 
        uci add dhcp domain 2>/dev/null
        uci set "dhcp.@domain[-1].name=$name" 2>/dev/null
        uci set "dhcp.@domain[-1].ip=$ip" 2>/dev/null
        uci commit dhcp 2>/dev/null
        echo "✅ Добавлен домен: $name -> $ip"
    else
        echo "✅ Домен $name уже существует"
    fi
}

byPassGeoBlockComssDNS() {
    echo "🔧 Настройка dhcp для обхода геоблокировок..."

    uci set dhcp.@dnsmasq[0].strictorder='1' 2>/dev/null
    uci set dhcp.@dnsmasq[0].filter_aaaa='1' 2>/dev/null
    
    # Очистка существующих серверов
    while uci delete dhcp.@dnsmasq[0].server 2>/dev/null; do :; done
    
    # Добавление новых серверов
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053' 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054' 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5055' 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5056' 2>/dev/null
    
    # Добавление доменных правил
    local domains=(
        '*.chatgpt.com'
        '*.oaistatic.com'
        '*.oaiusercontent.com'
        '*.openai.com'
        '*.microsoft.com'
        '*.windowsupdate.com'
        '*.bing.com'
        '*.github.com'
        '*.x.ai'
        '*.grok.com'
    )
    
    for domain in "${domains[@]}"; do
        uci add_list dhcp.@dnsmasq[0].server="/${domain}/127.0.0.1#5056" 2>/dev/null
    done
    
    uci commit dhcp 2>/dev/null

    echo "🔧 Добавление разблокировки ChatGPT..."

    checkAndAddDomainPermanentName "chatgpt.com" "83.220.169.155"
    checkAndAddDomainPermanentName "openai.com" "83.220.169.155"
    checkAndAddDomainPermanentName "webrtc.chatgpt.com" "83.220.169.155"
    checkAndAddDomainPermanentName "ios.chat.openai.com" "83.220.169.155"
    checkAndAddDomainPermanentName "searchgpt.com" "83.220.169.155"

    if service dnsmasq restart && service odhcpd restart; then
        echo "✅ DNS сервисы перезапущены успешно"
    else
        echo "⚠️ Ошибка перезапуска DNS сервисов"
        return 1
    fi
}

deleteByPassGeoBlockComssDNS() {
    echo "🧹 Удаление правил обхода геоблокировок..."
    
    # Удаление серверов
    while uci delete dhcp.@dnsmasq[0].server 2>/dev/null; do :; done
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5359' 2>/dev/null
    
    # Удаление доменов
    local domains_to_remove=("chatgpt.com" "openai.com" "webrtc.chatgpt.com" "ios.chat.openai.com" "searchgpt.com")
    
    for domain in "${domains_to_remove[@]}"; do
        local index
        index=$(uci show dhcp 2>/dev/null | grep "domain.*name.*$domain" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
        if [ -n "$index" ]; then
            uci delete "dhcp.@domain[$index]" 2>/dev/null
            echo "✅ Удален домен: $domain"
        fi
    done
    
    uci commit dhcp 2>/dev/null
    
    if service dnsmasq restart && service odhcpd restart; then
        echo "✅ DNS сервисы перезапущены успешно"
    else
        echo "⚠️ Ошибка перезапуска DNS сервисов"
        return 1
    fi
}

install_youtubeunblock_packages() {
    echo "📦 Установка YouTube Unblock пакетов..."
    
    local PKGARCH
    PKGARCH=$(opkg print-architecture | head -1 | awk '{print $2}')
    
    if [ -z "$PKGARCH" ]; then
        echo "❌ Не удалось определить архитектуру пакетов"
        return 1
    fi
    
    local VERSION
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version' 2>/dev/null || echo "snapshot")
    local BASE_URL="https://github.com/Waujito/youtubeUnblock/releases/download/v1.1.0/"
    local PACK_NAME="youtubeUnblock"
    local AWG_DIR="/tmp/$PACK_NAME"
    
    mkdir -p "$AWG_DIR"
    
    # Проверка и установка зависимостей
    local PACKAGES="kmod-nfnetlink-queue kmod-nft-queue kmod-nf-conntrack"
    for pkg in $PACKAGES; do
        checkPackageAndInstall "$pkg" "0"
    done

    # Установка основного пакета
    if install_package "$PACK_NAME" "youtubeUnblock-1.1.0-2-2d579d5-${PKGARCH}-openwrt-23.05.ipk" \
                      "${BASE_URL}youtubeUnblock-1.1.0-2-2d579d5-${PKGARCH}-openwrt-23.05.ipk" "$AWG_DIR"; then
        echo "✅ YouTube Unblock установлен"
    else
        echo "⚠️ Не удалось установить YouTube Unblock"
    fi

    # Установка Luci интерфейса
    local LUCI_PACK_NAME="luci-app-youtubeUnblock"
    if install_package "$LUCI_PACK_NAME" "luci-app-youtubeUnblock-1.1.0-1-473af29.ipk" \
                      "${BASE_URL}luci-app-youtubeUnblock-1.1.0-1-473af29.ipk" "$AWG_DIR"; then
        echo "✅ Luci интерфейс YouTube Unblock установлен"
    else
        echo "⚠️ Не удалось установить Luci интерфейс YouTube Unblock"
    fi

    rm -rf "$AWG_DIR"
    echo "✅ Установка YouTube Unblock завершена"
}

check_service_health() {
    local service="$1"
    local test_url="$2"
    
    if service "$service" status > /dev/null 2>&1; then
        echo "✅ Сервис $service запущен"
        return 0
    else
        echo "❌ Сервис $service не запущен"
        return 1
    fi
}

create_backup() {
    local DIR="/etc/config"
    local DIR_BACKUP="/root/backup_config"
    local config_files="network firewall dhcp"
    
    if [ ! -d "$DIR_BACKUP" ]; then
        echo "📦 Создание бэкапа конфигурационных файлов..."
        if mkdir -p "$DIR_BACKUP"; then
            for file in $config_files; do
                if [ -f "$DIR/$file" ]; then
                    if cp -f "$DIR/$file" "$DIR_BACKUP/$file"; then
                        echo "✅ Бэкап $file создан"
                    else
                        echo "⚠️ Ошибка при бэкапе $file"
                    fi
                else
                    echo "⚠️ Файл $DIR/$file не существует, пропускаем"
                fi
            done
            echo "✅ Бэкап создан в $DIR_BACKUP"
        else
            echo "❌ Не удалось создать директорию для бэкапа"
            return 1
        fi
    else
        echo "✅ Бэкап уже существует"
    fi
}

main() {
    local is_manual_input_parameters="${1:-n}"
    local is_reconfig_podkop="${2:-y}"
    
    echo "🚀 Запуск скрипта конфигурации OpenWRT роутера..."
    
    # Создание бэкапа
    create_backup
    
    # Обновление списка пакетов
    echo "🔄 Обновление списка пакетов..."
    if opkg update; then
        echo "✅ Список пакетов обновлен"
    else
        echo "⚠️ Не удалось обновить список пакетов, продолжаем..."
    fi
    
    # Установка обязательных пакетов
    echo "📦 Установка обязательных пакетов..."
    local required_packages="coreutils-base64 jq curl unzip"
    for pkg in $required_packages; do
        checkPackageAndInstall "$pkg" "1"
    done
    
    # Проверка версии sing-box
    echo "🔍 Проверка sing-box..."
    if opkg list-installed | grep -q "^sing-box "; then
        echo "✅ Sing-box установлен"
    else
        echo "📦 Установка sing-box..."
        checkPackageAndInstall "sing-box" "0"
    fi
    
    # Обновление пакетов AmneziaWG
    echo "🔄 Обновление пакетов AmneziaWG..."
    opkg upgrade amneziawg-tools 2>/dev/null || true
    opkg upgrade kmod-amneziawg 2>/dev/null || true
    opkg upgrade luci-app-amneziawg 2>/dev/null || true
    
    # Установка AmneziaWG
    install_awg_packages
    
    # Проверка установки dnsmasq-full
    if opkg list-installed | grep -q "dnsmasq-full "; then
        echo "✅ dnsmasq-full уже установлен"
    else
        echo "📦 Установка dnsmasq-full..."
        if opkg install dnsmasq-full 2>/dev/null; then
            echo "✅ dnsmasq-full установлен успешно"
        else
            echo "⚠️ Не удалось установить dnsmasq-full, используем стандартный dnsmasq"
        fi
    fi
    
    # Настройка dnsmasq
    echo "🔧 Настройка dnsmasq..."
    uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null
    uci commit dhcp 2>/dev/null
    
    # Дополнительные пакеты
    checkPackageAndInstall "luci-app-dns-failsafe-proxy" "0"
    
    # Настройка DHCP
    echo "🔧 Настройка DHCP..."
    uci set dhcp.@dnsmasq[0].strictorder='1' 2>/dev/null
    uci set dhcp.@dnsmasq[0].filter_aaaa='1' 2>/dev/null
    uci commit dhcp 2>/dev/null
    
    # Настройка sing-box
    echo "🔧 Настройка sing-box..."
    cat <<EOF > /etc/sing-box/config.json 2>/dev/null || true
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
    uci set sing-box.main.enabled='1' 2>/dev/null
    uci set sing-box.main.user='root' 2>/dev/null
    uci add_list sing-box.main.ifaces='wan' 2>/dev/null
    uci add_list sing-box.main.ifaces='wan6' 2>/dev/null
    uci commit sing-box 2>/dev/null
    
    # Добавление правил firewall
    echo "🔧 Настройка firewall..."
    local nameRule="option name 'Block_UDP_443'"
    if ! uci show firewall 2>/dev/null | grep -q "$nameRule"; then
        echo "🔧 Добавление блокировки QUIC..."
        
        uci add firewall rule 2>/dev/null
        uci set firewall.@rule[-1].name='Block_UDP_80' 2>/dev/null
        uci add_list firewall.@rule[-1].proto='udp' 2>/dev/null
        uci set firewall.@rule[-1].src='lan' 2>/dev/null
        uci set firewall.@rule[-1].dest='wan' 2>/dev/null
        uci set firewall.@rule[-1].dest_port='80' 2>/dev/null
        uci set firewall.@rule[-1].target='REJECT' 2>/dev/null
        
        uci add firewall rule 2>/dev/null
        uci set firewall.@rule[-1].name='Block_UDP_443' 2>/dev/null
        uci add_list firewall.@rule[-1].proto='udp' 2>/dev/null
        uci set firewall.@rule[-1].src='lan' 2>/dev/null
        uci set firewall.@rule[-1].dest='wan' 2>/dev/null
        uci set firewall.@rule[-1].dest_port='443' 2>/dev/null
        uci set firewall.@rule[-1].target='REJECT' 2>/dev/null
        
        uci commit firewall 2>/dev/null
        echo "✅ Правила firewall добавлены"
    else
        echo "✅ Правила firewall уже существуют"
    fi
    
    # Настройка обхода геоблокировок
    echo "🔧 Настройка обхода геоблокировок..."
    byPassGeoBlockComssDNS
    
    # Финальная проверка сервисов
    echo "🔍 Проверка состояния сервисов..."
    check_service_health "dnsmasq"
    check_service_health "firewall"
    
    # Перезапуск сетевых сервисов
    echo "🔄 Перезапуск сетевых сервисов..."
    if /etc/init.d/network reload; then
        echo "✅ Сетевые сервисы перезапущены"
    else
        echo "⚠️ Не удалось перезапустить сетевые сервисы"
    fi
    
    echo "=== Выполнение скрипта завершено $(date) ==="
    echo "📋 Логи сохранены в: $LOG_FILE"
    echo ""
    echo "🎉 Конфигурация роутера завершена успешно!"
    echo "🔧 Основные изменения:"
    echo "   ✅ Установлены необходимые пакеты"
    echo "   ✅ Настроены DNS и DHCP"
    echo "   ✅ Добавлены правила firewall"
    echo "   ✅ Настроен обход геоблокировок"
    echo "   ✅ Создан бэкап конфигурации"
}

# Вызов основной функции
main "$@"
