#!/bin/bash
# ==============================================================================
# Установщик MEDIA WORKS: Claude Code, MW DevKit, Docker & Presale Demo Stack
#   bash install-proxy.sh                      — интерактивное меню
#   bash install-proxy.sh --profile 5 --yes    — обновить все установки Claude + DevKit без вопросов
#   Флаги: --profile N | --proxy IP:PORT[:пароль] | --no-proxy | --yes | --dry-run | --keep-legacy | --domain D | --db-pass P
# ==============================================================================
set -o pipefail

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
ADFLOW_URL="${ADFLOW_URL:-https://adflow.mworx.ru/api/v1}"
NODE_DIR="/opt/vibe-node"; NODE_VER="v20.18.0"; DEMO_DIR="/opt/vibe-demo"
PKG_MANAGER=""; OS_ID=""; OS_VERSION=""
PROXY_IP=""; PROXY_PORT=""; PROXY_USER="proxyuser"; PROXY_PASS=""; PROXYCHAINS_CONF_FILE=""
USE_PROXY_FLAG=false; PREFIX=""
OPT_PROFILE=""; OPT_PROXY=""; OPT_YES=false; OPT_DRY=false; OPT_KEEP_LEGACY=false; OPT_DOMAIN=""; OPT_DBPASS=""
LOG="/var/log/mw-install.log"

log()  { echo -e "$1"; echo -e "$(date '+%F %T') $1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG" 2>/dev/null; }
info() { log "${C_CYAN}$1${C_NC}"; }
ok()   { log "${C_GREEN}$1${C_NC}"; }
warn() { log "${C_YELLOW}$1${C_NC}"; }
err()  { log "${C_RED}[!] $1${C_NC}"; }
run()  { if $OPT_DRY; then echo "  [dry-run] $*"; else eval "$@"; fi; }
ask()  { local q="$1" def="${2:-N}" a; if $OPT_YES; then [[ "$def" =~ ^[Yy]$ ]]; return; fi; read -p "$q " a </dev/tty; a=${a:-$def}; [[ "$a" =~ ^[Yy]$ ]]; }

# ==============================================================================
# БАЗА
# ==============================================================================
fn_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile) OPT_PROFILE="$2"; shift ;;
            --proxy) OPT_PROXY="$2"; shift ;;
            --no-proxy) OPT_PROXY="none" ;;
            --yes|-y) OPT_YES=true ;;
            --dry-run) OPT_DRY=true ;;
            --keep-legacy) OPT_KEEP_LEGACY=true ;;
            --domain) OPT_DOMAIN="$2"; shift ;;
            --db-pass) OPT_DBPASS="$2"; shift ;;
            -h|--help) sed -n 2,7p "$0"; exit 0 ;;
            *) err "Неизвестный флаг: $1"; exit 1 ;;
        esac
        shift
    done
}

fn_show_logo() {
    $OPT_YES || clear
    echo -e "${C_CYAN}"
    echo "  ███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗"
    echo "  ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝"
    echo "  ██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗"
    echo "  ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║"
    echo "  ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║"
    echo "  ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
    echo "                    Claude Code · MW DevKit · Docker · Presale Demo Stack"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
    echo -e "${C_NC}"
}

fn_check_root() { [ "$EUID" -ne 0 ] && { err "Запуск только от root (или sudo)."; exit 1; }; return 0; }

fn_detect_os() {
    [ -f /etc/os-release ] || { err "Не удалось определить ОС."; exit 1; }
    . /etc/os-release
    OS_ID="$ID"; OS_VERSION="${VERSION_ID%%.*}"
    if [[ "${ID_LIKE:-}" == *"debian"* || "$ID" == "debian" || "$ID" == "ubuntu" ]]; then PKG_MANAGER="apt"
    elif [[ "${ID_LIKE:-}" == *"rhel"* || "${ID_LIKE:-}" == *"fedora"* || "$ID" =~ ^(centos|fedora|almalinux|rocky|rhel)$ ]]; then PKG_MANAGER="yum"
    else PKG_MANAGER="apt"; fi
    command -v dnf >/dev/null 2>&1 && [ "$PKG_MANAGER" = "yum" ] && PKG_MANAGER="dnf"
    info "ОС: $PRETTY_NAME ($PKG_MANAGER)"
}

fn_is_centos7() { [ "$OS_ID" = "centos" ] && [ "$OS_VERSION" = "7" ]; }

fn_pkg_install() {   # тихо, но с проверкой результата
    local pkgs="$*"
    if [ "$PKG_MANAGER" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >>"$LOG" 2>&1
    else
        $PKG_MANAGER install -y $pkgs >>"$LOG" 2>&1
    fi
}

fn_prepare_minimal() {
    warn "--- Базовые утилиты ---"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get update >>"$LOG" 2>&1 || warn "apt-get update завершился с ошибкой (см. $LOG) — продолжаю"
        fn_pkg_install curl wget ca-certificates jq xz-utils python3 || { err "Не удалось поставить базовые утилиты (см. $LOG)"; exit 1; }
    else
        if fn_is_centos7; then
            sed -i 's/^mirrorlist/#mirrorlist/g; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
        fi
        fn_pkg_install epel-release >/dev/null 2>&1 || true
        fn_pkg_install curl wget ca-certificates jq tar xz python3 || { err "Не удалось поставить базовые утилиты (см. $LOG)"; exit 1; }
    fi
    ok "Базовые утилиты готовы."
}

fn_prepare_full() {
    fn_prepare_minimal
    warn "--- Зависимости для разработки ---"
    if [ "$PKG_MANAGER" = "apt" ]; then
        fn_pkg_install git build-essential htop tmux python3-venv python3-pip || { err "Не удалось поставить зависимости (см. $LOG)"; exit 1; }
    else
        fn_pkg_install git gcc-c++ make htop tmux python3-pip || { err "Не удалось поставить зависимости (см. $LOG)"; exit 1; }
    fi
    ok "Зависимости установлены."
}

# ==============================================================================
# СЕТЬ И ПРОКСИ
# ==============================================================================
fn_proxy_conf_path() {
    PROXYCHAINS_CONF_FILE=$(ls /etc/proxychains4.conf /etc/proxychains.conf 2>/dev/null | head -n 1)
    [ -z "$PROXYCHAINS_CONF_FILE" ] && PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
}

fn_proxy_read_existing() {   # уже настроенный proxychains → предложить переиспользовать
    fn_proxy_conf_path
    [ -f "$PROXYCHAINS_CONF_FILE" ] || return 1
    local line; line=$(grep -E '^\s*socks5\s' "$PROXYCHAINS_CONF_FILE" | tail -n 1)
    [ -z "$line" ] && return 1
    read -r _ PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS <<<"$line"
    return 0
}

fn_urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

fn_proxy_test() {
    local auth=""; [ -n "$PROXY_PASS" ] && auth="$(fn_urlenc "$PROXY_USER"):$(fn_urlenc "$PROXY_PASS")@"
    curl -x "socks5h://${auth}${PROXY_IP}:${PROXY_PORT}" -fsSL --connect-timeout 10 -o /dev/null https://claude.ai/ 2>>"$LOG" \
      || curl -x "socks5h://${auth}${PROXY_IP}:${PROXY_PORT}" -fsSL --connect-timeout 10 -o /dev/null https://www.google.com/ 2>>"$LOG"
}

fn_setup_proxy() {
    warn "--- Сетевой доступ (Proxychains) ---"
    command -v curl >/dev/null 2>&1 || fn_prepare_minimal
    if [ "$OPT_PROXY" = "none" ]; then USE_PROXY_FLAG=false; PREFIX=""; ok "Прямое соединение (--no-proxy)."; return 0; fi
    if [ -n "$OPT_PROXY" ]; then
        PROXY_IP=$(echo "$OPT_PROXY" | cut -d: -f1); PROXY_PORT=$(echo "$OPT_PROXY" | cut -d: -f2); PROXY_PASS=$(echo "$OPT_PROXY" | cut -d: -s -f3-)
    elif fn_proxy_read_existing; then
        info "Найден настроенный прокси: ${PROXY_IP}:${PROXY_PORT} (пользователь ${PROXY_USER})"
        if ! ask "Использовать его? (Y/n):" Y; then PROXY_IP=""; fi
    fi
    if [ -z "$PROXY_IP" ]; then
        if $OPT_YES; then USE_PROXY_FLAG=false; PREFIX=""; warn "Прокси не задан — прямое соединение."; return 0; fi
        echo -e "${C_CYAN}Нажмите [ENTER], если доступ прямой.${C_NC}"
        read -p "IP:порт SOCKS5 прокси (например 144.31.139.182:1080): " PROXY_INPUT </dev/tty
        if [ -z "$PROXY_INPUT" ]; then USE_PROXY_FLAG=false; PREFIX=""; warn "Прокси пропущен. Прямое соединение."; return 0; fi
        PROXY_IP=$(echo "$PROXY_INPUT" | cut -d: -f1); PROXY_PORT=$(echo "$PROXY_INPUT" | cut -d: -s -f2); [ -z "$PROXY_PORT" ] && PROXY_PORT=1080
        read -sp "Пароль для '$PROXY_USER' (Enter — без пароля): " PROXY_PASS </dev/tty; echo
    fi
    [ -z "$PROXY_PORT" ] && PROXY_PORT=1080
    info "Проверка соединения через ${PROXY_IP}:${PROXY_PORT}…"
    if fn_proxy_test; then ok "✅ Прокси работает."; else err "Через прокси не открывается ни claude.ai, ни google.com. Проверьте IP/порт/пароль."; exit 1; fi

    if ! command -v proxychains4 >/dev/null 2>&1; then
        [ "$PKG_MANAGER" = "apt" ] && apt-get update >>"$LOG" 2>&1
        fn_pkg_install proxychains-ng || { err "Не удалось установить proxychains-ng (на CentOS нужен EPEL; см. $LOG)"; exit 1; }
    fi
    fn_proxy_conf_path
    [ -f "$PROXYCHAINS_CONF_FILE" ] && cp -f "$PROXYCHAINS_CONF_FILE" "${PROXYCHAINS_CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    run "cat > '$PROXYCHAINS_CONF_FILE' <<EOF
strict_chain
quiet_mode
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_IP $PROXY_PORT $PROXY_USER $PROXY_PASS
EOF"
    chmod 600 "$PROXYCHAINS_CONF_FILE" 2>/dev/null
    ok "Proxychains: ${PROXY_IP}:${PROXY_PORT}"
    USE_PROXY_FLAG=true; PREFIX="proxychains4 -q "
    export HTTPS_PROXY="" HTTP_PROXY=""   # pip/npm ходят через proxychains, а не через переменные
}

# ==============================================================================
# DOCKER
# ==============================================================================
fn_install_docker() {
    warn "--- Docker и Compose v2 ---"
    if ! command -v docker >/dev/null 2>&1; then
        if [ "$PKG_MANAGER" = "apt" ]; then
            run "${PREFIX}bash -c 'curl -fsSL https://get.docker.com | bash'" || { err "Установка Docker не удалась"; exit 1; }
        else
            fn_pkg_install yum-utils
            run "${PREFIX}yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
            fn_pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin || { err "Установка Docker не удалась"; exit 1; }
        fi
        run "systemctl enable --now docker"
        ok "Docker установлен."
    else
        ok "Docker уже установлен: $(docker --version 2>/dev/null)"
    fi
    if ! docker compose version >/dev/null 2>&1; then
        local plug=/usr/libexec/docker/cli-plugins; mkdir -p "$plug"
        run "${PREFIX}curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o $plug/docker-compose && chmod +x $plug/docker-compose"
    fi
    if $USE_PROXY_FLAG; then
        warn "Внимание: dockerd не умеет SOCKS5 — образы (postgres, caddy) тянутся напрямую. Если реестр недоступен, нужен HTTP-прокси в /etc/systemd/system/docker.service.d/http-proxy.conf."
    fi
}

# ==============================================================================
# NODE SANDBOX И CLAUDE CODE
# ==============================================================================
fn_install_nodejs_sandboxed() {
    [ -x "$NODE_DIR/bin/node" ] && return 0
    warn "--- Изолированный Node.js $NODE_VER ($NODE_DIR) ---"
    mkdir -p "$NODE_DIR"; local tmp; tmp=$(mktemp -d)
    local file url tarflag
    if fn_is_centos7; then
        file="node-${NODE_VER}-linux-x64-glibc-217.tar.gz"; url="https://unofficial-builds.nodejs.org/download/release/${NODE_VER}/${file}"; tarflag="-xzf"
        info "CentOS 7 (glibc 2.17) — неофициальная сборка."
    else
        file="node-${NODE_VER}-linux-x64.tar.xz"; url="https://nodejs.org/dist/${NODE_VER}/${file}"; tarflag="-xJf"
    fi
    run "${PREFIX}curl -fL -# '$url' -o '$tmp/$file'" || { err "Не удалось скачать Node.js"; rm -rf "$tmp"; exit 1; }
    run "tar $tarflag '$tmp/$file' -C '$NODE_DIR' --strip-components=1"; rm -rf "$tmp"
    ok "Node.js: $("$NODE_DIR/bin/node" --version 2>/dev/null)"
}

fn_claude_version() { timeout 20 "$1" --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }

# Поиск всех установок Claude Code: путь | тип | версия | владелец
fn_discover_claude() {
    local found=()
    local homes=(/root); for h in /home/*; do [ -d "$h" ] && homes+=("$h"); done
    for h in "${homes[@]}"; do
        local owner; owner=$(stat -c %U "$h" 2>/dev/null || echo root)
        [ -x "$h/.local/bin/claude" ] && found+=("$h/.local/bin/claude|native|$(fn_claude_version "$h/.local/bin/claude")|$owner")
        [ -x "$h/.claude/local/claude" ] && found+=("$h/.claude/local/claude|npm-local|$(fn_claude_version "$h/.claude/local/claude")|$owner")
        [ -x "$h/.claude/local/node_modules/.bin/claude" ] && found+=("$h/.claude/local/node_modules/.bin/claude|npm-local|$(fn_claude_version "$h/.claude/local/node_modules/.bin/claude")|$owner")
    done
    [ -x "$NODE_DIR/bin/claude" ] && found+=("$NODE_DIR/bin/claude|npm-sandbox|$(fn_claude_version "$NODE_DIR/bin/claude")|root")
    for p in /usr/local/lib/node_modules/@anthropic-ai/claude-code /usr/lib/node_modules/@anthropic-ai/claude-code; do
        [ -d "$p" ] && found+=("$p|npm-global|$(grep -oE '"version": *"[^"]+"' "$p/package.json" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')|root")
    done
    if [ -e /usr/local/bin/claude ]; then
        local t="wrapper"; [ -L /usr/local/bin/claude ] && t="symlink→$(readlink -f /usr/local/bin/claude)"
        found+=("/usr/local/bin/claude|$t|$(fn_claude_version /usr/local/bin/claude)|root")
    fi
    printf '%s\n' "${found[@]}"
}

fn_install_claude_native_for() {   # $1 = пользователь; ставит в его ~/.local/bin
    local u="$1" home; home=$(getent passwd "$u" | cut -d: -f6)
    if [ "$u" = "root" ]; then
        run "${PREFIX}bash -c 'curl -fsSL https://claude.ai/install.sh | bash'" || return 1
    else
        run "su - '$u' -c '${PREFIX}bash -c \"curl -fsSL https://claude.ai/install.sh | bash\"'" || return 1
    fi
    [ -x "$home/.local/bin/claude" ]
}

fn_expose_claude_globally() {   # /usr/local/bin/claude как копия/обёртка, доступная всем пользователям
    local src="$1"
    if [ -L /usr/local/bin/claude ] || [ ! -e /usr/local/bin/claude ] || grep -q 'vibe-node\|exec ' /usr/local/bin/claude 2>/dev/null; then
        run "rm -f /usr/local/bin/claude && install -m 755 '$src' /usr/local/bin/claude"
    fi
}

fn_install_claude_smart() {
    warn "--- Claude Code ---"
    if fn_is_centos7; then
        info "CentOS 7: нативный бинарник не запустится (glibc 2.17) — ставлю через npm в песочнице."
        fn_install_nodejs_sandboxed
        run "PATH='$NODE_DIR/bin:$PATH' ${PREFIX}'$NODE_DIR/bin/npm' install -g @anthropic-ai/claude-code@latest >>'$LOG' 2>&1" || { err "npm install не удался (см. $LOG)"; exit 1; }
        run "cat > /usr/local/bin/claude <<'EOF'
#!/bin/bash
unset NODE_ENV NODE_PATH
export PATH=\"$NODE_DIR/bin:\$PATH\"
exec $NODE_DIR/bin/claude \"\$@\"
EOF
chmod 755 /usr/local/bin/claude"
        ok "Claude Code (sandbox): $(fn_claude_version /usr/local/bin/claude)"
    else
        info "Нативный установщик Anthropic…"
        fn_install_claude_native_for root || { err "Бинарник claude не найден после установки."; exit 1; }
        fn_expose_claude_globally /root/.local/bin/claude
        ok "Claude Code: $(fn_claude_version /usr/local/bin/claude) (/usr/local/bin/claude — доступен всем пользователям)"
    fi
}

# ==============================================================================
# ОБНОВЛЕНИЕ СУЩЕСТВУЮЩИХ УСТАНОВОК + МИГРАЦИЯ СТАРОГО backlog-add
# ==============================================================================
fn_update_all_claude() {
    warn "--- Поиск установок Claude Code ---"
    local list; list=$(fn_discover_claude)
    if [ -z "$list" ]; then warn "Установок не найдено — ставлю заново."; fn_install_claude_smart; return; fi
    printf '  %-55s %-14s %-10s %s\n' "ПУТЬ" "ТИП" "ВЕРСИЯ" "ВЛАДЕЛЕЦ"
    while IFS='|' read -r p t v o; do printf '  %-55s %-14s %-10s %s\n' "$p" "$t" "${v:-?}" "$o"; done <<<"$list"
    echo
    ask "Обновить все до последней версии? (Y/n):" Y || return 0

    local latest=""; latest=$(${PREFIX}curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | grep -oE '"version": *"[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'); [ -n "$latest" ] && info "Последняя версия: $latest"
    while IFS='|' read -r p t v o; do
        case "$t" in
            native)
                info "Обновляю native ($o): $p"
                if [ "$o" = "root" ]; then run "${PREFIX}'$p' update >>'$LOG' 2>&1" || fn_install_claude_native_for root
                else run "su - '$o' -c '${PREFIX}\"$p\" update' >>'$LOG' 2>&1" || fn_install_claude_native_for "$o"; fi ;;
            npm-sandbox)
                info "Обновляю sandbox npm: $p"
                run "PATH='$NODE_DIR/bin:$PATH' ${PREFIX}'$NODE_DIR/bin/npm' install -g @anthropic-ai/claude-code@latest >>'$LOG' 2>&1" || warn "npm (sandbox) не обновился — см. $LOG" ;;
            npm-global)
                info "Обновляю npm-global: $p"
                if fn_is_centos7 || ! command -v curl >/dev/null; then run "${PREFIX}npm install -g @anthropic-ai/claude-code@latest >>'$LOG' 2>&1" || warn "npm -g не обновился"
                else
                    warn "npm-global устарел как способ установки — ставлю нативный бинарник и переключаю /usr/local/bin/claude на него."
                    fn_install_claude_native_for root && fn_expose_claude_globally /root/.local/bin/claude
                fi ;;
            npm-local)
                info "Старая установка ~/.claude/local ($o) — заменяю нативной."
                fn_install_claude_native_for "$o" || warn "Не удалось поставить нативную для $o" ;;
            *) : ;;
        esac
    done <<<"$list"
    # /usr/local/bin/claude: если это симлинк в /root/.local — другие пользователи его не запустят
    if [ -L /usr/local/bin/claude ] && [[ "$(readlink -f /usr/local/bin/claude)" == /root/* ]]; then
        fn_expose_claude_globally /root/.local/bin/claude; ok "/usr/local/bin/claude теперь копия, доступная всем пользователям."
    fi
    ok "Обновление Claude завершено. Версии:"; fn_discover_claude | while IFS='|' read -r p t v o; do printf '  %-55s %s\n' "$p" "${v:-?}"; done
}

fn_migrate_legacy_backlog() {   # старый скилл backlog-add / sheets_sync / Stop-хук → выключить, DevKit вместо них
    local h="$1" u="$2" moved=0
    if [ -d "$h/.claude/skills/backlog-add" ]; then
        if $OPT_KEEP_LEGACY; then warn "  $u: backlog-add оставлен (--keep-legacy)"; return 0; fi
        run "mv '$h/.claude/skills/backlog-add' '$h/.claude/skills/backlog-add.disabled.$(date +%Y%m%d)'"; moved=1
    fi
    if [ -f "$h/.claude/settings.json" ] && grep -q 'check_backlog_called' "$h/.claude/settings.json"; then
        run "python3 - '$h/.claude/settings.json' <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); h=d.get('hooks',{})
for ev in list(h): h[ev]=[x for x in h[ev] if not any('check_backlog_called' in (c.get('command') or '') for c in x.get('hooks',[]))]; h[ev] or h.pop(ev)
json.dump(d,open(p,'w'),ensure_ascii=False,indent=2)
PY"; moved=1
    fi
    [ -d "$h/.claude/sheets_sync" ] && warn "  $u: sheets_sync оставлен на месте (cron sync.php выключите после переезда: crontab -e)"
    [ $moved = 1 ] && ok "  $u: старый backlog-add отключён — журнал работ ведёт DevKit"
    return 0
}

fn_setup_devkit_for_user() {   # $1 = пользователь
    local u="$1" home; home=$(getent passwd "$u" | cut -d: -f6)
    [ -d "$home/.claude" ] || return 0
    echo
    info "--- MW DevKit для пользователя $u ($home) ---"
    if [ -s "$home/.config/mw-devkit/key" ]; then
        info "  ключ уже есть — обновляю скилл и хуки"
        run "su - '$u' -c '${PREFIX}adflow update'" || warn "  adflow update не удался"
        fn_migrate_legacy_backlog "$home" "$u"; return 0
    fi
    if ask "  Подключить $u к DevKit сейчас? Нужен его рабочий e-mail и код из Битрикс24 (y/N):" N; then
        if [ "$u" = "root" ]; then run "${PREFIX}adflow login </dev/tty && ${PREFIX}adflow update"
        else run "su - '$u' -c '${PREFIX}adflow login </dev/tty && ${PREFIX}adflow update'"; fi \
          && fn_migrate_legacy_backlog "$home" "$u" || warn "  DevKit для $u не подключён — позже: adflow login && adflow update"
        warn "  Привязку проекта делают в каталоге репозитория: cd <проект> && adflow link"
    else
        warn "  Пропущено. Позже под $u: adflow login && adflow link && adflow update"
    fi
}

fn_setup_devkit() {
    echo; warn "--- Подключение к MEDIA WORKS DevKit ---"
    echo "Claude Code ведёт журнал работ проекта в AdFlow: вход по рабочему e-mail (код придёт в Битрикс24), выбор проекта, инструкции и хуки — из AdFlow."
    command -v python3 >/dev/null 2>&1 || fn_prepare_minimal
    run "${PREFIX}curl -fsSL '$ADFLOW_URL/devkit/cli' -o /usr/local/bin/adflow && chmod 755 /usr/local/bin/adflow" || { err "Не удалось скачать adflow из AdFlow"; return 1; }
    ok "adflow установлен ($(/usr/local/bin/adflow --help 2>&1 | head -n 1 | cut -c1-60)…)"
    local users=(root); for h in /home/*; do [ -d "$h/.claude" ] && users+=("$(stat -c %U "$h")"); done
    for u in "${users[@]}"; do fn_setup_devkit_for_user "$u"; done
}

# ==============================================================================
# PRESALE DEMO STACK
# ==============================================================================
fn_deploy_presale_stack() {
    warn "--- Presale Demo Stack ($DEMO_DIR) ---"
    if fn_is_centos7; then err "Presale-стек требует Python ≥ 3.9 и современный Docker — на CentOS 7 не поддерживается."; return 1; fi
    if [ -d "$DEMO_DIR/frontend" ] && ! ask "Стек уже развёрнут в $DEMO_DIR. Пересоздать (данные Postgres сохранятся)? (y/N):" N; then return 0; fi
    fn_install_nodejs_sandboxed
    local APP_DOMAIN="$OPT_DOMAIN" DB_PASS="$OPT_DBPASS"
    if [ -z "$APP_DOMAIN" ]; then $OPT_YES && APP_DOMAIN=localhost || { read -p "Домен для Caddy (по умолчанию localhost): " APP_DOMAIN </dev/tty; APP_DOMAIN=${APP_DOMAIN:-localhost}; }; fi
    if [ -z "$DB_PASS" ]; then
        if $OPT_YES; then DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20); else read -sp "Пароль PostgreSQL (Enter — сгенерировать): " DB_PASS </dev/tty; echo; DB_PASS=${DB_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}; fi
    fi
    mkdir -p "$DEMO_DIR"/{docker,backend}

    cat > "$DEMO_DIR/docker/docker-compose.yml" <<EOF
services:
  caddy:
    image: caddy:2
    container_name: vibe_caddy
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    extra_hosts: ["host.docker.internal:host-gateway"]
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
      POSTGRES_PASSWORD: "$DB_PASS"
      POSTGRES_DB: vibe_db
    ports: ["127.0.0.1:5432:5432"]
    volumes: ["pg_data:/var/lib/postgresql/data"]
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U vibe_admin -d vibe_db"], interval: 5s, retries: 10}
volumes:
  caddy_data:
  caddy_config:
  pg_data:
EOF
    cat > "$DEMO_DIR/docker/Caddyfile" <<EOF
$APP_DOMAIN {
    handle /api/* {
        reverse_proxy host.docker.internal:8000
    }
    handle {
        reverse_proxy host.docker.internal:5173
    }
}
EOF

    info "FastAPI бэкенд…"
    ( cd "$DEMO_DIR/backend" && python3 -m venv venv && . venv/bin/activate \
      && ${PREFIX}pip install --upgrade pip >>"$LOG" 2>&1 \
      && ${PREFIX}pip install "fastapi[standard]" "psycopg[binary]" sqlalchemy python-dotenv >>"$LOG" 2>&1 ) || { err "pip install не удался (см. $LOG)"; return 1; }
    cat > "$DEMO_DIR/backend/.env" <<EOF
DATABASE_URL=postgresql+psycopg://vibe_admin:${DB_PASS}@localhost:5432/vibe_db
EOF
    chmod 600 "$DEMO_DIR/backend/.env"
    cat > "$DEMO_DIR/backend/main.py" <<'EOF'
import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv

load_dotenv()
app = FastAPI(title="Presale Demo API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])


@app.get("/api/health")
def health_check():
    db_ok = False
    try:
        from sqlalchemy import create_engine, text
        with create_engine(os.environ["DATABASE_URL"]).connect() as c:
            db_ok = c.execute(text("select 1")).scalar() == 1
    except Exception:  # noqa: BLE001
        pass
    return {"status": "ok", "service": "Presale Demo API", "db": db_ok}
EOF

    info "React + Vite + Tailwind…"
    rm -rf "$DEMO_DIR/frontend"
    ( cd "$DEMO_DIR" && PATH="$NODE_DIR/bin:$PATH" CI=1 ${PREFIX}"$NODE_DIR/bin/npx" --yes create-vite@6 frontend --template react-ts </dev/null >>"$LOG" 2>&1 ) \
      || { err "create-vite не создал фронтенд (см. $LOG)"; return 1; }
    [ -d "$DEMO_DIR/frontend" ] || { err "Каталог frontend не появился"; return 1; }
    ( cd "$DEMO_DIR/frontend" && PATH="$NODE_DIR/bin:$PATH" ${PREFIX}"$NODE_DIR/bin/npm" install >>"$LOG" 2>&1 \
      && PATH="$NODE_DIR/bin:$PATH" ${PREFIX}"$NODE_DIR/bin/npm" install recharts lucide-react tailwindcss @tailwindcss/vite >>"$LOG" 2>&1 ) || { err "npm install не удался (см. $LOG)"; return 1; }
    cat > "$DEMO_DIR/frontend/vite.config.ts" <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: { host: '0.0.0.0', port: 5173, allowedHosts: true, hmr: { clientPort: 443 } },
})
EOF
    printf '@import "tailwindcss";\n' > "$DEMO_DIR/frontend/src/index.css"

    cat > "$DEMO_DIR/CLAUDE.md" <<'EOF'
# 🚀 PRESALE DEMO MODE ACTIVE

## 🎯 Главная цель
Вау-эффект для клиента. Продаём интерфейс и пользовательский опыт. Бэкенд должен просто работать; архитектурная чистота вторична.

## 🛠 Стек (уже установлен)
- **Frontend:** `/opt/vibe-demo/frontend` — React 18, Vite, TypeScript, Tailwind CSS v4 (`@import "tailwindcss"` в `src/index.css`), recharts, lucide-react. shadcn/ui — инициализируй сам при первой необходимости (`npx shadcn@latest init`).
- **Backend:** `/opt/vibe-demo/backend/main.py` — FastAPI, SQLAlchemy, PostgreSQL (`DATABASE_URL` в `.env`). Запуск: uvicorn на :8000, Caddy проксирует `/api/*`.
- **Запуск всего:** `/opt/vibe-demo/start_vibe.sh` (docker compose + tmux: backend/frontend).

## 📜 Правила вайбкодинга
1. **UI/UX в приоритете:** современные паттерны — дашборды, сайдбары, карточки, скелетоны при загрузке.
2. **Бизнес-фокус:** внутренний B2B-инструмент (CRM, ERP, ЛК, финансовый дашборд). Строго, стильно, дорого.
3. **Не усложняй бэкенд:** один-два файла API. CRUD работает и отдаёт данные — достаточно. Никаких микросервисов и DDD.
4. **Умные заглушки:** сложную логику (ML, биллинг) — хардкодь мок-данными. Клиент смотрит на визуал.
5. **Меньше вопросов, больше кода:** действуй уверенно, генерируй компоненты сразу.
EOF

    info "Git…"
    ( cd "$DEMO_DIR" && { [ -d .git ] || git init -q; } && git config user.name "VibeEnv Auto" && git config user.email "auto@vibe.env" \
      && printf 'node_modules/\nvenv/\n.env\n__pycache__/\ndist/\n' > .gitignore && git add -A >/dev/null 2>&1 && git commit -qm "feat: presale demo stack" >/dev/null 2>&1 || true )

    cat > "$DEMO_DIR/start_vibe.sh" <<EOF
#!/bin/bash
cd $DEMO_DIR/docker && docker compose up -d
tmux kill-session -t vibe_demo 2>/dev/null
tmux new-session -d -s vibe_demo -n backend
tmux send-keys -t vibe_demo:0 "cd $DEMO_DIR/backend && source venv/bin/activate && uvicorn main:app --host 0.0.0.0 --port 8000 --reload" C-m
tmux new-window -t vibe_demo:1 -n frontend
tmux send-keys -t vibe_demo:1 "export PATH=\"$NODE_DIR/bin:\$PATH\" && cd $DEMO_DIR/frontend && npm run dev" C-m
[ -t 0 ] && tmux attach-session -t vibe_demo
EOF
    chmod +x "$DEMO_DIR/start_vibe.sh"
    ok "Presale-стек готов: $DEMO_DIR (домен $APP_DOMAIN, Postgres только на 127.0.0.1, пароль в backend/.env)"
}

# ==============================================================================
# МЕНЮ
# ==============================================================================
fn_finish_message() {
    echo; ok "======================================================================"; ok "                      ГОТОВО"; ok "======================================================================"
    local pc=""; $USE_PROXY_FLAG && pc="proxychains4 -q "
    echo -e "Авторизация Claude: запустите ${C_BLUE}${pc}claude${C_NC} и выполните ${C_BLUE}/login${C_NC}"
    echo -e "Журнал работ: в каталоге проекта ${C_BLUE}adflow link${C_NC}; в конце работы скажите Claude «закрой таск»."
    echo -e "Лог установки: $LOG"
}

fn_interactive_menu() {
    fn_show_logo
    local existing; existing=$(fn_discover_claude | head -n 3)
    if [ -n "$existing" ] && [ -z "$OPT_PROFILE" ]; then
        echo -e "${C_YELLOW}На сервере уже есть Claude Code:${C_NC}"; while IFS='|' read -r p t v o; do echo "   $p ($t, ${v:-?}, $o)"; done <<<"$existing"; echo
    fi
    echo -e "${C_CYAN}======================================================================${C_NC}"
    echo -e "                 ${C_YELLOW}МЕНЮ РАЗВЕРТЫВАНИЯ: СИСТЕМНЫЙ ИНТЕГРАТОР${C_NC}"
    echo -e "${C_CYAN}======================================================================${C_NC}"
    echo
    echo -e "  ${C_GREEN}[1] Minimal Edition: Claude Code + DevKit${C_NC}          (для закрытых серверов клиентов)"
    echo -e "  ${C_BLUE}[2] Full VibeEnv Stack: Claude + Docker + Presale Demo${C_NC}  (демо-стенд: FastAPI + React + Caddy + Postgres)"
    echo -e "  ${C_YELLOW}[3] Infrastructure Only: Docker + Tools + Claude${C_NC}"
    echo -e "  ${C_CYAN}[4] Proxy Reconfigure: настройка сети${C_NC}"
    echo -e "  ${C_GREEN}[5] Update: обновить ВСЕ установки Claude + подключить DevKit${C_NC}  (любые способы установки, старый backlog-add → DevKit)"
    echo -e "  [0] Выход"
    echo
    local CHOICE="$OPT_PROFILE"
    [ -z "$CHOICE" ] && { read -p " Выберите профиль (0-5): " CHOICE </dev/tty; echo; }
    case "$CHOICE" in
        1) fn_setup_proxy; fn_prepare_minimal; fn_install_claude_smart; fn_setup_devkit ;;
        2) fn_setup_proxy; fn_prepare_full; fn_install_docker; fn_install_claude_smart; fn_deploy_presale_stack; fn_setup_devkit ;;
        3) fn_setup_proxy; fn_prepare_full; fn_install_docker; fn_install_claude_smart; fn_setup_devkit ;;
        4) fn_setup_proxy; exit 0 ;;
        5) fn_setup_proxy; fn_prepare_minimal; fn_update_all_claude; fn_setup_devkit ;;
        0) echo "Отмена."; exit 0 ;;
        *) err "Недопустимый код профиля."; exit 1 ;;
    esac
    fn_finish_message
    if [ "$CHOICE" = "2" ] && [ -x "$DEMO_DIR/start_vibe.sh" ] && ! $OPT_YES && ! $OPT_DRY; then
        echo -e "\n${C_YELLOW}Запускаю демо-стенд через 5 секунд (Ctrl+b, d — отключиться от tmux)…${C_NC}"; sleep 5; "$DEMO_DIR/start_vibe.sh"
    fi
}

fn_parse_args "$@"
fn_check_root
fn_detect_os
fn_interactive_menu
