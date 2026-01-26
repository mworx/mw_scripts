#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS для Claude Code, Docker и VibeEnv (v5)
# Поддержка: Ubuntu, Debian, Astra Linux, CentOS
#
# Логика v5:
# - Новый установщик Claude (install.sh).
# - Поддержка установки Docker + Docker Compose plugin.
# - Режим "Vibe Coding Pack" (All-in-One).
# - Интеграция с Proxychains для всех этапов.
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
IS_CENTOS7=false
PROXY_IP=""
PROXY_USER="proxyuser"
PROXYCHAINS_CONF_FILE=""

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
        ID_LOWER=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
        
        if [[ $ID_LOWER == "ubuntu" || $ID_LOWER == "debian" || $ID_LOWER == "astra" || $ID_LOWER == "kali" ]]; then
            OS_TYPE="debian_based"
            PKG_MANAGER="apt"
        elif [[ $ID_LOWER == "centos" || $ID_LOWER == "rhel" || $ID_LOWER == "fedora" ]]; then
            OS_TYPE="rhel_based"
            PKG_MANAGER="yum"
            if [[ $ID_LOWER == "centos" && $VERSION_ID == "7" ]]; then
                IS_CENTOS7=true
                echo -e "${C_RED}ВНИМАНИЕ: CentOS 7 устарела. Новый Claude CLI может не работать из-за старой glibc.${C_NC}"
            fi
        else
            echo -e "${C_RED}Неподдерживаемая ОС: $ID${C_NC}"
            exit 1
        fi
        echo -e "ОС: ${C_GREEN}$PRETTY_NAME${C_NC} ($PKG_MANAGER)"
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
# УСТАНОВКА КОМПОНЕНТОВ
# ==============================================================================

# --- Proxychains ---
fn_install_proxychains() {
    echo -e "${C_YELLOW}--- Установка Proxychains ---${C_NC}"
    
    # Установка пакета
    if ! command -v proxychains4 &> /dev/null; then
        if [ "$PKG_MANAGER" == "apt" ]; then
            apt install -y proxychains-ng
            PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
        elif [ "$PKG_MANAGER" == "yum" ]; then
            yum install -y epel-release
            yum install -y proxychains-ng
            # Поиск конфига, так как в RHEL он может отличаться
            if [ -f /etc/proxychains4.conf ]; then PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"; else PROXYCHAINS_CONF_FILE="/etc/proxychains.conf"; fi
        fi
    else
        echo "Proxychains уже установлен."
        PROXYCHAINS_CONF_FILE=$(find /etc -name "proxychains*.conf" | head -n 1)
    fi

    # Настройка
    read -p "Введите IP SOCKS5 прокси (Enter чтобы пропустить настройку): " PROXY_IP
    if [ ! -z "$PROXY_IP" ]; then
        read -sp "Введите пароль пользователя '$PROXY_USER': " PROXY_PASS
        echo
        
        cp "$PROXYCHAINS_CONF_FILE" "${PROXYCHAINS_CONF_FILE}.bak"
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
    else
        echo "Настройка прокси пропущена."
    fi
}

# --- Docker & Compose ---
fn_install_docker() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- Установка Docker & Compose ---${C_NC}"
    
    if command -v docker &> /dev/null; then
        echo "Docker уже установлен."
    else
        echo "Загрузка скрипта установки Docker..."
        # Используем официальный скрипт
        $prefix_cmd curl -fsSL https://get.docker.com -o get-docker.sh
        $prefix_cmd sh get-docker.sh
        rm get-docker.sh
        
        systemctl start docker
        systemctl enable docker
        
        # Добавляем текущего пользователя (не root, если скрипт запущен через sudo)
        REAL_USER=${SUDO_USER:-$USER}
        usermod -aG docker "$REAL_USER"
        echo -e "${C_GREEN}Docker установлен. Пользователь $REAL_USER добавлен в группу docker.${C_NC}"
    fi
}

# --- Доп. инструменты (Vibe Pack) ---
fn_install_tools() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- Установка инструментов (ripgrep, fzf, utils) ---${C_NC}"
    
    if [ "$PKG_MANAGER" == "apt" ]; then
        $prefix_cmd apt install -y ripgrep fzf jq htop
    elif [ "$PKG_MANAGER" == "yum" ]; then
        $prefix_cmd yum install -y ripgrep fzf jq htop
    fi
}

# --- Новый Claude Code ---
fn_install_claude_new() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- Установка Claude Code (New Installer) ---${C_NC}"
    
    # Проверка на существование
    if command -v claude &> /dev/null; then
        echo -e "${C_GREEN}Claude CLI уже установлен.${C_NC}"
        return
    fi

    echo "Запуск: curl https://claude.ai/install.sh | bash"
    
    # Хак для pipe через proxychains: создаем временный скрипт
    local tmp_install="/tmp/claude_inst.sh"
    echo '#!/bin/bash' > "$tmp_install"
    echo 'curl -fsSL https://claude.ai/install.sh | bash' >> "$tmp_install"
    chmod +x "$tmp_install"
    
    if [ -n "$prefix_cmd" ]; then
        echo "Установка через прокси..."
        $prefix_cmd "$tmp_install"
    else
        "$tmp_install"
    fi
    
    RET_CODE=$?
    rm "$tmp_install"
    
    if [ $RET_CODE -eq 0 ]; then
        echo -e "${C_GREEN}Claude успешно установлен.${C_NC}"
        # Попытка добавить в PATH для текущей сессии
        export PATH="$HOME/.local/bin:$PATH"
    else
        echo -e "${C_RED}Ошибка установки Claude.${C_NC}"
        exit 1
    fi
}

# ==============================================================================
# МЕНЮ И ЛОГИКА
# ==============================================================================

fn_show_logo
fn_check_root
fn_detect_os

echo "Выберите режим установки:"
echo "  1) Claude Code (Новый метод)"
echo "  2) Docker + Docker Compose"
echo "  3) Настройка Proxychains (только прокси)"
echo -e "${C_CYAN}  4) VIBE CODING PACK (Claude + Docker + Tools + Proxy)${C_NC}"
echo
read -p "Ваш выбор: " CHOICE

# Определяем префикс прокси заранее
PREFIX=""

case $CHOICE in
    1)
        # Просто Claude. Спрашиваем про прокси, если нужно.
        read -p "Использовать Proxychains? (y/n): " USE_PROXY
        if [[ "$USE_PROXY" == "y" ]]; then
            fn_install_proxychains
            PREFIX="proxychains4"
        fi
        fn_update_system
        fn_install_claude_new "$PREFIX"
        ;;
    2)
        fn_update_system
        fn_install_docker "" # Docker обычно ставится без прокси (зеркала)
        ;;
    3)
        fn_update_system
        fn_install_proxychains
        ;;
    4)
        echo -e "${C_CYAN}>>> Запуск полной установки Vibe Coding Pack <<<${C_NC}"
        fn_update_system
        
        # 1. Сначала настраиваем прокси, так как остальные могут зависеть от него
        fn_install_proxychains
        PREFIX="proxychains4"
        
        # 2. Ставим утилиты (через прокси на всякий случай, если репо заблочены)
        fn_install_tools "$PREFIX"
        
        # 3. Ставим Docker (пробуем напрямую, если фейл - то через прокси)
        # Обычно get.docker.com сам разбирается, но для надежности запустим без прокси,
        # так как Docker тянет большие образы и через socks5 это будет медленно.
        fn_install_docker "" 
        
        # 4. Ставим Claude (через прокси, т.к. claude.ai часто блочат)
        fn_install_claude_new "$PREFIX"
        ;;
    *)
        echo "Неверный выбор."
        exit 1
        ;;
esac

echo
echo -e "${C_GREEN}=== ГОТОВО ===${C_NC}"
if [[ $CHOICE == 2 || $CHOICE == 4 ]]; then
    echo "Важное примечание по Docker: Чтобы изменения групп вступили в силу,"
    echo "вам может потребоваться перезайти в систему (logout/login)."
fi
if [[ -n "$PREFIX" ]]; then
    echo "Запуск Claude через прокси: proxychains4 claude"
fi
