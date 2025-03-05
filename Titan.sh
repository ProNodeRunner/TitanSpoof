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
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== TITAN NODE MANAGER v10.0 ==="
    echo -e "\n1) Установить\n2) Создать ноды\n3) Статус\n4) Очистка\n5) Выход${NC}"
}

install_deps() {
    echo -e "${ORANGE}[*] Установка компонентов...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -yq && sudo apt-get install -yq docker.io jq screen
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
    echo -e "${GREEN}[✓] Готово! Перезапустите терминал.${NC}"
}

create_node() {
    local node_num=$1 key=$2
    local cpu=$((4*(1+RANDOM%8))) ram=$((8*(1+RANDOM%16))) ssd=$((100+(RANDOM%3900)))
    local node_ip=$(echo $BASE_IP | awk -v i=$node_num -F. '{OFS="."; $4+=i; print}')
    
    docker volume create titan_$node_num >/dev/null
    echo $key | docker run -i -v titan_$node_num:/data alpine sh -c "cat > /data/key"
    
    screen -dmS node_$node_num docker run -d \
        --name titan_$node_num \
        --network host \
        -v titan_$node_num:/root/.titan \
        nezha123/titan-edge
        
    sudo ip addr add $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null
    echo -e "${GREEN}[✓] Нода $node_num | ${cpu} ядер | ${ram}GB RAM | ${ssd}GB SSD${NC}"
}

setup_nodes() {
    read -p "Количество нод: " count
    for ((i=1; i<=count; i++)); do
        while read -p "Ключ $i: " key && [[ ! $key =~ ^[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}$ ]]; do
            echo -e "${RED}Неверный формат!${NC}"
        done
        create_node $i $key
    done
}

check_nodes() {
    docker ps -a --filter "name=titan_" --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || 
    echo -e "${ORANGE}Ноды не найдены${NC}"
}

cleanup() {
    echo -e "${ORANGE}[*] Начало очистки...${NC}"
    
    # Остановка и удаление контейнеров
    docker ps -aq --filter "name=titan_" | xargs -r docker rm -f 2>/dev/null
    
    # Удаление томов
    docker volume ls -q --filter "name=titan_" | xargs -r docker volume rm 2>/dev/null
    
    # Удаление Docker
    sudo apt-get purge -yq docker.io containerd 2>/dev/null
    sudo apt-get autoremove -yq 2>/dev/null
    sudo rm -rf /var/lib/docker /etc/docker 2>/dev/null
    
    # Восстановление сети
    for i in {1..50}; do
        sudo ip addr del $(echo $BASE_IP | awk -v i=$i -F. '{OFS="."; $4+=i; print}')/24 dev $NETWORK_INTERFACE 2>/dev/null
    done
    
    echo -e "${GREEN}[✓] Полная очистка завершена!${NC}"
    sleep 2
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
