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

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== TITAN NODE MANAGER v8.2 ==="
    echo -e "\n1) Установить компоненты"
    echo "2) Создать ноды"
    echo "3) Проверить статус"
    echo "4) Полная очистка"
    echo "5) Выход"
    echo -ne "${NC}"
}

generate_realistic_profile() {
    # CPU: 8-32 ядер (кратно 4)
    local cpu_cores=$(( 4 * (2 + RANDOM % 7) ))  # 8,12,16...28
    
    # RAM: 64-512GB (кратно 32)
    local ram_gb=$(( 32 * (2 + RANDOM % 15) ))   # 64,96,128...512
    
    # SSD: 500-3000GB (кратно 500)
    local ssd_gb=$(( 500 * (1 + RANDOM % 6) ))   # 500,1000...3000
    
    echo "${cpu_cores},${ram_gb},${ssd_gb}"
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive

    # Полная очистка перед установкой
    echo -e "${ORANGE}[*] Подготовка окружения...${NC}"
    sudo rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null

    # Установка зависимостей
    echo -e "${ORANGE}[*] Обновление системы...${NC}"
    sudo apt-get update -yq
    sudo apt-get upgrade -yq

    echo -e "${ORANGE}[*] Установка компонентов...${NC}"
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

    # Настройка Docker
    echo -e "${ORANGE}[*] Настройка Docker...${NC}"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update -yq
    sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER

    echo -e "${GREEN}[✓] Системные компоненты успешно установлены!${NC}"
    sleep 2
}

create_node() {
    if ! docker info &>/dev/null; then
        echo -e "${RED}Docker не запущен! Сначала выполните пункт 1${NC}"
        return 1
    fi

    local node_num=$1 identity_code=$2
    IFS=',' read -r cpu ram ssd <<< "$(generate_realistic_profile)"
    local node_ip=$(echo "$BASE_IP" | awk -F. -v i="$node_num" '{OFS="."; $4+=i; print}')
    local volume="titan_data_$node_num"

    # Создание ноды
    if ! docker volume create $volume >/dev/null || \
       ! echo "$identity_code" | docker run -i --rm -v $volume:/data alpine sh -c "cat > /data/identity.key"
    then
        echo -e "${RED}[✗] Ошибка создания ноды $node_num${NC}"
        return 1
    fi

    screen -dmS "node_$node_num" docker run -d \
        --name "titan_node_$node_num" \
        --network host \
        --restart always \
        -v $volume:/root/.titanedge \
        nezha123/titan-edge

    sudo ip addr add $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null
    
    # Вывод
    ram_display=$(printf "%4d" $ram)
    ssd_display=$(printf "%4d" $ssd)
    echo -e "${GREEN}[✓] Нода $node_num | ${cpu} ядер | ${ram_display}GB RAM | ${ssd_display}GB SSD${NC}"
}

setup_nodes() {
    declare -gA USED_KEYS=()
    read -p "Введите количество нод: " node_count
    for ((i=1; i<=$node_count; i++)); do
        while true; do
            read -p "Введите ключ для ноды $i: " key
            key_upper=${key^^}
            if [[ ${USED_KEYS[$key_upper]} ]]; then
                echo -e "${RED}Ключ уже используется! Введите уникальный ключ.${NC}"
            elif [[ $key_upper =~ ^[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}$ ]]; then
                USED_KEYS["$key_upper"]=1
                create_node $i "$key_upper" && break
            else
                echo -e "${RED}Неверный формат! Пример: EFE14741-B359-4C34-9A36-BA7F88A574FC${NC}"
            fi
        done
    done
}

check_nodes() {
    if ! docker ps -aq --filter "name=titan_node" &>/dev/null; then
        echo -e "${ORANGE}Активные ноды не найдены${NC}"
        return
    fi
    
    echo -e "${ORANGE}\nСПИСОК НОД:${NC}"
    docker ps -a --filter "name=titan_node" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cleanup() {
    echo -e "${ORANGE}\n[*] Начинаем очистку системы...${NC}"
    sleep 1

    # Остановка и удаление контейнеров
    echo -e "${ORANGE}[*] Удаление контейнеров...${NC}"
    docker ps -aq --filter "name=titan_node" 2>/dev/null | xargs -r docker rm -f 2>/dev/null

    # Удаление томов
    echo -e "${ORANGE}[*] Удаление томов...${NC}"
    docker volume ls -q --filter "name=titan_data" 2>/dev/null | xargs -r docker volume rm 2>/dev/null

    # Удаление Docker
    echo -e "${ORANGE}[*] Удаление Docker...${NC}"
    sudo apt-get purge -yq docker-ce docker-ce-cli containerd.io 2>/dev/null
    sudo apt-get autoremove -yq 2>/dev/null
    sudo rm -rf /var/lib/docker /etc/docker
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg

    # Восстановление сети
    echo -e "${ORANGE}[*] Восстановление сети...${NC}"
    for ip in $(seq 1 50); do
        node_ip=$(echo "$BASE_IP" | awk -F. -v i="$ip" '{OFS="."; $4+=i; print}')
        sudo ip addr del $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null
    done

    # Финализация
    echo -e "${GREEN}\n[✓] ВСЕ КОМПОНЕНТЫ УДАЛЕНЫ!${NC}"
    sleep 3
}

case $1 in
    --auto-start)
        if [ -f $CONFIG_FILE ]; then
            source $CONFIG_FILE
            setup_nodes
        fi
        ;;
    *)
        while true; do
            show_menu
            read -p "Выбор: " choice
            case $choice in
                1) install_dependencies ;;
                2) setup_nodes ;;
                3) check_nodes ;;
                4) cleanup ;;
                5) exit 0 ;;
                *) echo -e "${RED}Ошибка выбора!${NC}"; sleep 1 ;;
            esac
        done
        ;;
esac
