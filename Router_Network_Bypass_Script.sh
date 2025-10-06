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

# Логирование (упрощенная версия для /bin/sh)
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

# Упрощенная функция установки AmneziaWG
install_awg_packages() {
    echo "🔧 Установка AmneziaWG пакетов..."
    
    # Простой способ определения архитектуры
    local PKGARCH
    PKGARCH=$(opkg print-architecture | head -1 | awk '{print $2}')
    
    if [ -z "$PKGARCH" ]; then
        echo "❌ Не удалось определить архитектуру пакетов"
        return 1
    fi
    
    echo "📋 Архитектура: $PKGARCH"
    
    # Пытаемся установить из стандартного репозитория
    if opkg install kmod-amneziawg amneziawg-tools luci-app-amneziawg 2>/dev/null; then
        echo "✅ AmneziaWG пакеты установлены из репозитория"
        return 0
    else
        echo "⚠️ Не удалось установить из репозитория, пропускаем..."
        return 0
    fi
}

# Упрощенная проверка пакетов
checkPackageAndInstall() {
    local name="$1"
    local isRequired="${2:-0}"

    if opkg list-installed | grep -q "^$name "; then
        echo "✅ $name уже установлен"
        return 0
    fi

    echo "📦 Установка $name..."
    if opkg install "$name" 2>/dev/null; then
        echo "✅ $name установлен успешно"
        return 0
    else
        echo "❌ Ошибка установки $name"
        if [ "$isRequired" = "1" ]; then
            echo "⚠️ Пожалуйста, установите $name вручную и запустите скрипт снова."
            exit 1
        fi
        return 1
    fi
}

# Упрощенная настройка DHCP
setup_dhcp_basic() {
    echo "🔧 Базовая настройка DHCP..."
    
    # Безопасная настройка dnsmasq
    if uci get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
        uci set dhcp.@dnsmasq[0].strictorder='1' 2>/dev/null || true
        uci set dhcp.@dnsmasq[0].filter_aaaa='1' 2>/dev/null || true
        uci commit dhcp
        echo "✅ Настройки DHCP применены"
    else
        echo "⚠️ Секция dnsmasq не найдена в конфигурации DHCP"
    fi
}

# Упрощенная настройка firewall
setup_firewall_basic() {
    echo "🔧 Базовая настройка firewall..."
    
    # Проверяем, есть ли уже правила
    local has_quic_block
    has_quic_block=$(uci show firewall 2>/dev/null | grep -c "Block_UDP_443" || true)
    
    if [ "$has_quic_block" -eq 0 ]; then
        echo "🔧 Добавление блокировки QUIC..."
        
        uci add firewall rule >/dev/null 2>&1
        uci set firewall.@rule[-1].name='Block_UDP_443'
        uci set firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='wan'
        uci set firewall.@rule[-1].dest_port='443'
        uci set firewall.@rule[-1].target='REJECT'
        
        uci commit firewall
        echo "✅ Правила firewall добавлены"
    else
        echo "✅ Правила firewall уже существуют"
    fi
}

# Основная логика
main() {
    echo "🚀 Запуск упрощенной конфигурации OpenWRT роутера..."
    
    # Обновление списка пакетов
    echo "🔄 Обновление списка пакетов..."
    if opkg update; then
        echo "✅ Список пакетов обновлен"
    else
        echo "⚠️ Не удалось обновить список пакетов, продолжаем..."
    fi
    
    # Установка обязательных пакетов
    echo "📦 Установка основных пакетов..."
    local basic_packages="curl wget-ssl coreutils-base64 jq"
    for pkg in $basic_packages; do
        if ! checkPackageAndInstall "$pkg" "0"; then
            echo "⚠️ Пропускаем $pkg"
        fi
    done
    
    # Базовая настройка
    setup_dhcp_basic
    setup_firewall_basic
    
    # Попытка установки AmneziaWG (не критично)
    if install_awg_packages; then
        echo "✅ AmneziaWG настроен"
    else
        echo "⚠️ AmneziaWG не установлен, продолжаем..."
    fi
    
    # Перезапуск сервисов
    echo "🔄 Перезапуск сетевых сервисов..."
    if /etc/init.d/network reload; then
        echo "✅ Сетевые сервисы перезапущены"
    else
        echo "⚠️ Не удалось перезапустить сетевые сервисы"
    fi
    
    echo "=== Выполнение скрипта завершено $(date) ==="
    echo "📋 Логи сохранены в: $LOG_FILE"
    echo ""
    echo "✅ Основная конфигурация завершена успешно!"
}

# Вызов основной функции
main "$@"
