#!/bin/bash
################################################################################
# TITAN BLOCKCHAIN NODE FINAL INSTALLATION SCRIPT
# (ProxyChains + Socks5 + Titan) using:
# - "docker pull nezha123/titan-edge" + docker cp titanextract:/usr/local/bin/titan-edge ...
# - Then build local image “mytitan/proxy-titan-edge”
################################################################################

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

###############################################################################
# (A) Логотип и меню
###############################################################################
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
    echo -e "1) Установить компоненты\n2) Создать/запустить ноды\n3) Проверить статус\n4) Показать логи\n5) Перезапустить\n6) Очистка\n7) Выход"
    tput sgr0
}

###############################################################################
# (1) Установка компонентов
###############################################################################
install_dependencies() {
    echo -e "${ORANGE}[1/7] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections"
    sudo bash -c "echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections"

    sudo apt-get update -yq && sudo apt-get upgrade -yq

    echo -e "${ORANGE}[2/7] Установка пакетов...${NC}"
    sudo apt-get install -yq \
      apt-transport-https ca-certificates curl gnupg lsb-release \
      jq screen cgroup-tools net-tools ccze netcat iptables-persistent bc \
      ufw git build-essential

    echo -e "${ORANGE}[3/7] Настройка брандмауэра...${NC}"
    sudo ufw allow 30000:40000/udp || true
    sudo ufw reload || true

    echo -e "${ORANGE}[4/7] Установка Docker...${NC}"
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update -yq
    sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

   echo -e "${ORANGE}[5/7] Извлечение libgoworkerd.so...${NC}"

# Проверяем, есть ли уже библиотека, чтобы не загружать лишний раз
if [ ! -f "./libgoworkerd.so" ]; then
    echo -e "${ORANGE}Извлекаем libgoworkerd.so из кастомного образа...${NC}"
    
    docker create --name temp_titan mytitan/proxy-titan-edge-custom
    docker cp temp_titan:/usr/lib/libgoworkerd.so ./libgoworkerd.so
    docker rm -f temp_titan

    if [ ! -f "./libgoworkerd.so" ]; then
        echo -e "${RED}Ошибка: libgoworkerd.so не найден!${NC}"
        exit 1
    fi
fi

echo -e "${ORANGE}[6/7] Сборка Docker-образа Titan+ProxyChains...${NC}"

# Создаём Dockerfile для кастомного образа
cat > Dockerfile.titan <<EOF
FROM docker.io/library/ubuntu:22.04

COPY libgoworkerd.so /usr/lib/libgoworkerd.so
COPY titan-edge /usr/local/bin/titan-edge

RUN ldconfig
RUN chmod +x /usr/local/bin/titan-edge && ln -s /usr/local/bin/titan-edge /usr/bin/titan-edge

# Определяем аргументы (передаются при docker build)
ARG proxy_host
ARG proxy_port
ARG proxy_user
ARG proxy_pass

# Передаем аргументы в переменные окружения
ENV PROXY_HOST=${proxy_host}
ENV PROXY_PORT=${proxy_port}
ENV PROXY_USER=${proxy_user}
ENV PROXY_PASS=${proxy_pass}

RUN apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y proxychains4 curl && \
    echo "strict_chain" > /etc/proxychains4.conf && \
    echo "proxy_dns" >> /etc/proxychains4.conf && \
    echo "tcp_read_time_out 15000" >> /etc/proxychains4.conf && \
    echo "tcp_connect_time_out 8000" >> /etc/proxychains4.conf && \
    echo "[ProxyList]" >> /etc/proxychains4.conf && \
    echo "socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS" >> /etc/proxychains4.conf
EOF

# Собираем кастомный образ
docker build -t mytitan/proxy-titan-edge-custom -f Dockerfile.titan . || {
    echo -e "${RED}[✗] Ошибка сборки Docker-образа!${NC}"
    exit 1
}

echo -e "${ORANGE}[6.5/7] Проверка наличия titan-edge...${NC}"

# Проверяем, есть ли бинарник titan-edge, если его нет — извлекаем
if [ ! -f "./titan-edge" ]; then
    echo -e "${ORANGE}Извлекаем titan-edge из кастомного образа...${NC}"
    
    docker create --name titanextract mytitan/proxy-titan-edge-custom
    docker cp titanextract:/usr/bin/titan-edge ./titan-edge
    docker rm -f titanextract

    if [ ! -f "./titan-edge" ]; then
        echo -e "${RED}Ошибка: Не удалось извлечь titan-edge!${NC}"
        exit 1
    fi
    chmod +x ./titan-edge
fi

echo -e "${ORANGE}[7/7] Завершение установки...${NC}"
echo -e "${GREEN}[✓] Titan + ProxyChains готово!${NC}"
sleep 2
}


###############################################################################
# (2) Генерация IP, порт, CPU/RAM/SSD
###############################################################################
generate_country_ip() {
    local first_oct=164
    local second_oct=138
    local third_oct=10
    local forth_oct=$(shuf -i 2-254 -n1)
    echo "${first_oct}.${second_oct}.${third_oct}.${forth_oct}"
}

generate_random_port() {
    while true; do
        local p=$(shuf -i 30000-40000 -n1)
        if ! ss -uln | grep -q ":$p "; then
            echo "$p"
            return
        fi
    done
}

generate_spoofer_profile() {
    local cpus=(8 10 12 14 16 18 20 22 24 26 28 30 32)
    local c=${cpus[$RANDOM % ${#cpus[@]}]}
    local ram=$((32 + (RANDOM % 16)*32))
    local ssd=$((512 + (RANDOM % 20)*512))
    echo "$c,$ram,$ssd"
}

generate_fake_mac() {
    printf "02:%02x:%02x:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

###############################################################################
# (3) Создание/запуск ноды
###############################################################################
create_node() {
    local idx="$1"
    local identity_code="$2"
    local proxy_host="$3"
    local proxy_port="$4"
    local proxy_user="$5"
    local proxy_pass="$6"

    IFS=',' read -r cpu_val ram_val ssd_val <<< "$(generate_spoofer_profile)"
    local host_port=$(generate_random_port)
    local node_ip=$(generate_country_ip)
    local mac=$(generate_fake_mac)

    local cpu_period=100000
    local cpu_quota=$((cpu_val*cpu_period))

    local volume="titan_data_$idx"
    docker rm -f "titan_node_$idx" 2>/dev/null
    docker volume create "$volume" >/dev/null
# Указываем пути к библиотекам перед запуском контейнера
export PATH=$PATH:/usr/local/titan
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib

echo -e "${ORANGE}Запуск titan_node_$idx (CPU=$cpu_val, RAM=${ram_val}G), порт=$host_port${NC}"
if ! docker run -d \
    --name "titan_node_$idx" \
    --restart unless-stopped \
    --cpu-period="$cpu_period" \
    --cpu-quota="$cpu_quota" \
    --memory="${ram_val}g" \
    --memory-swap="$((ram_val * 2))g" \
    --mac-address="$mac" \
    -p "${host_port}:1234/udp" \
    -v "$volume:/root/.titanedge" \
    -e ALL_PROXY="socks5://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}" \
    -e PRELOAD_PROXYCHAINS=1 \
    -e PROXYCHAINS_CONF_PATH="/etc/proxychains4.conf" \
    mytitan/proxy-titan-edge-custom \
   bash -c "export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libproxychains.so.4 && proxychains4 /usr/bin/titan-edge daemon start --init --url=https://cassini-locator.titannet.io:5000/rpc/v0"
then
    echo -e "${RED}[✗] Ошибка запуска контейнера titan_node_$idx${NC}"
    return 1
fi

    sudo ip addr add "${node_ip}/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    sudo iptables -t nat -A PREROUTING -p udp --dport "$host_port" -j DNAT --to-destination "$node_ip:1234"
    sudo netfilter-persistent save >/dev/null 2>&1

    echo "${idx}|${identity_code}|${mac}|${host_port}|${node_ip}|$(date +%s)|${proxy_host}:${proxy_port}:${proxy_user}:${proxy_pass}|${cpu_val},${ram_val},${ssd_val}" \
      >> "$CONFIG_FILE"

    echo -e "${ORANGE}Спуф IP: $node_ip -> порт $host_port${NC}"
    echo -e "${ORANGE}[*] Bind ноды $idx (--hash=${identity_code})...${NC}"

    # Подождём 10s
    sleep 10

        echo -e "${ORANGE}[*] Ожидание запуска контейнера titan_node_$idx...${NC}"
    sleep 15  # Даем время контейнеру запуститься

    local BIND_URL="https://api-test1.container1.titannet.io/api/v2/device/binding"

    if docker exec -it "titan_node_$idx" bash -c "export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libproxychains.so.4 && proxychains4 /usr/bin/titan-edge bind --hash=$identity_code https://api-test1.container1.titannet.io/api/v2/device/binding"; then
    echo -e "${GREEN}[✓] Bind OK для ноды $idx${NC}"
else
    echo -e "${RED}[✗] Bind ошибка. Возможно, ключ не создан или identity неверен${NC}"
    echo -e "${RED}Проверяем логи контейнера...${NC}"
    docker logs --tail 10 "titan_node_$idx"
fi


}

setup_nodes() {
    local node_count
    while true; do
        read -p "Сколько нод создать: " node_count
        [[ "$node_count" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}Введите число > 0!${NC}"
    done

    for ((i=1; i<=node_count; i++)); do
        local px
        while true; do
            echo -e "${ORANGE}Укажите SOCKS5 (host:port:user:pass) для ноды $i:${NC}"
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
            echo -e "${GREEN}Socks5 OK: $phost:$pport${NC}"
            USED_PROXIES[$px]=1
            break
        done

        local key
        while true; do
            read -p "Identity Code (UUIDv4) для ноды $i: " key
            local upkey=${key^^}
            if [[ -z "$upkey" ]]; then
                echo -e "${RED}Введите ключ!${NC}"
                continue
            fi
            if [[ ${USED_KEYS[$upkey]} ]]; then
                echo -e "${RED}Ключ уже используется!${NC}"
                continue
            fi
            if [[ $upkey =~ ^[A-F0-9]{8}-[A-F0-9]{4}-4[A-F0-9]{3}-[89AB][A-F0-9]{3}-[A-F0-9]{12}$ ]]; then
                USED_KEYS[$upkey]=1
                create_node "$i" "$upkey" "$phost" "$pport" "$puser" "$ppass"
                break
            else
                echo -e "${RED}Неверный формат UUIDv4!${NC}"
            fi
        done
    done

    echo -e "${GREEN}\nСоздано нод: ${node_count}${NC}"
    read -p $'\nНажмите любую клавишу...' -n1 -s
}

###############################################################################
# (4) Проверка статуса
###############################################################################
check_status() {
    clear
    printf "${ORANGE}%-15s | %-5s | %-15s | %-25s | %s${NC}\n" \
           "Контейнер" "Port" "IP" "Спуф (CPU/RAM/SSD)" "Status"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет $CONFIG_FILE, ноды не создавались?${NC}"
        read -p $'\nНажмите любую клавишу...' -n1 -s
        return
    fi

    while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
        local cname="titan_node_$idx"
        if ! docker ps | grep -q "$cname"; then
            printf "%-15s | %-5s | %-15s | %-25s | %b\n" \
                   "$cname" "$hport" "$fip" "-" "${RED}🔴 DEAD${NC}"
            continue
        fi
        local info
        info=$(docker exec "$cname" proxychains4 /usr/bin/titan-edge info 2>/dev/null || true)
        local st
        if echo "$info" | grep -iq "Edge registered successfully"; then
            st="${GREEN}🟢 ALIVE${NC}"
        else
            st="${RED}🔴 NOT_READY${NC}"
        fi
        IFS=',' read -r cpuv ramv ssdv <<< "$hwdata"
        local spoofer="${cpuv} CPU / ${ramv}GB / ${ssdv}GB"
        printf "%-15s | %-5s | %-15s | %-25s | %b\n" \
               "$cname" "$hport" "$fip" "$spoofer" "$st"
    done < "$CONFIG_FILE"

    echo -e "\n${ORANGE}RESOURCES (docker stats):${NC}"
    docker stats --no-stream --format "{{.Name}}: {{.CPUPerc}} / {{.MemUsage}}" | grep titan_node || true

    read -p $'\nНажмите любую клавишу...' -n1 -s
}

###############################################################################
# (5) Логи (последние 5 строк) всех нод
###############################################################################
show_logs() {
    clear
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Нет $CONFIG_FILE, ноды не создавались?${NC}"
        read -p $'\nНажмите любую клавишу...' -n1 -s
        return
    fi

    while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
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

###############################################################################
# (6) Перезапуск, Очистка, автозапуск
###############################################################################
restart_nodes() {
    echo -e "${ORANGE}[*] Перезапуск нод...${NC}"
    docker ps -aq --filter "name=titan_node" | xargs -r docker rm -f

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
            local proxy_host proxy_port proxy_user proxy_pass
            IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$pxy"
            create_node "$idx" "$code" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
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
    while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
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
ExecStart=/bin/bash -c 'curl -sSL https://raw.githubusercontent.com/ProNodeRunner/TitanSpoof/main/Titan.sh | bash -s -- --auto-start'
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
    while IFS='|' read -r idx code mac hport fip stamp pxy hw; do
        local proxy_host proxy_port proxy_user proxy_pass
        IFS=':' read -r proxy_host proxy_port proxy_user proxy_pass <<< "$pxy"
        create_node "$idx" "$code" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass"
    done < "$CONFIG_FILE"
}

###############################################################################
# MAIN
###############################################################################
case "$1" in
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
