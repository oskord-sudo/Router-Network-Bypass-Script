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

# Безопасное удаление доменов
safe_remove_domains() {
    echo "🧹 Очистка доменных записей..."
    local keep_domains=("chatgpt.com" "openai.com")  # Домены которые нужно сохранить
    
    # Создаем временный файл с нужными доменами
    uci show dhcp | grep domain | while read -r line; do
        local domain_name=$(echo "$line" | grep -o "domain\\[[0-9]*\\].name='[^']*'" | cut -d"'" -f2)
        if [ -n "$domain_name" ]; then
            if printf '%s\n' "${keep_domains[@]}" | grep -q "^$domain_name$"; then
                echo "Сохраняем домен: $domain_name"
            else
                local section=$(echo "$line" | cut -d. -f1-2)
                uci delete "$section"
            fi
        fi
    done
    
    uci commit dhcp
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

# Основная логика с улучшенной обработкой ошибок
main() {
    local is_manual_input_parameters="${1:-n}"
    local is_reconfig_podkop="${2:-y}"
    
    echo "🚀 Запуск скрипта конфигурации OpenWRT роутера..."
    
    # Обновление списка пакетов
    if ! opkg update; then
        echo "❌ Не удалось обновить список пакетов"
        exit 1
    fi
    
    # Установка обязательных пакетов
    local required_packages="coreutils-base64 jq curl unzip opera-proxy zapret"
    for pkg in $required_packages; do
        if ! opkg list-installed | grep -q "^${pkg} "; then
            echo "📦 Установка $pkg..."
            if ! opkg install "$pkg"; then
                echo "❌ Критическая ошибка: не удалось установить $pkg"
                exit 1
            fi
        fi
    done
    
    # Дальнейшая логика скрипта...
    install_awg_packages || echo "⚠️ Предупреждение: проблемы с AmneziaWG"
    
    echo "✅ Скрипт выполнен успешно"
}

# Вызов основной функции с параметрами
main "$@"
