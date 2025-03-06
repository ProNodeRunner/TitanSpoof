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
DEPENDENCIES_INSTALLED=false

check_dependencies() {
    if command -v docker &>/dev/null && [ -f "/usr/bin/jq" ]; then
        DEPENDENCIES_INSTALLED=true
    else
        DEPENDENCIES_INSTALLED=false
    fi
}

show_menu() {
    clear
    echo -ne "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== TITAN NODE MANAGER v22 ==="
    check_dependencies
    echo -e "\n1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    
    if ! $DEPENDENCIES_INSTALLED; then
        echo -e "\n${RED}[!] Сначала установите компоненты (пункт 1)!${NC}"
    fi
    echo -ne "${NC}"
}

generate_random_port() {
    if [[ $1 -eq 1 ]]; then
        echo "1234"
        return
    fi

    while true; do
        port=$(shuf -i 30000-40000 -n1)
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

    if ! sudo apt-get update -yq || ! sudo apt-get upgrade -yq; then
        echo -e "${RED}[✗] Ошибка обновления пакетов!${NC}"
        return 1
    fi

    if ! sudo apt-get install -yq \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        jq screen cgroup-tools net-tools ccze netcat iptables-persistent; then
        echo -e "${RED}[✗] Ошибка установки базовых зависимостей!${NC}"
        return 1
    fi

    sudo ufw allow 1234/udp
    sudo ufw allow 30000:40000/udp
    sudo ufw reload

    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        echo -e "${RED}[✗] Ошибка добавления Docker GPG!${NC}"
        return 1
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    
    if ! sudo apt-get update -yq || ! sudo apt-get install -yq docker-ce docker-ce-cli containerd.io; then
        echo -e "${RED}[✗] Ошибка установки Docker!${NC}"
        return 1
    fi

    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    check_dependencies
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

setup_nodes() {
    check_dependencies
    if ! $DEPENDENCIES_INSTALLED; then
        echo -e "${RED}ОШИБКА: Сначала установите компоненты!${NC}"
        sleep 2
        return 1
    fi

    declare -A USED_KEYS=()
    
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
            elif [[ $key_upper =~ ^[A-F0-9]{8}-[A-F0-9]{4}-4[A-F0-9]{3}-[89AB][A-F0-9]{3}-[A-F0-9]{12}$ ]]; then
                USED_KEYS[$key_upper]=1
                if create_node "$i" "$key_upper"; then
                    break
                else
                    echo -e "${RED}Повторите ввод ключа для ноды $i${NC}"
                fi
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
    check_dependencies
    if ! $DEPENDENCIES_INSTALLED; then
        echo -e "${RED}ОШИБКА: Сначала установите компоненты!${NC}"
        sleep 2
        return 1
    fi

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
    echo -e "${ORANGE}\n[!] ПОЛНАЯ ОЧИСТКА [!]${NC}"
    
    # 1. Контейнеры
    echo -e "${ORANGE}[1/6] Удаление контейнеров...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f

    # 2. Тома
    echo -e "${ORANGE}[2/6] Удаление томов...${NC}"
    docker volume ls -q --filter "name=titan_data" | xargs -r docker volume rm

    # 3. Docker
    echo -e "${ORANGE}[3/6] Удаление Docker...${NC}"
    sudo apt-get purge -yq docker-ce docker-ce-cli containerd.io
    sudo apt-get autoremove -yq
    sudo rm -rf /var/lib/docker /etc/docker

    # 4. Screen
    echo -e "${ORANGE}[4/6] Очистка screen...${NC}"
    screen -ls | grep "node_" | awk -F. '{print $1}' | xargs -r -I{} screen -X -S {} quit

    # 5. Сеть
    echo -e "${ORANGE}[5/6] Восстановление сети...${NC}"
    for i in {1..50}; do
        node_ip="${BASE_IP%.*}.$(( ${BASE_IP##*.} + i ))"
        sudo ip addr del "$node_ip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done
    sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo netfilter-persistent save >/dev/null 2>&1

    # 6. Кэш
    echo -e "${ORANGE}[6/6] Очистка кэша...${NC}"
    sudo rm -rf /tmp/fake_* ~/.titanedge /var/cache/apt/archives/*.deb

    echo -e "\n${GREEN}[✓] Все следы удалены! Перезагрузите сервер.${NC}"
    sleep 3
    clear
}

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
            
            # Жёсткая блокировка пункта 2
            if [[ "$choice" == "2" ]]; then
                check_dependencies
                if ! $DEPENDENCIES_INSTALLED; then
                    echo -e "${RED}ОШИБКА: Сначала установите компоненты!${NC}"
                    sleep 2
                    continue
                fi
            fi

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
