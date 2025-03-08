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
# (1) Установка компонентов
###############################################################################
install_dependencies() {
    echo -e "${ORANGE}[1/7] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a  

    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections"
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections"
    echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections  

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
    sudo bash -c 'cat > /etc/proxychains4.conf <<EOL
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 \$PROXY_HOST \$PROXY_PORT \$PROXY_USER \$PROXY_PASS
EOL'
    echo -e "${GREEN}[✓] Proxychains4 настроен!${NC}"

    echo -e "${ORANGE}[3/7] Настройка брандмауэра...${NC}"
    sudo ufw allow 30000:40000/udp || true
    sudo ufw reload || true

    echo -e "${ORANGE}[4/7] Установка Docker...${NC}"
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update -yq
    sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

    echo -e "${ORANGE}[5/7] Извлечение libgoworkerd.so и titan-edge...${NC}"
    
    docker rm -f temp_titan 2>/dev/null || true

    CONTAINER_ID=$(docker create nezha123/titan-edge:latest)
    echo -e "${GREEN}Создан временный контейнер с ID: $CONTAINER_ID${NC}"

    docker start "$CONTAINER_ID"
    sleep 5  

    docker cp "$CONTAINER_ID":/usr/lib/libgoworkerd.so ./libgoworkerd.so || {
        echo -e "${RED}[✗] Ошибка копирования libgoworkerd.so!${NC}"
        docker logs "$CONTAINER_ID"
        docker rm -f "$CONTAINER_ID"
        exit 1
    }

    EDGE_PATH=$(docker exec "$CONTAINER_ID" find / -type f -name "titan-edge" 2>/dev/null | head -n 1)

    if [ -z "$EDGE_PATH" ]; then
        echo -e "${ORANGE}[*] titan-edge не найден стандартным способом! Ищем в overlay2...${NC}"
        CONTAINER_PATH=$(docker inspect --format='{{.GraphDriver.Data.UpperDir}}' "$CONTAINER_ID" 2>/dev/null)
        EDGE_PATH=$(find "$CONTAINER_PATH" -type f -name "titan-edge" | head -n 1)
        cp "$EDGE_PATH" ./titan-edge
    else
        docker cp "$CONTAINER_ID":"$EDGE_PATH" ./titan-edge
    fi

    if [ ! -f "./titan-edge" ]; then
        echo -e "${RED}Ошибка: titan-edge отсутствует!${NC}"
        docker logs "$CONTAINER_ID"
        docker rm -f "$CONTAINER_ID"
        exit 1
    fi

    chmod +x ./titan-edge
    docker rm -f "$CONTAINER_ID"

    echo -e "${GREEN}[✓] Библиотеки и бинарники успешно извлечены!${NC}"

    echo -e "${ORANGE}[6/7] Сборка кастомного Docker-образа с proxychains4...${NC}"
    
    cat > Dockerfile.titan <<EOF
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

COPY libgoworkerd.so /usr/lib/libgoworkerd.so
COPY titan-edge /usr/local/bin/titan-edge
RUN chmod +x /usr/local/bin/titan-edge && ln -s /usr/local/bin/titan-edge /usr/bin/titan-edge

RUN apt update && \
    apt install -y proxychains4 curl && \
    echo "strict_chain" > /etc/proxychains4.conf && \
    echo "proxy_dns" >> /etc/proxychains4.conf && \
    echo "tcp_read_time_out 15000" >> /etc/proxychains4.conf && \
    echo "tcp_connect_time_out 8000" >> /etc/proxychains4.conf && \
    echo "[ProxyList]" >> /etc/proxychains4.conf

ENV PROXY_HOST=""
ENV PROXY_PORT=""
ENV PROXY_USER=""
ENV PROXY_PASS=""
ENV ALL_PROXY=""

CMD ["sh", "-c", \
    "echo 'socks5 \${PROXY_HOST} \${PROXY_PORT} \${PROXY_USER} \${PROXY_PASS}' >> /etc/proxychains4.conf && \
    export ALL_PROXY=socks5://\${PROXY_USER}:\${PROXY_PASS}@\${PROXY_HOST}:\${PROXY_PORT} && \
    proxychains4 /usr/bin/titan-edge daemon start --init --url=https://cassini-locator.titannet.io:5000/rpc/v0"]
EOF

    docker build -t mytitan/proxy-titan-edge-custom -f Dockerfile.titan . || {
        echo -e "${RED}[✗] Ошибка сборки Docker-образа!${NC}"
        exit 1
    }

    echo -e "${GREEN}[7/7] Установка завершена! Titan + ProxyChains готово к работе!${NC}"
}

###############################################################################
# (2) Генерация IP, порт, CPU/RAM/SSD
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
    local cpus=(8 10 12 14 16 18 20 22 24 26 28 30 32)
    local c=${cpus[$RANDOM % ${#cpus[@]}]}
    local ram=$((32 + (RANDOM % 16)*32))
    local ssd=$((512 + (RANDOM % 20)*512))
    echo "$c,$ram,$ssd"
}

generate_fake_mac() {
    printf "02:%02x:%02x:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

#!/bin/bash

###############################################################################
# (3) Создание/запуск ноды
###############################################################################
setup_nodes() {
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
# (4) Настройка нод
###############################################################################
create_node() {
    local idx="$1"
    local identity_code="$2"
    local proxy_host="$3"
    local proxy_port="$4"
    local proxy_user="$5"
    local proxy_pass="$6"

    # Генерация случайных параметров
    local host_port=$((30000 + idx))
    local cpu_val=$((2 + RANDOM % 8))
    local ram_val=$((8 + RANDOM % 8))
    local ssd_val=$((256 + RANDOM % 1024))
    
    echo -e "${ORANGE}[*] Запуск контейнера titan_node_$idx (порт $host_port, CPU=${cpu_val}, RAM=${ram_val}GB)...${NC}"
    
    CONTAINER_ID=$(docker run -d \
        --name "titan_node_$idx" \
        --restart unless-stopped \
        --cpu-quota=$((cpu_val * 100000)) \
        --memory="${ram_val}g" \
        -p "${host_port}:1234/udp" \
        -e ALL_PROXY="socks5://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}" \
        mytitan/proxy-titan-edge-custom)

    if [ -z "$CONTAINER_ID" ]; then
        echo -e "${RED}[✗] Ошибка запуска контейнера titan_node_$idx${NC}"
        return 1
    fi

    echo -e "${GREEN}[✓] Контейнер titan_node_$idx запущен! ID: $CONTAINER_ID${NC}"
}

setup_nodes() {
    echo -e "${ORANGE}[*] Начинаем настройку нод...${NC}"
    
    read -p "Сколько нод создать: " node_count
    while [[ ! "$node_count" =~ ^[0-9]+$ || "$node_count" -le 0 ]]; do
        echo -e "${RED}[!] Введите корректное число (> 0)!${NC}"
        read -p "Сколько нод создать: " node_count
    done

    for ((i=1; i<=node_count; i++)); do
        local px
        while true; do
            read -p "Введите SOCKS5-прокси (host:port:user:pass) для ноды $i: " px
            IFS=':' read -r phost pport puser ppass <<< "$px"
            if [[ -z "$phost" || -z "$pport" || -z "$puser" || -z "$ppass" ]]; then
                echo -e "${RED}[!] Некорректный формат! Пример: 1.2.3.4:1080:user:pass${NC}"
                continue
            fi
            break
        done

        local key
        while true; do
            read -p "Введите Identity Code (UUIDv4) для ноды $i: " key
            local upkey=${key^^}
            if [[ -z "$upkey" ]]; then
                echo -e "${RED}[!] Identity Code не может быть пустым!${NC}"
                continue
            fi
            if [[ ! "$upkey" =~ ^[A-F0-9]{8}-[A-F0-9]{4}-4[A-F0-9]{3}-[89AB][A-F0-9]{3}-[A-F0-9]{12}$ ]]; then
                echo -e "${RED}[!] Некорректный формат UUIDv4!${NC}"
                continue
            fi
            break
        done

        create_node "$i" "$upkey" "$phost" "$pport" "$puser" "$ppass"
    done

    echo -e "${GREEN}[✓] Настройка завершена!${NC}"
}

###############################################################################
# (4.1) Проверка статуса
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
# (5) Логи (последние 5 строк) всех нод
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
# (6) Перезапуск, Очистка, автозапуск
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
