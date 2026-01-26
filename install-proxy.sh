#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS: Claude Code, Docker & VibeEnv (v8)
#
# Изменения v8:
# 1. SILENT MODE: Авто-добавление PATH в .bashrc/.zshrc (убирает warning).
# 2. DUAL USER FIX: Настройка путей и для root, и для sudo-пользователя.
# 3. DOCKER CHECK: Гарантия Docker Compose v2.
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
PROXY_IP=""
PROXY_USER="proxyuser"
PROXYCHAINS_CONF_FILE=""
USE_PROXY_FLAG=false

# ==============================================================================
# ФУНКЦИИ
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
            PKG_MANAGER="apt"
        fi
    else
        echo -e "${C_RED}Не удалось определить ОС. Выход.${C_NC}"
        exit 1
    fi
}

fn_update_system() {
    echo -e "${C_YELLOW}--- 1. Обновление пакетов ---${C_NC}"
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt update && apt install -y curl wget git build-essential
    elif [ "$PKG_MANAGER" == "yum" ]; then
        yum install -y curl wget git gcc-c++ make
    fi
}

fn_install_proxychains() {
    echo -e "${C_YELLOW}--- 2. Настройка Proxychains ---${C_NC}"
    
    # Проверка бинарника
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
        PROXYCHAINS_CONF_FILE=$(find /etc -name "proxychains*.conf" | head -n 1)
    fi

    echo -e "Если вы в РФ, Claude требует SOCKS5 прокси. Если нет - нажмите Enter."
    read -p "Введите IP SOCKS5 прокси: " PROXY_IP
    
    if [ ! -z "$PROXY_IP" ]; then
        read -sp "Введите пароль пользователя '$PROXY_USER': " PROXY_PASS
        echo
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
        echo -e "${C_YELLOW}Прокси не задан. Прямое соединение.${C_NC}"
        USE_PROXY_FLAG=false
    fi
}

fn_install_docker() {
    echo -e "${C_YELLOW}--- 3. Установка Docker & Docker Compose (v2) ---${C_NC}"
    
    # Снос старого compose (v1)
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt remove -y docker-compose 2>/dev/null
    fi

    if command -v docker &> /dev/null; then
        echo "Docker Engine уже установлен."
    else
        echo "Загрузка скрипта Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        
        systemctl start docker
        systemctl enable docker
        
        REAL_USER=${SUDO_USER:-$USER}
        usermod -aG docker "$REAL_USER"
    fi

    # Проверка Compose v2
    echo -e "${C_BLUE}Проверка плагина Compose...${C_NC}"
    if docker compose version &> /dev/null; then
        D_VER=$(docker compose version)
        echo -e "${C_GREEN}✅ OK: $D_VER${C_NC}"
    else
        echo -e "${C_RED}⚠ Плагин не найден. Ставим вручную...${C_NC}"
        if [ "$PKG_MANAGER" == "apt" ]; then
            apt install -y docker-compose-plugin
        elif [ "$PKG_MANAGER" == "yum" ]; then
            yum install -y docker-compose-plugin
        fi
    fi
}

fn_install_tools() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- 4. Установка инструментов (ripgrep, fzf, jq) ---${C_NC}"
    if [ "$PKG_MANAGER" == "apt" ]; then
        $prefix_cmd apt install -y ripgrep fzf jq htop
    elif [ "$PKG_MANAGER" == "yum" ]; then
        $prefix_cmd yum install -y ripgrep fzf jq htop
    fi
}

fn_install_claude_new() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- 5. Установка Claude Code ---${C_NC}"
    
    # Чистка
    rm -f /usr/local/bin/claude
    rm -f /root/.local/bin/claude
    
    local tmp_install="/tmp/claude_inst.sh"
    echo '#!/bin/bash' > "$tmp_install"
    echo 'set -e; set -o pipefail' >> "$tmp_install"
    echo 'curl -fsSL https://claude.ai/install.sh | bash' >> "$tmp_install"
    chmod +x "$tmp_install"
    
    if [ -n "$prefix_cmd" ]; then
        echo "Скачивание через прокси..."
        $prefix_cmd "$tmp_install"
    else
        "$tmp_install"
    fi
    
    RET_CODE=$?
    rm "$tmp_install"

    if [ $RET_CODE -eq 0 ]; then
        # 1. Симлинк (физический доступ)
        fn_fix_path_symlink
        # 2. Переменные окружения (убирает warning)
        fn_update_shell_rc
    else
        echo -e "${C_RED}ОШИБКА установки Claude.${C_NC}"
        return 1
    fi
}

fn_fix_path_symlink() {
    echo -e "${C_YELLOW}--- Настройка путей (Symlink) ---${C_NC}"
    TARGET_PATH=""
    
    if [ -f "$HOME/.local/bin/claude" ]; then
        TARGET_PATH="$HOME/.local/bin/claude"
    elif [ -n "$SUDO_USER" ] && [ -f "/home/$SUDO_USER/.local/bin/claude" ]; then
        TARGET_PATH="/home/$SUDO_USER/.local/bin/claude"
    fi
    
    if [ -n "$TARGET_PATH" ]; then
        ln -sf "$TARGET_PATH" /usr/local/bin/claude
        echo -e "${C_GREEN}✅ Симлинк создан в /usr/local/bin/claude${C_NC}"
    else
        echo -e "${C_RED}Бинарник не найден для создания симлинка.${C_NC}"
    fi
}

# --- Новая функция для правки .bashrc ---
fn_update_shell_rc() {
    echo -e "${C_YELLOW}--- Обновление .bashrc (убирает Warning) ---${C_NC}"
    
    local ADD_LINE='export PATH="$HOME/.local/bin:$PATH"'
    
    # Функция применения к конкретному файлу
    apply_to_file() {
        local f="$1"
        if [ -f "$f" ]; then
            if ! grep -q ".local/bin" "$f"; then
                echo "" >> "$f"
                echo "# Added by Vibe Coding Installer" >> "$f"
                echo "$ADD_LINE" >> "$f"
                echo -e "${C_GREEN}Обновлен: $f${C_NC}"
            else
                echo "Уже настроен: $f"
            fi
        fi
    }

    # 1. Для root
    apply_to_file "/root/.bashrc"
    apply_to_file "/root/.zshrc"

    # 2. Для реального пользователя (если есть)
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
        fn_install_tools "$PREFIX"
        fn_install_docker
        fn_install_claude_new "$PREFIX"
        ;;
    *)
        echo "Неверный выбор."
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
