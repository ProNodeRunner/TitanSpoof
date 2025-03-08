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
echo -e "\033[0;33m[1/3] Установка компонентов и подготовка системы...\033[0m"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Отключаем запросы на рестарт служб
sudo bash -c "echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections"
sudo systemctl stop unattended-upgrades
sudo systemctl disable unattended-upgrades || true

# Обновление системы и установка зависимостей
sudo apt-get update -yq && sudo apt-get upgrade -yq
sudo apt-get install -yq \
    apt-transport-https ca-certificates curl gnupg lsb-release jq \
    screen cgroup-tools net-tools ccze netcat iptables-persistent bc \
    ufw git build-essential proxychains4 needrestart \
    docker.io docker-compose nano wget htop unzip iputils-ping software-properties-common

# Настройка Docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER

echo -e "\033[0;32m[✓] Система подготовлена и компоненты установлены!\033[0m"

###############################################################################
# (2) Извлечение Titan Edge из контейнера
###############################################################################
echo -e "\033[0;33m[2/3] Извлечение Titan Edge из контейнера...\033[0m"

# Создаём временный контейнер для извлечения файлов
CONTAINER_ID=$(docker create nezha123/titan-edge)
echo -e "\033[0;32m[*] Создан временный контейнер с ID: $CONTAINER_ID\033[0m"

# Извлекаем файлы
docker cp "$CONTAINER_ID":/usr/bin/titan-edge ./titan-edge || \
docker cp "$CONTAINER_ID":/usr/local/bin/titan-edge ./titan-edge || \
docker cp "$CONTAINER_ID":/opt/titan-edge ./titan-edge || \
docker cp "$CONTAINER_ID":/root/titan-edge ./titan-edge || \
docker cp "$CONTAINER_ID":/bin/titan-edge ./titan-edge

docker cp "$CONTAINER_ID":/usr/lib/libgoworkerd.so ./libgoworkerd.so || \
docker cp "$CONTAINER_ID":/usr/local/lib/libgoworkerd.so ./libgoworkerd.so || \
docker cp "$CONTAINER_ID":/opt/libgoworkerd.so ./libgoworkerd.so || \
docker cp "$CONTAINER_ID":/root/libgoworkerd.so ./libgoworkerd.so || \
docker cp "$CONTAINER_ID":/lib/libgoworkerd.so ./libgoworkerd.so

# Проверяем, что файлы успешно извлечены
if [[ -f "titan-edge" && -f "libgoworkerd.so" ]]; then
    chmod +x ./titan-edge
    sudo mv ./libgoworkerd.so /usr/lib/
    sudo chmod 755 /usr/lib/libgoworkerd.so
    sudo ldconfig

    echo -e "\033[0;32m[✓] titan-edge и libgoworkerd.so успешно извлечены и зарегистрированы!\033[0m"
else
    echo -e "\033[0;31m[✗] Ошибка: Не удалось извлечь файлы из контейнера!\033[0m"
    exit 1
fi

# Удаляем временный контейнер
docker rm -f "$CONTAINER_ID"

echo -e "\033[0;32m[✓] Успешное извлечение бинарников!\033[0m"

###############################################################################
# (3) Настройка proxychains4 и создание кастомного контейнера
###############################################################################
echo -e "\033[0;33m[3/3] Настройка proxychains4 и создание кастомного контейнера...\033[0m"

# Спрашиваем, нужно ли использовать прокси
read -p "Хотите использовать SOCKS5-прокси? (y/n): " USE_PROXY
if [[ "$USE_PROXY" == "y" ]]; then
    echo -ne "\033[0;33mВведите SOCKS5-прокси (формат: host:port:user:pass): \033[0m"
    read PROXY_INPUT

    # Разбираем введённый прокси
    IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$PROXY_INPUT"

    if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" ]]; then
        echo -e "\033[0;31m[✗] Ошибка: Неправильный формат прокси!${NC}"
        exit 1
    fi

    # Создаём конфигурационный файл proxychains4
    cat > proxychains4.conf <<EOL
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS
EOL

    echo -e "\033[0;32m[✓] Proxychains4 настроен!${NC}"
fi

# Создаём Dockerfile для кастомного контейнера
cat <<EOF > Dockerfile
FROM ubuntu:22.04
COPY titan-edge /usr/bin/titan-edge
COPY libgoworkerd.so /usr/lib/libgoworkerd.so
WORKDIR /root/

# Устанавливаем зависимости
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    proxychains4 \
    && rm -rf /var/lib/apt/lists/*

# Если был указан прокси, добавляем его конфиг в контейнер
EOF

if [[ "$USE_PROXY" == "y" ]]; then
    echo "COPY proxychains4.conf /etc/proxychains4.conf" >> Dockerfile
fi

# Собираем кастомный контейнер
docker build -t custom-titan-edge .

echo -e "\033[0;32m[✓] Кастомный контейнер создан успешно! Запускаем...\033[0m"
docker run --rm -it --name custom_titan_edge custom-titan-edge

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
                break
            else
                echo -e "${RED}[✗] Прокси не работает!${NC}"
                curl --proxy "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" -v --connect-timeout 5 https://api.ipify.org
                echo -e "${RED}[!] Попробуйте ввести другой прокси.${NC}"
            fi
        done

        create_node "$i" "$PROXY_HOST" "$PROXY_PORT" "$PROXY_USER" "$PROXY_PASS"
    done
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

    # Генерация случайных параметров с учетом реалистичности
    local host_port=$((30000 + idx))
    local cpu_options=(12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46)
    local ram_options=(32 64 96 128 160 192 224 256 320 384 448 512)
    local ssd_options=(512 1024 1536 2048 2560 3072 3584 4096)

    # Выбираем случайные значения с фильтрацией
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

    echo -e "${ORANGE}[*] Запуск контейнера titan_node_$idx (порт $host_port, CPU=${cpu_val}, RAM=${ram_val}GB, SSD=${ssd_val}GB)...${NC}"

    CONTAINER_ID=$(docker run -d \
        --name "titan_node_$idx" \
        --restart unless-stopped \
        --cpu-quota=$((cpu_val * 100000)) \
        --memory="${ram_val}g" \
        -p "${host_port}:1234/udp" \
        -v /etc/proxychains4.conf:/etc/proxychains4.conf:ro \
        -e ALL_PROXY="socks5://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}" \
        mytitan/proxy-titan-edge-custom)

    if [ -z "$CONTAINER_ID" ]; then
        echo -e "${RED}[✗] Ошибка запуска контейнера titan_node_$idx${NC}"
        return 1
    fi

    # ✅ Копируем proxychains4.conf внутрь контейнера (если маунт не сработал)
    docker cp /etc/proxychains4.conf "$CONTAINER_ID":/etc/proxychains4.conf

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
                7) exit 0 ;;
                *)
                    echo -e "${RED}Неверный выбор!${NC}"
                    sleep 1
                ;;
            esac
        done
        ;;
esac
