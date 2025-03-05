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
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== TITAN NODE MANAGER v9.4 ==="
    echo -e "\n1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Перезапустить все ноды\n5) Полная очистка\n6) Выход"
    echo -ne "${NC}"
}

generate_random_port() {
    while true; do
        port=$(shuf -i 1000-10000 -n 1)
        if [[ ! -v USED_PORTS[$port] ]] && ! ss -uln | grep -q ":$port "; then
            USED_PORTS["$port"]=1
            echo "$port"
            break
        fi
    done
}

generate_realistic_profile() {
    echo "$((4*(2+RANDOM%7))),$((32*(1+RANDOM%16))),$((500*(1+RANDOM%6)))"
}

create_node() {
    local node_num=$1 identity_code=$2
    IFS=',' read -r cpu ram ssd <<< "$(generate_realistic_profile)"
    local port=$(generate_random_port)
    local volume="titan_data_$node_num"

    docker volume create "$volume" >/dev/null && \
    echo "$identity_code" | docker run -i --rm -v "$volume:/data" alpine sh -c "cat > /data/identity.key" && \
    screen -dmS "node_$node_num" docker run -d \
        --name "titan_node_$node_num" \
        --restart always \
        -p "${port}:1234/udp" \
        -v "$volume:/root/.titanedge" \
        nezha123/titan-edge || return 1

    printf "${GREEN}[✓] Нода %02d | %2d ядер | %4dGB RAM | %4dGB SSD | Порт: %5d${NC}\n" \
        "$node_num" "$cpu" "$ram" "$ssd" "$port"
}

check_nodes() {
    clear
    echo -e "${ORANGE}ТЕКУЩИЙ СТАТУС НОД:${NC}"
    docker ps -a --filter "name=titan_node" --format '{{.Names}} {{.Status}} {{.Ports}}' | \
    awk '{
        split($3, ports, /[:->]/); 
        printf "%-15s %-25s %-10s\n", $1, $2, ports[2]
    }' | column -t -N "ИМЯ,СТАТУС,ПОРТ"
    
    echo -e "\n${ORANGE}СЕТЕВЫЕ НАСТРОЙКИ:${NC}"
    ip -br addr show "$NETWORK_INTERFACE" | awk '{print $1" "$3}'
    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

# Остальные функции без изменений (install_dependencies, setup_nodes, restart_nodes, cleanup)

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
                4) restart_nodes ;;
                5) cleanup ;;
                6) exit 0 ;;
                *) echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
            esac
        done
        ;;
esac
