#!/bin/bash
# ==============================================================================
# Установщик MEDIA WORKS: Claude Code, MW DevKit, Docker & Presale Demo Stack
#   Запускать из КОРНЯ ПРОЕКТА (например cd /home/bitrix) — DevKit привязывает Claude к проекту по текущему каталогу.
#   bash install-proxy.sh                      — интерактивное меню
#   bash install-proxy.sh update               — мастер обновления: все установки Claude + DevKit (с вопросами)
#   bash install-proxy.sh update --yes         — то же без вопросов (рекомендуемые ответы)
#   Флаги: --profile N | --proxy IP:PORT[:пароль] | --proxy adflow (из AdFlow по ключу DevKit) | --no-proxy | --method native|npm|auto | --ascii | --yes | --dry-run | --keep-legacy | --domain D | --db-pass P
# ==============================================================================
set -o pipefail

ADFLOW_URL="${ADFLOW_URL:-https://adflow.mworx.ru/api/v1}"
NODE_DIR="/opt/vibe-node"; NODE_VER="v20.18.0"; DEMO_DIR="/opt/vibe-demo"
PKG_MANAGER=""; OS_ID=""; OS_VERSION=""
PROXY_IP=""; PROXY_PORT=""; PROXY_USER="proxyuser"; PROXY_PASS=""; PROXYCHAINS_CONF_FILE=""
USE_PROXY_FLAG=false; PREFIX=""
OPT_PROFILE=""; OPT_PROXY=""; OPT_YES=false; OPT_DRY=false; OPT_KEEP_LEGACY=false; OPT_DOMAIN=""; OPT_DBPASS=""
LOG="/var/log/mw-install.log"
if { : </dev/tty; } 2>/dev/null; then IN=/dev/tty; else exec 3<&0; IN=/dev/fd/3; fi   # ответы читаем с терминала; без него — из исходного stdin (fd 3, не зависит от here-string в циклах)
NATIVE_OK=true; OPT_METHOD="auto"

for _a in "$@"; do [ "$_a" = "--ascii" ] && export MW_ASCII=1; done
# ---------- UI: цвета через tput (PuTTY/старые терминалы), UTF-8 или ASCII-символы, спиннер ----------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_BLUE=$(tput setaf 4); C_CYAN=$(tput setaf 6); C_DIM=$(tput dim 2>/dev/null || tput setaf 8 2>/dev/null); C_BOLD=$(tput bold); C_NC=$(tput sgr0)
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_DIM=''; C_BOLD=''; C_NC=''
fi
# символы: по умолчанию UTF-8 (самый красивый режим); чистый ASCII — только по --ascii или MW_ASCII=1 (PuTTY без UTF-8)
if [ -z "${MW_ASCII:-}" ]; then
    S_OK='✓'; S_FAIL='✗'; S_ARR='→'; S_DOT='•'; S_LINE='─'; S_SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
else
    S_OK='OK'; S_FAIL='X'; S_ARR='->'; S_DOT='*'; S_LINE='-'; S_SPIN='|/-\'
fi
COLS=$(tput cols 2>/dev/null || echo 87); [ "$COLS" -gt 87 ] && COLS=87
hr()   { local l="" i; for ((i=0; i<COLS; i++)); do l+="$S_LINE"; done; printf '%s%s%s\n' "$C_DIM" "$l" "$C_NC"; }
STEP_N=0; STEP_TOTAL=0
step() { STEP_N=$((STEP_N+1)); echo; printf '  %s%s %s%s %s%s/%s%s\n' "$C_CYAN" "$S_DOT" "$C_BOLD" "$1" "$C_DIM" "$STEP_N" "${STEP_TOTAL:-?}" "$C_NC"; echo "$(date '+%F %T') === [$STEP_N] $1" >> "$LOG" 2>/dev/null; }
log()  { echo -e "$1"; echo -e "$(date '+%F %T') $1" | sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\(B//g' >> "$LOG" 2>/dev/null; }
info() { log "   $1"; }
ok()   { log "   ${C_GREEN}${S_OK}${C_NC} $1"; }
warn() { log "   ${C_YELLOW}!${C_NC} $1"; }
err()  { log "   ${C_RED}${S_FAIL} $1${C_NC}"; }
run()  { if $OPT_DRY; then echo "   ${C_DIM}[dry-run] $*${C_NC}"; return 0; fi; echo "$(date '+%F %T') \$ $*" >> "$LOG"; eval "$@" </dev/null; }
# spin "описание" команда… — спиннер и время; весь вывод команды в лог; таймаут SPIN_TIMEOUT (сек, по умолчанию 900)
spin() {
    local title="$1"; shift
    if $OPT_DRY; then echo "   ${C_DIM}[dry-run] $title: $*${C_NC}"; return 0; fi
    echo "$(date '+%F %T') >>> $title: $*" >> "$LOG"
    local start=$(date +%s) limit="${SPIN_TIMEOUT:-900}" rc
    ( eval "$@" ) </dev/null >>"$LOG" 2>&1 & local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ $(( $(date +%s) - start )) -ge "$limit" ]; then kill "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; echo "$(date '+%F %T') !!! таймаут ${limit}s: $title" >> "$LOG"; [ -t 1 ] && printf '\r\033[K'; err "$title — таймаут ${limit}s (подробности: $LOG)"; return 124; fi
        [ -t 1 ] && printf '\r   %s%s%s %s… %ss' "$C_CYAN" "${S_SPIN:$((i % ${#S_SPIN})):1}" "$C_NC" "$title" "$(( $(date +%s) - start ))"; i=$((i+1)); sleep 0.25
    done
    wait "$pid"; rc=$?; [ -t 1 ] && printf '\r\033[K'
    local dur=$(( $(date +%s) - start ))
    if [ $rc -eq 0 ]; then ok "$title ${C_DIM}(${dur}s)${C_NC}"; else err "$title — ошибка (${dur}s), подробности: $LOG"; fi
    return $rc
}
ask()  { local q="$1" def="${2:-N}" a; if $OPT_YES; then [[ "$def" =~ ^[Yy]$ ]]; return; fi; echo; read -p "   ${C_BOLD}$q${C_NC} " a <"$IN"; a=${a:-$def}; [[ "$a" =~ ^[YyДд]$ ]]; }
# choose "Вопрос" "номер по умолчанию" "описание" … → CHOSEN (номер, начиная с 1)
choose() { local q="$1" def="$2"; shift 2; local opts=("$@") a i=0 opt; echo; printf '   %s%s%s\n' "$C_BOLD" "$q" "$C_NC"
           for opt in "${opts[@]}"; do i=$((i+1)); if [ "$i" = "$def" ]; then printf '     %s%s%s  %s   %s%s%s\n' "$C_CYAN" "$i" "$C_NC" "$opt" "$C_DIM" "$S_ARR Enter" "$C_NC"; else printf '     %s%s%s  %s\n' "$C_CYAN" "$i" "$C_NC" "$opt"; fi; done
           if $OPT_YES; then CHOSEN="$def"; return; fi
           while true; do read -p "     ${S_ARR} " a <"$IN"; a=${a:-$def}; [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le ${#opts[@]} ] && { CHOSEN="$a"; return; }; echo "     Введите номер 1–${#opts[@]}."; done; }

# ==============================================================================
# БАЗА
# ==============================================================================
fn_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile) OPT_PROFILE="$2"; shift ;;
            update) OPT_PROFILE=5 ;;
            --proxy) OPT_PROXY="$2"; shift ;;
            --no-proxy) OPT_PROXY="none" ;;
            --yes|-y) OPT_YES=true ;;
            --dry-run) OPT_DRY=true ;;
            --keep-legacy) OPT_KEEP_LEGACY=true ;;
            --domain) OPT_DOMAIN="$2"; shift ;;
            --db-pass) OPT_DBPASS="$2"; shift ;;
            --method) OPT_METHOD="$2"; shift ;;      # native | npm | auto
            --ascii) export MW_ASCII=1 ;;
            -h|--help) sed -n 2,7p "$0"; exit 0 ;;
            *) err "Неизвестный флаг: $1"; exit 1 ;;
        esac
        shift
    done
}

fn_show_logo() {
    $OPT_YES || clear
    echo
    printf '%s%s' "$C_BOLD" "$C_CYAN"
    if [ "$S_OK" = '✓' ]; then
        echo '  ███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗'
        echo '  ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝'
        echo '  ██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗'
        echo '  ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║'
        echo '  ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║'
        echo '  ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝'
    else
        echo '  ###    ### ####### ######  ##  #####      ##     ##  ######  ######  ##   ## #######'
        echo '  ####  #### ##      ##   ## ## ##   ##     ##     ## ##    ## ##   ## ##  ##  ##'
        echo '  ## #### ## #####   ##   ## ## #######     ##  #  ## ##    ## ######  #####   #######'
        echo '  ##  ##  ## ##      ##   ## ## ##   ##     ## ### ## ##    ## ##   ## ##  ##       ##'
        echo '  ##      ## ####### ######  ## ##   ##      ### ###   ######  ##   ## ##   ## #######'
        echo ''
    fi
    printf '%s' "$C_NC"
    local l="" i; for ((i=0; i<87; i++)); do l+="$S_LINE"; done
    printf '  %s%s%s\n' "$C_DIM" "$l" "$C_NC"
    printf '  %sУстановщик MEDIA WORKS%s   %sClaude Code %s MW DevKit %s Docker %s Presale Demo Stack%s\n' "$C_BOLD" "$C_NC" "$C_DIM" "$S_DOT" "$S_DOT" "$S_DOT" "$C_NC"
    printf '  %s%s%s\n' "$C_DIM" "$l" "$C_NC"
    if fn_is_web_root; then printf '  %sКаталог проекта: %s — это веб-корень (www), запускайте уровнем выше%s\n' "$C_RED" "$(pwd -P)" "$C_NC"
    elif fn_is_home_dir; then printf '  %sКаталог проекта: %s — это домашний каталог, запускайте из корня проекта%s\n' "$C_YELLOW" "$(pwd -P)" "$C_NC"
    else printf '  %sКаталог проекта:%s %s\n' "$C_DIM" "$C_NC" "$(pwd -P)"; fi
    echo
}

fn_check_root() { [ "$EUID" -ne 0 ] && { err "Запуск только от root (или sudo)."; exit 1; }; return 0; }

fn_is_home_dir() {   # /, /root, /home/<user>, $HOME — не каталог проекта
    local d; d=$(pwd -P)
    [ "$d" = "/" ] || [ "$d" = "/root" ] || [ "$d" = "${HOME:-/root}" ] || [[ "$d" =~ ^/home/[^/]+/?$ ]] || [ "$d" = "/tmp" ]
}

fn_is_web_root() {   # веб-корень (www, public_html, htdocs, public) — сюда ничего служебного класть нельзя
    local d; d=$(pwd -P)
    [[ "$d" =~ (^|/)(www|public_html|htdocs|public|web)(/|$) ]] || [ -f "$d/bitrix/php_interface/dbconn.php" ] || [ -d "$d/bitrix/modules" ]
}

fn_require_project_dir() {   # DevKit привязывает Claude к проекту по текущему каталогу — запуск должен быть из него
    if fn_is_web_root && ! $OPT_YES; then
        echo
        err "Вы в каталоге $(pwd -P) — это веб-корень сайта (www)."
        info "Claude, DevKit и служебные каталоги (.claude, claude_docs, .example) нельзя размещать внутри www — они станут доступны из интернета."
        info "Запускайте из корня проекта уровнем выше:"
        printf '   %scd %s && bash %s%s\n' "$C_BOLD" "$(dirname "$(pwd -P)")" "$(basename "$0")" "$C_NC"
        exit 1
    fi
    if fn_is_home_dir && ! $OPT_YES; then
        echo
        err "Вы в каталоге $(pwd -P) — это домашний каталог, а не проект."
        info "Установщик привязывает Claude к проекту по каталогу, из которого запущен. Перейдите в корень проекта и запустите снова:"
        printf '   %scd /home/bitrix && bash %s%s\n' "$C_BOLD" "$(basename "$0")" "$C_NC"
        info "${C_DIM}(для Битрикса корень проекта — /home/bitrix, не /home/bitrix/www)${C_NC}"
        exit 1
    fi
}

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

fn_missing_pkgs() {   # пакет:команда … → список пакетов, чьей команды нет
    local out=() x; for x in "$@"; do local pkg="${x%%:*}" cmd="${x#*:}"; [ "$cmd" = "-" ] && { out+=("$pkg"); continue; }; command -v "$cmd" >/dev/null 2>&1 || out+=("$pkg"); done; echo "${out[@]}"
}
PREPARED_MIN=false
fn_prepare_minimal() {
    $PREPARED_MIN && return 0; PREPARED_MIN=true
    step "Базовые утилиты"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get update >>"$LOG" 2>&1 || warn "apt-get update завершился с ошибкой (см. $LOG) — продолжаю"
        local need opt; need=$(fn_missing_pkgs curl:curl python3:python3 tar:tar ca-certificates:-); opt=$(fn_missing_pkgs wget:wget jq:jq xz-utils:xz)
        [ -n "$need" ] && { spin "пакеты: $need" fn_pkg_install $need || exit 1; } || ok "curl, python3, tar уже есть"
        [ -n "$opt" ] && { spin "дополнительно: $opt" fn_pkg_install $opt || warn "необязательные пакеты ($opt) не поставились — продолжаю"; }
    else
        if fn_is_centos7; then
            sed -i 's/^mirrorlist/#mirrorlist/g; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
        fi
        fn_pkg_install epel-release >/dev/null 2>&1 || true
        local need opt; need=$(fn_missing_pkgs curl:curl python3:python3 tar:tar); opt=$(fn_missing_pkgs wget:wget jq:jq xz:xz)
        [ -n "$need" ] && { spin "пакеты: $need" fn_pkg_install $need || exit 1; } || ok "curl, python3, tar уже есть"
        [ -n "$opt" ] && { spin "дополнительно: $opt" fn_pkg_install $opt || warn "необязательные пакеты ($opt) не поставились — продолжаю"; }
    fi
}

fn_prepare_full() {
    fn_prepare_minimal
    step "Зависимости для разработки"
    if [ "$PKG_MANAGER" = "apt" ]; then
        local need; need=$(fn_missing_pkgs git:git build-essential:gcc htop:htop tmux:tmux python3-venv:- python3-pip:pip3)
        [ -n "$need" ] && { spin "пакеты: $need" fn_pkg_install $need || exit 1; } || ok "инструменты разработки уже есть"
    else
        local need; need=$(fn_missing_pkgs git:git gcc-c++:g++ make:make htop:htop tmux:tmux python3-pip:pip3)
        [ -n "$need" ] && { spin "пакеты: $need" fn_pkg_install $need || exit 1; } || ok "инструменты разработки уже есть"
    fi
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

fn_direct_test() {   # без прокси: доступен ли claude.ai напрямую
    local code; code=$(curl -sSL -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 25 https://claude.ai/install.sh 2>>"$LOG")
    if [ "$code" = "200" ]; then NATIVE_OK=true; else NATIVE_OK=false; info "${C_DIM}claude.ai напрямую закрыт — Claude поставим через npm${C_NC}"; fi
}

fn_proxy_test() {   # 0 — интернет есть; NATIVE_OK=false, если claude.ai не отдаёт установщик (403 Cloudflare для датацентровых IP)
    local auth=""; [ -n "$PROXY_PASS" ] && auth="$(fn_urlenc "$PROXY_USER"):$(fn_urlenc "$PROXY_PASS")@"
    local px="socks5h://${auth}${PROXY_IP}:${PROXY_PORT}" code
    code=$(curl -x "$px" -sSL -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 25 https://claude.ai/install.sh 2>>"$LOG")
    echo "$(date '+%F %T') claude.ai/install.sh через прокси: HTTP $code" >> "$LOG"
    if [ "$code" = "200" ]; then NATIVE_OK=true; return 0; fi
    NATIVE_OK=false
    curl -x "$px" -fsS -o /dev/null --connect-timeout 10 --max-time 25 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>>"$LOG"
}

fn_adflow_direct() { curl -fsS -o /dev/null --connect-timeout 8 --max-time 20 "$ADFLOW_URL/devkit/install.sh" 2>>"$LOG"; }

fn_ensure_adflow_cli() {   # adflow ставится напрямую с AdFlow (прокси не нужен)
    [ -x /usr/local/bin/adflow ] && return 0
    command -v python3 >/dev/null 2>&1 || fn_prepare_minimal
    spin "Утилита adflow из AdFlow" "curl -fsSL --max-time 60 '$ADFLOW_URL/devkit/cli' -o /usr/local/bin/adflow && chmod 755 /usr/local/bin/adflow"
}

fn_proxy_from_adflow() {   # параметры SOCKS5 из AdFlow по личному ключу → PROXY_*; 0 — получены
    fn_ensure_adflow_cli || return 1
    if [ -z "${ADFLOW_DEV_KEY:-}" ] && [ ! -s /root/.config/mw-devkit/key ]; then
        info "${C_DIM}настройки сети хранятся в AdFlow и выдаются после входа в DevKit${C_NC}"
        if ask "Войти в DevKit сейчас? Код придёт в Битрикс24 (Y/n):" Y; then fn_devkit_login root || return 1; else return 1; fi
    fi
    local js; js=$(adflow proxy 2>>"$LOG") || return 1
    echo "$js" | grep -q '"configured": true' || { warn "в AdFlow прокси не настроен (devkit.proxy)"; return 1; }
    PROXY_IP=$(echo "$js" | python3 -c 'import sys,json; print(json.load(sys.stdin)["host"])'); PROXY_PORT=$(echo "$js" | python3 -c 'import sys,json; print(json.load(sys.stdin)["port"])')
    PROXY_USER=$(echo "$js" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("user") or "proxyuser")'); PROXY_PASS=$(echo "$js" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("pass") or "")')
    ok "Параметры прокси получены из AdFlow: ${PROXY_IP}:${PROXY_PORT}"
}

fn_setup_proxy() {
    step "Сеть"
    command -v curl >/dev/null 2>&1 || fn_prepare_minimal
    if [ "$OPT_PROXY" = "none" ]; then USE_PROXY_FLAG=false; PREFIX=""; ok "Прямое соединение (--no-proxy)."; fn_direct_test; return 0; fi
    if [ "$OPT_PROXY" = "adflow" ]; then fn_proxy_from_adflow || { err "Не удалось получить прокси из AdFlow"; exit 1; }
    elif [ -n "$OPT_PROXY" ]; then
        PROXY_IP=$(echo "$OPT_PROXY" | cut -d: -f1); PROXY_PORT=$(echo "$OPT_PROXY" | cut -d: -f2); PROXY_PASS=$(echo "$OPT_PROXY" | cut -d: -s -f3-)
    elif fn_proxy_read_existing; then
        choose "Сеть: прокси ${PROXY_IP}:${PROXY_PORT} уже настроен" 1 "Использовать его" "Настроить заново"
        [ "$CHOSEN" = 2 ] && PROXY_IP=""
    fi
    if [ -z "$PROXY_IP" ] && [ "$OPT_PROXY" != "none" ]; then
        local direct; direct=$(curl -sSL -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 https://claude.ai/install.sh 2>>"$LOG")
        if [ "$direct" = "200" ]; then ok "Интернет есть, claude.ai открывается напрямую — прокси не нужен"; NATIVE_OK=true; USE_PROXY_FLAG=false; PREFIX=""; return 0; fi
        if fn_adflow_direct; then
            choose "claude.ai отсюда не открывается. Прокси:" 1 "Взять из AdFlow (после входа в DevKit)" "Ввести вручную" "Работать без прокси"
            case "$CHOSEN" in 1) fn_proxy_from_adflow || warn "не получилось — введите вручную";; 3) USE_PROXY_FLAG=false; PREFIX=""; fn_direct_test; return 0;; esac
        fi
    fi
    if [ -z "$PROXY_IP" ]; then
        if $OPT_YES; then USE_PROXY_FLAG=false; PREFIX=""; warn "Прокси не задан — прямое соединение."; fn_direct_test; return 0; fi
        echo; read -p "   ${C_BOLD}SOCKS5 прокси IP:порт${C_NC} ${C_DIM}(Enter — без прокси)${C_NC}: " PROXY_INPUT <"$IN"
        if [ -z "$PROXY_INPUT" ]; then USE_PROXY_FLAG=false; PREFIX=""; warn "Прямое соединение."; fn_direct_test; return 0; fi
        PROXY_IP=$(echo "$PROXY_INPUT" | cut -d: -f1); PROXY_PORT=$(echo "$PROXY_INPUT" | cut -d: -s -f2); [ -z "$PROXY_PORT" ] && PROXY_PORT=1080
        read -sp "   Пароль $PROXY_USER (Enter — без пароля): " PROXY_PASS <"$IN"; echo
    fi
    [ -z "$PROXY_PORT" ] && PROXY_PORT=1080
    if spin "Проверка прокси ${PROXY_IP}:${PROXY_PORT}" fn_proxy_test; then :; else err "Через прокси не открываются ни claude.ai, ни registry.npmjs.org — проверьте IP/порт/пароль."; exit 1; fi
    $NATIVE_OK || info "${C_DIM}claude.ai через этот прокси закрыт — Claude поставим через npm${C_NC}"

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
    ok "Proxychains ${S_ARR} ${PROXY_IP}:${PROXY_PORT}"
    USE_PROXY_FLAG=true; PREFIX="proxychains4 -q "
    export HTTPS_PROXY="" HTTP_PROXY=""   # pip/npm ходят через proxychains, а не через переменные
}

# ==============================================================================
# DOCKER
# ==============================================================================
fn_install_docker() {
    step "Docker"
    if ! command -v docker >/dev/null 2>&1; then
        if [ "$PKG_MANAGER" = "apt" ]; then
            SPIN_TIMEOUT=900 spin "Установка Docker (get.docker.com)" "${PREFIX}bash -c 'curl -fsSL https://get.docker.com | bash'" || exit 1
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
    STEP_TOTAL=$((STEP_TOTAL+1)); step "Node.js $NODE_VER (песочница $NODE_DIR)"
    mkdir -p "$NODE_DIR"; local tmp; tmp=$(mktemp -d)
    local file url tarflag
    if fn_is_centos7; then
        file="node-${NODE_VER}-linux-x64-glibc-217.tar.gz"; url="https://unofficial-builds.nodejs.org/download/release/${NODE_VER}/${file}"; tarflag="-xzf"
        info "CentOS 7 (glibc 2.17) — неофициальная сборка."
    else
        file="node-${NODE_VER}-linux-x64.tar.xz"; url="https://nodejs.org/dist/${NODE_VER}/${file}"; tarflag="-xJf"
    fi
    SPIN_TIMEOUT=600 spin "Скачивание Node.js $NODE_VER" "${PREFIX}curl -fsSL --retry 2 '$url' -o '$tmp/$file'" || { rm -rf "$tmp"; return 1; }
    [ -s "$tmp/$file" ] || { err "архив Node.js пустой — сеть до nodejs.org недоступна (см. $LOG)"; rm -rf "$tmp"; return 1; }
    run "tar $tarflag '$tmp/$file' -C '$NODE_DIR' --strip-components=1"; rm -rf "$tmp"
    [ -x "$NODE_DIR/bin/node" ] || { err "Node.js не распаковался (см. $LOG)"; return 1; }
    ok "Node.js $("$NODE_DIR/bin/node" --version 2>/dev/null)"
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

fn_install_claude_native_for() {   # $1 = пользователь; нативный установщик Anthropic (claude.ai/install.sh) в ~/.local/bin
    local u="$1" home; home=$(getent passwd "$u" | cut -d: -f6)
    $NATIVE_OK || { warn "нативный установщик недоступен через текущую сеть"; return 1; }
    if [ "$u" = "root" ]; then
        SPIN_TIMEOUT=600 spin "Claude Code, нативный установщик ($u)" "${PREFIX}bash -c 'curl -fsSL --max-time 60 https://claude.ai/install.sh | bash'" || return 1
    else
        SPIN_TIMEOUT=600 spin "Claude Code, нативный установщик ($u)" "su - '$u' -c '${PREFIX}bash -c \"curl -fsSL --max-time 60 https://claude.ai/install.sh | bash\"'" || return 1
    fi
    [ -x "$home/.local/bin/claude" ]
}

fn_system_node_ok() { command -v node >/dev/null 2>&1 && [ "$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)" -ge 18 ] 2>/dev/null; }

fn_install_claude_npm() {   # второй способ: npm из registry.npmjs.org — системный Node ≥ 18 или песочница /opt/vibe-node
    local npm_bin="npm" node_hint="системный Node $(node -v 2>/dev/null)"
    if ! fn_system_node_ok; then fn_install_nodejs_sandboxed || return 1; npm_bin="$NODE_DIR/bin/npm"; node_hint="песочница $NODE_DIR"; fi
    SPIN_TIMEOUT=900 spin "Claude Code через npm ($node_hint)" "PATH='$NODE_DIR/bin:$PATH' ${PREFIX}$npm_bin install -g @anthropic-ai/claude-code@latest" || return 1
    local bin; bin=$(PATH="$NODE_DIR/bin:$PATH" command -v claude 2>/dev/null || ls "$NODE_DIR/bin/claude" 2>/dev/null | head -n 1)
    [ -n "$bin" ] || { err "после npm install бинарник claude не найден"; return 1; }
    if [[ "$bin" == "$NODE_DIR/"* ]]; then
        run "cat > /usr/local/bin/claude <<'EOF'
#!/bin/bash
unset NODE_ENV NODE_PATH
export PATH=\"$NODE_DIR/bin:\$PATH\"
exec $NODE_DIR/bin/claude \"\$@\"
EOF
chmod 755 /usr/local/bin/claude"
    elif [ "$bin" != "/usr/local/bin/claude" ] && [ ! -e /usr/local/bin/claude ]; then run "ln -sf '$bin' /usr/local/bin/claude"; fi
    return 0
}

fn_fix_claude_path() {   # старые ссылки npm (/usr/bin/claude → node_modules) после замены нативной: перевести на /usr/local/bin/claude
    for lnk in /usr/bin/claude /usr/local/bin/claude; do
        if [ -L "$lnk" ] && [ ! -e "$lnk" ]; then run "rm -f '$lnk'"; fi
    done
    if [ ! -e /usr/bin/claude ] && [ -x /usr/local/bin/claude ]; then run "ln -s /usr/local/bin/claude /usr/bin/claude"; fi
    hash -r 2>/dev/null
}

fn_expose_claude_globally() {   # /usr/local/bin/claude как копия/обёртка, доступная всем пользователям
    local src="$1"
    if [ -L /usr/local/bin/claude ] || [ ! -e /usr/local/bin/claude ] || grep -q 'vibe-node\|exec ' /usr/local/bin/claude 2>/dev/null; then
        run "rm -f /usr/local/bin/claude && install -m 755 '$src' /usr/local/bin/claude"
    fi
}

fn_install_claude_smart() {   # auto: нативный → при недоступности/ошибке npm; --method native|npm — принудительно
    step "Claude Code"
    local method="$OPT_METHOD"
    fn_is_centos7 && method="npm"
    if [ "$method" = "auto" ]; then $NATIVE_OK && method="native" || method="npm"; fi
    if [ "$method" = "native" ]; then
        if fn_install_claude_native_for root; then fn_expose_claude_globally /root/.local/bin/claude
        else warn "нативная установка не удалась — пробую через npm"; fn_install_claude_npm || { err "Claude Code не установлен ни одним способом (см. $LOG)"; exit 1; }; fi
    else
        fn_install_claude_npm || { err "npm-установка не удалась (см. $LOG)"; exit 1; }
    fi
    fn_fix_claude_path
    ok "Claude Code ${C_BOLD}$(fn_claude_version /usr/local/bin/claude 2>/dev/null || fn_claude_version "$(command -v claude)")${C_NC} установлен"
}

# ==============================================================================
# МАСТЕР ОБНОВЛЕНИЯ: Claude Code + миграция backlog-add + DevKit (диалоговый)
# ==============================================================================
PLAN=()            # строки плана «что сделаем»
PLAN_CLAUDE=()     # path|type|owner|action  (update|native|skip)
PLAN_USERS=()      # user|home|devkit(login|update|skip)|legacy(off|keep)

fn_type_label() { case "$1" in native) echo "официальная установка";; npm-sandbox) echo "через npm (песочница)";; npm-global) echo "через npm (устаревший способ)";; npm-local) echo "старая установка ~/.claude/local";; wrapper) echo "обёртка";; symlink*) echo "ссылка";; *) echo "$1";; esac; }

fn_wizard_claude() {
    step "Claude Code"
    local list; list=$(fn_discover_claude)
    if [ -z "$list" ]; then
        warn "Установок Claude не найдено."
        if ask "Установить Claude Code? (Y/n):" Y; then PLAN+=("Установить Claude Code"); PLAN_CLAUDE+=("|install|root|install"); fi
        return 0
    fi
    local latest; latest=$(${PREFIX}curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null </dev/null | grep -oE '"version": *"[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    local i=0
    while IFS='|' read -r p t v o; do [[ "$t" == wrapper || "$t" == symlink* ]] && continue; i=$((i+1))
        local mark=""
        if [ "$t" = native ]; then mark="${C_DIM}официальный канал обновлений${C_NC}"
        elif [ -n "$latest" ] && [ "$v" = "$latest" ]; then mark="${C_GREEN}$S_OK актуальная${C_NC}"
        elif [ -n "$latest" ]; then mark="${C_YELLOW}есть новее: $latest${C_NC}"; fi
        printf '   %s%s%s  Claude Code %s%s%s %s %s%s%s   %s\n' "$C_CYAN" "$i" "$C_NC" "$C_BOLD" "${v:-?}" "$C_NC" "$S_DOT" "$C_DIM" "$(fn_type_label "$t"), $o" "$C_NC" "$mark"
        printf '      %s%s%s\n' "$C_DIM" "$p" "$C_NC"; done <<<"$list"
    choose "Claude Code:" 1 "Обновить до последней версии" "Решить по каждой установке" "Оставить как есть"
    local mode; case "$CHOSEN" in 1) mode=a;; 2) mode=o;; *) return 0;; esac
    while IFS='|' read -r p t v o; do
        [[ "$t" == wrapper || "$t" == symlink* ]] && continue      # обёртки/симлинки обновляются вместе с целью
        local act="update"
        if [ "$mode" = "o" ]; then
            if [[ "$t" == npm-global || "$t" == npm-local ]] && ! fn_is_centos7 && $NATIVE_OK; then
                choose "Claude ${v:-?} ($(fn_type_label "$t"), $o):" 1 "Заменить официальной установкой Anthropic" "Обновить как есть, через npm" "Не трогать"
                case "$CHOSEN" in 1) act="native";; 2) act="update";; *) act="skip";; esac
            elif [ "$t" = native ]; then
                choose "Claude ${v:-?} (официальная, $o):" 1 "Обновить" "Переустановить через npm" "Не трогать"
                case "$CHOSEN" in 1) act="update";; 2) act="npm";; *) act="skip";; esac
            else
                choose "Claude ${v:-?} ($(fn_type_label "$t"), $o):" 1 "Обновить через npm" "Не трогать"
                case "$CHOSEN" in 1) act="update";; *) act="skip";; esac
            fi
        elif [[ "$t" == npm-global || "$t" == npm-local ]] && ! fn_is_centos7 && $NATIVE_OK; then act="native"; fi
        [ "$act" = "skip" ] && continue
        PLAN_CLAUDE+=("$p|$t|$o|$act")
        case "$act" in
            update) PLAN+=("Обновить Claude Code ($(fn_type_label "$t"), $o)");;
            native) PLAN+=("Перейти на официальный Claude Code, старую npm-установку убрать ($o)");;
            npm) PLAN+=("Переустановить Claude Code через npm ($o)");;
        esac
    done <<<"$list"
    if [ -L /usr/local/bin/claude ] && [[ "$(readlink -f /usr/local/bin/claude)" == /root/* ]]; then
        PLAN+=("Сделать Claude доступным всем пользователям сервера")
    fi
}

fn_user_devkit_state() {   # $1 home → "key|legacy|projects"
    local h="$1" key=no legacy=no projects=0
    [ -s "$h/.config/mw-devkit/key" ] && key=yes
    { [ -d "$h/.claude/skills/backlog-add" ] || grep -qs 'check_backlog_called' "$h/.claude/settings.json"; } && legacy=yes
    projects=$(find "$h" /home /opt /var/www -maxdepth 3 -name .mw-devkit -user "$(stat -c %U "$h")" 2>/dev/null | wc -l)
    echo "$key|$legacy|$projects"
}

fn_wizard_devkit() {
    step "MW DevKit"
    info "${C_DIM}вход по рабочему e-mail (код в Битрикс24); права — по роли в проекте; скилл и хуки — из AdFlow${C_NC}"
    local users=("root|/root"); for h in /home/*; do [ -d "$h/.claude" ] && users+=("$(stat -c %U "$h")|$h"); done
    for ent in "${users[@]}"; do IFS='|' read -r u h <<<"$ent"; IFS='|' read -r k l pr <<<"$(fn_user_devkit_state "$h")"
        printf '   %s%s%s  %s%s%s %s %s\n' "$C_CYAN" "$S_DOT" "$C_NC" "$C_BOLD" "$u" "$C_NC" "$S_DOT" "$([ $k = yes ] && echo "${C_GREEN}подключён${C_NC}" || echo "не подключён")$([ $l = yes ] && echo ", старый backlog-add (Google-таблица)")$([ "$pr" -gt 0 ] && echo ", проектов: $pr")"; done
    for ent in "${users[@]}"; do
        IFS='|' read -r u h <<<"$ent"; IFS='|' read -r k l pr <<<"$(fn_user_devkit_state "$h")"
        local dk="skip" lg="keep"
        if [ "$k" = yes ]; then
            choose "$u — DevKit уже подключён:" 1 "Обновить инструкции и хуки" "Не трогать"; [ "$CHOSEN" = 1 ] && dk="update"
        else
            if $OPT_YES; then warn "$u: DevKit не подключён — вход интерактивный, выполните позже: adflow login && adflow update"
            else choose "$u — подключить DevKit?" "$([ "$u" = root ] && echo 1 || echo 2)" "Да, сейчас (e-mail, код придёт в Битрикс24)" "Позже"; [ "$CHOSEN" = 1 ] && dk="login"; fi
        fi
        if [ "$l" = yes ]; then
            if $OPT_KEEP_LEGACY; then lg="keep"
            else choose "$u — старый backlog-add (Google-таблица):" "$([ "$dk" = skip ] && echo 2 || echo 1)" "Отключить — журнал теперь ведёт DevKit" "Оставить"; [ "$CHOSEN" = 1 ] && lg="off"; fi
        fi
        PLAN_USERS+=("$u|$h|$dk|$lg")
        case "$dk" in login) PLAN+=("Подключить $u к DevKit (вход по e-mail, код из Битрикс24)");; update) PLAN+=("Обновить инструкции и хуки DevKit для $u");; esac
        [ "$lg" = off ] && PLAN+=("Отключить старый backlog-add у $u (бэкап сохраняется)")
    done
}

fn_apply_claude() {
    local latest; latest=$(${PREFIX}curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | grep -oE '"version": *"[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    for ent in "${PLAN_CLAUDE[@]}"; do
        IFS='|' read -r p t o act <<<"$ent"
        case "$act" in
            install) fn_install_claude_smart ;;
            native) if [ "$o" = root ] && [ -x /root/.local/bin/claude ] || fn_install_claude_native_for "$o"; then
                        [ "$o" = root ] && fn_expose_claude_globally /root/.local/bin/claude
                        if [ "$t" = npm-global ] && command -v npm >/dev/null 2>&1; then spin "Убираю старую npm-установку" "${PREFIX}npm -g uninstall @anthropic-ai/claude-code" || true; fi
                    else warn "нативная не удалась — второй способ: npm"; fn_install_claude_npm || err "Claude для $o не обновлён (см. $LOG)"; fi ;;
            npm) fn_install_claude_npm || err "npm-установка не удалась (см. $LOG)" ;;
            update)
                case "$t" in
                    native)
                        if [ "$o" = root ]; then SPIN_TIMEOUT=600 spin "claude update ($o)" "${PREFIX}'$p' update" || fn_install_claude_native_for root || fn_install_claude_npm
                        else SPIN_TIMEOUT=600 spin "claude update ($o)" "su - '$o' -c '${PREFIX}\"$p\" update'" || fn_install_claude_native_for "$o" || fn_install_claude_npm; fi ;;
                    npm-sandbox) SPIN_TIMEOUT=900 spin "npm install (песочница)" "PATH='$NODE_DIR/bin:$PATH' ${PREFIX}'$NODE_DIR/bin/npm' install -g @anthropic-ai/claude-code@latest" ;;
                    npm-global) SPIN_TIMEOUT=900 spin "npm install -g @anthropic-ai/claude-code@latest" "${PREFIX}npm install -g @anthropic-ai/claude-code@latest" ;;
                    npm-local) fn_install_claude_native_for "$o" || fn_install_claude_npm || warn "не удалось обновить для $o" ;;
                esac ;;
        esac
    done
    if [ -L /usr/local/bin/claude ] && [[ "$(readlink -f /usr/local/bin/claude)" == /root/* ]]; then fn_expose_claude_globally /root/.local/bin/claude; fi
    fn_fix_claude_path
}

fn_migrate_legacy_backlog() {   # $1 home $2 user
    local h="$1" u="$2"
    [ -d "$h/.claude/skills/backlog-add" ] && run "mv '$h/.claude/skills/backlog-add' '$h/.claude/skills/backlog-add.disabled.$(date +%Y%m%d)'"
    if grep -qs 'check_backlog_called' "$h/.claude/settings.json"; then
        run "python3 - '$h/.claude/settings.json' <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); h=d.get('hooks',{})
for ev in list(h): h[ev]=[x for x in h[ev] if not any('check_backlog_called' in (c.get('command') or '') for c in x.get('hooks',[]))]; h[ev] or h.pop(ev)
json.dump(d,open(p,'w'),ensure_ascii=False,indent=2)
PY"
    fi
    [ -d "$h/.claude/sheets_sync" ] && info "${C_DIM}$u: sheets_sync и его cron оставлены — выключите после первого закрытого таска в AdFlow${C_NC}"
    ok "Старый backlog-add у $u отключён — журнал работ теперь ведёт DevKit"
}

fn_as_user() { local u="$1"; shift; if [ "$u" = root ]; then "$@"; else su - "$u" -c "cd '$(pwd -P)' && $*"; fi; }
fn_json() { python3 -c "
import sys,json
d=json.load(sys.stdin)
for k in '$1'.split('.'):
    d=d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" 2>/dev/null; }

fn_devkit_login() {   # $1 = пользователь: вход по e-mail → код → выбор проекта (только коды, один раз) → привязка каталога → код ПМа
    local u="$1" out state
    echo; printf '   %sВход в DevKit%s — %s: код придёт вам в Битрикс24 и на почту; затем выберите проект для каталога %s\n' "$C_BOLD" "$C_NC" "$u" "$(pwd -P)"
    read -p "   Рабочий e-mail: " email <"$IN"; [ -z "$email" ] && { warn "e-mail не введён — пропускаю"; return 1; }
    out=$(fn_as_user "$u" adflow login --email "$email" <"$IN") || { err "Вход не выполнен: $(echo "$out" | fn_json error)"; return 1; }
    ok "Вы вошли как ${C_BOLD}$(echo "$out" | fn_json employee)${C_NC}"
    state=$(echo "$out" | fn_json link.state)
    case "$state" in
        approved) ok "Каталог $(pwd -P) подключён к проекту ${C_BOLD}$(echo "$out" | fn_json link.project.code)${C_NC}" ;;
        pending)  ok "Проект $(echo "$out" | fn_json link.project.code): ждёт подтверждения ПМа (код у него или кнопка в AdFlow); пока — гостевой режим" ;;
        guest)    info "Гостевой режим: записи копятся на вас, ПМ привяжет их к проекту" ;;
    esac
    return 0
}

fn_devkit_update() {   # $1 = пользователь
    local u="$1" out
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] adflow update ($u)${C_NC}"; return 0; }
    out=$(fn_as_user "$u" adflow update 2>/dev/null) || { warn "$u: инструкции не обновились: $(echo "$out" | fn_json error)"; return 1; }
    ok "Инструкции и хуки Claude обновлены ${C_DIM}(версия $(echo "$out" | fn_json version))${C_NC}"
}

fn_apply_devkit() {
    command -v python3 >/dev/null 2>&1 || fn_prepare_minimal
    spin "Утилита adflow" "${PREFIX}curl -fsSL --max-time 60 '$ADFLOW_URL/devkit/cli' -o /usr/local/bin/adflow && chmod 755 /usr/local/bin/adflow" || return 1
    for ent in "${PLAN_USERS[@]}"; do
        IFS='|' read -r u h dk lg <<<"$ent"
        case "$dk" in
            login) if fn_devkit_login "$u"; then fn_devkit_update "$u"; else warn "$u: подключить позже — в каталоге проекта adflow login && adflow update"; fi ;;
            update) fn_devkit_update "$u" ;;
        esac
        [ "$lg" = off ] && fn_migrate_legacy_backlog "$h" "$u"
    done
}

fn_update_wizard() {
    PLAN=(); PLAN_CLAUDE=(); PLAN_USERS=()
    fn_wizard_claude
    fn_wizard_devkit
    step "План"
    if [ ${#PLAN[@]} -eq 0 ]; then ok "Делать нечего."; return 0; fi
    local n=0; for x in "${PLAN[@]}"; do n=$((n+1)); printf '   %s%s%s %s\n' "$C_CYAN" "$S_OK" "$C_NC" "$x"; done
    $OPT_DRY && info "${C_DIM}режим проверки: команды только печатаются${C_NC}"
    ask "Поехали? (Y/n):" Y || { warn "Отменено."; return 0; }
    step "Claude Code"; fn_apply_claude
    step "MW DevKit"; fn_apply_devkit
}

# совместимость: старые имена
fn_update_all_claude() { fn_update_wizard; }
fn_setup_devkit() {
    PLAN=(); PLAN_CLAUDE=(); PLAN_USERS=(); fn_wizard_devkit
    echo; local n=0; for x in "${PLAN[@]}"; do n=$((n+1)); echo "  $n. $x"; done
    ask "Выполнить? (Y/n):" Y && fn_apply_devkit
}

# ==============================================================================
# PRESALE DEMO STACK
# ==============================================================================
fn_deploy_presale_stack() {
    step "Presale Demo Stack ($DEMO_DIR)"
    if fn_is_centos7; then err "Presale-стек требует Python ≥ 3.9 и современный Docker — на CentOS 7 не поддерживается."; return 1; fi
    if [ -d "$DEMO_DIR/frontend" ] && ! ask "Стек уже развёрнут в $DEMO_DIR. Пересоздать (данные Postgres сохранятся)? (y/N):" N; then return 0; fi
    fn_install_nodejs_sandboxed
    local APP_DOMAIN="$OPT_DOMAIN" DB_PASS="$OPT_DBPASS"
    if [ -z "$APP_DOMAIN" ]; then $OPT_YES && APP_DOMAIN=localhost || { read -p "Домен для Caddy (по умолчанию localhost): " APP_DOMAIN <"$IN"; APP_DOMAIN=${APP_DOMAIN:-localhost}; }; fi
    if [ -z "$DB_PASS" ]; then
        if $OPT_YES; then DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20); else read -sp "Пароль PostgreSQL (Enter — сгенерировать): " DB_PASS <"$IN"; echo; DB_PASS=${DB_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}; fi
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
    local cv; cv=$(fn_claude_version /usr/local/bin/claude 2>/dev/null || fn_claude_version "$(command -v claude 2>/dev/null)")
    local who=""; [ -s /root/.config/mw-devkit/key ] && who=$(adflow whoami 2>/dev/null | fn_json employee)
    echo; hr
    printf '   %s%s%s  %sВсё готово%s\n' "$C_GREEN" "$S_OK" "$C_NC" "$C_BOLD" "$C_NC"
    echo
    if [ -n "$cv" ]; then printf '   %sClaude Code%s     версия %s\n' "$C_BOLD" "$C_NC" "$cv"; else printf '   %sClaude Code%s     не установлен\n' "$C_BOLD" "$C_NC"; fi
    if [ -n "$who" ]; then printf '   %sDevKit%s          подключён как %s\n' "$C_BOLD" "$C_NC" "$who"; else printf '   %sDevKit%s          не подключён %s(adflow login)%s\n' "$C_BOLD" "$C_NC" "$C_DIM" "$C_NC"; fi
    $USE_PROXY_FLAG && printf '   %sСеть%s            через прокси %s:%s\n' "$C_BOLD" "$C_NC" "$PROXY_IP" "$PROXY_PORT"
    echo
    local pc=""; $USE_PROXY_FLAG && pc="proxychains4 -q "
    printf '   %sЧто дальше%s\n' "$C_BOLD" "$C_NC"
    printf '   %s1%s  Запустите %s%sclaude%s, внутри — команда %s/login%s\n' "$C_CYAN" "$C_NC" "$C_BOLD" "$pc" "$C_NC" "$C_BOLD" "$C_NC"
    printf '   %s2%s  Другой проект/каталог: %sadflow login%s там же %s(выбор проекта показывается только после кода входа)%s\n' "$C_CYAN" "$C_NC" "$C_BOLD" "$C_NC" "$C_DIM" "$C_NC"
    printf '   %s3%s  Работайте как обычно, в конце скажите Claude %s«закрой таск»%s\n' "$C_CYAN" "$C_NC" "$C_BOLD" "$C_NC"
    echo; printf '   %sЕсли в этой же сессии «claude» не находится — выполните hash -r или откройте новый терминал. Лог: %s%s\n' "$C_DIM" "$LOG" "$C_NC"
    hr
}

fn_interactive_menu() {
    fn_show_logo
    local existing; existing=$(fn_discover_claude | head -n 3)
    if [ -n "$existing" ] && [ -z "$OPT_PROFILE" ]; then
        while IFS='|' read -r p t v o; do [[ "$t" == wrapper || "$t" == symlink* ]] && continue; printf '   %sНа сервере уже есть Claude Code %s%s (%s)%s\n' "$C_DIM" "$C_NC" "${v:-?}" "$(fn_type_label "$t")" "$C_NC"; done <<<"$existing"; echo
    fi
    printf '   %s1%s  Claude Code + DevKit               %sбыстрая установка на сервер клиента%s\n' "$C_CYAN" "$C_NC" "$C_DIM" "$C_NC"
    printf '   %s2%s  Полный стенд                       %sClaude + Docker + демо-приложение для пресейла%s\n' "$C_CYAN" "$C_NC" "$C_DIM" "$C_NC"
    printf '   %s3%s  Инфраструктура                     %sDocker + инструменты + Claude, без демо%s\n' "$C_CYAN" "$C_NC" "$C_DIM" "$C_NC"
    printf '   %s4%s  Настроить сеть                     %sпрокси для закрытых серверов%s\n' "$C_CYAN" "$C_NC" "$C_DIM" "$C_NC"
    printf '   %s5%s  Обновить всё                       %sClaude любых версий + DevKit, старый backlog-add %s DevKit%s\n' "$C_CYAN" "$C_NC" "$C_DIM" "$S_ARR" "$C_NC"
    printf '   %s0%s  Выход\n' "$C_CYAN" "$C_NC"
    echo
    local CHOICE="$OPT_PROFILE"
    [ -z "$CHOICE" ] && { read -p "   ${S_ARR} " CHOICE <"$IN"; }
    case "$CHOICE" in
        1) fn_require_project_dir; STEP_TOTAL=4; fn_setup_proxy; fn_prepare_minimal; fn_install_claude_smart; fn_setup_devkit ;;
        2) STEP_TOTAL=7; fn_setup_proxy; fn_prepare_full; fn_install_docker; fn_install_claude_smart; fn_deploy_presale_stack; fn_setup_devkit ;;
        3) fn_require_project_dir; STEP_TOTAL=6; fn_setup_proxy; fn_prepare_full; fn_install_docker; fn_install_claude_smart; fn_setup_devkit ;;
        4) STEP_TOTAL=1; fn_setup_proxy; exit 0 ;;
        5) fn_require_project_dir; STEP_TOTAL=7; fn_setup_proxy; fn_prepare_minimal; fn_update_wizard ;;
        0) echo "Отмена."; exit 0 ;;
        *) err "Введите номер пункта 0–5."; exit 1 ;;
    esac
    fn_finish_message
    if [ "$CHOICE" = "2" ] && [ -x "$DEMO_DIR/start_vibe.sh" ] && ! $OPT_YES && ! $OPT_DRY; then
        echo; info "Запускаю демо-стенд через 5 секунд ${C_DIM}(Ctrl+b, d — отключиться от tmux)${C_NC}"; sleep 5; "$DEMO_DIR/start_vibe.sh"
    fi
}

fn_parse_args "$@"
fn_check_root
fn_detect_os
fn_interactive_menu
