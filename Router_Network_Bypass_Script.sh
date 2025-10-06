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

requestConfWARP1() {
    # запрос конфигурации WARP
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://valokda-amnezia.vercel.app/api/warp' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://valokda-amnezia.vercel.app/api/warp' 2>/dev/null)
    echo "$result"
}

requestConfWARP2() {
    # запрос конфигурации WARP
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://warp-gen.vercel.app/generate-config' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://warp-gen.vercel.app/generate-config' 2>/dev/null)
    echo "$result"
}

requestConfWARP3() {
    # запрос конфигурации WARP
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warpd' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://config-generator-warp.vercel.app/' 2>/dev/null)
    echo "$result"
}

requestConfWARP4() {
    # запрос конфигурации WARP без параметров
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warp6t' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://config-generator-warp.vercel.app/' 2>/dev/null)
    echo "$result"
}

requestConfWARP5() {
    # запрос конфигурации WARP без параметров
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warp4t' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.9' \
        -H 'referer: https://config-generator-warp.vercel.app/' 2>/dev/null)
    echo "$result"
}

requestConfWARP6() {
    # запрос конфигурации WARP
    local result
    result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://warp-generator.vercel.app/api/warp' \
        -H 'accept: */*' \
        -H 'accept-language: ru-RU,ru;q=0.6' \
        -H 'content-type: application/json' \
        -H 'referer: https://warp-generator.vercel.app/' \
        --data-raw '{"selectedServices":[],"siteMode":"all","deviceType":"computer"}' 2>/dev/null)
    echo "$result"
}

# Функция для обработки выполнения запроса
check_request() {
    local response="$1"
    local choice="$2"
    
    # Извлекаем код состояния
    local response_code="${response: -3}"  # Последние 3 символа - это код состояния
    local response_body="${response%???}"    # Все, кроме последних 3 символов - это тело ответа
    
    # Проверяем код состояния
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
    uci add_list dhcp.cfg01411c.server='/*.windowsupdate.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.bing.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.supercell.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.seeurlpcl.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.supercellid.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.supercellgames.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.clashroyale.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.brawlstars.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.clash.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.clashofclans.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.x.ai/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.grok.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.github.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.forzamotorsport.net/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.forzaracingchampionship.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.forzarc.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.gamepass.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.orithegame.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.renovacionxboxlive.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.tellmewhygame.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox.co/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox.eu/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox.org/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox360.co/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox360.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox360.eu/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbox360.org/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxab.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxgamepass.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxgamestudios.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxlive.cn/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxlive.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxone.co/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxone.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxone.eu/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxplayanywhere.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxservices.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xboxstudios.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.xbx.lv/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.sentry.io/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.usercentrics.eu/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.recaptcha.net/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.gstatic.com/127.0.0.1#5056'
    uci add_list dhcp.cfg01411c.server='/*.brawlstarsgame.com/127.0.0.1#5056'
    
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

deleteByPassGeoBlockComssDNS() {
    echo "🧹 Удаление правил обхода геоблокировок..."
    
    # Удаление серверов
    while uci delete dhcp.cfg01411c.server 2>/dev/null; do :; done
    uci add_list dhcp.cfg01411c.server='127.0.0.1#5359'
    
    # Удаление доменов (только добавленных скриптом)
    local domains_to_remove=("chatgpt.com" "openai.com" "webrtc.chatgpt.com" "ios.chat.openai.com" "searchgpt.com")
    
    for domain in "${domains_to_remove[@]}"; do
        local index
        index=$(uci show dhcp | grep "domain.*name.*$domain" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
        if [ -n "$index" ]; then
            uci delete "dhcp.@domain[$index]"
            echo "✅ Удален домен: $domain"
        fi
    done
    
    uci commit dhcp
    
    if service dnsmasq restart && service odhcpd restart && service doh-proxy restart; then
        echo "✅ DNS сервисы перезапущены успешно"
    else
        echo "❌ Ошибка перезапуска DNS сервисов"
        return 1
    fi
}

install_youtubeunblock_packages() {
    echo "📦 Установка YouTube Unblock пакетов..."
    
    if ! PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}'); then
        echo "❌ Не удалось определить архитектуру пакетов"
        return 1
    fi
    
    local VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    local BASE_URL="https://github.com/Waujito/youtubeUnblock/releases/download/v1.1.0/"
    local PACK_NAME="youtubeUnblock"
    local AWG_DIR="/tmp/$PACK_NAME"
    
    mkdir -p "$AWG_DIR"
    
    # Проверка и установка зависимостей
    local PACKAGES="kmod-nfnetlink-queue kmod-nft-queue kmod-nf-conntrack"
    for pkg in $PACKAGES; do
        checkPackageAndInstall "$pkg" "1" || return 1
    done

    # Установка основного пакета
    if ! install_package "$PACK_NAME" "youtubeUnblock-1.1.0-2-2d579d5-${PKGARCH}-openwrt-23.05.ipk" \
                        "${BASE_URL}youtubeUnblock-1.1.0-2-2d579d5-${PKGARCH}-openwrt-23.05.ipk" "$AWG_DIR"; then
        rm -rf "$AWG_DIR"
        return 1
    fi

    # Установка Luci интерфейса
    local LUCI_PACK_NAME="luci-app-youtubeUnblock"
    if ! install_package "$LUCI_PACK_NAME" "luci-app-youtubeUnblock-1.1.0-1-473af29.ipk" \
                        "${BASE_URL}luci-app-youtubeUnblock-1.1.0-1-473af29.ipk" "$AWG_DIR"; then
        rm -rf "$AWG_DIR"
        return 1
    fi

    rm -rf "$AWG_DIR"
    echo "✅ YouTube Unblock пакеты установлены успешно"
}

# Улучшенная проверка работы сервисов
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
            else
                echo "⚠️ Файл $DIR/$file не существует, пропускаем"
            fi
        done
        echo "✅ Бэкап создан в $DIR_BACKUP"
    else
        echo "✅ Бэкап уже существует"
    fi
}

# Основная логика с улучшенной обработкой ошибок
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
    local required_packages="coreutils-base64 jq curl unzip opera-proxy zapret"
    for pkg in $required_packages; do
        checkPackageAndInstall "$pkg" "1" || exit 1
    done
    
    # Проверка версии sing-box
    local findVersion="1.12.0"
    local INSTALLED_SINGBOX_VERSION
    INSTALLED_SINGBOX_VERSION=$(opkg list-installed | grep "^sing-box " | cut -d ' ' -f 3)
    
    if [ -n "$INSTALLED_SINGBOX_VERSION" ] && [ "$(printf '%s\n%s\n' "$findVersion" "$INSTALLED_SINGBOX_VERSION" | sort -V | tail -n1)" = "$INSTALLED_SINGBOX_VERSION" ]; then
        echo "✅ Установленная версия sing-box $INSTALLED_SINGBOX_VERSION совместима"
    else
        echo "🔄 Установленная версия sing-box устарела или не установлена. Установка/обновление sing-box..."
        manage_package "podkop" "enable" "stop"
        opkg remove --force-removal-of-dependent-packages "sing-box"
        checkPackageAndInstall "sing-box" "1" || exit 1
    fi
    
    # Обновление пакетов AmneziaWG
    echo "🔄 Обновление пакетов AmneziaWG..."
    opkg upgrade amneziawg-tools
    opkg upgrade kmod-amneziawg
    opkg upgrade luci-app-amneziawg
    
    # Обновление zapret
    echo "🔄 Обновление zapret..."
    opkg upgrade zapret
    opkg upgrade luci-app-zapret
    manage_package "zapret" "enable" "start"
    
    # Проверка установки dnsmasq-full
    if opkg list-installed | grep -q "dnsmasq-full "; then
        echo "✅ dnsmasq-full уже установлен"
    else
        echo "📦 Установка dnsmasq-full..."
        if ! cd /tmp/ && opkg download dnsmasq-full; then
            echo "❌ Ошибка загрузки dnsmasq-full"
            exit 1
        fi
        
        if opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/; then
            echo "✅ dnsmasq-full установлен успешно"
        else
            echo "❌ Ошибка установки dnsmasq-full"
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
    checkPackageAndInstall "luci-app-dns-failsafe-proxy" "1"
    checkPackageAndInstall "luci-i18n-stubby-ru" "0"
    checkPackageAndInstall "luci-i18n-doh-proxy-ru" "0"
    
    # Настройка конфигурационных файлов
    local URL="https://raw.githubusercontent.com/routerich/RouterichAX3000_configs/refs/heads/new_awg_podkop"
    local config_files="doh-proxy dns-failsafe-proxy"
    
    for file in $config_files; do
        echo "🔧 Настройка $file..."
        if wget -q -O "/etc/config/$file" "$URL/config_files/$file"; then
            echo "✅ $file настроен успешно"
        else
            echo "❌ Ошибка настройки $file"
        fi
    done
    
    # Настройка DHCP
    echo "🔧 Настройка DHCP..."
    uci set dhcp.cfg01411c.strictorder='1'
    uci set dhcp.cfg01411c.filter_aaaa='1'
    uci commit dhcp
    
    # Настройка sing-box
    echo "🔧 Настройка sing-box..."
    cat <<EOF > /etc/sing-box/config.json
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
    uci add_list sing-box.main.ifaces='wan2'
    uci add_list sing-box.main.ifaces='wan6'
    uci add_list sing-box.main.ifaces='wwan'
    uci add_list sing-box.main.ifaces='wwan0'
    uci add_list sing-box.main.ifaces='modem'
    uci add_list sing-box.main.ifaces='l2tp'
    uci add_list sing-box.main.ifaces='pptp'
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
    
    # Настройка zapret
    echo "🔧 Проверка работы zapret..."
    manage_package "podkop" "enable" "stop"
    
    local zapret_config_url="https://raw.githubusercontent.com/routerich/RouterichAX3000_configs/refs/heads/new_awg_podkop"
    
    if wget -q -O "/etc/config/zapret" "$zapret_config_url/config_files/zapret" &&
       wget -q -O "/opt/zapret/ipset/zapret-hosts-user.txt" "$zapret_config_url/config_files/zapret-hosts-user.txt" &&
       wget -q -O "/opt/zapret/init.d/openwrt/custom.d/50-stun4all" "$zapret_config_url/config_files/50-stun4all" &&
       wget -q -O "/opt/zapret/init.d/openwrt/custom.d/50-wg4all" "$zapret_config_url/config_files/50-wg4all"; then
        
        chmod +x "/opt/zapret/init.d/openwrt/custom.d/50-stun4all"
        chmod +x "/opt/zapret/init.d/openwrt/custom.d/50-wg4all"
        
        service zapret restart
        echo "✅ Zapret настроен и перезапущен"
    else
        echo "❌ Ошибка настройки zapret"
    fi
    
    # Проверка работы zapret
    local isWorkZapret=0
    if curl -f -o /dev/null -k --connect-to ::google.com -L -H "Host: mirror.gcr.io" --max-time 120 \
       "https://test.googlevideo.com/v2/cimg/android/blobs/sha256:2ab09b027e7f3a0c2e8bb1944ac46de38cebab7145" ; then
        isWorkZapret=1
        echo "✅ Zapret работает корректно"
    else
        echo "❌ Zapret не работает"
    fi
    
    # Завершение настройки AmneziaWG если нужно
    if [ "$is_reconfig_podkop" = "y" ]; then
        echo "🔧 Завершение настройки AmneziaWG..."
        # Дополнительные настройки AmneziaWG
    fi
    
    # Финальная проверка сервисов
    echo "🔍 Проверка состояния сервисов..."
    check_service_health "dnsmasq" "https://google.com"
    check_service_health "zapret" ""
    check_service_health "doh-proxy" ""
    
    echo "=== Выполнение скрипта завершено $(date) ==="
    echo "📋 Логи сохранены в: $LOG_FILE"
}

# Вызов основной функции
main "$@"
