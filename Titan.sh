
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
   # ✅ Отключаем режим отладки после установки
    set +x
    echo -e "${ORANGE}[1/7] Инициализация системы...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a  

    # === 1️⃣ Запрос SOCKS5-прокси (САМОЕ ПЕРВОЕ, до всего) ===
    while true; do
        echo -ne "${ORANGE}Введите SOCKS5-прокси (формат: host:port:user:pass): ${NC}"
        read PROXY_INPUT

        if [[ -z "$PROXY_INPUT" ]]; then
            echo -e "${RED}[!] Ошибка: Ввод не должен быть пустым. Попробуйте снова.${NC}"
            continue
        fi

        IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_INPUT"

        if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" || -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
            echo -e "${RED}[!] Ошибка: Неверный формат! Пример: 1.2.3.4:1080:user:pass${NC}"
            continue
        fi

        echo -e "${GREEN}[*] Проверяем прокси: socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}${NC}"
        PROXY_TEST=$(curl --proxy "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" -s --connect-timeout 5 https://api.ipify.org)

        if [[ -n "$PROXY_TEST" ]]; then
            echo -e "${GREEN}[✓] Прокси успешно подключен! IP: $PROXY_TEST${NC}"
            break
        else
            echo -e "${RED}[✗] Прокси не работает! Попробуйте другой прокси.${NC}"
        fi
    done

    # ✅ Сохраняем прокси
    echo "$PROXY_HOST:$PROXY_PORT:$PROXY_USER:$PROXY_PASS" > /root/proxy_config.txt
    chmod 600 /root/proxy_config.txt

    # === 2️⃣ Настройка NAT (идёт сразу после запроса прокси) ===
    echo -e "${ORANGE}[1.1/7] Настройка NAT ${NC}"
    if iptables -t nat -L -n | grep -q "MASQUERADE"; then
        echo -e "${GREEN}[✓] NAT уже настроен.${NC}"
    else
        echo -e "${ORANGE}[*] Включение NAT-маскарадинга...${NC}"
        sudo iptables -t nat -A POSTROUTING -o "$(ip route | grep default | awk '{print $5}')" -j MASQUERADE
        sudo netfilter-persistent save >/dev/null 2>&1
        echo -e "${GREEN}[✓] NAT-маскарадинг включен.${NC}"
    fi

    # === 3️⃣ Установка необходимых пакетов ===
    sudo apt-get update -yq && sudo apt-get upgrade -yq
    echo -e "${ORANGE}[2/7] Установка пакетов...${NC}"
    sudo apt-get install -yq \
        apt-transport-https ca-certificates curl gnupg lsb-release jq \
        screen cgroup-tools net-tools ccze netcat iptables-persistent bc \
        ufw git build-essential proxychains4 needrestart debconf-utils

    echo -e "${ORANGE}[2.3/7] Установка Docker...${NC}"
    sudo apt-get install -yq docker-ce docker-ce-cli containerd.io
    sudo systemctl start docker
    sudo systemctl enable docker
    echo -e "${GREEN}[✓] Docker установлен и работает!${NC}"

    # === 4️⃣ Извлечение Titan Edge из контейнера ===
    echo -e "${ORANGE}[2.5/7] Извлечение Titan Edge из контейнера...${NC}"
    CONTAINER_ID=$(docker create nezha123/titan-edge)
    if [[ -z "$CONTAINER_ID" ]]; then
        echo -e "${RED}[!] Ошибка: не удалось создать контейнер для извлечения Titan Edge!${NC}"
        exit 1
    fi
    echo -e "${GREEN}[*] Создан временный контейнер с ID: ${CONTAINER_ID}${NC}"

    docker cp "$CONTAINER_ID":/usr/bin/titan-edge ./titan-edge
    docker cp "$CONTAINER_ID":/usr/lib/libgoworkerd.so ./libgoworkerd.so

    if [[ ! -f "./titan-edge" || ! -f "./libgoworkerd.so" ]]; then
        echo -e "${RED}[!] Ошибка: Не удалось скопировать titan-edge или libgoworkerd.so!${NC}"
        docker rm -f "$CONTAINER_ID"
        exit 1
    fi

    chmod +x ./titan-edge
    chmod 755 ./libgoworkerd.so

    docker rm -f "$CONTAINER_ID"
    echo -e "${GREEN}[✓] Titan Edge и библиотека успешно извлечены!${NC}"

    # ✅ Запускаем настройку proxychains4 и сборку контейнера
    setup_proxychains_and_build
}

###############################################################################
# (2) Генерация IP, портов, CPU/RAM/SSD
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
# (3) Настройка proxychains4 и создание кастомного контейнера
###############################################################################
setup_proxychains_and_build() {
    echo -e "${ORANGE}[3/7] Настройка proxychains4 и создание кастомного контейнера...${NC}"

    # Читаем сохраненный прокси из файла
    if [ -f "/root/proxy_config.txt" ]; then
        IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS < /root/proxy_config.txt
    else
        echo -e "${RED}[!] Ошибка: Файл с настройками прокси не найден!${NC}"
        exit 1
    fi

    # Удаляем старый proxychains4 и конфигурацию без подтверждения
    echo -e "${ORANGE}[*] Удаляем старую версию proxychains4...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y proxychains4 libproxychains4
    sudo rm -f /etc/proxychains4.conf
    sudo apt-get autoremove -y
    sudo apt-get clean

    # ✅ Создаём конфигурацию proxychains4
    echo -e "${GREEN}[✓] Записываем конфигурацию proxychains4...${NC}"
    sudo tee /etc/proxychains4.conf > /dev/null <<EOL
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS
EOL

    cp /etc/proxychains4.conf ./proxychains4.conf

    if [ ! -f "./proxychains4.conf" ]; then
        echo -e "${RED}[!] Ошибка: proxychains4.conf не скопировался в текущую директорию!${NC}"
        exit 1
    fi

    echo -e "${GREEN}[✓] Proxychains4 настроен и скопирован в текущую директорию!${NC}"

    # ✅ Проверяем, что `titan-edge` и `libgoworkerd.so` существуют перед сборкой
    if [[ ! -f "./titan-edge" || ! -f "./libgoworkerd.so" ]]; then
        echo -e "${RED}[!] Ошибка: titan-edge или libgoworkerd.so отсутствуют!${NC}"
        exit 1
    fi

    # ✅ Генерируем Dockerfile
    echo -e "${ORANGE}[*] Генерируем Dockerfile...${NC}"
    sudo tee Dockerfile > /dev/null <<EOF
FROM ubuntu:22.04

# ✅ Копируем бинарники Titan и конфиг proxychains4
COPY titan-edge /usr/bin/titan-edge
COPY libgoworkerd.so /usr/lib/libgoworkerd.so
COPY proxychains4.conf /etc/proxychains4.conf

WORKDIR /root/

# ✅ Убираем подтверждения debconf перед установкой proxychains4
RUN export DEBIAN_FRONTEND=noninteractive && \
    echo "proxychains4	proxychains4/conf_mode	boolean false" | debconf-set-selections && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    libssl3 ca-certificates proxychains4 curl tzdata iptables \
    net-tools iproute2 iptables-persistent apt-utils && \
    rm -rf /var/lib/apt/lists/*

# ✅ Настраиваем NAT (iptables) внутри контейнера
RUN iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE && \
    iptables-save > /etc/iptables.rules

# ✅ Автозагрузка NAT при запуске контейнера
RUN echo '#!/bin/sh' > /etc/init.d/iptables-restore && \
    echo 'iptables-restore < /etc/iptables.rules' >> /etc/init.d/iptables-restore && \
    chmod +x /etc/init.d/iptables-restore && \
    update-rc.d iptables-restore defaults

# ✅ Делаем файлы исполняемыми
RUN chmod +x /usr/bin/titan-edge

# ✅ Контейнер остаётся активным
CMD [ "tail", "-f", "/dev/null" ]
EOF

    # ✅ Собираем кастомный контейнер
    echo -e "${ORANGE}[*] Собираем кастомный Docker-контейнер...${NC}"
    docker build -t mytitan/proxy-titan-edge .

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[!] Ошибка: Не удалось собрать контейнер!${NC}"
        exit 1
    fi

    echo -e "${GREEN}[✓] Кастомный контейнер собран успешно!${NC}"
}

###############################################################################
# (4) Создание/запуск ноды
###############################################################################
setup_nodes() {
    echo -e "${ORANGE}[*] Укажите количество нод, которые хотите создать:${NC}"
    while true; do
        read -p "Сколько нод создать? (1-100): " NODE_COUNT
        [[ "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}[!] Введите число больше 0!${NC}"
    done

    for ((i=1; i<=NODE_COUNT; i++)); do
        echo -e "${ORANGE}[*] Введите SOCKS5-прокси для ноды $i (формат: host:port:user:pass):${NC}"
        while true; do
            read -p "Прокси для ноды $i: " PROXY_INPUT
            IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_INPUT"

            if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" || -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
                echo -e "${RED}[!] Некорректный формат! Пример: 1.2.3.4:1080:user:pass${NC}"
                continue
            fi

            echo -e "${ORANGE}[*] Проверка доступности прокси...${NC}"
            PROXY_TEST=$(curl --proxy "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" -s --connect-timeout 5 https://api.ipify.org)

            if [[ -n "$PROXY_TEST" ]]; then
                echo -e "${GREEN}[✓] Прокси успешно подключен! IP: $PROXY_TEST${NC}"
                break  # ✅ Выход из цикла после успешной проверки
            else
                echo -e "${RED}[✗] Прокси не работает!${NC}"
                curl --proxy "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" -v --connect-timeout 5 https://api.ipify.org
                echo -e "${RED}[!] Попробуйте ввести другой прокси.${NC}"
            fi
        done

        # ✅ Добавляем отладочный вывод перед вызовом create_node()
        echo -e "${ORANGE}[*] Запуск create_node для ноды $i...${NC}"
        create_node "$i" "$PROXY_HOST" "$PROXY_PORT" "$PROXY_USER" "$PROXY_PASS"
        
        # ✅ Проверка, не завис ли скрипт после вызова create_node()
        echo -e "${GREEN}[✓] Нода $i успешно обработана!${NC}"
    done

    echo -e "${GREEN}[✓] Все ноды обработаны!${NC}"
}

###############################################################################
# (5) Запуск контейнера с учетом спуфинга
###############################################################################
create_node() {
    local idx="$1"
    local proxy_host="$2"
    local proxy_port="$3"
    local proxy_user="$4"
    local proxy_pass="$5"

    # Генерация случайных параметров для спуфинга (CPU, RAM, SSD)
    local cpu_options=(12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46)
    local ram_options=(32 64 96 128 160 192 224 256 320 384 448 512)
    local ssd_options=(512 1024 1536 2048 2560 3072 3584 4096)

    # Выбираем случайные значения с логическими ограничениями
    local cpu_val=${cpu_options[$RANDOM % ${#cpu_options[@]}]}
    local ram_val=32
    local ssd_val=512

    while true; do
        ram_val=${ram_options[$RANDOM % ${#ram_options[@]}]}
        ssd_val=${ssd_options[$RANDOM % ${#ssd_options[@]}]}

        # ✅ Проверка: разумное соотношение CPU/RAM
        if ((cpu_val <= 16 && ram_val >= 64)) || ((cpu_val >= 36 && ram_val >= 128)) || ((cpu_val >= 44 && ram_val >= 192)); then
            break
        fi
    done

    echo -e "${ORANGE}[*] Запуск контейнера titan_node_$idx (порт $((30000 + idx)), CPU=${cpu_val}, RAM=${ram_val}GB, SSD=${ssd_val}GB)...${NC}"

    # ✅ Запускаем контейнер с NAT, правами NET_ADMIN и proxychains
    CONTAINER_ID=$(docker run -d \
        --name "titan_node_$idx" \
        --restart unless-stopped \
        --cap-add=NET_ADMIN \  # ⚡ Даем контейнеру права на изменение сети
        --network host \  # ⚡ Используем NAT-хост
        --cpu-quota=$((cpu_val * 100000)) \
        --memory="${ram_val}g" \
        -v /etc/proxychains4.conf:/etc/proxychains4.conf:ro \
        -e ALL_PROXY="socks5://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}" \
        mytitan/proxy-titan-edge)

    if [[ -z "$CONTAINER_ID" ]]; then
        echo -e "${RED}[✗] Ошибка запуска контейнера titan_node_$idx${NC}"
        return 1
    fi

    # ✅ Включаем NAT в контейнере
    echo -e "${ORANGE}[*] Настраиваем NAT в контейнере titan_node_$idx...${NC}"
    docker exec "$CONTAINER_ID" bash -c "
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE && \
        netfilter-persistent save
    "

    # ✅ Проверяем, видит ли контейнер внешний IP через прокси
    echo -e "${ORANGE}[*] Проверяем IP внутри контейнера через proxychains4...${NC}"
    IP_CHECK=$(docker exec "$CONTAINER_ID" proxychains4 curl -s --connect-timeout 5 https://api.ipify.org)

    if [[ -n "$IP_CHECK" ]]; then
        echo -e "${GREEN}[✓] Контейнер titan_node_$idx видит IP через прокси: $IP_CHECK${NC}"
    else
        echo -e "${RED}[✗] Ошибка: контейнер titan_node_$idx не видит внешний IP через прокси!${NC}"
        docker logs "$CONTAINER_ID"
        return 1
    fi

    echo -e "${GREEN}[✓] Контейнер titan_node_$idx запущен! ID: $CONTAINER_ID${NC}"
}

###############################################################################
# (6) Проверка статуса
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
# (7) Логи (последние 5 строк) всех нод
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
# (8) Перезапуск, Очистка, автозапуск
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

    echo -e "${ORANGE}[3/6] Полное удаление данных Titan...${NC}"
    sudo rm -rf /root/.titanedge
    sudo rm -rf /var/lib/docker/volumes/titan_data_*

    echo -e "${ORANGE}[4/6] Удаление Docker...${NC}"
    sudo apt-get purge -yq docker-ce docker-ce-cli containerd.io
    sudo apt-get autoremove -yq
    sudo rm -rf /var/lib/docker /etc/docker

    echo -e "${ORANGE}[5/6] Очистка screen...${NC}"
    screen -ls | grep "node_" | awk -F. '{print $1}' | xargs -r -I{} screen -X -S {} quit

    echo -e "${ORANGE}[6/6] Восстановление сети...${NC}"
    while IFS='|' read -r idx code mac hport fip stamp pxy hwdata; do
        sudo ip addr del "$fip/24" dev "$NETWORK_INTERFACE" 2>/dev/null
    done < "$CONFIG_FILE"
    sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo netfilter-persistent save >/dev/null 2>&1

    echo -e "${ORANGE}[+] Удаляем $CONFIG_FILE ...${NC}"
    sudo rm -f "$CONFIG_FILE"

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
                7) exit 0 ;;  # ✅ Теперь последний пункт — выход
                *)
                    echo -e "${RED}Неверный выбор!${NC}"
                    sleep 1
                ;;
            esac
        done
        ;;
esac
