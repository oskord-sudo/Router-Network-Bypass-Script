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
    
    # Проверка зависимостей
    echo "📋 Проверка зависимостей..."
    if opkg info "$package" 2>/dev/null | grep -q "Depends:"; then
        echo "Зависимости пакета:"
        opkg info "$package" | grep "Depends:" | sed 's/Depends://' | tr ',' '\n' | while read -r dep; do
            dep=$(echo "$dep" | xargs)
            if [ -n "$dep" ]; then
                if opkg list-installed | grep -q "^$dep "; then
                    echo "  ✅ $dep: установлен"
                else
                    echo "  ❌ $dep: НЕ установлен"
                fi
            fi
        done
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

# Специальная функция для установки Zapret
install_zapret() {
    echo "🔧 Специальная установка Zapret..."
    
    local packages="
        zapret
        luci-app-zapret
        luci-i18n-zapret-ru
        luci-i18n-zapret-en
    "
    
    local found=0
    for pkg in $packages; do
        if opkg list | grep -q "^$pkg "; then
            echo "✅ Найден пакет: $pkg"
            if opkg install "$pkg"; then
                echo "✅ $pkg установлен успешно"
                found=1
                # Не прерываем цикл, пробуем установить все найденные пакеты
            else
                echo "⚠️ Не удалось установить $pkg"
            fi
        fi
    done
    
    if [ "$found" -eq 0 ]; then
        echo "⚠️ Не удалось найти или установить Zapret в репозиториях"
        echo "🔄 Попробуем установить из исходников или альтернативных источников..."
        
        # Попытка установки через GitHub
        echo "📦 Попытка установки Zapret из GitHub..."
        local zapret_github_url="https://github.com/bol-van/zapret/archive/refs/heads/master.zip"
        local temp_dir="/tmp/zapret_install"
        
        mkdir -p "$temp_dir"
        cd "$temp_dir"
        
        if wget -O zapret-master.zip "$zapret_github_url"; then
            echo "✅ Архив Zapret загружен"
            if unzip zapret-master.zip; then
                echo "✅ Архив распакован"
                if [ -d "zapret-master" ]; then
                    cd zapret-master
                    echo "🔧 Компиляция и установка Zapret из исходников..."
                    if make && make install; then
                        echo "✅ Zapret успешно установлен из исходников"
                        found=1
                    else
                        echo "❌ Ошибка компиляции Zapret"
                    fi
                fi
            else
                echo "❌ Ошибка распаковки архива"
            fi
        else
            echo "❌ Не удалось загрузить Zapret из GitHub"
        fi
        
        rm -rf "$temp_dir"
    fi
    
    if [ "$found" -eq 0 ]; then
        echo "💡 Альтернативные решения для блокировки трафика:"
        echo "   1. Используйте iptables/nftables для ручной блокировки"
        echo "   2. Настройте dnsmasq для блокировки на DNS уровне"
        echo "   3. Используйте AdBlock или другие фильтры"
        echo "   4. Ручная установка Zapret:"
        echo "      git clone https://github.com/bol-van/zapret.git"
        echo "      cd zapret"
        echo "      make && make install"
    fi
    
    return $found
}

# Специальная функция для установки Opera Proxy
install_opera_proxy() {
    echo "🔧 Специальная установка Opera Proxy..."
    
    local packages="
        opera-proxy
        luci-app-opera-proxy
        luci-i18n-opera-proxy-ru
        luci-i18n-opera-proxy-en
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
        echo "🔍 Поиск альтернативных прокси пакетов..."
        
        local alternative_proxies="
            https-dns-proxy
            luci-app-https-dns-proxy
            shadowsocks-libev
            luci-app-shadowsocks
            v2ray
            xray
        "
        
        for proxy in $alternative_proxies; do
            if opkg list | grep -q "^$proxy "; then
                echo "📦 Найден альтернативный прокси пакет: $proxy"
                if opkg install "$proxy"; then
                    echo "✅ $proxy установлен как альтернатива Opera Proxy"
                    found=1
                    break
                fi
            fi
        done
    fi
    
    if [ "$found" -eq 0 ]; then
        echo "💡 Альтернативные решения для Opera Proxy:"
        echo "   1. Используйте sing-box для проксирования трафика"
        echo "   2. Настройте вручную другие прокси сервисы"
        echo "   3. Пропустите установку Opera Proxy"
        echo "   4. Установите вручную: opkg install https-dns-proxy"
    fi
    
    return $found
}

# Специальная функция для проблемных пакетов DNS
install_dns_failsafe_proxy() {
    echo "🔧 Специальная установка DNS Fail-Safe Proxy..."
    
    local packages="
        dns-failsafe-proxy
        luci-app-dns-failsafe-proxy
        luci-i18n-dns-failsafe-proxy-ru
        luci-i18n-dns-failsafe-proxy-en
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
        echo "💡 Альтернативные решения:"
        echo "   1. Используйте другие DNS сервисы (dnsmasq-full уже установлен)"
        echo "   2. Настройте резервные DNS вручную в /etc/config/dhcp"
        echo "   3. Пропустите установку этого пакета"
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

# Альтернативная установка AmneziaWG если официальный скрипт не сработал
install_awg_alternative() {
    echo "🔧 Альтернативная установка AmneziaWG..."
    
    # Определение архитектуры
    local PKGARCH
    if ! PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}'); then
        echo "❌ Не удалось определить архитектуру пакетов"
        return 1
    fi
    
    local TARGET
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    local SUBTARGET
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    local VERSION
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    
    if [ -z "$VERSION" ]; then
        echo "❌ Не удалось определить версию OpenWRT"
        return 1
    fi
    
    local PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    local BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VERSION}/"
    local AWG_DIR="/tmp/amneziawg"
    
    if ! mkdir -p "$AWG_DIR"; then
        echo "❌ Не удалось создать временную директорию"
        return 1
    fi
    
    # Установка основных пакетов
    echo "📦 Установка kmod-amneziawg..."
    local kmod_filename="kmod-amneziawg${PKGPOSTFIX}"
    local kmod_url="${BASE_URL}${kmod_filename}"
    
    if wget -O "${AWG_DIR}/${kmod_filename}" "$kmod_url"; then
        if opkg install "${AWG_DIR}/${kmod_filename}"; then
            echo "✅ kmod-amneziawg установлен успешно"
        else
            echo "⚠️ Ошибка установки kmod-amneziawg, пробуем с --force-overwrite"
            opkg install --force-overwrite "${AWG_DIR}/${kmod_filename}" || echo "❌ Не удалось установить kmod-amneziawg"
        fi
    else
        echo "❌ Не удалось загрузить kmod-amneziawg"
    fi
    
    echo "📦 Установка amneziawg-tools..."
    local tools_filename="amneziawg-tools${PKGPOSTFIX}"
    local tools_url="${BASE_URL}${tools_filename}"
    
    if wget -O "${AWG_DIR}/${tools_filename}" "$tools_url"; then
        if opkg install "${AWG_DIR}/${tools_filename}"; then
            echo "✅ amneziawg-tools установлен успешно"
        else
            echo "⚠️ Ошибка установки amneziawg-tools, пробуем с --force-overwrite"
            opkg install --force-overwrite "${AWG_DIR}/${tools_filename}" || echo "❌ Не удалось установить amneziawg-tools"
        fi
    else
        echo "❌ Не удалось загрузить amneziawg-tools"
    fi
    
    echo "📦 Установка luci-app-amneziawg..."
    local luci_filename="luci-app-amneziawg${PKGPOSTFIX}"
    local luci_url="${BASE_URL}${luci_filename}"
    
    if wget -O "${AWG_DIR}/${luci_filename}" "$luci_url"; then
        if opkg install "${AWG_DIR}/${luci_filename}"; then
            echo "✅ luci-app-amneziawg установлен успешно"
        else
            echo "⚠️ Ошибка установки luci-app-amneziawg, пробуем с --force-overwrite"
            opkg install --force-overwrite "${AWG_DIR}/${luci_filename}" || echo "❌ Не удалось установить luci-app-amneziawg"
        fi
    else
        echo "❌ Не удалось загрузить luci-app-amneziawg"
    fi
    
    rm -rf "$AWG_DIR"
    
    # Проверка установленных пакетов
    echo "🔍 Проверка установленных пакетов AmneziaWG:"
    for pkg in kmod-amneziawg amneziawg-tools luci-app-amneziawg; do
        if opkg list-installed | grep -q "^$pkg "; then
            echo "   ✅ $pkg: установлен"
        else
            echo "   ❌ $pkg: НЕ установлен"
        fi
    done
    
    return 0
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
    local config_files="network firewall doh-proxy zapret dhcp"
    
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
        echo "🔄 Пробуем альтернативный метод установки..."
        if ! install_awg_alternative; then
            echo "❌ Не удалось установить AmneziaWG"
            echo "💡 Установите AmneziaWG вручную:"
            echo "   wget -O /tmp/install.sh https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/master/amneziawg-install.sh"
            echo "   sh /tmp/install.sh"
        fi
    fi
    
    # Установка sing-box через официальный скрипт
    echo "🔧 Установка sing-box..."
    if ! install_sing_box; then
        echo "❌ Официальный скрипт установки sing-box не сработал"
        echo "🔄 Пробуем альтернативный метод установки..."
        
        # Остановка старого сервиса если был
        manage_package "podkop" "enable" "stop"
        
        # Удаление старой версии если есть
        opkg remove --force-removal-of-dependent-packages "sing-box" 2>/dev/null || true
        
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
        # Переустановка через официальный скрипт для обновления
        if install_sing_box; then
            echo "✅ sing-box успешно обновлен"
        else
            echo "⚠️ Не удалось обновить sing-box, продолжаем с текущей версией"
        fi
    fi
    
    # Обновление пакетов AmneziaWG
    echo "🔄 Обновление пакетов AmneziaWG..."
    for pkg in amneziawg-tools kmod-amneziawg luci-app-amneziawg; do
        if opkg list-installed | grep -q "^${pkg} "; then
            if opkg upgrade "$pkg"; then
                echo "✅ $pkg обновлен"
            else
                echo "⚠️ Не удалось обновить $pkg"
            fi
        fi
    done
    
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
    
    # Zapret (специальная обработка)
    install_zapret
    
    # Opera Proxy (специальная обработка)
    install_opera_proxy
    
    # DNS Fail-Safe Proxy (специальная обработка)
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
    
    # Запуск Opera Proxy только если он установлен
    if opkg list-installed | grep -q "opera-proxy "; then
        manage_package "opera-proxy" "enable" "start"
    else
        echo "⚠️ Opera Proxy не установлен, пропускаем запуск"
    fi
    
    # Запуск Zapret только если он установлен
    if opkg list-installed | grep -q "zapret "; then
        manage_package "zapret" "enable" "start"
    else
        echo "⚠️ Zapret не установлен, пропускаем запуск"
    fi
    
    # Финальные проверки
    echo "🔍 Финальные проверки..."
    check_service_health "sing-box"
    
    if opkg list-installed | grep -q "opera-proxy "; then
        check_service_health "opera-proxy"
    fi
    
    if opkg list-installed | grep -q "zapret "; then
        check_service_health "zapret"
    fi
    
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
