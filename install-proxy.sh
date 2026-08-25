#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS: Claude Code, Docker & VibeEnv
# Архитектура: Smart-Routing, Presale Demo Stack + Автостарт Tmux & CLAUDE.md
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
PROXY_PORT=""
PROXY_USER="proxyuser"
PROXY_PASS=""
PROXYCHAINS_CONF_FILE=""
USE_PROXY_FLAG=false
PREFIX=""

# ==============================================================================
# БАЗОВЫЕ ФУНКЦИИ
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
    echo "                    VibeEnv Installer: Presale & Smart Routing"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
    echo -e "${C_NC}"
}

fn_check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_RED}[!] Ошибка: Запуск разрешен только от root (или sudo).${C_NC}"
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
        elif [[ "$ID_LIKE" == *"rhel"* || "$ID" == "centos" || "$ID" == "fedora" || "$ID" == "almalinux" ]]; then
            PKG_MANAGER="yum"
        else
            PKG_MANAGER="apt"
        fi
    else
        echo -e "${C_RED}[!] Не удалось определить ОС. Работа прервана.${C_NC}"
        exit 1
    fi
}

# ==============================================================================
# СЕТЬ И ПРОКСИ
# ==============================================================================

fn_setup_proxy() {
    echo -e "${C_YELLOW}--- Настройка сетевого доступа (Proxychains) ---${C_NC}"
    echo "Для установки и работы Claude Code требуется SOCKS5 прокси (если доступ заблокирован)."
    echo -e "${C_CYAN}Нажмите [ENTER] для пропуска, если доступ прямой.${C_NC}"
    
    read -p "IP адрес и порт SOCKS5 прокси (например, 144.31.139.182:1080): " PROXY_INPUT
    
    if [ -z "$PROXY_INPUT" ]; then
        echo -e "${C_YELLOW}Прокси пропущен. Прямое соединение.${C_NC}"
        USE_PROXY_FLAG=false
        PREFIX=""
        return 0
    fi

    # Парсинг IP и порта
    PROXY_IP=$(echo "$PROXY_INPUT" | cut -d: -f1)
    PROXY_PORT=$(echo "$PROXY_INPUT" | cut -d: -s -f2)
    
    if [ -z "$PROXY_PORT" ]; then
        PROXY_PORT=1080
    fi

    read -sp "Пароль для пользователя '$PROXY_USER' (Enter если без пароля): " PROXY_PASS
    echo
    
    local PROXY_AUTH=""
    if [ -n "$PROXY_PASS" ]; then
        PROXY_AUTH="${PROXY_USER}:${PROXY_PASS}@"
    fi

    # ПРОВЕРКА СОЕДИНЕНИЯ (FAIL-FAST)
    echo -e "${C_CYAN}Проверка соединения через SOCKS5 прокси (${PROXY_IP}:${PROXY_PORT})...${C_NC}"
    if curl -x "socks5h://${PROXY_AUTH}${PROXY_IP}:${PROXY_PORT}" -fsSLk --connect-timeout 7 https://google.com >/dev/null; then
        echo -e "${C_GREEN}✅ Соединение успешно установлено!${C_NC}"
    else
        echo -e "${C_RED}[!] Ошибка соединения с прокси-сервером. Проверьте IP, порт или пароль.${C_NC}"
        exit 1
    fi

    if ! command -v proxychains4 &> /dev/null; then
        if [ "$PKG_MANAGER" == "apt" ]; then
            apt-get install -y proxychains-ng >/dev/null 2>&1
            PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
        elif [ "$PKG_MANAGER" == "yum" ]; then
            yum install -y proxychains-ng >/dev/null 2>&1
            PROXYCHAINS_CONF_FILE=$(find /etc -name "proxychains*.conf" | head -n 1)
            [ -z "$PROXYCHAINS_CONF_FILE" ] && PROXYCHAINS_CONF_FILE="/etc/proxychains.conf"
        fi
    else
        PROXYCHAINS_CONF_FILE=$(find /etc -name "proxychains*.conf" | head -n 1)
    fi
    
    cp "$PROXYCHAINS_CONF_FILE" "${PROXYCHAINS_CONF_FILE}.bak" 2>/dev/null
    
    cat << EOF > "$PROXYCHAINS_CONF_FILE"
strict_chain
quiet_mode
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_IP $PROXY_PORT $PROXY_USER $PROXY_PASS
EOF
    echo -e "${C_GREEN}Proxychains сконфигурирован: ${PROXY_IP}:${PROXY_PORT}${C_NC}"
    USE_PROXY_FLAG=true
    PREFIX="proxychains4 "
}

# ==============================================================================
# ПОДГОТОВКА СИСТЕМЫ
# ==============================================================================

fn_prepare_minimal() {
    echo -e "${C_YELLOW}--- 1. Проверка базовых утилит (Безопасный режим Bitrix) ---${C_NC}"
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt-get update >/dev/null 2>&1
        apt-get install -y curl wget jq xz-utils >/dev/null 2>&1
    elif [ "$PKG_MANAGER" == "yum" ]; then
        if [ "$OS_ID" == "centos" ] && [ "$OS_VERSION" == "7" ]; then
            sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null
            sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null
        fi
        yum install -y curl wget jq tar xz >/dev/null 2>&1
    fi
    echo -e "${C_GREEN}Базовые утилиты готовы.${C_NC}"
}

fn_prepare_full() {
    echo -e "${C_YELLOW}--- 1. Установка зависимостей для разработки ---${C_NC}"
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt-get update
        apt-get install -y curl wget git build-essential xz-utils jq htop tmux python3 python3-venv python3-pip
    elif [ "$PKG_MANAGER" == "yum" ]; then
        if [ "$OS_ID" == "centos" ] && [ "$OS_VERSION" == "7" ]; then
            sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null
            sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null
        fi
        yum install -y epel-release
        yum install -y curl wget git gcc-c++ make tar xz jq htop tmux python3 python3-pip
    fi
    echo -e "${C_GREEN}Зависимости установлены.${C_NC}"
}

# ==============================================================================
# DOCKER
# ==============================================================================

fn_install_docker() {
    echo -e "${C_YELLOW}--- Установка Docker и Compose v2 ---${C_NC}"
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

    if ! docker compose version &> /dev/null; then
        DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/libexec/docker/cli-plugins}
        mkdir -p $DOCKER_CONFIG
        curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/docker-compose
        chmod +x $DOCKER_CONFIG/docker-compose
    fi
}

# ==============================================================================
# NODE.JS SANDBOX И SMART CLAUDE INSTALLER
# ==============================================================================

fn_install_nodejs_sandboxed() {
    local NODE_DIR="/opt/vibe-node"
    if [ -d "$NODE_DIR/bin" ] && [ -x "$NODE_DIR/bin/node" ]; then
        return 0
    fi

    echo -e "${C_YELLOW}--- Инициализация изолированной песочницы Node.js ---${C_NC}"
    mkdir -p $NODE_DIR
    cd /tmp

    local PROXY_AUTH=""
    if [ -n "$PROXY_PASS" ]; then
        PROXY_AUTH="${PROXY_USER}:${PROXY_PASS}@"
    fi

    # Используем curl с флагом -# для отображения прогресс-бара
    local CURL_CMD="curl -fLk -#"
    if [ "$USE_PROXY_FLAG" = true ]; then
        CURL_CMD="curl -fLk -# -x socks5h://${PROXY_AUTH}${PROXY_IP}:${PROXY_PORT}"
    fi

    if [ "$OS_ID" == "centos" ] && [ "$OS_VERSION" == "7" ]; then
        echo -e "${C_BLUE}Скачивание неофициального Node.js 20 для устаревшей glibc 2.17...${C_NC}"
        local NODE_VER="v20.18.0"
        local NODE_FILE="node-${NODE_VER}-linux-x64-glibc-217.tar.gz"
        
        $CURL_CMD "https://unofficial-builds.nodejs.org/download/release/${NODE_VER}/${NODE_FILE}" -o "$NODE_FILE" || { echo -e "\n${C_RED}[!] Ошибка скачивания архива Node.js. Сервер недоступен.${C_NC}"; exit 1; }
        
        echo -e "${C_CYAN}Распаковка...${C_NC}"
        tar -xzf "$NODE_FILE" -C $NODE_DIR --strip-components=1
        rm -f "$NODE_FILE"
    else
        echo -e "${C_BLUE}Скачивание LTS сборки Node.js 20...${C_NC}"
        local NODE_VER="v20.18.0"
        local NODE_FILE="node-${NODE_VER}-linux-x64.tar.xz"
        
        $CURL_CMD "https://nodejs.org/dist/${NODE_VER}/${NODE_FILE}" -o "$NODE_FILE" || { echo -e "\n${C_RED}[!] Ошибка скачивания архива Node.js.${C_NC}"; exit 1; }
        
        echo -e "${C_CYAN}Распаковка...${C_NC}"
        tar -xJf "$NODE_FILE" -C $NODE_DIR --strip-components=1
        rm -f "$NODE_FILE"
    fi
}

fn_install_claude_smart() {
    local prefix_cmd="$1"
    echo -e "${C_YELLOW}--- Установка Claude Code (Smart Routing) ---${C_NC}"

    if [ "$OS_ID" == "centos" ] && [ "$OS_VERSION" == "7" ]; then
        echo -e "${C_RED}[!] Обнаружен CentOS 7. Активация песочницы NPM для Claude Code...${C_NC}"
        
        fn_install_nodejs_sandboxed
        
        local NPM_BIN="/opt/vibe-node/bin/npm"
        if [ ! -x "$NPM_BIN" ]; then
            echo -e "${C_RED}[!] Ошибка: NPM не найден в песочнице.${C_NC}"
            exit 1
        fi

        echo "Установка через NPM..."
        
        # КРИТИЧЕСКИЙ ФИКС: Форсируем использование изолированного node для npm
        export PATH="/opt/vibe-node/bin:$PATH"
        
        if [ -n "$prefix_cmd" ]; then
            $prefix_cmd $NPM_BIN install -g @anthropic-ai/claude-code
        else
            $NPM_BIN install -g @anthropic-ai/claude-code
        fi

        cat << 'EOF' > /usr/local/bin/claude
#!/bin/bash
unset NODE_ENV
unset NODE_PATH
export PATH="/opt/vibe-node/bin:$PATH"
exec /opt/vibe-node/bin/claude "$@"
EOF
        chmod +x /usr/local/bin/claude
        echo -e "${C_GREEN}Установка через Sandbox успешна: /usr/local/bin/claude${C_NC}"

    else
        echo -e "${C_CYAN}Современная система обнаружена. Выполнение нативного установщика...${C_NC}"
        if [ -n "$prefix_cmd" ]; then
            $prefix_cmd bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
        else
            curl -fsSL https://claude.ai/install.sh | bash
        fi

        local CLAUDE_BIN=""
        if command -v claude &> /dev/null; then
            CLAUDE_BIN=$(command -v claude)
        elif [ -f "$HOME/.local/bin/claude" ]; then
            CLAUDE_BIN="$HOME/.local/bin/claude"
        elif [ -f "/usr/local/bin/claude" ]; then
            CLAUDE_BIN="/usr/local/bin/claude"
        elif [ -n "$SUDO_USER" ] && [ -f "/home/$SUDO_USER/.local/bin/claude" ]; then
            CLAUDE_BIN="/home/$SUDO_USER/.local/bin/claude"
        fi

        if [ -n "$CLAUDE_BIN" ]; then
            echo -e "${C_GREEN}Установка успешна: $CLAUDE_BIN${C_NC}"
            if [ "$CLAUDE_BIN" != "/usr/local/bin/claude" ] && [ ! -f "/usr/local/bin/claude" ]; then
                ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
            fi
        else
            echo -e "${C_RED}[!] Ошибка: бинарник claude не найден после установки.${C_NC}"
            exit 1
        fi
    fi
}

# ==============================================================================
# PRESALE DEMO STACK & CLAUDE.MD
# ==============================================================================

fn_deploy_presale_stack() {
    echo -e "${C_YELLOW}--- Развертывание Presale Demo Stack ---${C_NC}"
    
    fn_install_nodejs_sandboxed

    read -p "Домен для Caddy (по умолчанию localhost): " APP_DOMAIN
    APP_DOMAIN=${APP_DOMAIN:-localhost}
    read -sp "Пароль для PostgreSQL (по умолчанию vibe2026): " DB_PASS
    echo
    DB_PASS=${DB_PASS:-vibe2026}

    local DEMO_DIR="/opt/vibe-demo"
    mkdir -p "$DEMO_DIR"/{docker,backend}

    cat << EOF > "$DEMO_DIR/docker/docker-compose.yml"
version: '3.8'
services:
  caddy:
    image: caddy:latest
    container_name: vibe_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config

  postgres:
    image: postgres:15-alpine
    container_name: vibe_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: vibe_admin
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: vibe_db
    ports:
      - "5432:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data

volumes:
  caddy_data:
  caddy_config:
  pg_data:
EOF

    cat << EOF > "$DEMO_DIR/docker/Caddyfile"
$APP_DOMAIN {
    handle /api/* {
        reverse_proxy host.docker.internal:8000
    }
    handle /* {
        reverse_proxy host.docker.internal:5173
    }
}
EOF

    echo -e "${C_CYAN}Генерация FastAPI бэкенда...${C_NC}"
    cd "$DEMO_DIR/backend"
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip >/dev/null 2>&1
    pip install "fastapi[all]" >/dev/null 2>&1
    
    cat << EOF > .env
DATABASE_URL=postgresql://vibe_admin:${DB_PASS}@localhost:5432/vibe_db
EOF

    cat << 'EOF' > main.py
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import os

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/api/health")
def health_check():
    return {"status": "ok", "service": "Vibe API is running", "db_configured": "DATABASE_URL" in os.environ}
EOF
    deactivate

    echo -e "${C_CYAN}Генерация React + Vite...${C_NC}"
    cd "$DEMO_DIR"
    local NPM_BIN="/opt/vibe-node/bin/npm"
    local NPX_BIN="/opt/vibe-node/bin/npx"

    $NPX_BIN create-vite@latest frontend --template react-ts -y >/dev/null 2>&1
    cd frontend
    $NPM_BIN install recharts lucide-react >/dev/null 2>&1
    
    cat << 'EOF' > vite.config.ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    hmr: {
      clientPort: 443,
    }
  }
})
EOF

    echo -e "${C_CYAN}Создание CLAUDE.md...${C_NC}"
    cat << 'EOF' > "$DEMO_DIR/CLAUDE.md"
# 🚀 PRESALE DEMO MODE ACTIVE

## 🎯 Главная цель
Вау-эффект для клиента. Мы продаем интерфейс и пользовательский опыт. Бэкенд должен просто работать, архитектурная чистота бэкенда вторична.

## 🛠 Стэк
- **Frontend:** React, Vite, TailwindCSS, shadcn/ui, recharts, lucide-react.
- **Backend:** FastAPI, PostgreSQL.

## 📜 Правила вайбкодинга
1. **UI/UX в приоритете:** Используй современные паттерны. Дашборды, сайдбары, карточки, скелетоны при загрузке.
2. **Бизнес-фокус:** Это внутренний B2B инструмент (CRM, ERP, ЛК, Дашборд фин. отдела). Дизайн должен быть строгим, но стильным и дорогим.
3. **Не усложняй бэкенд:** Один-два файла для API достаточно. Главное — чтобы CRUD работал и отдавал данные на фронт. Никаких микросервисов и DDD.
4. **Умные заглушки:** Если логика слишком сложная (например, ML-аналитика или сложный биллинг) — хардкодь мок-данные. Клиент смотрит на визуал.
5. **Меньше вопросов, больше кода:** Действуй уверенно, генерируй компоненты сразу. Инициализируй shadcn-ui самостоятельно при первой необходимости.
EOF

    echo -e "${C_CYAN}Инициализация Git репозитория...${C_NC}"
    cd "$DEMO_DIR"
    git config --global user.name "VibeEnv Auto"
    git config --global user.email "auto@vibe.env"
    git init >/dev/null 2>&1
    
    cat << 'EOF' > .gitignore
node_modules/
venv/
.env
__pycache__/
dist/
EOF
    
    git add . >/dev/null 2>&1
    git commit -m "feat: init presale demo stack with CLAUDE.md" >/dev/null 2>&1

    echo -e "${C_CYAN}Создание скрипта запуска Tmux...${C_NC}"
    cat << 'EOF' > "$DEMO_DIR/start_vibe.sh"
#!/bin/bash
cd /opt/vibe-demo/docker && docker compose up -d

tmux new-session -d -s vibe_demo -n "backend"
tmux send-keys -t vibe_demo:0 "cd /opt/vibe-demo/backend && source venv/bin/activate && set -a && source .env && set +a && uvicorn main:app --host 0.0.0.0 --port 8000 --reload" C-m

tmux new-window -t vibe_demo:1 -n "frontend"
tmux send-keys -t vibe_demo:1 "export PATH='/opt/vibe-node/bin:$PATH' && cd /opt/vibe-demo/frontend && npm run dev" C-m

tmux attach-session -t vibe_demo
EOF
    chmod +x "$DEMO_DIR/start_vibe.sh"
}

# ==============================================================================
# ИНТЕРАКТИВНОЕ МЕНЮ
# ==============================================================================

fn_setup_devkit() {
    echo
    echo -e "${C_CYAN}--- Подключение к MEDIA WORKS DevKit ---${C_NC}"
    echo "Claude Code на этом сервере будет вести журнал работ проекта: вход по рабочему e-mail (код придёт в Битрикс24),"
    echo "выбор проекта, инструкции и хуки — из AdFlow."
    read -p " Подключить сейчас? (y/N): " DK
    if [[ "$DK" =~ ^[Yy]$ ]]; then
        if [ "$USE_PROXY_FLAG" = true ]; then
            proxychains4 -q curl -fsSL https://adflow.mworx.ru/api/v1/devkit/install.sh | proxychains4 -q bash || echo -e "${C_RED}DevKit не подключён — позже: curl -fsSL https://adflow.mworx.ru/api/v1/devkit/install.sh | bash${C_NC}"
        else
            curl -fsSL https://adflow.mworx.ru/api/v1/devkit/install.sh | bash || echo -e "${C_RED}DevKit не подключён — позже: curl -fsSL https://adflow.mworx.ru/api/v1/devkit/install.sh | bash${C_NC}"
        fi
    else
        echo "Пропущено. Подключить позже: curl -fsSL https://adflow.mworx.ru/api/v1/devkit/install.sh | bash"
    fi
}

fn_interactive_menu() {
    clear
    fn_show_logo

    echo -e "${C_CYAN}======================================================================${C_NC}"
    echo -e "                 ${C_YELLOW}МЕНЮ РАЗВЕРТЫВАНИЯ: СИСТЕМНЫЙ ИНТЕГРАТОР${C_NC}"
    echo -e "${C_CYAN}======================================================================${C_NC}"
    echo
    echo -e "  ${C_GREEN}[1] Minimal Edition: Только Claude Code${C_NC}"
    echo "      (Умная установка CLI-ассистента для закрытых серверов)"
    echo
    echo -e "  ${C_BLUE}[2] Full VibeEnv Stack: Claude + Docker + Presale Demo${C_NC}"
    echo "      (Claude + изолированный Node + демо стенд + Git + CLAUDE.md)"
    echo
    echo -e "  ${C_YELLOW}[3] Infrastructure Only: Docker + Tools + Claude${C_NC}"
    echo "      (Подготовка чистой среды без генерации демо-архитектуры)"
    echo
    echo -e "  ${C_CYAN}[4] Proxy Reconfigure: Настройка сети${C_NC}"
    echo "      (Изменить или отключить текущие настройки Proxychains)"
    echo
    echo -e "  [0] Выход"
    echo
    echo -e "${C_CYAN}======================================================================${C_NC}"
    echo
    
    read -p " Выберите профиль (0-4): " CHOICE
    echo

    case $CHOICE in
        1)
            fn_setup_proxy
            fn_prepare_minimal
            fn_install_claude_smart "$PREFIX"
            fn_setup_devkit
            ;;
        2)
            fn_setup_proxy
            fn_prepare_full
            fn_install_docker
            fn_install_claude_smart "$PREFIX"
            fn_deploy_presale_stack
            fn_setup_devkit
            ;;
        3)
            fn_setup_proxy
            fn_prepare_full
            fn_install_docker
            fn_install_claude_smart "$PREFIX"
            fn_setup_devkit
            ;;
        4)
            fn_setup_proxy
            exit 0
            ;;
        0)
            echo "Отмена."
            exit 0
            ;;
        *)
            echo -e "${C_RED}Недопустимый код профиля.${C_NC}"
            exit 1
            ;;
    esac

    echo
    echo -e "${C_GREEN}======================================================================${C_NC}"
    echo -e "${C_GREEN}                      УСТАНОВКА ЗАВЕРШЕНА                             ${C_NC}"
    echo -e "${C_GREEN}======================================================================${C_NC}"
    
    if [[ "$CHOICE" == "1" || "$CHOICE" == "3" ]]; then
        if [ "$USE_PROXY_FLAG" = true ]; then
            echo -e "Авторизация: ${C_BLUE}proxychains4 claude login${C_NC}"
        else
            echo -e "Авторизация: ${C_BLUE}claude login${C_NC}"
        fi
    elif [[ "$CHOICE" == "2" ]]; then
        if [ "$USE_PROXY_FLAG" = true ]; then
            echo -e "Перед началом работы авторизуйся: ${C_BLUE}proxychains4 claude login${C_NC}"
        else
            echo -e "Перед началом работы авторизуйся: ${C_BLUE}claude login${C_NC}"
        fi
        
        echo -e "\n${C_YELLOW}Стек готов. Запускаю Tmux-сессию через 5 секунд...${C_NC}"
        echo -e "(Для отключения от сессии нажми ${C_BLUE}Ctrl+b${C_NC}, затем ${C_BLUE}d${C_NC})"
        sleep 5
        /opt/vibe-demo/start_vibe.sh
    fi
}

# Запуск
fn_check_root
fn_detect_os
fn_interactive_menu
