#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS для Claude Code, Docker и VibeEnv (v6)
# Исправления:
# - Корректная обработка отказа от прокси (не включает proxychains, если IP пуст).
# - Fix: set -o pipefail для отлова ошибок curl в пайпах.
# - Fix: Проверка наличия binary после установки.
# ==============================================================================

# --- Цвета ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_NC='\033[0m'

# --- Глобальные переменные ---
PKG_MANAGER=""
OS_TYPE=""
PROXY_IP=""
PROXY_USER="proxyuser"
PROXYCHAINS_CONF_FILE=""
USE_PROXY_FLAG=false # Флаг: будем ли использовать прокси реально

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

fn_show_logo() {
    clear
    echo -e "${C_CYAN}"
    echo "  ███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗"
    echo "  ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝"
    echo "  ██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗"
    echo "  ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║"
    echo "  ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║"
    echo "  ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
    echo "                                  Установщик Claude Code"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
}

fn_check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_RED}Ошибка: Запустите скрипт через sudo.${C_NC}"
        exit 1
    fi
}

fn_detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID_LIKE" == *"debian"* || "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
            PKG_MANAGER="apt"
        elif [[ "$ID_LIKE" == *"rhel"* || "$ID" == "centos" || "$ID" == "fedora" ]]; then
            PKG_MANAGER="yum"
        else
            echo -e "${C_RED}Неподдерживаемая ОС. Попытка использовать apt...${C_NC}"
            PKG_MANAGER="apt"
        fi
    else
        echo -e "${C_RED}Не удалось определить ОС.${C_NC}"
        exit 1
    fi
}

fn_update_system() {
    echo -e "${C_YELLOW}--- Обновление пакетов ---${C_NC}"
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt update && apt install -y curl wget git build-essential
    elif [ "$PKG_MANAGER" == "yum" ]; then
        yum install -y curl wget git gcc-c++ make
    fi
}

# ==============================================================================
# КОМПОНЕНТЫ
# ==============================================================================

fn_install_proxychains() {
    echo -e "${C_YELLOW}--- Настройка Proxychains ---${C_NC}"
    
    # Установка пакета
    if ! command -v proxychains4 &> /dev/null; then
        if [ "$PKG_MANAGER" == "apt" ]; then
            apt install -y proxychains-ng
            PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
        elif [ "$PKG_MANAGER" == "yum" ]; then
            yum install -y epel-release
            yum install -y proxychains-ng
            if [ -f /etc/proxychains4.conf ]; then PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"; else PROXYCHAINS_CONF_FILE="/etc/proxychains.conf"; fi
        fi
    else
        echo "Proxychains уже установлен."
        PROXYCHAINS_CONF_FILE=$(find /etc -name "proxychains*.conf" | head -n 1)
    fi

    # Настройка
    echo -e "${C_YELLOW}ВАЖНО: Для работы Claude в РФ прокси ОБЯЗАТЕЛЕН.${C_NC}"
    read -p "Введите IP SOCKS5 прокси (Enter чтобы пропустить): " PROXY_IP
    
    if [ ! -z "$PROXY_IP" ]; then
        read -sp "Введите пароль пользователя '$PROXY_USER': " PROXY_PASS
        echo
        
        # Бэкап
        cp "$PROXYCHAINS_CONF_FILE" "${PROXYCHAINS_CONF_FILE}.bak" 2>/dev/null
        
        cat << EOF > "$PROXYCHAINS_CONF_FILE"
dynamic_chain
quiet_mode
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_IP 1080 $PROXY_USER $PROXY_PASS
EOF
        echo -e "${C_GREEN}Proxychains настроен.${C_NC}"
        USE_PROXY_FLAG=true
    else
        echo -e "${C_RED}Настройка прокси пропущена. Установка Claude может не сработать (geo-block).${C_NC}"
        USE_PROXY_FLAG=false
    fi
}

fn_install_docker() {
    echo -e "${C_YELLOW}--- Установка Docker & Compose ---${C_NC}"
    if command -v docker &> /dev/null; then
        echo "Docker уже установлен."
    else
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        
        systemctl start docker
        systemctl enable docker
        REAL_USER=${SUDO_USER:-$USER}
        usermod -aG docker "$REAL_USER"
        echo -e "${C_GREEN}Docker установлен.${C_NC}"
    fi
}

fn_install_tools() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- Установка инструментов (ripgrep, fzf, utils) ---${C_NC}"
    # Если прокси не настроен, prefix_cmd будет пустым, пакеты пойдут напрямую
    if [ "$PKG_MANAGER" == "apt" ]; then
        $prefix_cmd apt install -y ripgrep fzf jq htop
    elif [ "$PKG_MANAGER" == "yum" ]; then
        $prefix_cmd yum install -y ripgrep fzf jq htop
    fi
}

fn_install_claude_new() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- Установка Claude Code ---${C_NC}"
    
    # Удаляем старый битый файл если есть
    rm -f /root/.local/bin/claude 2>/dev/null
    rm -f /home/${SUDO_USER:-$USER}/.local/bin/claude 2>/dev/null

    echo "Запуск установщика..."
    
    local tmp_install="/tmp/claude_inst.sh"
    # set -o pipefail ВАЖЕН: если curl упадет, весь скрипт вернет ошибку
    echo '#!/bin/bash' > "$tmp_install"
    echo 'set -e; set -o pipefail' >> "$tmp_install"
    echo 'curl -fsSL https://claude.ai/install.sh | bash' >> "$tmp_install"
    chmod +x "$tmp_install"
    
    if [ -n "$prefix_cmd" ]; then
        echo "Используем прокси: $prefix_cmd"
        $prefix_cmd "$tmp_install"
    else
        echo "Установка НАПРЯМУЮ (без прокси). Может быть заблокировано."
        "$tmp_install"
    fi
    
    RET_CODE=$?
    rm "$tmp_install"
    
    if [ $RET_CODE -eq 0 ]; then
        echo -e "${C_GREEN}Скрипт установки отработал успешно.${C_NC}"
    else
        echo -e "${C_RED}ОШИБКА: Не удалось скачать или установить Claude.${C_NC}"
        echo "Возможные причины: нет прокси, неверный прокси, или сайт недоступен."
        return 1
    fi
}

# ==============================================================================
# МЕНЮ
# ==============================================================================

fn_show_logo
fn_check_root
fn_detect_os

echo "Выберите режим установки:"
echo "  1) Claude Code (Новый метод)"
echo "  2) Docker + Docker Compose"
echo "  3) Настройка Proxychains"
echo -e "${C_CYAN}  4) VIBE CODING PACK (Claude + Docker + Tools + Proxy)${C_NC}"
echo
read -p "Ваш выбор: " CHOICE

PREFIX=""

case $CHOICE in
    1)
        fn_install_proxychains
        if [ "$USE_PROXY_FLAG" = true ]; then PREFIX="proxychains4"; fi
        fn_update_system
        fn_install_claude_new "$PREFIX"
        ;;
    2)
        fn_update_system
        fn_install_docker
        ;;
    3)
        fn_install_proxychains
        ;;
    4)
        echo -e "${C_CYAN}>>> Vibe Coding Pack <<<${C_NC}"
        fn_update_system
        
        # 1. Настройка прокси
        fn_install_proxychains
        if [ "$USE_PROXY_FLAG" = true ]; then 
            PREFIX="proxychains4"
        else
            PREFIX=""
        fi
        
        # 2. Инструменты (используем прокси только если он настроен)
        fn_install_tools "$PREFIX"
        
        # 3. Docker (обычно ставим без прокси, это надежнее для зеркал)
        fn_install_docker
        
        # 4. Claude
        fn_install_claude_new "$PREFIX"
        ;;
    *)
        echo "Неверный выбор."
        exit 1
        ;;
esac

echo
echo -e "${C_GREEN}=== ЗАВЕРШЕНО ===${C_NC}"
echo "Для запуска Claude:"
if [ "$USE_PROXY_FLAG" = true ]; then
    echo -e "  ${C_BLUE}proxychains4 claude${C_NC}"
else
    echo -e "  ${C_BLUE}claude${C_NC}"
fi

# Проверка PATH
if ! command -v claude &> /dev/null; then
    echo -e "${C_YELLOW}Внимание: 'claude' не найден в PATH.${C_NC}"
    echo "Попробуйте выполнить команду:"
    echo "  source ~/.bashrc"
    echo "Или найдите его тут: ~/.local/bin/claude"
fi
