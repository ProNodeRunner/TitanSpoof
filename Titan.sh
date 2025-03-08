#!/bin/bash
################################################################################
# TITAN BLOCKCHAIN NODE FINAL INSTALLATION SCRIPT
# (ProxyChains + Socks5 + Titan) using:
# - "docker pull nezha123/titan-edge" + docker cp titanextract:/usr/local/bin/titan-edge ...
# - Then build local image “mytitan/proxy-titan-edge”
################################################################################

CONFIG_FILE="/etc/titan_nodes.conf"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"

ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

declare -A USED_KEYS=()
declare -A USED_PORTS=()
declare -A USED_PROXIES=()

###############################################################################
# (A) Логотип и меню
###############################################################################
show_logo() {
    local raw
    raw=$(curl -sSf "$LOGO_URL" 2>/dev/null | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')
    if [[ -z "$raw" ]]; then
        echo "=== TITAN NODE MANAGER v22 ==="
    else
        echo "$raw"
    fi
}

show_menu() {
    clear
    tput setaf 3
    show_logo
    echo -e "1) Установить компоненты\n2) Создать/запустить ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    tput sgr0
}

###############################################################################
# (1) Установка компонентов (Исправленный)
###############################################################################
install_dependencies() {
    echo -e "${ORANGE}[1/7] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a  

    sudo systemctl stop unattended-upgrades
    sudo systemctl disable unattended-upgrades || true

    sudo apt-get update -yq && sudo apt-get upgrade -yq

    echo -e "${ORANGE}[2/7] Установка пакетов...${NC}"
    sudo apt-get install -yq \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        jq screen cgroup-tools net-tools ccze netcat iptables-persistent bc \
        ufw git build-essential proxychains4 needrestart

    sudo sed -i 's/#\$nrconf{restart} = "i"/\$nrconf{restart} = "a"/' /etc/needrestart/needrestart.conf

    echo -e "${ORANGE}[2.5/7] Настройка proxychains4...${NC}"
    echo -e "${ORANGE}[*] Введите SOCKS5-прокси для установки (формат: host:port:user:pass):${NC}"

    while true; do
        read -p "Прокси для установки: " PROXY_INPUT
        IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_INPUT"

        if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" || -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
            echo -e "${RED}[!] Некорректный формат! Пример: 1.2.3.4:1080:user:pass${NC}"
            continue
        fi

        # Проверка прокси
        if curl --proxy "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" -s --connect-timeout 5 https://api.ipify.org >/dev/null; then
            echo -e "${GREEN}[✓] Прокси успешно подключен!${NC}"
            break
        else
            echo -e "${RED}[✗] Прокси не работает! Попробуйте другой.${NC}"
        fi
    done

    cat > /etc/proxychains4.conf <<EOL
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS
EOL

    echo -e "${GREEN}[✓] Proxychains4 настроен!${NC}"
}

###############################################################################
# (3) Проверка proxychains перед скачиванием
###############################################################################
test_proxychains4() {
    echo -e "${ORANGE}[*] Проверяем работу proxychains4 перед скачиванием образа...${NC}"
    
    if ! proxychains4 curl -s --connect-timeout 5 https://api.ipify.org; then
        echo -e "${RED}[✗] Ошибка: proxychains4 не работает!${NC}"
        exit 1
    fi

    echo -e "${GREEN}[✓] Proxychains4 работает!${NC}"
}
###############################################################################
# (4) Скачивание Docker-образа через proxychains4
###############################################################################
pull_titan_image() {
    echo -e "${ORANGE}[4/7] Скачивание Docker-образа nezha123/titan-edge...${NC}"
    
    # Проверяем, работает ли proxychains4
    if proxychains4 curl -s --connect-timeout 5 https://api.ipify.org >/dev/null; then
        echo -e "${GREEN}[✓] Proxychains4 работает! Загружаем через него...${NC}"
        if proxychains4 docker pull nezha123/titan-edge:latest; then
            echo -e "${GREEN}[✓] Образ успешно загружен через proxychains4!${NC}"
            return
        fi
    fi

    echo -e "${RED}[✗] Ошибка загрузки через proxychains4. Пробуем напрямую...${NC}"

    if docker pull nezha123/titan-edge:latest; then
        echo -e "${GREEN}[✓] Образ успешно загружен напрямую!${NC}"
    else
        echo -e "${RED}[✗] Полная ошибка: не удалось загрузить Docker-образ!${NC}"
        exit 1
    fi
}


###############################################################################
# (4) Извлечение бинарников Titan
###############################################################################
extract_titan_edge() {
    docker rm -f temp_titan 2>/dev/null || true

    CONTAINER_ID=$(docker create nezha123/titan-edge:latest)
    echo -e "${GREEN}Создан временный контейнер с ID: $CONTAINER_ID${NC}"

    docker start "$CONTAINER_ID"
    sleep 5  

    echo -e "${ORANGE}[*] Проверяем IP внутри контейнера...${NC}"
    docker exec "$CONTAINER_ID" curl -s ifconfig.me

    docker cp "$CONTAINER_ID":/usr/lib/libgoworkerd.so ./libgoworkerd.so || {
        echo -e "${RED}[✗] Ошибка копирования libgoworkerd.so!${NC}"
        exit 1
    }

    docker cp "$CONTAINER_ID":/usr/local/bin/titan-edge ./titan-edge || {
        echo -e "${RED}Ошибка: titan-edge отсутствует!${NC}"
        exit 1
    }

    chmod +x ./titan-edge
    docker rm -f "$CONTAINER_ID"
    echo -e "${GREEN}[✓] Titan Edge успешно извлечен!${NC}"
    
}###############################################################################
# (5) Генерация IP, портов, CPU/RAM/SSD
###############################################################################
generate_country_ip() {
    local first_oct=164
    local second_oct=138
    local third_oct=10
    local forth_oct=$(shuf -i 2-254 -n1)
    echo "${first_oct}.${second_oct}.${third_oct}.${forth_oct}"
}

generate_random_port() {
    while true; do
        local p=$(shuf -i 30000-40000 -n1)
        if ! ss -uln | grep -q ":$p "; then
            echo "$p"
            return
        fi
    done
}

generate_spoofer_profile() {
    local cpu_options=(12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46)
    local ram_options=(64 96 128 160 192 224 256 320 384 448 512)
    local ssd_options=(512 1024 1536 2048 2560 3072 3584 4096)

    local cpu_val=${cpu_options[$RANDOM % ${#cpu_options[@]}]}
    local ram_val=${ram_options[$RANDOM % ${#ram_options[@]}]}
    local ssd_val=${ssd_options[$RANDOM % ${#ssd_options[@]}]}

    # Гарантируем, что CPU/RAM соответствуют друг другу
    while true; do
        ram_val=${ram_options[$RANDOM % ${#ram_options[@]}]}
        ssd_val=${ssd_options[$RANDOM % ${#ssd_options[@]}]}

        # CPU до 16 ядер → минимум 64GB RAM
        # CPU 36+ ядер → минимум 128GB RAM
        # CPU 44+ ядер → минимум 192GB RAM
        if ((cpu_val <= 16 && ram_val >= 64)) || ((cpu_val >= 36 && ram_val >= 128)) || ((cpu_val >= 44 && ram_val >= 192)); then
            break
        fi
    done

    echo "$cpu_val,$ram_val,$ssd_val"
}

###############################################################################
# (6) Создание/запуск ноды
###############################################################################
setup_nodes() {
    # Проверяем, установлен ли Docker
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}[✗] Ошибка: Docker не установлен!${NC}"
        echo -e "${ORANGE}[*] Установите компоненты (1) перед запуском нод.${NC}"
        sleep 3
        return
    fi

    echo -e "${ORANGE}[*] Укажите количество нод, которые хотите создать:${NC}"
    while true; do
        read -p "Сколько нод создать? (1-100): " NODE_COUNT
        [[ "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}[!] Введите число больше 0!${NC}"
    done

    for ((i=1; i<=NODE_COUNT; i++)); do
        echo -e "${ORANGE}[*] Введите SOCKS5-прокси для ноды $i (формат: host:port:user:pass):${NC}"
        while true; do
            read -p "Прокси для ноды $i: " PROXY_INPUT
            IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_INPUT"
            if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" || -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
                echo -e "${RED}[!] Некорректный формат! Пример: 1.2.3.4:1080:user:pass${NC}"
                continue
            fi
            break
        done

        create_node "$i" "$PROXY_HOST" "$PROXY_PORT" "$PROXY_USER" "$PROXY_PASS"
    done
}

###############################################################################
# (7) Запуск контейнера с учетом спуфинга
###############################################################################
create_node() {
    local idx="$1"
    local proxy_host="$2"
    local proxy_port="$3"
    local proxy_user="$4"
    local proxy_pass="$5"

    # Генерация случайных параметров с учетом реалистичности
    local host_port=$((30000 + idx))
    local cpu_options=(12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46)
    local ram_options=(32 64 96 128 160 192 224 256 320 384 448 512)
    local ssd_options=(512 1024 1536 2048 2560 3072 3584 4096)

    # Выбираем случайные значения с фильтрацией
    local cpu_val=${cpu_options[$RANDOM % ${#cpu_options[@]}]}
    local ram_val=32
    local ssd_val=512

    while true; do
        ram_val=${ram_options[$RANDOM % ${#ram_options[@]}]}
        ssd_val=${ssd_options[$RANDOM % ${#ssd_options[@]}]}

        # ✅ Проверка: разумное соотношение CPU/RAM
        if ((cpu_val <= 16 && ram_val >= 64)) || ((cpu_val >= 36 && ram_val >= 128)) || ((cpu_val >= 44 && ram_val >= 192)); then
            break
        fi
    done

    echo -e "${ORANGE}[*] Запуск контейнера titan_node_$idx (порт $host_port, CPU=${cpu_val}, RAM=${ram_val}GB, SSD=${ssd_val}GB)...${NC}"

    CONTAINER_ID=$(docker run -d \
        --name "titan_node_$idx" \
        --restart unless-stopped \
        --cpu-quota=$((cpu_val * 100000)) \
        --memory="${ram_val}g" \
        -p "${host_port}:1234/udp" \
        -v /etc/proxychains4.conf:/etc/proxychains4.conf:ro \
        -e ALL_PROXY="socks5://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}" \
        mytitan/proxy-titan-edge-custom)

    if [ -z "$CONTAINER_ID" ]; then
        echo -e "${RED}[✗] Ошибка запуска контейнера titan_node_$idx${NC}"
        return 1
    fi

    # ✅ Копируем proxychains4.conf внутрь контейнера (если маунт не сработал)
    docker cp /etc/proxychains4.conf "$CONTAINER_ID":/etc/proxychains4.conf

    # ✅ Проверяем, видит ли контейнер внешний IP через прокси
    echo -e "${ORANGE}[*] Проверяем IP внутри контейнера через proxychains4...${NC}"
    docker exec "$CONTAINER_ID" proxychains4 curl -s ifconfig.me

    echo -e "${GREEN}[✓] Контейнер titan_node_$idx запущен! ID: $CONTAINER_ID${NC}"
}

###############################################################################
# (8) Проверка статуса
###############################################################################
check_status() {
    clear
    printf "${ORANGE}%-15s | %-5s | %-15s | %-25s | %s${NC}\n" \
           "Контейнер" "Port" "IP" "Спуф (CPU/RAM/SSD)" "Status"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет $CONFIG_FILE, ноды не создавались?${NC}"
        read -p $'\nНажмите любую клавишу...' -n1 -s
        return
    fi

    while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
        local cname="titan_node_$idx"
        if ! docker ps | grep -q "$cname"; then
            printf "%-15s | %-5s | %-15s | %-25s | %b\n" \
                   "$cname" "$hport" "$fip" "-" "${RED}🔴 DEAD${NC}"
            continue
        fi
        local info
        info=$(docker exec "$cname" proxychains4 /usr/bin/titan-edge info 2>/dev/null || true)
        local st
        if echo "$info" | grep -iq "Edge registered successfully"; then
            st="${GREEN}🟢 ALIVE${NC}"
        else
            st="${RED}🔴 NOT_READY${NC}"
        fi
        IFS=',' read -r cpuv ramv ssdv <<< "$hwdata"
        local spoofer="${cpuv} CPU / ${ramv}GB / ${ssdv}GB"
        printf "%-15s | %-5s | %-15s | %-25s | %b\n" \
               "$cname" "$hport" "$fip" "$spoofer" "$st"
    done < "$CONFIG_FILE"

    echo -e "\n${ORANGE}RESOURCES (docker stats):${NC}"
    docker stats --no-stream --format "{{.Name}}: {{.CPUPerc}} / {{.MemUsage}}" | grep titan_node || true

    read -p $'\nНажмите любую клавишу...' -n1 -s
}

###############################################################################
# (9) Логи (последние 5 строк) всех нод
###############################################################################
show_logs() {
    clear
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет $CONFIG_FILE, ноды не создавались?${NC}"
        read -p $'\nНажмите любую клавишу...' -n1 -s
        return
    fi

    while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
        local cname="titan_node_$idx"
        echo -e "\n=== Логи $cname (tail=5) ==="
        if docker ps | grep -q "$cname"; then
            docker logs --tail 5 "$cname" 2>&1
        else
            echo "(Контейнер не запущен)"
        fi
    done < "$CONFIG_FILE"

    read -p $'\nНажмите любую клавишу...' -n1 -s
}

###############################################################################
# (10) Перезапуск, Очистка, автозапуск
###############################################################################
restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
            local proxy_host proxy_port proxy_user proxy_pass
            IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$pxy"
            create_node "$idx" "$code" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
        done < "$CONFIG_FILE"
        echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    else
        echo -e "${RED}Нет конфигурации!${NC}"
    fi
    sleep 2
}

cleanup() {
    echo -e "${ORANGE}\n[!] ПОЛНАЯ ОЧИСТКА [!]${NC}"

    echo -e "${ORANGE}[1/6] Удаление контейнеров...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f

    echo -e "${ORANGE}[2/6] Удаление томов...${NC}"
    docker volume ls -q --filter "name=titan_data" | xargs -r docker volume rm

    echo -e "${ORANGE}[3/6] Полное удаление данных Titan...${NC}"
    sudo rm -rf /root/.titanedge
    sudo rm -rf /var/lib/docker/volumes/titan_data_*

    echo -e "${ORANGE}[4/6] Удаление Docker...${NC}"
    sudo apt-get purge -yq docker-ce docker-ce-cli containerd.io
    sudo apt-get autoremove -yq
    sudo rm -rf /var/lib/docker /etc/docker

    echo -e "${ORANGE}[5/6] Очистка screen...${NC}"
    screen -ls | grep "node_" | awk -F. '{print $1}' | xargs -r -I{} screen -X -S {} quit

    echo -e "${ORANGE}[6/6] Восстановление сети...${NC}"
    while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
        sudo ip addr del "$fip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done < "$CONFIG_FILE"
    sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo netfilter-persistent save >/dev/null 2>&1

    echo -e "${ORANGE}[+] Удаляем $CONFIG_FILE ...${NC}"
    sudo rm -f "$CONFIG_FILE"

    echo -e "\n${GREEN}[✓] Все следы удалены! Перезагрузите сервер.${NC}"
    sleep 3
}

if [ ! -f /etc/systemd/system/titan-node.service ]; then
    sudo tee /etc/systemd/system/titan-node.service >/dev/null <<EOF
[Unit]
Description=Titan Node Service
After=network.target docker.service

[Service]
ExecStart=/bin/bash -c 'curl -sSL https://raw.githubusercontent.com/ProNodeRunner/TitanSpoof/main/Titan.sh | bash -s -- --auto-start'
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl enable titan-node.service >/dev/null 2>&1
fi

auto_start_nodes() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет $CONFIG_FILE, автозапуск невозможен!${NC}"
        exit 1
    fi
    while IFS='|' read -r idx code mac hport fip stamp pxy hw; do
        local proxy_host proxy_port proxy_user proxy_pass
        IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$pxy"
        create_node "$idx" "$code" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
    done < "$CONFIG_FILE"
}

###############################################################################
# MAIN
###############################################################################
case "$1" in
    --auto-start)
        auto_start_nodes
        ;;
    *)
        while true; do
            show_menu
            read -p "Выбор: " CH
            case "$CH" in
                1) install_dependencies ;;
                2)
                    if ! command -v docker &>/dev/null || [ ! -f "/usr/bin/jq" ]; then
                        echo -e "\n${RED}Сначала установите компоненты (1)!${NC}"
                        sleep 2
                        continue
                    fi
                    setup_nodes
                    ;;
                3) check_status ;;
                4) show_logs ;;
                5) restart_nodes ;;
                6) cleanup ;;
                7) exit 0 ;;
                *)
                    echo -e "${RED}Неверный выбор!${NC}"
                    sleep 1
                ;;
            esac
        done
        ;;
esac
