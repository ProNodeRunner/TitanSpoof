#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/titan_nodes.conf"
BASE_IP="172.$(shuf -i 16-31 -n1).$(shuf -i 0-255 -n1).0"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

declare -A USED_KEYS=()
declare -A USED_PORTS=()

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== TITAN NODE MANAGER v21 ==="
    echo -e "\n1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    echo -ne "${NC}"
}

generate_random_port() {
    if [[ $1 -eq 1 ]]; then
        echo "1234"
        return
    fi

    while true; do
        port=$(shuf -i 30000-40000 -n 1)
        [[ ! -v USED_PORTS[$port] ]] && ! ss -uln | grep -q ":${port} " && break
    done
    USED_PORTS[$port]=1
    echo "$port"
}

generate_realistic_profile() {
    echo "$((2 + RANDOM%4)),$((4 + RANDOM%8)),$((50 + RANDOM%50))"
}

generate_fake_mac() {
    printf "02:%02x:%02x:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive

    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections"
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections"

    sudo apt-get update -yq && sudo apt-get upgrade -yq
    sudo apt-get install -yq \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        jq screen cgroup-tools net-tools ccze netcat iptables-persistent

    sudo ufw allow 1234/udp
    sudo ufw allow 30000:40000/udp
    sudo ufw reload

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    
    sudo apt-get update -yq && sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

    echo -e "${GREEN}[✓] Система готова!${NC}"
    sleep 1
}

create_node() {
    local node_num=$1 identity_code=$2
    IFS=',' read -r cpu ram_gb ssd_gb <<< "$(generate_realistic_profile)"
    local port=$(generate_random_port $node_num)
    local volume="titan_data_$node_num"
    local node_ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + node_num ))"
    local mac=$(generate_fake_mac)

    docker rm -f "titan_node_$node_num" 2>/dev/null
    docker volume create "$volume" >/dev/null || {
        echo -e "${RED}[✗] Ошибка создания тома $volume${NC}"
        return 1
    }

    echo "$identity_code" | docker run -i --rm -v "$volume:/data" busybox sh -c "cat > /data/identity.key" || {
        echo -e "${RED}[✗] Ошибка записи ключа${NC}"
        return 1
    }

    if ! screen -dmS "node_$node_num" docker run -d \
        --name "titan_node_$node_num" \
        --restart unless-stopped \
        --cpus "$cpu" \
        --memory "${ram_gb}g" \
        --storage-opt "size=${ssd_gb}g" \
        --mac-address "$mac" \
        -p ${port}:${port}/udp \
        -v "$volume:/root/.titanedge" \
        nezha123/titan-edge:latest \
        --bind "0.0.0.0:${port}" \
        --storage-size "${ssd_gb}GB"; then
        echo -e "${RED}[✗] Ошибка запуска контейнера${NC}"
        return 1
    fi

    sudo ip addr add "${node_ip}/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    sudo iptables -t nat -A PREROUTING -i $NETWORK_INTERFACE -p udp --dport $port -j DNAT --to-destination $node_ip:$port
    sudo netfilter-persistent save >/dev/null 2>&1

    echo -e "${ORANGE}[*] Инициализация ноды (2 мин)...${NC}"
    sleep 120

    printf "${GREEN}[✓] Нода %02d | IP: %s | Порт: %5d | Ресурсы: %d ядер, %dGB RAM, %dGB SSD | MAC: %s${NC}\n" \
        "$node_num" "$node_ip" "$port" "$cpu" "$ram_gb" "$ssd_gb" "$mac"
}

check_nodes() {
    clear
    echo -e "${ORANGE}ТЕКУЩИЙ СТАТУС:${NC}"
    docker ps -a --filter "name=titan_node" --format '{{.Names}} {{.Status}} {{.Ports}}' | \
    awk '{
        status_color = ($2 ~ /Up/) ? "\033[32m" : "\033[31m";
        printf "%-15s %s%-12s\033[0m %s\n", $1, status_color, $2, $3
    }'

    echo -e "\n${ORANGE}СИНХРОНИЗАЦИЯ:${NC}"
    docker ps --filter "name=titan_node" --format "{{.Names}}" | xargs -I{} sh -c \
    'echo -n "{}: "; docker exec {} titan-edge info sync 2>/dev/null | grep "Progress" || echo "OFFLINE"'

    echo -e "\n${ORANGE}ЗАДАЧИ:${NC}"
    docker ps --filter "name=titan_node" --format "{{.Names}}" | xargs -I{} sh -c \
    'echo -n "{}: "; docker exec {} titan-edge info tasks 2>/dev/null | grep "Total tasks"'

    echo -e "\n${ORANGE}ТРАФИК:${NC}"
    docker ps --filter "name=titan_node" --format "{{.Names}}" | xargs -I{} sh -c \
    'echo -n "{}: "; docker exec {} titan-edge info bandwidth 2>/dev/null | grep "used"'

    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

# ... [Остальные функции (setup_nodes, show_logs и др.) без изменений] ...

[ ! -f /etc/systemd/system/titan-node.service ] && sudo bash -c "cat > /etc/systemd/system/titan-node.service <<EOF
[Unit]
Description=Titan Node Service
After=network.target docker.service

[Service]
ExecStart=$(realpath "$0") --auto-start
Restart=on-failure
RestartSec=60

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
