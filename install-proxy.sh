#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS: Claude Code, Docker & VibeEnv (v9 - CentOS 7 Fix)
#
# Изменения:
# 1. CRITICAL: Обход ограничения glibc 2.17 в CentOS 7 для Node.js 20.
# 2. Добавлены отсутствующие функции (fn_install_docker, fn_install_tools).
# 3. Фикс репозиториев для EOL систем.
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
OS_ID=""
OS_VERSION=""
PROXY_IP=""
PROXY_USER="proxyuser"
PROXYCHAINS_CONF_FILE=""
USE_PROXY_FLAG=false

# ==============================================================================
# ФУНКЦИИ БАЗОВЫЕ
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
    echo "                          Установщик Claude Code (CentOS 7 Edition)"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
    echo -e "${C_NC}"
}

fn_check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_RED}Ошибка: Запустите скрипт через sudo или от root.${C_NC}"
        exit 1
    fi
}

fn_detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        
        if [[ "$ID_LIKE" == *"debian"* || "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
            PKG_MANAGER="apt"
        elif [[ "$ID_LIKE" == *"rhel"* || "$ID" == "centos" || "$ID" == "fedora" ]]; then
            PKG_MANAGER="yum"
        else
            PKG_MANAGER="apt"
        fi
    else
        echo -e "${C_RED}Не удалось определить ОС. Выход.${C_NC}"
        exit 1
    fi
}

# ==============================================================================
# УСТАНОВКА И НАСТРОЙКА
# ==============================================================================

fn_update_system() {
    echo -e "${C_YELLOW}--- 1. Обновление пакетов и установка Node.js ---${C_NC}"
    
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt update && apt install -y curl wget git build-essential
        if ! command -v node &> /dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt install -y nodejs
        fi
    elif [ "$PKG_MANAGER" == "yum" ]; then
        # CentOS 7 фикс для vault репозиториев (если штатные зеркала уже не работают)
        if [ "$OS_ID" == "centos" ] && [ "$OS_VERSION" == "7" ]; then
            sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
            sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
        fi

        yum install -y epel-release
        yum install -y curl wget git gcc-c++ make tar

        if ! command -v node &> /dev/null; then
            if [ "$OS_ID" == "centos" ] && [ "$OS_VERSION" == "7" ]; then
                echo "CentOS 7 обнаружен. Установка специальной сборки Node.js 20 (glibc 2.17)..."
                local NODE_VER="v20.18.0"
                local NODE_FILE="node-${NODE_VER}-linux-x64-glibc-217.tar.gz"
                
                cd /tmp
                wget "https://unofficial-builds.nodejs.org/download/release/${NODE_VER}/${NODE_FILE}"
                tar -xzf "$NODE_FILE" -C /usr/local --strip-components=1
                rm -f "$NODE_FILE"
                
                # Принудительное обновление PATH для текущей сессии
                export PATH="/usr/local/bin:$PATH"
            else
                echo "Настройка репозитория NodeSource..."
                curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
                yum install -y nodejs --allowerasing
            fi
        fi
        
        # Проверка работоспособности node
        if node -v &> /dev/null; then
            echo -e "${C_GREEN}Node.js установлен: $(node -v)${C_NC}"
        else
            echo -e "${C_RED}Ошибка: Node.js не работает. Проверьте совместимость glibc.${C_NC}"
            exit 1
        fi
    fi
}

fn_install_proxychains() {
    echo -e "${C_YELLOW}--- 2. Настройка Proxychains ---${C_NC}"
    
    if ! command -v proxychains4 &> /dev/null; then
        if [ "$PKG_MANAGER" == "apt" ]; then
            apt install -y proxychains-ng
            PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
        elif [ "$PKG_MANAGER" == "yum" ]; then
            yum install -y proxychains-ng
            if [ -f /etc/proxychains4.conf ]; then 
                PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
            else 
                PROXYCHAINS_CONF_FILE="/etc/proxychains.conf"
            fi
        fi
    else
        PROXYCHAINS_CONF_FILE=$(find /etc -name "proxychains*.conf" | head -n 1)
    fi

    echo -e "Если нужен SOCKS5 прокси для Claude, введите IP. Если нет - нажмите Enter."
    read -p "IP SOCKS5 прокси: " PROXY_IP
    
    if [ ! -z "$PROXY_IP" ]; then
        read -sp "Пароль пользователя '$PROXY_USER': " PROXY_PASS
        echo
        cp "$PROXYCHAINS_CONF_FILE" "${PROXYCHAINS_CONF_FILE}.bak" 2>/dev/null
        
        cat << EOF > "$PROXYCHAINS_CONF_FILE"
dynamic_chain
quiet_mode
#proxy_dns 
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_IP 1080 $PROXY_USER $PROXY_PASS
EOF
        echo -e "${C_GREEN}Proxychains настроен.${C_NC}"
        USE_PROXY_FLAG=true
    else
        echo -e "${C_YELLOW}Прокси не задан. Используется прямое соединение.${C_NC}"
        USE_PROXY_FLAG=false
    fi
}

fn_install_docker() {
    echo -e "${C_YELLOW}--- 3. Установка Docker и Compose v2 ---${C_NC}"
    
    if ! command -v docker &> /dev/null; then
        if [ "$PKG_MANAGER" == "apt" ]; then
            curl -fsSL https://get.docker.com | bash
        elif [ "$PKG_MANAGER" == "yum" ]; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi
        systemctl enable --now docker
        echo -e "${C_GREEN}Docker установлен.${C_NC}"
    else
        echo -e "${C_GREEN}Docker уже установлен.${C_NC}"
    fi

    # Проверка плагина compose v2
    if docker compose version &> /dev/null; then
        echo -e "${C_GREEN}Docker Compose v2 доступен: $(docker compose version)${C_NC}"
    else
        echo -e "${C_RED}Docker Compose v2 не найден. Устанавливаем...${C_NC}"
        DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
        mkdir -p $DOCKER_CONFIG/cli-plugins
        curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
        chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
    fi
}

fn_install_tools() {
    echo -e "${C_YELLOW}--- 4. Установка дополнительных утилит (Tools) ---${C_NC}"
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt install -y jq htop tmux
    elif [ "$PKG_MANAGER" == "yum" ]; then
        yum install -y jq htop tmux
    fi
    echo -e "${C_GREEN}Утилиты установлены.${C_NC}"
}

fn_install_claude_new() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- 5. Установка Claude Code ---${C_NC}"
    
    if ! command -v npm &> /dev/null; then
        echo -e "${C_RED}Ошибка: NPM не установлен. Проверьте установку Node.js.${C_NC}"
        exit 1
    fi

    # На CentOS 7 при ручной установке Node npm уже в /usr/local/bin
    if [ -n "$prefix_cmd" ]; then
        $prefix_cmd npm install -g @anthropic-ai/claude-code
    else
        npm install -g @anthropic-ai/claude-code
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${C_GREEN}Claude успешно установлен!${C_NC}"
        fn_update_shell_rc
    else
        echo -e "${C_RED}Ошибка установки через NPM.${C_NC}"
        exit 1
    fi
}

fn_update_shell_rc() {
    echo -e "${C_YELLOW}--- 6. Обновление переменных окружения (.bashrc) ---${C_NC}"
    local ADD_LINE='export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"'
    
    apply_to_file() {
        local f="$1"
        if [ -f "$f" ]; then
            if ! grep -q "Vibe Coding Installer" "$f"; then
                echo -e "\n# Added by Vibe Coding Installer" >> "$f"
                echo "$ADD_LINE" >> "$f"
                echo -e "${C_GREEN}Обновлен: $f${C_NC}"
            fi
        fi
    }

    apply_to_file "/root/.bashrc"
    apply_to_file "/root/.zshrc"

    if [ -n "$SUDO_USER" ]; then
        local USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        apply_to_file "$USER_HOME/.bashrc"
        apply_to_file "$USER_HOME/.zshrc"
    fi
}

# ==============================================================================
# МЕНЮ
# ==============================================================================

fn_show_logo
fn_check_root
fn_detect_os

echo "Выберите режим установки:"
echo "  1) Claude Code (Только Claude)"
echo "  2) Docker + Docker Compose (v2)"
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
        echo -e "${C_CYAN}>>> Запуск полной установки Vibe Coding Pack <<<${C_NC}"
        fn_update_system
        fn_install_proxychains
        if [ "$USE_PROXY_FLAG" = true ]; then PREFIX="proxychains4"; else PREFIX=""; fi
        fn_install_tools
        fn_install_docker
        fn_install_claude_new "$PREFIX"
        ;;
    *)
        echo -e "${C_RED}Неверный выбор.${C_NC}"
        exit 1
        ;;
esac

echo
echo -e "${C_GREEN}=== УСТАНОВКА ЗАВЕРШЕНА ===${C_NC}"
if [ "$USE_PROXY_FLAG" = true ]; then
    echo -e "Запуск: ${C_BLUE}proxychains4 claude login${C_NC}"
else
    echo -e "Запуск: ${C_BLUE}claude login${C_NC}"
fi
