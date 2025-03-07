#!/bin/bash
################################################################################
# TITAN BLOCKCHAIN NODE FINAL INSTALLATION SCRIPT
# Изменения:
#   1) Установка (п.1) не требует подтверждения, iptables-persistent не ломает
#   2) Убрана "key import -content", Titan Edge генерирует ключ при запуске
#   3) Bind после запуска (docker exec ... bind --hash=IDENTITY)
#   4) Меню 3 -> реальный статус (titan-edge info) + CPU/RAM/SSD, без логов
#   5) Меню 4 -> последние 5 строк всех нод (или спрашивает, если хотите)
#   6) П.6 (Очистка) шаги 1/6,2/6,... сохранены, полностью чистит
################################################################################

############### 1. Глобальные переменные, цвета ###############
CONFIG_FILE="/etc/titan_nodes.conf"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"

ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# Для дублей
declare -A USED_KEYS=()
declare -A USED_PORTS=()
declare -A USED_PROXIES=()

############### 2. Логотип и меню ###############
show_logo() {
    local raw
    raw=$(curl -sSf "$LOGO_URL" 2>/dev/null | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')
    if [[ -z "$raw" ]]; then
        echo "=== TITAN NODE MANAGER v22 ==="
    else
        echo "$raw"
    fi
}

show_menu() {
    clear
    tput setaf 3
    show_logo
    echo -e "1) Установить компоненты\n2) Создать ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    tput sgr0
}

############### 3. Установка ###############
install_dependencies() {
    echo -e "${ORANGE}[1/5] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections"
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections"

    sudo apt-get update -yq && sudo apt-get upgrade -yq

    echo -e "${ORANGE}[2/5] Установка пакетов...${NC}"
    sudo apt-get install -yq \
        apt-transport-https ca-certificates curl gnupg lsb-release \
        jq screen cgroup-tools net-tools ccze netcat iptables-persistent bc \
        ufw

    echo -e "${ORANGE}[3/5] Настройка брандмауэра...${NC}"
    sudo ufw allow 30000:40000/udp
    sudo ufw reload

    echo -e "${ORANGE}[4/5] Установка Docker...${NC}"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
     | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update -yq
    sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

    echo -e "${ORANGE}[5/5] Завершение...${NC}"
    echo -e "${GREEN}[✓] Система готова!${NC}"
    sleep 1
}

############### 4. Генерация IP, портов ###############
random_port() {
    while true; do
        local p=$(shuf -i 30000-40000 -n1)
        if ! ss -uln | grep -q ":$p "; then
            echo "$p"
            return
        fi
    done
}
random_mac() {
    printf "02:%02x:%02x:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}
random_ip() {
    echo "164.138.10.$((2 + RANDOM % 253))"
}

############### 5. Спуфинг CPU/RAM/SSD ###############
generate_spoof_profile() {
    local cpus=(8 10 12 14 16 18 20 22 24 26 28 30 32)
    local c=${cpus[$RANDOM % ${#cpus[@]}]}
    local ram=$((32 + (RANDOM % 16) * 32))
    local ssd=$((512 + (RANDOM % 20) * 512))
    echo "$c,$ram,$ssd"
}

############### 6. Проверка прокси ###############
check_proxy() {
    local host="$1" port="$2" user="$3" pass="$4"
    local output
    output=$(curl -m 5 -s --proxy "http://${host}:${port}" --proxy-user "${user}:${pass}" https://api.ipify.org || echo "FAILED")
    if [[ "$output" == "FAILED" ]]; then
        return 1
    fi
    return 0
}

############### 7. Создание ноды + bind ###############
create_node() {
    local idx="$1"
    local identity="$2"
    local proxy_host="$3"
    local proxy_port="$4"
    local proxy_user="$5"
    local proxy_pass="$6"

    IFS=',' read -r fake_cpu ram_gb ssd_gb <<< "$(generate_spoof_profile)"
    local volume="titan_data_$idx"
    local node_ip=$(random_ip)
    local mac=$(random_mac)
    local host_port=$(random_port)

    local cpu_period=100000
    local cpu_quota=$((fake_cpu*cpu_period))

    # Удаляем/создаем volume
    docker rm -f "titan_node_$idx" 2>/dev/null
    docker volume create "$volume" >/dev/null

    echo -e "${ORANGE}Запуск titan_node_$idx -> Port=$host_port / CPU=$fake_cpu / RAM=${ram_gb}G${NC}"
    if ! docker run -d \
        --name "titan_node_$idx" \
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
        echo -e "${RED}[✗] Ошибка запуска контейнера titan_node_$idx${NC}"
        return 1
    fi

    # Спуф IP
    sudo ip addr add "${node_ip}/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    sudo iptables -t nat -A PREROUTING -p udp --dport "$host_port" -j DNAT --to-destination "$node_ip:1234"
    sudo netfilter-persistent save >/dev/null 2>&1

    # Запись в конфиг (номер|ключ|MAC|порт|IP|время|прокси|CPU,RAM,SSD)
    local now=$(date +%s)
    echo "${idx}|${identity}|${mac}|${host_port}|${node_ip}|${now}|${proxy_host}:${proxy_port}:${proxy_user}:${proxy_pass}|${fake_cpu},${ram_gb},${ssd_gb}" \
        >> "$CONFIG_FILE"

    echo -e "${ORANGE}[*] Bind для ноды $idx (Identity=${identity})...${NC}"
    local BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"  # Пример
    # docker exec ...
    if ! docker exec "titan_node_$idx" titan-edge bind --hash="$identity" "$BIND_URL" 2>&1; then
        echo -e "${RED}[✗] Ошибка bind!${NC}"
    else
        echo -e "${GREEN}[✓] Bind OK для ноды $idx${NC}"
    fi
}

setup_nodes() {
    local node_count
    while true; do
        read -p "Сколько нод создать: " node_count
        [[ "$node_count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Введите число >0!${NC}"
    done

    for ((i=1; i<=node_count; i++)); do
        # Прокси
        local px
        while true; do
            echo -e "${ORANGE}Укажите прокси (host:port:user:pass) для ноды $i:${NC}"
            read -p "Прокси: " px
            if [[ -z "$px" ]]; then
                echo -e "${RED}Неверный формат!${NC}"
                continue
            fi
            if [[ ${USED_PROXIES[$px]} ]]; then
                echo -e "${RED}Прокси уже используется!${NC}"
                continue
            fi
            IFS=':' read -r phost pport puser ppass <<< "$px"
            if [[ -z "$phost" || -z "$pport" || -z "$puser" || -z "$ppass" ]]; then
                echo -e "${RED}Неверный формат!${NC}"
                continue
            fi
            # check_proxy optional
            echo -e "${GREEN}Прокси OK (не проверяем curl).${NC}"
            USED_PROXIES[$px]=1
            break
        done

        # Key
        local key
        while true; do
            read -p "Введите Identity Code (UUIDv4) для ноды $i: " key
            local key_up=${key^^}
            if [[ -z "$key_up" ]]; then
                echo -e "${RED}Введите ключ!${NC}"
                continue
            fi
            if [[ ${USED_KEYS[$key_up]} ]]; then
                echo -e "${RED}Ключ уже используется!${NC}"
                continue
            fi
            if [[ $key_up =~ ^[A-F0-9]{8}-[A-F0-9]{4}-4[A-F0-9]{3}-[89AB][A-F0-9]{3}-[A-F0-9]{12}$ ]]; then
                USED_KEYS[$key_up]=1
                create_node "$i" "$key_up" "$phost" "$pport" "$puser" "$ppass"
                break
            else
                echo -e "${RED}Неверный формат UUIDv4!${NC}"
            fi
        done
    done

    echo -e "${GREEN}\nСоздано нод: $node_count${NC}"
    read -p $'\nНажмите любую клавишу...' -n1 -s
}

############### 8. Меню 3 - Проверка статуса ###############
check_status() {
    clear
    printf "${ORANGE}%-15s | %-5s | %-15s | %-25s | %s${NC}\n" \
           "Контейнер" "Port" "IP" "Спуф (CPU/RAM/SSD)" "Статус"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет $CONFIG_FILE, ноды не создавались?${NC}"
        read -p $'\nНажмите любую клавишу...' -n1 -s
        return
    fi

    while IFS='|' read -r idx key mac hport ip ts pxy hw; do
        local cname="titan_node_$idx"
        # Контейнер жив?
        if ! docker ps | grep -q "$cname"; then
            printf "%-15s | %-5s | %-15s | %-25s | %b\n" \
                   "$cname" "$hport" "$ip" "-" "${RED}🔴 DEAD${NC}"
            continue
        fi
        # titan-edge info
        local info
        info=$(docker exec "$cname" titan-edge info 2>/dev/null || true)
        local st
        if echo "$info" | grep -iq "Node state: Running"; then
            st="${GREEN}🟢 ALIVE${NC}"
        else
            st="${RED}🔴 NOT_READY${NC}"
        fi
        IFS=',' read -r cpun ramn ssdn <<< "$hw"
        local spoofer="${cpun} CPU / ${ramn}GB / ${ssdn}GB"
        printf "%-15s | %-5s | %-15s | %-25s | %b\n" \
               "$cname" "$hport" "$ip" "$spoofer" "$st"
    done < "$CONFIG_FILE"

    echo -e "\n${ORANGE}РЕСУРСЫ (docker stats):${NC}"
    docker stats --no-stream --format "{{.Name}}: {{.CPUPerc}} / {{.MemUsage}}" | grep titan_node || true

    read -p $'\nНажмите любую клавишу...' -n1 -s
}

############### 9. Меню 4 - логи (5 строк) всех нод ###############
show_logs() {
    clear
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет конфига, ноды не создавались?${NC}"
        read -p $'\nНажмите любую клавишу...' -n1 -s
        return
    fi
    # Выведем 5 строк по каждой ноде
    while IFS='|' read -r idx key mac hport ip ts pxy hw; do
        local cname="titan_node_$idx"
        echo -e "\n=== Логи $cname (tail=5) ==="
        if docker ps | grep -q "$cname"; then
            docker logs --tail 5 "$cname" 2>&1
        else
            echo "(Контейнер не запущен)"
        fi
    done < "$CONFIG_FILE"
    read -p $'\nНажмите любую клавишу...' -n1 -s
}

############### 10. Перезапуск, Очистка, автозапуск ###############
restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r idx key mac hport ip ts pxy hw; do
            local proxy_host proxy_port proxy_user proxy_pass
            IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$pxy"
            create_node "$idx" "$key" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
        done < "$CONFIG_FILE"
        echo -e "${GREEN}[✓] Ноды перезапущены!${NC}"
    else
        echo -e "${RED}Нет конфигурации!${NC}"
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
    while IFS='|' read -r idx key mac hport fip ts pxy hw; do
        sudo ip addr del "$fip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done < "$CONFIG_FILE"
    sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo netfilter-persistent save >/dev/null 2>&1

    echo -e "${ORANGE}[+] Удаляем $CONFIG_FILE ...${NC}"
    sudo rm -f "$CONFIG_FILE"

    echo -e "${ORANGE}[6/6] Очистка кэша...${NC}"
    sudo rm -rf /tmp/fake_* ~/.titanedge /var/cache/apt/archives/*.deb

    echo -e "\n${GREEN}[✓] Все следы удалены! Перезагрузите сервер.${NC}"
    sleep 3
}

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

auto_start_nodes() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет $CONFIG_FILE, автозапуск невозможен!${NC}"
        exit 1
    fi
    while IFS='|' read -r idx key mac hport ip ts pxy hw; do
        local proxy_host proxy_port proxy_user proxy_pass
        IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$pxy"
        create_node "$idx" "$key" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
    done < "$CONFIG_FILE"
}

############### Точка входа ###############
case $1 in
    --auto-start)
        auto_start_nodes
        ;;
    *)
        while true; do
            show_menu
            read -p "Выбор: " CH
            case "$CH" in
                1) install_dependencies ;;
                2)
                    if ! command -v docker &>/dev/null || [ ! -f "/usr/bin/jq" ]; then
                        echo -e "\n${RED}Сначала установите компоненты (1)!${NC}"
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
