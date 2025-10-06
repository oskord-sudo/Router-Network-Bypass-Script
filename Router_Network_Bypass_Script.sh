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

# Функция диагностики
diagnose_installation_issue() {
    local package="$1"
    local url="$2"
    local temp_file="$3"
    
    echo "🔍 Диагностика проблемы установки $package..."
    
    # Проверка доступности URL
    echo "📡 Проверка доступности URL: $url"
    if wget --spider "$url" 2>/dev/null; then
        echo "✅ URL доступен"
    else
        echo "❌ URL недоступен"
        return 1
    fi
    
    # Проверка размера файла
    echo "📦 Проверка загрузки файла..."
    if wget -O "$temp_file" "$url" 2>/dev/null; then
        local file_size
        file_size=$(stat -c%s "$temp_file" 2>/dev/null || echo "0")
        echo "✅ Файл загружен, размер: ${file_size} байт"
        
        if [ "$file_size" -lt 1000 ]; then
            echo "⚠️ Файл слишком маленький, возможно ошибка загрузки"
            return 1
        fi
    else
        echo "❌ Ошибка загрузки файла"
        return 1
    fi
    
    # Проверка зависимостей
    echo "🔍 Проверка зависимостей для $package..."
    if opkg info "$package" 2>/dev/null | grep -q "Depends:"; then
        opkg info "$package" | grep "Depends:" | sed 's/Depends://' | tr ',' '\n' | while read -r dep; do
            dep=$(echo "$dep" | xargs)
            if [ -n "$dep" ] && ! opkg list-installed | grep -q "^$dep "; then
                echo "⚠️ Отсутствует зависимость: $dep"
            fi
        done
    fi
    
    return 0
}

# Улучшенная функция установки пакетов
install_package_safe() {
    local package="$1"
    local filename="$2"
    local url="$3"
    local temp_dir="$4"
    
    local temp_file="${temp_dir}/${filename}"
    
    # Проверка, не установлен ли уже пакет
    if opkg list-installed | grep -q "^${package} "; then
        echo "✅ $package уже установлен"
        return 0
    fi
    
    echo "📦 Установка $package..."
    
    # Создание временной директории
    mkdir -p "$temp_dir"
    
    # Загрузка пакета
    echo "⬇️  Загрузка $package из $url"
    if ! wget --progress=dot -O "$temp_file" "$url" 2>&1 | grep --line-buffered -oE '([0-9]+)%|$'; then
        echo "❌ Ошибка загрузки $package"
        diagnose_installation_issue "$package" "$url" "$temp_file"
        return 1
    fi
    
    # Проверка файла
    if [ ! -f "$temp_file" ] || [ ! -s "$temp_file" ]; then
        echo "❌ Загруженный файл пуст или отсутствует"
        return 1
    fi
    
    echo "🔧 Установка $package из локального файла..."
    
    # Попытка установки с обработкой ошибок
    if opkg install "$temp_file" 2>&1; then
        echo "✅ $package успешно установлен"
        rm -f "$temp_file"
        return 0
    else
        echo "❌ Ошибка установки $package"
        echo "🔄 Попытка установки с принудительным перезаписом..."
        
        # Попробуем установить с опцией --force-overwrite
        if opkg install --force-overwrite "$temp_file" 2>&1; then
            echo "✅ $package установлен с принудительным перезаписом"
            rm -f "$temp_file"
            return 0
        else
            echo "❌ Критическая ошибка установки $package"
            diagnose_installation_issue "$package" "$url" "$temp_file"
            return 1
        fi
    fi
}

install_awg_packages() {
    echo "🔧 Установка AmneziaWG пакетов..."
    
    # Определение архитектуры и версии
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
    
    echo "📊 Информация о системе:"
    echo "   Архитектура: $PKGARCH"
    echo "   Цель: $TARGET"
    echo "   Подцель: $SUBTARGET" 
    echo "   Версия: $VERSION"
    
    local PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    local BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"
    local AWG_DIR="/tmp/amneziawg"
    
    # Создаем временную директорию
    mkdir -p "$AWG_DIR"
    
    # Установка kmod-amneziawg
    echo "🔧 Установка kmod-amneziawg..."
    if ! install_package_safe "kmod-amneziawg" "kmod-amneziawg${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/kmod-amneziawg${PKGPOSTFIX}" "$AWG_DIR"; then
        echo "❌ Критическая ошибка: не удалось установить kmod-amneziawg"
        rm -rf "$AWG_DIR"
        return 1
    fi
    
    # Установка amneziawg-tools
    echo "🔧 Установка amneziawg-tools..."
    if ! install_package_safe "amneziawg-tools" "amneziawg-tools${PKGPOSTFIX}" "${BASE_URL}v${VERSION}/amneziawg-tools${PKGPOSTFIX}" "$AWG_DIR"; then
        echo "❌ Критическая ошибка: не удалось установить amneziawg-tools"
        rm -rf "$AWG_DIR"
        return 1
    fi
    
    # Установка luci-app-amneziawg с расширенной диагностикой
    echo "🔧 Установка luci-app-amneziawg..."
    local LUCI_PACKAGE="luci-app-amneziawg"
    local LUCI_FILENAME="luci-app-amneziawg${PKGPOSTFIX}"
    local LUCI_URL="${BASE_URL}v${VERSION}/${LUCI_FILENAME}"
    
    # Проверка доступности пакета Luci
    echo "🔍 Проверка доступности Luci пакета..."
    if ! wget --spider "$LUCI_URL" 2>/dev/null; then
        echo "⚠️ Пакет luci-app-amneziawg недоступен по стандартному URL"
        echo "🔄 Попробуем альтернативный метод установки..."
        
        # Альтернативная попытка - установка из репозитория если доступно
        if opkg list | grep -q "^luci-app-amneziawg "; then
            echo "📦 Установка luci-app-amneziawg из репозитория..."
            if opkg install luci-app-amneziawg; then
                echo "✅ luci-app-amneziawg установлен из репозитория"
            else
                echo "❌ Не удалось установить luci-app-amneziawg из репозитория"
                echo "💡 Возможные решения:"
                echo "   1. Проверьте доступность репозиториев: opkg update"
                echo "   2. Установите пакет вручную с правильным URL"
                echo "   3. Пропустите установку Luci интерфейса"
            fi
        else
            echo "❌ luci-app-amneziawg не найден в репозиториях"
            echo "💡 Ручная установка:"
            echo "   wget -O /tmp/luci-app-amneziawg.ipk 'ПРАВИЛЬНЫЙ_URL'"
            echo "   opkg install /tmp/luci-app-amneziawg.ipk"
        fi
    else
        # Стандартная установка
        if install_package_safe "$LUCI_PACKAGE" "$LUCI_FILENAME" "$LUCI_URL" "$AWG_DIR"; then
            echo "✅ luci-app-amneziawg установлен успешно"
        else
            echo "⚠️ Не удалось установить luci-app-amneziawg, но продолжаем работу"
            echo "💡 Web-интерфейс будет недоступен, но AmneziaWG будет работать"
        fi
    fi
    
    # Очистка
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
    
    echo "✅ Процесс установки AmneziaWG завершен"
    return 0
}

# Функция для ручной установки Luci
manual_install_luci_amneziawg() {
    echo "🔧 Ручная установка luci-app-amneziawg..."
    
    # Определение параметров системы
    local PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    local TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    local SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    local VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    
    echo "Поиск подходящего пакета для:"
    echo "  Архитектура: $PKGARCH"
    echo "  Цель: $TARGET"
    echo "  Версия: $VERSION"
    
    # Попробуем найти пакет в репозиториях
    echo "🔍 Поиск в репозиториях..."
    opkg update
    if opkg list | grep luci-app-amneziawg; then
        echo "✅ Пакет найден в репозитории, устанавливаем..."
        opkg install luci-app-amneziawg
        return $?
    fi
    
    # Альтернативные URL для попытки
    local alt_urls=(
        "https://github.com/Slava-Shchipunov/awg-openwrt/releases/latest/download/luci-app-amneziawg_${VERSION}_${PKGARCH}.ipk"
        "https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/latest/luci-app-amneziawg_${PKGARCH}.ipk"
    )
    
    for url in "${alt_urls[@]}"; do
        echo "🔄 Попытка: $url"
        if wget -O /tmp/luci_temp.ipk "$url"; then
            if opkg install /tmp/luci_temp.ipk; then
                rm -f /tmp/luci_temp.ipk
                echo "✅ Установка успешна"
                return 0
            fi
        fi
    done
    
    echo "❌ Все попытки установки не удались"
    return 1
}

# Остальные функции остаются без изменений (manage_package, checkPackageAndInstall и т.д.)

# В основной функции main замените вызов install_awg_packages на:
main() {
    # ... остальной код ...
    
    # Установка AmneziaWG
    if ! install_awg_packages; then
        echo "⚠️ Были проблемы с установкой AmneziaWG, но продолжаем..."
        echo "🔄 Попробуем ручную установку Luci интерфейса..."
        manual_install_luci_amneziawg
    fi
    
    # ... остальной код ...
}

# Запуск
main "$@"
