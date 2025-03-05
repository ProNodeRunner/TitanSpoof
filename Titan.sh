#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/titan_nodes.conf"
BASE_IP="192.168.1.100"
TIMEZONE="Europe/Moscow"
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
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== TITAN NODE MANAGER v9.2 ==="
    echo -e "\n1) Установить компоненты"
    echo "2) Создать ноды"
    echo "3) Проверить статус"
    echo "4) Перезапустить все ноды"
    echo "5) Полная очистка"
    echo "6) Выход"
    echo -ne "${NC}"
}

generate_random_port() {
    while true; do
        local port=$(( 1000 + RANDOM % 9001 ))
        if [[ ! -v USED_PORTS[$port] ]] && ! ss -uln | grep -q ":$port "; then
            USED_PORTS[$port]=1
            echo $port
            break
        fi
    done
}

generate_realistic_profile() {
    local cpu_cores=$(( 4 * (2 + RANDOM % 7) ))  # 8-28 ядер
    local ram_gb=$(( 32 * (1 + RANDOM % 16) ))   # 32-512GB RAM
    local ssd_gb=$(( 500 * (1 + RANDOM % 6) ))   # 500-3000GB SSD
    echo "${cpu_cores},${ram_gb},${ssd_gb}"
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive

    # Очистка предыдущих установок
    sudo rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null

    # Установка пакетов
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
        net-tools

    # Установка Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -yq && sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER

    # Настройка сети
    echo "net.core.rmem_max=2500000" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p

    echo -e "${GREEN}[✓] Системные компоненты успешно установлены!${NC}"
    sleep 2
}

create_node() {
    local node_num=$1 identity_code=$2
    IFS=',' read -r cpu ram ssd <<< "$(generate_realistic_profile)"
    local node_ip=$(echo "$BASE_IP" | awk -F. -v i="$node_num" '{OFS="."; $4+=i; print}')
    local volume="titan_data_$node_num"
    local port=$(generate_random_port)

    if ! docker volume create $volume >/dev/null || \
       ! echo "$identity_code" | docker run -i --rm -v $volume:/data alpine sh -c "cat > /data/identity.key"
    then
        echo -e "${RED}[✗] Ошибка создания ноды $node_num${NC}"
        return 1
    fi

    screen -dmS "node_$node_num" docker run -d \
        --name "titan_node_$node_num" \
        --restart always \
        -p ${port}:1234/udp \
        -v $volume:/root/.titanedge \
        nezha123/titan-edge

    sudo ip addr add $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null
    
    # Форматированный вывод
    printf "${GREEN}[✓] Нода %2d | %2d ядер | %4dGB RAM | %4dGB SSD | Порт: %5d${NC}\n" \
        $node_num $cpu $ram $ssd $port
}

setup_nodes() {
    declare -gA USED_KEYS=()
    declare -gA USED_PORTS=()
    
    # Ввод количества нод
    while true; do
        read -p "Введите количество нод: " node_count
        [[ "$node_count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Ошибка: введите целое положительное число!${NC}"
    done

    # Создание нод
    for ((i=1; i<=$node_count; i++)); do
        while true; do
            read -p "Введите ключ для ноды $i: " key
            key_upper=${key^^}
            if [[ ${USED_KEYS[$key_upper]} ]]; then
                echo -e "${RED}Ключ уже используется!${NC}"
            elif [[ $key_upper =~ ^[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}$ ]]; then
                USED_KEYS["$key_upper"]=1
                create_node $i "$key_upper" && break
            else
                echo -e "${RED}Неверный формат! Пример: EFE14741-B359-4C34-9A36-BA7F88A574FC${NC}"
            fi
        done
    done

    echo -e "\n${GREEN}Все $node_count нод успешно созданы!${NC}"
    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

check_nodes() {
    clear
    echo -e "${ORANGE}ТЕКУЩИЙ СТАТУС НОД:${NC}"
    
    # Цветной вывод статусов
    docker ps -a --filter "name=titan_node" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | \
    awk 'BEGIN {printf "%-15s %-25s %-15s\n", "ИМЯ", "СТАТУС", "ПОРТЫ"}
    {
        status = $2
        color = 37  # Белый
        if (status ~ /Up/) color = 32  # Зеленый
        if (status ~ /Restarting|Exited/) color = 31  # Красный
        printf "\033[%dm%-15s %-25s %-15s\033[0m\n", color, $1, $2, $3
    }'
    
    echo -e "\n${ORANGE}СЕТЕВЫЕ НАСТРОЙКИ:${NC}"
    ip -o addr show $NETWORK_INTERFACE | awk '{print $2" "$4}'
    
    read -p $'\nНажмите любую клавишу...' -n1 -s
    clear
}

restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск всех нод...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f
    
    if [ -f $CONFIG_FILE ]; then
        source $CONFIG_FILE
        for key in "${!USED_KEYS[@]}"; do
            node_num=$(echo "$key" | sed 's/node_//')
            create_node $node_num "${USED_KEYS[$key]}"
        done
        echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    else
        echo -e "${RED}Конфигурация не найдена!${NC}"
    fi
    sleep 2
}

cleanup() {
    echo -e "${ORANGE}[*] Очистка системы...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f 2>/dev/null
    docker volume ls -q --filter "name=titan_data" | xargs -r docker volume rm 2>/dev/null
    sudo apt-get purge -yq docker-ce docker-ce-cli containerd.io 2>/dev/null
    sudo rm -rf /var/lib/docker /etc/docker
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Очистка IP
    for ip in $(seq 1 50); do
        node_ip=$(echo "$BASE_IP" | awk -F. -v i="$ip" '{OFS="."; $4+=i; print}')
        sudo ip addr del $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null
    done
    
    echo -e "${GREEN}[✓] Система очищена!${NC}"
    sleep 3
}

# Автозапуск
if [ ! -f /etc/systemd/system/titan-node.service ]; then
    sudo bash -c "cat > /etc/systemd/system/titan-node.service <<EOF
[Unit]
Description=Titan Node Service
After=network.target docker.service

[Service]
ExecStart=$(realpath $0) --auto-start
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"
    sudo systemctl enable titan-node.service
fi

case $1 in
    --auto-start)
        [ -f $CONFIG_FILE ] && source $CONFIG_FILE && setup_nodes
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
