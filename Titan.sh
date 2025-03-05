#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/titan_nodes.conf"
BASE_IP="192.168.1.100"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Автоматическое определение интерфейса
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

declare -A USED_KEYS=()
declare -A USED_PORTS=()

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== TITAN NODE MANAGER v12.2 ==="
    echo -e "\n1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Показать логи ноды\n5) Перезапустить все ноды\n6) Полная очистка\n7) Выход"
    echo -ne "${NC}"
}

generate_random_port() {
    while true; do
        port=$(shuf -i 30000-40000 -n 1)
        if [[ ! -v USED_PORTS[$port] ]] && ! ss -uln | grep -q ":${port} "; then
            USED_PORTS[$port]=1
            echo "$port"
            break
        fi
    done
}

generate_realistic_profile() {
    echo "$((12 + 4*(RANDOM%5))),$((64*(1+RANDOM%8))),$((1000*(1+RANDOM%3)))"
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive

    sudo apt-get update -yq && sudo apt-get upgrade -yq
    sudo apt-get install -yq \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        jq \
        screen \
        cgroup-tools \
        net-tools \
        ccze \
        netcat

    sudo ufw allow 30000:40000/udp
    sudo ufw reload

    echo "net.core.rmem_max=2500000" | sudo tee -a /etc/sysctl.conf
    echo "net.core.wmem_max=2500000" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p >/dev/null

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -yq && sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

    echo -e "${GREEN}[✓] Система готова! Перезагрузите сервер.${NC}"
    sleep 2
}

create_node() {
    local node_num=$1 identity_code=$2
    IFS=',' read -r cpu ram ssd <<< "$(generate_realistic_profile)"
    local port=$(generate_random_port)
    local volume="titan_data_$node_num"
    local node_ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + node_num ))"

    docker rm -f "titan_node_$node_num" 2>/dev/null

    if ! docker volume create "$volume" >/dev/null || \
       ! echo "$identity_code" | docker run -i --rm -v "$volume:/data" alpine sh -c "cat > /data/identity.key"; then
        echo -e "${RED}[✗] Ошибка создания ноды $node_num${NC}"
        return 1
    fi

    screen -dmS "node_$node_num" docker run -d \
        --name "titan_node_$node_num" \
        --restart unless-stopped \
        --network bridge \
        -p ${port}:1234/udp \
        -v "$volume:/root/.titanedge" \
        nezha123/titan-edge:latest

    sudo ip addr add "${node_ip}/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    sleep 5

    if ! docker exec "titan_node_$node_num" curl -sSf https://api.titan.network/health >/dev/null; then
        echo -e "${RED}[✗] Нода $node_num: Нет интернет-доступа${NC}"
        return 1
    fi

    printf "${GREEN}[✓] Нода %02d | %2d ядер | %4dGB RAM | %4dGB SSD | Порт: %5d | IP: %s${NC}\n" \
        "$node_num" "$cpu" "$ram" "$ssd" "$port" "$node_ip"
}

setup_nodes() {
    declare -gA USED_KEYS=()
    
    while true; do
        read -p "Введите количество нод: " node_count
        [[ "$node_count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Ошибка: введите число > 0!${NC}"
    done

    for ((i=1; i<=node_count; i++)); do
        while true; do
            read -p "Введите ключ для ноды $i: " key
            key_upper=${key^^}
            if [[ ${USED_KEYS[$key_upper]} ]]; then
                echo -e "${RED}Ключ уже используется!${NC}"
            elif [[ $key_upper =~ ^[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}$ ]]; then
                USED_KEYS[$key_upper]=1
                create_node "$i" "$key_upper" && break
            else
                echo -e "${RED}Неверный формат! Пример: EFE14741-B359-4C34-9A36-BA7F88A574FC${NC}"
            fi
        done
    done

    echo -e "\n${GREEN}Создано нод: ${node_count}${NC}"
    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

check_nodes() {
    clear
    echo -e "${ORANGE}ТЕКУЩИЙ СТАТУС НОД:${NC}"
    docker ps -a --filter "name=titan_node" --format '{{.Names}} {{.Status}} {{.Ports}}' | \
    awk '{
        status_color = ($2 ~ /Up/) ? "\033[32m" : "\033[31m";
        time_unit = $4;
        value = $3;
        
        if ($2 == "Up") {
            total_minutes = 0;
            if (time_unit == "weeks") total_minutes = value * 10080;
            if (time_unit == "days") total_minutes = value * 1440;
            if (time_unit == "hours") total_minutes = value * 60;
            if (time_unit == "minutes") total_minutes = value;
            
            days = int(total_minutes / 1440);
            hours = int((total_minutes % 1440) / 60);
            minutes = int(total_minutes % 60);
            uptime = "";
            if (days > 0) uptime = sprintf("%dд ", days);
            if (hours > 0) uptime = uptime sprintf("%dч ", hours);
            uptime = uptime sprintf("%dм", minutes);
        }
        else {
            uptime = "N/A";
        }
        
        printf "%-15s %s%-12s\033[37m (up %-15s)\033[0m %s\n", 
               $1, status_color, $2, uptime, $5
    }'
    
    echo -e "\n${ORANGE}СЕТЕВЫЕ НАСТРОЙКИ:${NC}"
    ip -br addr show "$NETWORK_INTERFACE" | awk '{print $1" "$3}'
    echo -e "\n${ORANGE}АКТИВНЫЕ ПОРТЫ:${NC}"
    docker ps --filter "name=titan_node" --format "{{.Names}}" | xargs -I{} docker port {} | grep udp
    
    echo -e "\n${ORANGE}СИНХРОНИЗАЦИЯ:${NC}"
    docker ps --filter "name=titan_node" --format "{{.Names}}" | xargs -I{} sh -c \
    'echo -n "{}: "; docker exec {} titan-edge info sync 2>/dev/null | grep "Sync Progress" || echo "OFFLINE"'
    
    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

show_logs() {
    read -p "Введите номер ноды: " num
    echo -e "${ORANGE}Логи titan_node_${num}:${NC}"
    logs=$(docker logs --tail 50 "titan_node_${num}" 2>&1 | grep -iE 'error|fail|warn|binding')
    if command -v ccze &>/dev/null; then
        echo "$logs" | ccze -A
    else
        echo "$logs"
    fi
    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        for key in "${!USED_KEYS[@]}"; do
            node_num=${key##*_}
            create_node "$node_num" "${USED_KEYS[$key]}"
        done
        echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    else
        echo -e "${RED}Конфигурация отсутствует!${NC}"
    fi
    sleep 2
}

cleanup() {
    echo -e "${ORANGE}\n[!] НАЧИНАЕМ ПОЛНУЮ ОЧИСТКУ [!]${NC}"
    
    echo -e "${ORANGE}[1/5] Контейнеры...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f
    
    echo -e "${ORANGE}[2/5] Тома...${NC}"
    docker volume ls -q --filter "name=titan_data" | xargs -r docker volume rm
    
    echo -e "${ORANGE}[3/5] Docker...${NC}"
    sudo apt-get purge -yq docker-ce docker-ce-cli containerd.io
    sudo apt-get autoremove -yq
    sudo rm -rf /var/lib/docker /etc/docker
    
    echo -e "${ORANGE}[4/5] Screen...${NC}"
    screen -ls | grep "node_" | awk -F. '{print $1}' | xargs -r -I{} screen -X -S {} quit
    
    echo -e "${ORANGE}[5/5] Сеть...${NC}"
    for i in {1..50}; do
        node_ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + i ))"
        sudo ip addr del "$node_ip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done

    echo -e "\n${GREEN}[✓] Все компоненты удалены!${NC}"
    sleep 3
    clear
}

[ ! -f /etc/systemd/system/titan-node.service ] && sudo bash -c "cat > /etc/systemd/system/titan-node.service <<EOF
[Unit]
Description=Titan Node Service
After=network.target docker.service

[Service]
ExecStart=$(realpath "$0") --auto-start
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF" && sudo systemctl enable titan-node.service >/dev/null 2>&1

case $1 in
    --auto-start)
        [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && setup_nodes
        ;;
    *)
        while true; do
            show_menu
            read -p "Выбор: " choice
            case $choice in
                1) install_dependencies ;;
                2) setup_nodes ;;
                3) check_nodes ;;
                4) show_logs ;;
                5) restart_nodes ;;
                6) cleanup ;;
                7) exit 0 ;;
                *) echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
            esac
        done
        ;;
esac
