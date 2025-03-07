#!/bin/bash
################################################################################
# TITAN BLOCKCHAIN NODE FINAL INSTALLATION SCRIPT
# Изменения:
#   1) Меню 3 (Проверить статус) теперь выводит короткие (5 строк) логи
#   2) Bind через временный контейнер docker run --rm ... bind
#   3) Запрещены дубли прокси и ключей
#   4) Реальный статус через titan-edge info, а не «фейковый ALIVE»
################################################################################

############### 1. Глобальные переменные и цвета ###############
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

############### 2. Отрисовка логотипа, меню, прогресс ###############
show_logo() {
    local logo
    logo=$(curl -sSf "$LOGO_URL" 2>/dev/null | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')
    if [[ -z "$logo" ]]; then
        echo "=== TITAN NODE MANAGER v22 ==="
    else
        echo "$logo"
    fi
}

show_menu() {
    clear
    tput setaf 3
    show_logo
    echo -e "1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    tput sgr0
}

progress_step() {
    local step=$1
    local total=$2
    local message=$3
    echo -e "${ORANGE}[${step}/${total}] ${message}...${NC}"
}

############### 3. Установка зависимостей ###############
install_dependencies() {
    progress_step 1 5 "Инициализация системы"
    export DEBIAN_FRONTEND=noninteractive

    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections"
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections"

    sudo apt-get update -yq && sudo apt-get upgrade -yq

    progress_step 2 5 "Установка пакетов"
    sudo apt-get install -yq \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        jq screen cgroup-tools net-tools ccze netcat iptables-persistent bc \
        ufw

    progress_step 3 5 "Настройка брандмауэра"
    sudo ufw allow 30000:40000/udp
    sudo ufw reload

    progress_step 4 5 "Установка Docker"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update -yq && sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

    progress_step 5 5 "Установка завершена"
    echo -e "${GREEN}[✓] Система готова!${NC}"
    sleep 1
}

############### 4. Генерация IP, портов, профилей ###############
generate_country_ip() {
    local first_octet=164
    local second_octet=138
    local third_octet=10
    local fourth_octet=$(shuf -i 2-254 -n1)
    echo "${first_octet}.${second_octet}.${third_octet}.${fourth_octet}"
}

generate_random_port() {
    while true; do
        port=$(shuf -i 30000-40000 -n1)
        [[ ! -v USED_PORTS[$port] ]] && ! ss -uln | grep -q ":${port} " && break
    done
    USED_PORTS[$port]=1
    echo "$port"
}

generate_fake_mac() {
    printf "02:%02x:%02x:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

generate_realistic_profile() {
    local cpu_values=(8 10 12 14 16 18 20 22 24 26 28 30 32)
    local cpu=${cpu_values[$RANDOM % ${#cpu_values[@]}]}
    local ram=$((32 + (RANDOM % 16) * 32))
    local ssd=$((512 + (RANDOM % 20) * 512))
    echo "$cpu,$ram,$ssd"
}

############### 5. Проверка прокси ###############
check_proxy() {
    local proxy_host=$1
    local proxy_port=$2
    local proxy_user=$3
    local proxy_pass=$4

    local output
    output=$(curl -m 5 -s --proxy "http://${proxy_host}:${proxy_port}" --proxy-user "${proxy_user}:${proxy_pass}" https://api.ipify.org || echo "FAILED")
    if [[ "$output" == "FAILED" ]]; then
        return 1
    fi
    return 0
}

############### 6. Создание ноды: запуск + bind ###############
create_node() {
    local node_num="$1"
    local identity_code="$2"
    local proxy_host="$3"
    local proxy_port="$4"
    local proxy_user="$5"
    local proxy_pass="$6"

    IFS=',' read -r fake_cpu ram_gb ssd_gb <<< "$(generate_realistic_profile)"
    local volume="titan_data_$node_num"
    local node_ip=$(generate_country_ip)
    local mac=$(generate_fake_mac)

    local cpu_period=100000
    local cpu_quota=$((fake_cpu*cpu_period))

    local host_port
    host_port=$(generate_random_port)

    docker rm -f "titan_node_$node_num" 2>/dev/null
    docker volume create "$volume" >/dev/null || {
        echo -e "${RED}[✗] Ошибка создания тома $volume${NC}"
        return 1
    }

    # Пишем ключ
    echo "$identity_code" | docker run -i --rm -v "$volume:/data" busybox sh -c "cat > /data/identity.key" || {
        echo -e "${RED}[✗] Ошибка записи ключа${NC}"
        return 1
    }

    # Запускаем Titan Edge
    if ! docker run -d \
        --name "titan_node_$node_num" \
        --restart unless-stopped \
        --cpu-period="$cpu_period" \
        --cpu-quota="$cpu_quota" \
        --memory "${ram_gb}g" \
        --memory-swap "$((ram_gb * 2))g" \
        --mac-address "$mac" \
        -p "${host_port}:1234/udp" \
        -v "$volume:/root/.titanedge" \
        -e http_proxy="http://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}" \
        -e https_proxy="http://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}" \
        nezha123/titan-edge:latest
    then
        echo -e "${RED}[✗] Ошибка запуска контейнера${NC}"
        return 1
    fi

    # Спуф IP
    sudo ip addr add "${node_ip}/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    sudo iptables -t nat -A PREROUTING -i "$NETWORK_INTERFACE" -p udp --dport "$host_port" -j DNAT --to-destination "$node_ip:1234"
    sudo netfilter-persistent save >/dev/null 2>&1

    # Запись в конфиг
    echo "${node_num}|${identity_code}|${mac}|${host_port}|${node_ip}|$(date +%s)|${proxy_host}:${proxy_port}:${proxy_user}:${proxy_pass}|${fake_cpu},${ram_gb},${ssd_gb}" \
        >> "$CONFIG_FILE"

    echo -e "${ORANGE}Запущен titan_node_$node_num на порту ${host_port} (RAM=${ram_gb}G CPU=${fake_cpu}).${NC}"

    # Bind: отдельный временный контейнер
    # Документация: docker run --rm -it -v ~/.titanedge:/root/.titanedge nezha123/titan-edge bind --hash=... <URL>
    # Мы используем volume=...
    local BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding" # Пример
    echo -e "${ORANGE}[*] Bind ноды $node_num...${NC}"
    if ! docker run --rm \
        -v "$volume:/root/.titanedge" \
        nezha123/titan-edge:latest \
        bind --hash="$identity_code" "$BIND_URL"
    then
        echo -e "${RED}[✗] Ошибка bind (docker run).${NC}"
    else
        echo -e "${GREEN}[✓] Bind OK!${NC}"
    fi
}

############### 7. Авто-старт (--auto-start) ###############
auto_start_nodes() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Файл $CONFIG_FILE не найден, автозапуск невозможен!${NC}"
        exit 1
    fi

    while IFS='|' read -r node_num node_key mac host_port ip timestamp proxy_data hw_data; do
        [[ -z "$node_num" || -z "$node_key" ]] && continue
        local proxy_host proxy_port proxy_user proxy_pass
        IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$proxy_data"

        if docker ps --format '{{.Names}}' | grep -q "titan_node_$node_num"; then
            continue
        fi
        create_node "$node_num" "$node_key" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
    done < "$CONFIG_FILE"
}

############### 8. Меню ###############
setup_nodes() {
    local node_count
    while true; do
        read -p "Введите количество нод: " node_count
        [[ "$node_count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Ошибка: число > 0!${NC}"
    done

    for ((i=1; i<=node_count; i++)); do
        local proxyInput proxy_host proxy_port proxy_user proxy_pass
        while true; do
            echo -e "${ORANGE}Укажите прокси в формате: host:port:user:pass${NC}"
            read -p "Прокси для ноды $i: " proxyInput

            if [[ ${USED_PROXIES[$proxyInput]} ]]; then
                echo -e "${RED}Прокси уже используется!${NC}"
                continue
            fi

            IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$proxyInput"
            if [[ -z "$proxy_host" || -z "$proxy_port" || -z "$proxy_user" || -z "$proxy_pass" ]]; then
                echo -e "${RED}Неверный формат! Повторите ввод.${NC}"
                continue
            fi

            if check_proxy "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"; then
                echo -e "${GREEN}Прокси OK: $proxy_host:$proxy_port${NC}"
                USED_PROXIES[$proxyInput]=1
                break
            else
                echo -e "${RED}Прокси недоступно! Повторите ввод.${NC}"
            fi
        done

        while true; do
            read -p "Введите ключ (Identity Code) для ноды $i: " key
            local key_upper=${key^^}

            if [[ ${USED_KEYS[$key_upper]} ]]; then
                echo -e "${RED}Ключ уже используется!${NC}"
                continue
            fi

            if [[ $key_upper =~ ^[A-F0-9]{8}-[A-F0-9]{4}-4[A-F0-9]{3}-[89AB][A-F0-9]{3}-[A-F0-9]{12}$ ]]; then
                if create_node "$i" "$key_upper" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"; then
                    USED_KEYS[$key_upper]=1
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
}

check_status() {
    # Меню 3: для каждой ноды -> показываем real status + последние 5 строк логов
    clear
    printf "${ORANGE}%-20s | %-5s | %-15s | %s${NC}\n" \
           "Контейнер" "Порт" "IP" "Статус"

    while IFS='|' read -r node_num node_key mac host_port ip timestamp proxy_data hw_data; do
        local cname="titan_node_$node_num"

        # Выводим краткую строку
        if ! docker ps | grep -q "$cname"; then
            printf "%-20s | %-5s | %-15s | %b\n" \
                   "$cname" "$host_port" "$ip" "${RED}🔴 DEAD${NC}"
            # Логов нет
            echo -e "${ORANGE}Последние 5 строк логов:${NC}\n<нет, т.к. контейнер мёртв>\n---"
            continue
        fi

        # Контейнер жив => смотрим titan-edge info
        local state_out
        state_out=$(docker exec "$cname" titan-edge info 2>&1 || true)
        if echo "$state_out" | grep -qi "Node state: Running"; then
            printf "%-20s | %-5s | %-15s | %b\n" \
                   "$cname" "$host_port" "$ip" "${GREEN}🟢 ALIVE${NC}"
        else
            printf "%-20s | %-5s | %-15s | %b\n" \
                   "$cname" "$host_port" "$ip" "${RED}🔴 NOT_READY${NC}"
        fi

        # Логи (последние 5 строк)
        local logs
        logs=$(docker logs --tail 5 "$cname" 2>&1)
        echo -e "${ORANGE}Последние 5 строк логов:${NC}\n${logs}\n---"
    done < "$CONFIG_FILE"

    echo -e "\n${ORANGE}РЕСУРСЫ (docker stats):${NC}"
    docker stats --no-stream --format "{{.Name}}: {{.CPUPerc}} CPU / {{.MemUsage}}" | grep "titan_node" || true

    read -p $'\nНажмите любую клавишу...' -n1 -s
}

show_logs() {
    # Оставим пунк 4, если хотим ещё логи
    read -p "Введите номер ноды: " num
    echo -e "${ORANGE}Логи titan_node_${num}:${NC}"
    local logs
    logs=$(docker logs --tail 50 "titan_node_${num}" 2>&1)
    if command -v ccze &>/dev/null; then
        echo "$logs" | ccze -A
    else
        echo "$logs"
    fi
    read -p $'\nНажмите любую клавишу...' -n1 -s
}

restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r node_num node_key mac host_port ip timestamp proxy_data hw_data; do
            local proxy_host proxy_port proxy_user proxy_pass
            IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$proxy_data"
            create_node "$node_num" "$node_key" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
        done < "$CONFIG_FILE"
        echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    else
        echo -e "${RED}Конфигурация отсутствует!${NC}"
    fi
    sleep 2
}

cleanup() {
    echo -e "${ORANGE}\n[!] ПОЛНАЯ ОЧИСТКА [!]${NC}"
    echo -e "${ORANGE}[1/6] Удаление контейнеров...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f

    echo -e "${ORANGE}[2/6] Удаление томов...${NC}"
    docker volume ls -q --filter "name=titan_data" | xargs -r docker volume rm

    echo -e "${ORANGE}[3/6] Удаление Docker...${NC}"
    sudo apt-get purge -yq docker-ce docker-ce-cli containerd.io
    sudo apt-get autoremove -yq
    sudo rm -rf /var/lib/docker /etc/docker

    echo -e "${ORANGE}[4/6] Очистка screen...${NC}"
    screen -ls | grep "node_" | awk -F. '{print $1}' | xargs -r -I{} screen -X -S {} quit

    echo -e "${ORANGE}[5/6] Восстановление сети...${NC}"
    while IFS='|' read -r node_num node_key mac port ip timestamp proxy_data hw_data; do
        sudo ip addr del "$ip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done < "$CONFIG_FILE"
    sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo netfilter-persistent save >/dev/null 2>&1

    echo -e "${ORANGE}[+] Удаляем $CONFIG_FILE...${NC}"
    sudo rm -f "$CONFIG_FILE"

    echo -e "${ORANGE}[6/6] Очистка кэша...${NC}"
    sudo rm -rf /tmp/fake_* ~/.titanedge /var/cache/apt/archives/*.deb

    echo -e "\n${GREEN}[✓] Все следы удалены! Перезагрузите сервер.${NC}"
    sleep 3
}

############### 9. Systemd-юнит для автозапуска ###############
if [ ! -f /etc/systemd/system/titan-node.service ]; then
    sudo tee /etc/systemd/system/titan-node.service >/dev/null <<EOF
[Unit]
Description=Titan Node Service
After=network.target docker.service

[Service]
ExecStart=$(realpath "$0") --auto-start
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl enable titan-node.service >/dev/null 2>&1
fi

############### 10. Точка входа ###############
case $1 in
    --auto-start)
        auto_start_nodes
        ;;
    *)
        while true; do
            show_menu
            read -p "Выбор: " choice
            case $choice in
                1) install_dependencies ;;
                2)
                    if ! command -v docker &>/dev/null || [ ! -f "/usr/bin/jq" ]; then
                        echo -e "\n${RED}ОШИБКА: Сначала установите компоненты (пункт 1)!${NC}"
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
