#!/bin/sh

install_awg_packages() {
    # Получение pkgarch с наибольшим приоритетом
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')

    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"
    
    if opkg list-installed | grep -q kmod-amneziawg; then
        echo "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME="kmod-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${KMOD_AMNEZIAWG_FILENAME}"
        wget -O "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error downloading kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
        
        opkg install "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error installing kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
    fi

    if opkg list-installed | grep -q amneziawg-tools; then
        echo "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME="amneziawg-tools${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${AMNEZIAWG_TOOLS_FILENAME}"
        wget -O "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error downloading amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi

        opkg install "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error installing amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi
    fi
    
    if opkg list-installed | grep -q luci-app-amneziawg; then
        echo "luci-app-amneziawg already installed"
    else
        LUCI_APP_AMNEZIAWG_FILENAME="luci-app-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${LUCI_APP_AMNEZIAWG_FILENAME}"
        wget -O "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "luci-app-amneziawg file downloaded successfully"
        else
            echo "Error downloading luci-app-amneziawg. Please, install luci-app-amneziawg manually and run the script again"
            exit 1
        fi

        opkg install "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "luci-app-amneziawg file downloaded successfully"
        else
            echo "Error installing luci-app-amneziawg. Please, install luci-app-amneziawg manually and run the script again"
            exit 1
        fi
    fi

    rm -rf "$AWG_DIR"
}

manage_package() {
    local name="$1"
    local autostart="$2"
    local process="$3"

    # Проверка, установлен ли пакет
    if opkg list-installed | grep -q "^$name"; then
        
        # Проверка, включен ли автозапуск
        if /etc/init.d/$name enabled; then
            if [ "$autostart" = "disable" ]; then
                /etc/init.d/$name disable
            fi
        else
            if [ "$autostart" = "enable" ]; then
                /etc/init.d/$name enable
            fi
        fi

        # Проверка, запущен ли процесс
        if pidof $name > /dev/null; then
            if [ "$process" = "stop" ]; then
                /etc/init.d/$name stop
            fi
        else
            if [ "$process" = "start" ]; then
                /etc/init.d/$name start
            fi
        fi
    fi
}

checkPackageAndInstall() {
    local name="$1"
    local isRequired="$2"
    local alt=""

    if [ "$name" = "https-dns-proxy" ]; then
        alt="luci-app-doh-proxy"
    fi

    if [ -n "$alt" ]; then
        if opkg list-installed | grep -qE "^($name|$alt) "; then
            echo "$name or $alt already installed..."
            return 0
        fi
    else
        if opkg list-installed | grep -q "^$name "; then
            echo "$name already installed..."
            return 0
        fi
    fi

    echo "$name not installed. Installing $name..."
    opkg install "$name"
    res=$?

    if [ "$isRequired" = "1" ]; then
        if [ $res -eq 0 ]; then
            echo "$name installed successfully"
        else
            echo "Error installing $name. Please, install $name manually$( [ -n "$alt" ] && echo " or $alt") and run the script again."
            exit 1
        fi
    fi
}

requestConfWARP1()
{
  #запрос конфигурации WARP
  local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://valokda-amnezia.vercel.app/api/warp' \
    -H 'accept: */*' \
    -H 'accept-language: ru-RU,ru;q=0.9' \
    -H 'referer: https://valokda-amnezia.vercel.app/api/warp')
  echo "$result"
}

requestConfWARP2()
{
  #запрос конфигурации WARP
  local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://warp-gen.vercel.app/generate-config' \
    -H 'accept: */*' \
    -H 'accept-language: ru-RU,ru;q=0.9' \
    -H 'referer: https://warp-gen.vercel.app/generate-config')
  echo "$result"
}

requestConfWARP3()
{
  #запрос конфигурации WARP
  local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warpd' \
    -H 'accept: */*' \
    -H 'accept-language: ru-RU,ru;q=0.9' \
    -H 'referer: https://config-generator-warp.vercel.app/')
  echo "$result"
}

requestConfWARP4()
{
  #запрос конфигурации WARP без параметров
  local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warp6t' \
    -H 'accept: */*' \
    -H 'accept-language: ru-RU,ru;q=0.9' \
    -H 'referer: https://config-generator-warp.vercel.app/')
  echo "$result"
}

requestConfWARP5()
{
  #запрос конфигурации WARP без параметров
  local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://config-generator-warp.vercel.app/warp4t' \
    -H 'accept: */*' \
    -H 'accept-language: ru-RU,ru;q=0.9' \
    -H 'referer: https://config-generator-warp.vercel.app/')
  echo "$result"
}

requestConfWARP6()
{
  #запрос конфигурации WARP
  local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://warp-generator.vercel.app/api/warp' \
    -H 'accept: */*' \
    -H 'accept-language: ru-RU,ru;q=0.6' \
    -H 'content-type: application/json' \
    -H 'referer: https://warp-generator.vercel.app/' \
    --data-raw '{"selectedServices":[],"siteMode":"all","deviceType":"computer"}')
  echo "$result"
}

# Функция для обработки выполнения запроса
check_request() {
    local response="$1"
	local choice="$2"
	
    # Извлекаем код состояния
    response_code="${response: -3}"  # Последние 3 символа - это код состояния
    response_body="${response%???}"    # Все, кроме последних 3 символов - это тело ответа
    #echo $response_body
	#echo $response_code
    # Проверяем код состояния
    if [ "$response_code" -eq 200 ]; then
		case $choice in
		1)
			content=$(echo $response_body | jq -r '.content')    
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
		2)
			content=$(echo $response_body | jq -r '.config')    
            echo "$content"
            ;;
		3)
			content=$(echo $response_body | jq -r '.content')    
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
		4)
			content=$(echo $response_body | jq -r '.content')  
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
		5)
			content=$(echo $response_body | jq -r '.content')
			warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
		6)
			content=$(echo $response_body | jq -r '.content')  
			content=$(echo $content | jq -r '.configBase64')  
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
		*)
			echo "Error"
		esac
	else
		echo "Error"
	fi
}

checkAndAddDomainPermanentName()
{
  nameRule="option name '$1'"
  str=$(grep -i "$nameRule" /etc/config/dhcp)
  if [ -z "$str" ] 
  then 

    uci add dhcp domain
    uci set dhcp.@domain[-1].name="$1"
    uci set dhcp.@domain[-1].ip="$2"
    uci commit dhcp
  fi
}

byPassGeoBlockComssDNS()
{
	echo "Configure dhcp..."

	uci set dhcp.cfg01411c.strictorder='1'
	uci set dhcp.cfg01411c.filter_aaaa='1'
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

	echo "Add unblock ChatGPT..."

	checkAndAddDomainPermanentName "chatgpt.com" "83.220.169.155"
	checkAndAddDomainPermanentName "openai.com" "83.220.169.155"
	checkAndAddDomainPermanentName "webrtc.chatgpt.com" "83.220.169.155"
	checkAndAddDomainPermanentName "ios.chat.openai.com" "83.220.169.155"
	checkAndAddDomainPermanentName "searchgpt.com" "83.220.169.155"

	service dnsmasq restart
	service odhcpd restart
}

deleteByPassGeoBlockComssDNS()
{
	uci del dhcp.cfg01411c.server
	uci add_list dhcp.cfg01411c.server='127.0.0.1#5359'
	while uci del dhcp.@domain[-1] ; do : ;  done;
	uci commit dhcp
	service dnsmasq restart
	service odhcpd restart
	service doh-proxy restart
}

install_youtubeunblock_packages() {
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    BASE_URL="https://github.com/Waujito/youtubeUnblock/releases/download/v1.1.0/"
  	PACK_NAME="youtubeUnblock"

    AWG_DIR="/tmp/$PACK_NAME"
    mkdir -p "$AWG_DIR"
    
    if opkg list-installed | grep -q $PACK_NAME; then
        echo "$PACK_NAME already installed"
    else
	    # Список пакетов, которые нужно проверить и установить/обновить
		PACKAGES="kmod-nfnetlink-queue kmod-nft-queue kmod-nf-conntrack"

		for pkg in $PACKAGES; do
			# Проверяем, установлен ли пакет
			if opkg list-installed | grep -q "^$pkg "; then
				echo "$pkg already installed"
			else
				echo "$pkg not installed. Instal..."
				opkg install $pkg
				if [ $? -eq 0 ]; then
					echo "$pkg file installing successfully"
				else
					echo "Error installing $pkg Please, install $pkg manually and run the script again"
					exit 1
				fi
			fi
		done

        YOUTUBEUNBLOCK_FILENAME="youtubeUnblock-1.1.0-2-2d579d5-${PKGARCH}-openwrt-23.05.ipk"
        DOWNLOAD_URL="${BASE_URL}${YOUTUBEUNBLOCK_FILENAME}"
		echo $DOWNLOAD_URL
        wget -O "$AWG_DIR/$YOUTUBEUNBLOCK_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "$PACK_NAME file downloaded successfully"
        else
            echo "Error downloading $PACK_NAME. Please, install $PACK_NAME manually and run the script again"
            exit 1
        fi
        
        opkg install "$AWG_DIR/$YOUTUBEUNBLOCK_FILENAME"

        if [ $? -eq 0 ]; then
            echo "$PACK_NAME file installing successfully"
        else
            echo "Error installing $PACK_NAME. Please, install $PACK_NAME manually and run the script again"
            exit 1
        fi
    fi
	
	PACK_NAME="luci-app-youtubeUnblock"
	if opkg list-installed | grep -q $PACK_NAME; then
        echo "$PACK_NAME already installed"
    else
		PACK_NAME="luci-app-youtubeUnblock"
		YOUTUBEUNBLOCK_FILENAME="luci-app-youtubeUnblock-1.1.0-1-473af29.ipk"
        DOWNLOAD_URL="${BASE_URL}${YOUTUBEUNBLOCK_FILENAME}"
		echo $DOWNLOAD_URL
        wget -O "$AWG_DIR/$YOUTUBEUNBLOCK_FILENAME" "$DOWNLOAD_URL"
		
        if [ $? -eq 0 ]; then
            echo "$PACK_NAME file downloaded successfully"
        else
            echo "Error downloading $PACK_NAME. Please, install $PACK_NAME manually and run the script again"
            exit 1
        fi
        
        opkg install "$AWG_DIR/$YOUTUBEUNBLOCK_FILENAME"

        if [ $? -eq 0 ]; then
            echo "$PACK_NAME file installing successfully"
        else
            echo "Error installing $PACK_NAME. Please, install $PACK_NAME manually and run the script again"
            exit 1
        fi
	fi

    rm -rf "$AWG_DIR"
}

if [ "$1" = "y" ] || [ "$1" = "Y" ]
then
	is_manual_input_parameters="y"
else
	is_manual_input_parameters="n"
fi
if [ "$2" = "y" ] || [ "$2" = "Y" ] || [ "$2" = "" ]
then
	is_reconfig_podkop="y"
else
	is_reconfig_podkop="n"
fi

# Удалена проверка на конкретную модель роутера
printf "\033[32;1mStarting configuration script for OpenWRT router...\033[0m\n"

echo "Update list packages..."
opkg update

checkPackageAndInstall "coreutils-base64" "1"
checkPackageAndInstall "jq" "1"
checkPackageAndInstall "curl" "1"
checkPackageAndInstall "unzip" "1"
checkPackageAndInstall "opera-proxy" "1"
checkPackageAndInstall "zapret" "1"

# Проверка версии sing-box без привязки к конкретному роутеру
findVersion="1.12.0"
INSTALLED_SINGBOX_VERSION=$(opkg list-installed | grep "^sing-box" | cut -d ' ' -f 3)
if [ -n "$INSTALLED_SINGBOX_VERSION" ] && [ "$(printf '%s\n%s\n' "$findVersion" "$INSTALLED_SINGBOX_VERSION" | sort -V | tail -n1)" = "$INSTALLED_SINGBOX_VERSION" ]; then
	printf "\033[32;1mInstalled sing-box version $INSTALLED_SINGBOX_VERSION is compatible...\033[0m\n"
else
	printf "\033[32;1mInstalled sing-box version is outdated or not installed. Installing/updating sing-box...\033[0m\n"
	manage_package "podkop" "enable" "stop"
	opkg remove --force-removal-of-dependent-packages "sing-box"
	checkPackageAndInstall "sing-box" "1"
fi

# Обновление пакетов AmneziaWG
opkg upgrade amneziawg-tools
opkg upgrade kmod-amneziawg
opkg upgrade luci-app-amneziawg

opkg upgrade zapret
opkg upgrade luci-app-zapret
manage_package "zapret" "enable" "start"

#проверяем установлени ли пакет dnsmasq-full
if opkg list-installed | grep -q dnsmasq-full; then
	echo "dnsmasq-full already installed..."
else
	echo "Installed dnsmasq-full..."
	cd /tmp/ && opkg download dnsmasq-full
	opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/

	[ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
fi

printf "Setting confdir dnsmasq\n"
uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
uci commit dhcp

DIR="/etc/config"
DIR_BACKUP="/root/backup5"
config_files="network
firewall
doh-proxy
zapret
dhcp
dns-failsafe-proxy"
URL="https://raw.githubusercontent.com/routerich/RouterichAX3000_configs/refs/heads/new_awg_podkop"

checkPackageAndInstall "luci-app-dns-failsafe-proxy" "1"
checkPackageAndInstall "luci-i18n-stubby-ru" "1"
checkPackageAndInstall "luci-i18n-doh-proxy-ru" "1"

if [ ! -d "$DIR_BACKUP" ]
then
    echo "Backup files..."
    mkdir -p $DIR_BACKUP
    for file in $config_files
    do
        cp -f "$DIR/$file" "$DIR_BACKUP/$file"  
    done
	echo "Replace configs..."

	for file in $config_files
	do
		if [ "$file" == "doh-proxy" ] || [ "$file" == "dns-failsafe-proxy" ]
		then 
		  wget -O "$DIR/$file" "$URL/config_files/$file" 
		fi
	done
fi

echo "Configure dhcp..."

uci set dhcp.cfg01411c.strictorder='1'
uci set dhcp.cfg01411c.filter_aaaa='1'
uci commit dhcp

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

echo "Setting sing-box..."
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

nameRule="option name 'Block_UDP_443'"
str=$(grep -i "$nameRule" /etc/config/firewall)
if [ -z "$str" ] 
then
  echo "Add block QUIC..."

  uci add firewall rule # =cfg2492bd
  uci set firewall.@rule[-1].name='Block_UDP_80'
  uci add_list firewall.@rule[-1].proto='udp'
  uci set firewall.@rule[-1].src='lan'
  uci set firewall.@rule[-1].dest='wan'
  uci set firewall.@rule[-1].dest_port='80'
  uci set firewall.@rule[-1].target='REJECT'
  uci add firewall rule # =cfg2592bd
  uci set firewall.@rule[-1].name='Block_UDP_443'
  uci add_list firewall.@rule[-1].proto='udp'
  uci set firewall.@rule[-1].src='lan'
  uci set firewall.@rule[-1].dest='wan'
  uci set firewall.@rule[-1].dest_port='443'
  uci set firewall.@rule[-1].target='REJECT'
  uci commit firewall
fi

printf "\033[32;1mCheck work zapret.\033[0m\n"
#install_youtubeunblock_packages
opkg upgrade zapret
opkg upgrade luci-app-zapret
manage_package "zapret" "enable" "start"
wget -O "/etc/config/zapret" "$URL/config_files/zapret"
wget -O "/opt/zapret/ipset/zapret-hosts-user.txt" "$URL/config_files/zapret-hosts-user.txt"
wget -O "/opt/zapret/init.d/openwrt/custom.d/50-stun4all" "$URL/config_files/50-stun4all"
wget -O "/opt/zapret/init.d/openwrt/custom.d/50-wg4all" "$URL/config_files/50-wg4all"
chmod +x "/opt/zapret/init.d/openwrt/custom.d/50-stun4all"
chmod +x "/opt/zapret/init.d/openwrt/custom.d/50-wg4all"

manage_package "podkop" "enable" "stop"
service zapret restart

isWorkZapret=0

curl -f -o /dev/null -k --connect-to ::google.com -L -H "Host: mirror.gcr.io" --max-time 120 https://test.googlevideo.com/v2/cimg/android/blobs/sha256:2ab09b027e7f3a0c2e8bb1944ac46de38cebab7145f0bd6effebfe5492c818b6

# Проверяем код выхода
if [ $? -eq 0 ]; then
	printf "\033[32;1mzapret well work...\033[0m\n"
	cronTask="0 4 * * * service zapret restart"
	str=$(grep -i "0 4 \* \* \* service zapret restart" /etc/crontabs/root)
	if [ -z "$str" ] 
	then
		echo "Add cron task auto reboot service zapret..."
		echo "$cronTask" >> /etc/crontabs/root
	fi
	str=$(grep -i "0 4 \* \* \* service youtubeUnblock restart" /etc/crontabs/root)
	if [ ! -z "$str" ]
	then
		grep -v "0 4 \* \* \* service youtubeUnblock restart" /etc/crontabs/root > /etc/crontabs/temp
		cp -f "/etc/crontabs/temp" "/etc/crontabs/root"
		rm -f "/etc/crontabs/temp"
	fi
	isWorkZapret=1
else
	manage_package "zapret" "disable" "stop"
	printf "\033[32;1mzapret not work...\033[0m\n"
	isWorkZapret=0
	str=$(grep -i "0 4 \* \* \* service youtubeUnblock restart" /etc/crontabs/root)
	if [ ! -z "$str" ]
	then
		grep -v "0 4 \* \* \* service youtubeUnblock restart" /etc/crontabs/root > /etc/crontabs/temp
		cp -f "/etc/crontabs/temp" "/etc/crontabs/root"
		rm -f "/etc/crontabs/temp"
	fi
	str=$(grep -i "0 4 \* \* \* service zapret restart" /etc/crontabs/root)
	if [ ! -z "$str" ]
	then
		grep -v "0 4 \* \* \* service zapret restart" /etc/crontabs/root > /etc/crontabs/temp
		cp -f "/etc/crontabs/temp" "/etc/crontabs/root"
		rm -f "/etc/crontabs/temp"
	fi
fi

isWorkOperaProxy=0
printf "\033[32;1mCheck opera proxy...\033[0m\n"
service sing-box restart
sing-box tools fetch ifconfig.co -D /etc/sing-box/
if [ $? -eq 0 ]; then
	printf "\033[32;1mOpera proxy well work...\033[0m\n"
	isWorkOperaProxy=1
else
	printf "\033[32;1mOpera proxy not work...\033[0m\n"
	isWorkOperaProxy=0
fi

countRepeatAWGGen=2
currIter=0
isExit=0
while [ $currIter -lt $countRepeatAW
