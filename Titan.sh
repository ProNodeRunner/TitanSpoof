#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/titan_nodes.conf"
BASE_IP="192.168.1.100"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}')

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== TITAN NODE MANAGER v9.1 ==="
    echo -e "\n1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Очистка\n5) Выход${NC}"
}

install_deps() {
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -yq && sudo apt-get install -yq docker.io jq screen
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
    echo -e "${GREEN}[✓] Система готова!${NC}"
}

create_node() {
    local node_num=$1 key=$2
    local cpu=$((4*(1+RANDOM%8))) ram=$((8*(1+RANDOM%16))) ssd=$((100+(RANDOM%3900)))
    local node_ip=$(echo $BASE_IP | awk -F. -v i=$node_num '{OFS="."; $4+=i; print}')
    
    docker volume create titan_data_$node_num >/dev/null
    echo $key | docker run -i -v titan_data_$node_num:/data alpine sh -c "cat > /data/identity.key"
    
    screen -dmS node_$node_num docker run -d --name titan_node_$node_num --network host -v titan_data_$node_num:/root/.titanedge nezha123/titan-edge
    sudo ip addr add $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null
    
    printf "${GREEN}[✓] Нода $node_num | ${cpu} ядер | %4dGB RAM | %4dGB SSD${NC}\n" $ram $ssd
}

setup_nodes() {
    read -p "Количество нод: " count
    for ((i=1; i<=count; i++)); do
        while read -p "Ключ для ноды $i: " key && [[ ! $key =~ ^[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}$ ]]; do
            echo -e "${RED}Неверный формат!${NC}"
        done
        create_node $i $key
    done
}

check_nodes() {
    docker ps -a --filter "name=titan_node" --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || echo -e "${ORANGE}Ноды не найдены${NC}"
}

cleanup() {
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f 2>/dev/null
    docker volume ls -q --filter "name=titan_data" | xargs -r docker volume rm 2>/dev/null
    sudo apt-get purge -yq docker.io 2>/dev/null
    for ip in {1..50}; do 
        sudo ip addr del $(echo $BASE_IP | awk -v i=$ip -F. '{OFS="."; $4+=i; print}')/24 dev $NETWORK_INTERFACE 2>/dev/null
    done
    echo -e "${GREEN}[✓] Система очищена!${NC}"
}

while true; do
    show_menu
    read -p "Выбор: " c
    case $c in
        1) install_deps ;;
        2) setup_nodes ;;
        3) check_nodes ;;
        4) cleanup ;;
        5) exit ;;
        *) echo -e "${RED}Ошибка!${NC}"; sleep 1 ;;
    esac
done
