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

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== TITAN NODE MANAGER v6.3 ==="
    echo -e "\n1) Установить компоненты"
    echo "2) Создать ноды"
    echo "3) Проверить статус"
    echo "4) Полная очистка"
    echo "5) Выход"
    echo -ne "${NC}"
}

generate_realistic_profile() {
    local cpu_cores=$(( (2 + RANDOM % 7) * 4 ))  # 8-32 ядра
    local ram_gb=$(( cpu_cores * (2 + RANDOM % 7) ))  # 16-224GB
    local ssd_gb=$(( 100 + (ram_gb * 10) + (RANDOM % 500) ))  # 200-2740GB
    
    (( ram_gb = ram_gb < 512 ? ram_gb : 512 ))
    (( ssd_gb = ssd_gb < 4096 ? ssd_gb : 4096 ))
    
    echo "${cpu_cores},${ram_gb},${ssd_gb}"
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    
    # Подавление диалогов
    sudo mkdir -p /etc/needrestart/conf.d
    echo -e "\$nrconf{restart} = 'a';\n\$nrconf{kernelhints} = 0;" | sudo tee /etc/needrestart/conf.d/99-disable.conf >/dev/null
    sudo apt-get purge -y unattended-upgrades

    # Установка
    sudo apt-get update -y && sudo apt-get install -yq \
        curl docker.io jq screen cgroup-tools

    # Настройка Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER
    newgrp docker

    # Сервис автозапуска
    sudo tee /etc/systemd/system/titan-node.service >/dev/null <<EOF
[Unit]
Description=Titan Node Service
After=docker.service

[Service]
ExecStart=/usr/bin/screen -dmS titan_nodes /bin/bash $0 --auto-start
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    echo -e "${GREEN}[✓] Система готова!${NC}"
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
    read -p "Введите количество нод: " node_count
    for ((i=1; i<=$node_count; i++)); do
        while true; do
            read -p "Введите ключ для ноды $i: " key
            if [[ $key =~ ^[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}$ ]]; then
                create_node $i "$key" && break
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

    # Проверка активности Docker
    if ! systemctl is-active docker &>/dev/null; then
        echo -e "${GREEN}[✓] Docker не активен, пропускаем удаление контейнеров/томов${NC}"
    else
        # Контейнеры
        echo -e "${ORANGE}[*] Поиск контейнеров...${NC}"
        containers=$(docker ps -aq --filter "name=titan_node" 2>/dev/null)
        
        if [ -n "$containers" ]; then
            echo -e "${ORANGE}[*] Остановка контейнеров...${NC}"
            docker stop $containers 2>/dev/null || true
            sleep 3
            
            echo -e "${ORANGE}[*] Удаление контейнеров...${NC}"
            docker rm $containers 2>/dev/null || true
            sleep 1
        else
            echo -e "${GREEN}[✓] Активные контейнеры не найдены${NC}"
        fi

        # Тома данных
        echo -e "${ORANGE}[*] Поиск томов...${NC}"
        volumes=$(docker volume ls -q --filter "name=titan_data" 2>/dev/null)
        
        if [ -n "$volumes" ]; then
            echo -e "${ORANGE}[*] Удаление томов...${NC}"
            docker volume rm $volumes 2>/dev/null || true
            sleep 2
        else
            echo -e "${GREEN}[✓] Тома данных не найдены${NC}"
        fi
    fi

    # Сеть
    echo -e "${ORANGE}[*] Восстановление сети...${NC}"
    for ip in $(seq 1 50); do
        node_ip=$(echo "$BASE_IP" | awk -F. -v i="$ip" '{OFS="."; $4+=i; print}')
        sudo ip addr del $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null || true
    done
    sleep 1

    # Сервис
    echo -e "${ORANGE}[*] Проверка сервиса...${NC}"
    if systemctl is-enabled titan-node.service &>/dev/null; then
        echo -e "${ORANGE}[*] Отключение сервиса...${NC}"
        sudo systemctl stop titan-node.service 2>/dev/null || true
        sudo systemctl disable titan-node.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/titan-node.service 2>/dev/null || true
        sudo systemctl daemon-reload 2>/dev/null || true
        sleep 2
    else
        echo -e "${GREEN}[✓] Сервис не активен${NC}"
    fi

    # Проверка
    echo -e "${ORANGE}[*] Финальная проверка...${NC}"
    containers=0
    volumes=0
    
    if systemctl is-active docker &>/dev/null; then
        containers=$(docker ps -aq --filter "name=titan_node" 2>/dev/null | wc -l)
        volumes=$(docker volume ls -q --filter "name=titan_data" 2>/dev/null | wc -l)
    fi
    
    if [ $containers -eq 0 ] && [ $volumes -eq 0 ]; then
        echo -e "${GREEN}\n[✓] ВСЕ КОМПОНЕНТЫ УДАЛЕНЫ!${NC}"
    else
        echo -e "${RED}\n[✗] Обнаружены остатки:"
        [ $containers -gt 0 ] && docker ps -a --filter "name=titan_node" 2>/dev/null || true
        [ $volumes -gt 0 ] && docker volume ls --filter "name=titan_data" 2>/dev/null || true
        echo -e "${NC}"
    fi

    echo -e "\n${ORANGE}[*] Возврат в меню через 5 секунд...${NC}"
    sleep 5
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
