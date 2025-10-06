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
    
    # Проверка что это bash скрипт (базовая проверка)
    if ! head -n 5 "$temp_script" | grep -q "bash\|sh"; then
        echo "⚠️  Загруженный файл может не быть скриптом"
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

# Альтернативная установка если официальный скрипт не сработал
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
    
    # Установка основных пакетов (без массивов для совместимости с busybox)
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

checkPackageAndInstall() {
    local name="$1"
    local isRequired="${2:-0}"
    local alt=""

    if [ "$name" = "https-dns-proxy" ]; then
        alt="luci-app-doh-proxy"
    fi

    local installed=0
    if [ -n "$alt" ]; then
        if opkg list-installed | grep -q "^${name} " || opkg list-installed | grep -q "^${alt} "; then
            installed=1
        fi
    else
        if opkg list-installed | grep -q "^${name} "; then
            installed=1
        fi
    fi

    if [ "$installed" -eq 1 ]; then
        echo "✅ $name уже установлен"
        return 0
    fi

    echo "📦 $name не установлен. Установка $name..."
    if opkg install "$name"; then
        echo "✅ $name установлен успешно"
        return 0
    else
        echo "❌ Ошибка установки $name"
        if [ "$isRequired" = "1" ]; then
            if [ -n "$alt" ]; then
                echo "⚠️ Пожалуйста, установите $name или $alt вручную и запустите скрипт снова."
            else
                echo "⚠️ Пожалуйста, установите $name вручную и запустите скрипт снова."
            fi
            exit 1
        fi
        return 1
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
    local config_files="network firewall doh-proxy zapret dhcp dns-failsafe-proxy"
    
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
    
    # Проверка версии sing-box
    local findVersion="1.12.0"
    local INSTALLED_SINGBOX_VERSION
    INSTALLED_SINGBOX_VERSION=$(opkg list-installed | grep "^sing-box " | awk '{print $3}')
    
    if [ -n "$INSTALLED_SINGBOX_VERSION" ]; then
        if [ "$(printf '%s\n%s\n' "$findVersion" "$INSTALLED_SINGBOX_VERSION" | sort -V | tail -n1)" = "$INSTALLED_SINGBOX_VERSION" ]; then
            echo "✅ Установленная версия sing-box $INSTALLED_SINGBOX_VERSION совместима"
        else
            echo "🔄 Установленная версия sing-box устарела. Обновление..."
            manage_package "podkop" "enable" "stop"
            opkg remove --force-removal-of-dependent-packages "sing-box" 2>/dev/null || true
            checkPackageAndInstall "sing-box" "1" || exit 1
        fi
    else
        echo "📦 Установка sing-box..."
        checkPackageAndInstall "sing-box" "1" || exit 1
    fi
    
    # Обновление пакетов
    echo "🔄 Обновление пакетов..."
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
    local optional_packages="luci-app-dns-failsafe-proxy opera-proxy zapret"
    for pkg in $optional_packages; do
        checkPackageAndInstall "$pkg" "0"
    done
    
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
    manage_package "opera-proxy" "enable" "start"
    
    # Финальные проверки
    echo "🔍 Финальные проверки..."
    check_service_health "sing-box"
    check_service_health "opera-proxy"
    
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
