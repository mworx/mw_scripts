#!/bin/bash
# ==============================================================================
# Установщик MEDIA WORKS: Claude Code, MW DevKit, Docker & Presale Demo Stack
#   Запускать из КОРНЯ ПРОЕКТА (например cd /home/bitrix) — DevKit привязывает Claude к проекту по текущему каталогу.
#   bash install-proxy.sh                      — интерактивное меню
#   bash install-proxy.sh update               — мастер обновления: все установки Claude + DevKit (с вопросами)
#   bash install-proxy.sh update --yes         — то же без вопросов (рекомендуемые ответы)
#   Флаги: --profile N | --proxy IP:PORT[:пароль] | --proxy adflow (из AdFlow по ключу DevKit) | --no-proxy | --method native|npm|auto | --ascii | --yes | --dry-run | --keep-legacy | --domain D | --db-pass P
#          --all-users (с --yes: трогать и установки других пользователей) | --force-dir (с --yes: не проверять веб-корень/домашний каталог)
#   Бережность: свои файлы помечены «mw-installer», чужие не перезаписываются (бэкап .bak.<время>); лог /var/log/mw-install.log (600, пароли замаскированы)
# ==============================================================================
set -o pipefail

ADFLOW_URL="${ADFLOW_URL:-https://adflow.mworx.ru/api/v1}"
NODE_DIR="/opt/vibe-node"; NODE_VER="v22.23.2"; NODE_MAJOR=22; DEMO_DIR="/opt/vibe-demo"   # Claude Code ≥ 2.1.246 требует Node ≥ 22; для CentOS 7 есть сборка glibc-217
PKG_MANAGER=""; OS_ID=""; OS_VERSION=""
PROXY_IP=""; PROXY_PORT=""; PROXY_USER="proxyuser"; PROXY_PASS=""; PROXYCHAINS_CONF_FILE=""; PROXY_LIST=""; PROXY_LABEL=""
USE_PROXY_FLAG=false; PREFIX=""
OPT_PROFILE=""; OPT_PROXY=""; OPT_YES=false; OPT_DRY=false; OPT_KEEP_LEGACY=false; OPT_DOMAIN=""; OPT_DBPASS=""; OPT_ALL_USERS=false; OPT_FORCE_DIR=false
LOG="/var/log/mw-install.log"
MARK="mw-installer"   # маркер наших обёрток/конфигов: заменяем только то, что создали сами
if { : </dev/tty; } 2>/dev/null; then IN=/dev/tty; HAVE_TTY=true; else IN=/dev/null; HAVE_TTY=false; fi   # все вопросы — только с терминала; без него работает лишь --yes
NATIVE_OK=true; OPT_METHOD="auto"
TS=$(date +%Y%m%d%H%M%S)
SPIN_PID=""; TMP_DIRS=()

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
{ touch "$LOG" && chmod 600 "$LOG"; } 2>/dev/null || LOG="/tmp/mw-install.$$.log"   # лог только root: в него попадают команды
# секреты в лог не пишем: url-креды (user:pass@) и сам пароль прокси маскируются
fn_mask() { local t="$1"; t=$(printf '%s' "$t" | sed -E 's#://[^/@[:space:]]*@#://***@#g'); [ -n "${PROXY_PASS:-}" ] && t=${t//"$PROXY_PASS"/***}; printf '%s' "$t"; }
fn_killtree() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do fn_killtree "$c"; done; kill "${2:-}" "$p" 2>/dev/null; }
fn_cleanup() {   # Ctrl+C / выход: убить фоновую команду спиннера (всё дерево), вернуть echo терминалу, убрать временные каталоги, откатить полузаменённую песочницу Node
    local rc=$?
    [ -n "$SPIN_PID" ] && { fn_killtree "$SPIN_PID"; sleep 0.3; fn_killtree "$SPIN_PID" -9; }
    $HAVE_TTY && stty echo 2>/dev/null
    local d; for d in "${TMP_DIRS[@]}"; do [ -d "$d" ] && rm -rf "$d"; done
    if [ -d "${NODE_DIR}.old" ] && [ ! -x "$NODE_DIR/bin/node" ]; then rm -rf "$NODE_DIR"; mv "${NODE_DIR}.old" "$NODE_DIR"; echo "$(date '+%F %T') откат песочницы Node из .old" >> "$LOG"; fi
    [ -d "${NODE_DIR}.new" ] && rm -rf "${NODE_DIR}.new"
    return $rc
}
trap 'fn_cleanup; echo; echo "   Прервано. Лог: $LOG"; exit 130' INT TERM
trap 'fn_cleanup' EXIT
hr()   { local l="" i; for ((i=0; i<COLS; i++)); do l+="$S_LINE"; done; printf '%s%s%s\n' "$C_DIM" "$l" "$C_NC"; }
STEP_N=0; STEP_TOTAL=0
step() { STEP_N=$((STEP_N+1)); echo; printf '  %s%s %s%s %s%s/%s%s\n' "$C_CYAN" "$S_DOT" "$C_BOLD" "$1" "$C_DIM" "$STEP_N" "${STEP_TOTAL:-?}" "$C_NC"; echo "$(date '+%F %T') === [$STEP_N] $1" >> "$LOG" 2>/dev/null; }
log()  { echo -e "$1"; echo -e "$(date '+%F %T') $1" | sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\(B//g' >> "$LOG" 2>/dev/null; }
info() { log "   $1"; }
ok()   { log "   ${C_GREEN}${S_OK}${C_NC} $1"; }
warn() { log "   ${C_YELLOW}!${C_NC} $1"; }
err()  { log "   ${C_RED}${S_FAIL} $1${C_NC}"; }
run()  { if $OPT_DRY; then echo "   ${C_DIM}[dry-run] $(fn_mask "$*")${C_NC}"; return 0; fi; echo "$(date '+%F %T') \$ $(fn_mask "$*")" >> "$LOG"; eval "$@" </dev/null; }
# spin "описание" команда… — спиннер и время; весь вывод команды в лог; таймаут SPIN_TIMEOUT (сек, по умолчанию 900)
spin() {
    local title="$1"; shift
    if $OPT_DRY; then echo "   ${C_DIM}[dry-run] $title: $(fn_mask "$*")${C_NC}"; return 0; fi
    echo "$(date '+%F %T') >>> $title: $(fn_mask "$*")" >> "$LOG"
    local start=$(date +%s) limit="${SPIN_TIMEOUT:-900}" rc
    ( eval "$@" ) </dev/null >>"$LOG" 2>&1 & local pid=$! i=0; SPIN_PID=$pid   # Ctrl+C/таймаут убивают всё дерево (fn_killtree)
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$limit" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$limit" ]; then fn_killtree "$pid"; sleep 1; fn_killtree "$pid" -9; SPIN_PID=""; echo "$(date '+%F %T') !!! таймаут ${limit}s: $title" >> "$LOG"; [ -t 1 ] && printf '\r\033[K'; err "$title — таймаут ${limit}s (подробности: $LOG)"; return 124; fi
        [ -t 1 ] && printf '\r   %s%s%s %s… %ss' "$C_CYAN" "${S_SPIN:$((i % ${#S_SPIN})):1}" "$C_NC" "$title" "$(( $(date +%s) - start ))"; i=$((i+1)); sleep 0.25
    done
    wait "$pid"; rc=$?; SPIN_PID=""; [ -t 1 ] && printf '\r\033[K'
    local dur=$(( $(date +%s) - start ))
    if [ $rc -eq 0 ]; then ok "$title ${C_DIM}(${dur}s)${C_NC}"; else err "$title — ошибка (${dur}s), подробности: $LOG"; fi
    return $rc
}
fn_need_input() { $HAVE_TTY && return 0; err "Нет терминала для вопросов — запустите в терминале (ssh -t) или добавьте --yes/--profile N (ответы по умолчанию)."; exit 1; }
# fn_read ПЕРЕМЕННАЯ "приглашение" [-s]: читать ответ пользователя (с терминала; без терминала — ошибка, чтобы не читать «ответы» из тела скрипта при curl | bash)
fn_read() { local __v="$1" __p="$2" __s="${3:-}"; fn_need_input; if [ -n "$__s" ]; then read -r -s -p "$__p" "$__v" </dev/tty || eval "$__v=''"; echo; else read -r -p "$__p" "$__v" </dev/tty || eval "$__v=''"; fi; }
fn_yes() { case "$1" in Y|y|Д|д|yes|да) return 0;; esac; return 1; }   # без regex: под локалью C кириллица — 2 байта
ask()  { local q="$1" def="${2:-N}" a; if $OPT_YES; then fn_yes "$def"; return; fi; echo; fn_read a "   ${C_BOLD}$q${C_NC} "; a=${a:-$def}; fn_yes "$a"; }
# choose "Вопрос" "номер по умолчанию" "описание" … → CHOSEN (номер, начиная с 1)
choose() { local q="$1" def="$2"; shift 2; local opts=("$@") a i=0 opt; echo; printf '   %s%s%s\n' "$C_BOLD" "$q" "$C_NC"
           for opt in "${opts[@]}"; do i=$((i+1)); if [ "$i" = "$def" ]; then printf '     %s%s%s  %s   %s%s%s\n' "$C_CYAN" "$i" "$C_NC" "$opt" "$C_DIM" "$S_ARR Enter" "$C_NC"; else printf '     %s%s%s  %s\n' "$C_CYAN" "$i" "$C_NC" "$opt"; fi; done
           if $OPT_YES; then CHOSEN="$def"; return; fi
           while true; do fn_read a "     ${S_ARR} "; a=${a:-$def}; [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le ${#opts[@]} ] && { CHOSEN="$a"; return; }; echo "     Введите номер 1–${#opts[@]}."; done; }

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
            --all-users) OPT_ALL_USERS=true ;;
            --force-dir) OPT_FORCE_DIR=true ;;
            --ascii) export MW_ASCII=1 ;;
            -h|--help) [ -f "$0" ] && sed -n 2,10p "$0" || echo "bash install-proxy.sh [update] [--profile N] [--proxy IP:PORT[:пароль]|adflow] [--no-proxy] [--yes] [--dry-run] [--all-users] [--force-dir] [--ascii]"; exit 0 ;;
            *) err "Неизвестный флаг: $1"; exit 1 ;;
        esac
        shift
    done
}

fn_show_logo() {
    $OPT_YES || { [ -t 1 ] && clear; }
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
    if fn_is_web_root; then printf '  %sКаталог проекта: %s — похоже на веб-корень (www), потребуется подтверждение%s\n' "$C_YELLOW" "$(pwd -P)" "$C_NC"
    elif fn_is_home_dir; then printf '  %sКаталог проекта: %s — это домашний каталог, запускайте из корня проекта%s\n' "$C_YELLOW" "$(pwd -P)" "$C_NC"
    else printf '  %sКаталог проекта:%s %s\n' "$C_DIM" "$C_NC" "$(pwd -P)"; fi
    echo
}

fn_check_root() { [ "$EUID" -ne 0 ] && { err "Запуск только от root (или sudo)."; exit 1; }; return 0; }

fn_looks_like_project() {   # признаки корня проекта: веб-корень внутри, git, документация Claude, привязка DevKit, манифесты
    local d; d=$(pwd -P)
    [ -d "$d/www" ] || [ -d "$d/public_html" ] || [ -d "$d/htdocs" ] || [ -d "$d/.git" ] || [ -f "$d/CLAUDE.md" ] || [ -d "$d/claude_docs" ] \
      || [ -f "$d/.mw-devkit" ] || [ -f "$d/composer.json" ] || [ -f "$d/package.json" ] || [ -f "$d/docker-compose.yml" ]
}

fn_is_home_dir() {   # /, /root, /home/<user>, $HOME, /tmp — не каталог проекта, если в нём нет признаков проекта (/home/bitrix с www/ — проект)
    local d; d=$(pwd -P)
    { [ "$d" = "/" ] || [ "$d" = "/root" ] || [ "$d" = "${HOME:-/root}" ] || [[ "$d" =~ ^/home/[^/]+/?$ ]] || [ "$d" = "/tmp" ]; } && ! fn_looks_like_project
}

fn_is_web_root() {   # веб-корень (www, public_html, htdocs, public) — сюда ничего служебного класть нельзя
    local d; d=$(pwd -P)
    [[ "$(basename "$d")" =~ ^(www|public_html|htdocs|public|web)$ ]] || [ -f "$d/bitrix/php_interface/dbconn.php" ] || [ -d "$d/bitrix/modules" ]
}

fn_require_project_dir() {   # DevKit привязывает Claude к проекту по текущему каталогу — запуск должен быть из него
    $OPT_FORCE_DIR && return 0
    if fn_is_web_root; then   # похоже на веб-корень — предупреждаем, решение за разработчиком (сборки бывают разные: html/ внутри www и т.п.)
        echo
        warn "Каталог $(pwd -P) похож на веб-корень сайта (www)."
        info "Служебные каталоги Claude и DevKit (.claude, claude_docs, .example) внутри веб-корня могут стать доступны из интернета."
        info "Обычно установщик запускают из корня проекта уровнем выше:"
        printf '   %scd %s && bash %s%s\n' "$C_BOLD" "$(dirname "$(pwd -P)")" "$(basename "$0")" "$C_NC"
        info "${C_DIM}Если в вашей сборке публичный каталог лежит глубже (например, www/html), устанавливать сюда можно.${C_NC}"
        $OPT_YES && { err "В режиме --yes установка в веб-корень запрещена (добавьте --force-dir, если уверены)."; exit 1; }
        ask "Вы уверены, что хотите установить в $(pwd -P)? [y/N]" N || { echo; info "Отменено. Перейдите в корень проекта и запустите снова."; exit 1; }
    fi
    if fn_is_home_dir; then
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

fn_pkg_install() {   # тихо, но с проверкой результата; через spin вызывать с SPIN_TIMEOUT=0 — прерванный apt/yum портит базу пакетов
    local pkgs="$*"
    if [ "$PKG_MANAGER" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >>"$LOG" 2>&1
    else
        $PKG_MANAGER install -y $pkgs >>"$LOG" 2>&1
    fi
}

fn_pkg_present() { if [ "$PKG_MANAGER" = apt ]; then dpkg -s "$1" >/dev/null 2>&1; else rpm -q "$1" >/dev/null 2>&1; fi; }
fn_missing_pkgs() {   # пакет:команда … → список пакетов, чьей команды нет («-» вместо команды — проверка по базе пакетов)
    local out=() x; for x in "$@"; do local pkg="${x%%:*}" cmd="${x#*:}"; if [ "$cmd" = "-" ]; then fn_pkg_present "$pkg" || out+=("$pkg"); else command -v "$cmd" >/dev/null 2>&1 || out+=("$pkg"); fi; done; echo "${out[@]}"
}
PREPARED_MIN=false
fn_prepare_minimal() {
    $PREPARED_MIN && return 0; PREPARED_MIN=true
    step "Базовые утилиты"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get update >>"$LOG" 2>&1 || warn "apt-get update завершился с ошибкой (см. $LOG) — продолжаю"
        local need opt; need=$(fn_missing_pkgs curl:curl python3:python3 tar:tar ca-certificates:- xz-utils:xz); opt=$(fn_missing_pkgs wget:wget jq:jq)
        [ -n "$need" ] && { SPIN_TIMEOUT=0 spin "пакеты: $need" fn_pkg_install $need || exit 1; } || ok "curl, python3, tar уже есть"
        [ -n "$opt" ] && { SPIN_TIMEOUT=0 spin "дополнительно: $opt" fn_pkg_install $opt || warn "необязательные пакеты ($opt) не поставились — продолжаю"; }
    else
        fn_is_centos7 && fn_centos7_vault_if_needed
        local need opt; need=$(fn_missing_pkgs curl:curl python3:python3 tar:tar ca-certificates:-); opt=$(fn_missing_pkgs wget:wget jq:jq)
        fn_is_centos7 || need="$need $(fn_missing_pkgs xz:xz)"; need=${need# }; need=${need% }
        [ -n "$need" ] && { SPIN_TIMEOUT=0 spin "пакеты: $need" fn_pkg_install $need || exit 1; } || ok "curl, python3, tar уже есть"
        [ -n "$opt" ] && { SPIN_TIMEOUT=0 spin "дополнительно: $opt" fn_pkg_install $opt || warn "необязательные пакеты ($opt) не поставились — продолжаю"; }
    fi
}

fn_centos7_vault_if_needed() {   # CentOS 7 снят с поддержки: если зеркала уже не отвечают — переключить на vault (с бэкапом .repo); рабочие/внутренние зеркала не трогаем
    timeout 90 yum -q makecache fast >>"$LOG" 2>&1 && return 0
    grep -qs 'mirror.centos.org' /etc/yum.repos.d/CentOS-*.repo || { warn "yum не отвечает, а репозитории нестандартные — не трогаю (см. $LOG)"; return 0; }
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] переключить /etc/yum.repos.d/CentOS-*.repo на vault.centos.org (бэкап .mw-bak.$TS)${C_NC}"; return 0; }
    local f; for f in /etc/yum.repos.d/CentOS-*.repo; do [ -f "$f" ] && cp -p "$f" "$f.mw-bak.$TS"; done
    sed -i 's/^mirrorlist/#mirrorlist/g; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null
    warn "зеркала CentOS 7 не отвечали — репозитории переключены на vault.centos.org (бэкапы *.mw-bak.$TS)"
}
fn_epel7_archive_if_needed() {   # EPEL 7 закрыт (2024): если репозиторий не отвечает — перевести epel.repo на archives.fedoraproject.org (с бэкапом)
    [ -f /etc/yum.repos.d/epel.repo ] || return 0
    timeout 90 yum -q --disablerepo='*' --enablerepo=epel makecache fast >>"$LOG" 2>&1 && return 0
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] переключить epel.repo на archives.fedoraproject.org${C_NC}"; return 0; }
    cp -p /etc/yum.repos.d/epel.repo "/etc/yum.repos.d/epel.repo.mw-bak.$TS"
    sed -i 's|^metalink=|#metalink=|; s|^#baseurl=http://download.fedoraproject.org/pub/epel/7/\$basearch|baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/$basearch|' /etc/yum.repos.d/epel.repo
    warn "EPEL 7 не отвечал — переключён на архив archives.fedoraproject.org (бэкап epel.repo.mw-bak.$TS)"
}
fn_ensure_epel() {   # EPEL только когда нужен конкретный пакет ($1), не «на всякий случай»
    [ "$PKG_MANAGER" = apt ] && return 0
    rpm -q epel-release >/dev/null 2>&1 || SPIN_TIMEOUT=0 spin "репозиторий EPEL (нужен для $1)" fn_pkg_install epel-release || true
    fn_is_centos7 && fn_epel7_archive_if_needed; return 0
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
    read -r _ PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS <<<"$line"; [ -z "$PROXY_USER" ] && PROXY_USER=proxyuser
    return 0
}

fn_urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

fn_curl_clean() {   # curl БЕЗ унаследованного прокси: env-переменные (*_proxy), ~/.curlrc (-q первым), LD_PRELOAD от proxychains.
    # Без этого «прямая» проверка может уйти через тот самый прокси и показать доступ там, где его нет.
    env -u LD_PRELOAD -u PROXYCHAINS_CONF_FILE -u ALL_PROXY -u all_proxy -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u NO_PROXY -u no_proxy \
        curl -q --noproxy '*' "$@"
}
fn_direct_test() {   # без прокси: доступен ли claude.ai напрямую (нативный установщик)
    local r; r=$(fn_curl_clean -sSL -o /dev/null -w '%{http_code} %{remote_ip}' --connect-timeout 10 --max-time 25 https://claude.ai/install.sh 2>>"$LOG")
    local code="${r%% *}"
    echo "$(date '+%F %T') claude.ai/install.sh без proxychains: HTTP ${r:-нет ответа}" >> "$LOG"
    if [ "$code" = "200" ]; then NATIVE_OK=true; else NATIVE_OK=false; info "${C_DIM}claude.ai напрямую закрыт — Claude поставим через npm${C_NC}"; fi
}
API_DIRECT=""   # кэш ответа api.anthropic.com: yes | no (проверяем один раз за запуск)
fn_api_direct_ok() {   # доступен ли api.anthropic.com из этого окружения: 401/400 с телом ошибки Anthropic = дошли до API (ключ фиктивный).
    # Тело смотрим потому, что голый 401 умеет отдать и перехватчик TLS, и заглушка провайдера.
    if [ -z "$API_DIRECT" ]; then
        local body code; body=$(mktemp)
        local r; r=$(fn_curl_clean -sS -o "$body" -w '%{http_code} %{remote_ip}' --connect-timeout 5 --max-time 12 -X POST https://api.anthropic.com/v1/messages \
            -H 'x-api-key: probe' -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' 2>>"$LOG"); code="${r%% *}"
        if { [ "$code" = "401" ] || [ "$code" = "400" ]; } && grep -qE '"type" *: *"(authentication_error|invalid_request_error)"' "$body"; then API_DIRECT=yes; else API_DIRECT=no; fi
        echo "$(date '+%F %T') api.anthropic.com без proxychains: HTTP ${r:-нет ответа} → $API_DIRECT" >> "$LOG"
        rm -f "$body"
    fi
    [ "$API_DIRECT" = yes ]
}

fn_curl_px() {   # curl через SOCKS5 с кредами из stdin-конфига (пароль не светится в ps); остальные аргументы — как у curl
    { printf 'proxy = "socks5h://%s:%s"\n' "$PROXY_IP" "$PROXY_PORT"; [ -n "$PROXY_PASS" ] && printf 'proxy-user = "%s:%s"\n' "$PROXY_USER" "$PROXY_PASS"; } | curl -K - "$@"
}
fn_proxy_test() {   # 0 — интернет есть; NATIVE_OK=false, если claude.ai не отдаёт установщик (403 Cloudflare для датацентровых IP). Вызывать напрямую, не через spin
    local code; code=$(fn_curl_px -sSL -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 25 https://claude.ai/install.sh 2>>"$LOG")
    echo "$(date '+%F %T') claude.ai/install.sh через прокси: HTTP ${code:-нет ответа}" >> "$LOG"
    if [ "$code" = "200" ]; then NATIVE_OK=true; return 0; fi
    NATIVE_OK=false
    fn_curl_px -fsS -o /dev/null --connect-timeout 10 --max-time 25 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>>"$LOG"
}

# Прокси нужен только для claude.ai/anthropic; registry.npmjs.org и nodejs.org из РФ доступны напрямую.
# Node.js через proxychains-ng не работает (fake-DNS 224.x → ECONNREFUSED), поэтому npm идёт напрямую, а если нельзя — через свой socks-прокси (npm ≥ 9).
NET_CACHE=$(mktemp -d /tmp/mw-install-net.XXXXXX); TMP_DIRS+=("$NET_CACHE")
fn_net_prefix() {   # $1 = URL → печатает "" (напрямую) или "$PREFIX"; проверка лёгкая (первый байт по range / HEAD), кэш в файле — работает и из $(…)
    local url="$1" host; host=$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/]+).*#\1#'); local c="$NET_CACHE/$host"
    if [ ! -f "$c" ]; then
        if fn_curl_clean -fsS -o /dev/null --range 0-0 --connect-timeout 6 --max-time 15 "$url" 2>>"$LOG" || fn_curl_clean -fsSI -o /dev/null --connect-timeout 6 --max-time 15 "$url" 2>>"$LOG"; then echo yes > "$c"; echo "$(date '+%F %T') $host: доступен напрямую" >> "$LOG"
        else echo no > "$c"; echo "$(date '+%F %T') $host: напрямую недоступен → через прокси" >> "$LOG"; fi
    fi
    [ "$(cat "$c")" = yes ] && echo "" || echo "$PREFIX"
}
fn_npm_cmd() {   # $1 = путь к npm, остальное — аргументы → строка команды для spin: напрямую / socks через npm_config_* / proxychains (старый npm)
    local npm_bin="$1"; shift; local pfx; pfx=$(fn_net_prefix "https://registry.npmjs.org/-/ping")
    if [ -z "$pfx" ] || ! $USE_PROXY_FLAG; then printf "'%s' %s" "$npm_bin" "$*"; return; fi
    local major; major=$(PATH="$(dirname "$npm_bin"):$PATH" "$npm_bin" -v 2>/dev/null | cut -d. -f1)
    if [ "${major:-0}" -ge 9 ] 2>/dev/null; then
        local auth=""; [ -n "$PROXY_PASS" ] && auth="$(fn_urlenc "$PROXY_USER"):$(fn_urlenc "$PROXY_PASS")@"
        local px="socks5h://${auth}${PROXY_IP}:${PROXY_PORT}"
        printf "npm_config_proxy='%s' npm_config_https_proxy='%s' '%s' %s" "$px" "$px" "$npm_bin" "$*"
    else printf "%s'%s' %s" "$PREFIX" "$npm_bin" "$*"; fi
}

fn_adflow_direct() { fn_curl_clean -fsS -o /dev/null --connect-timeout 8 --max-time 20 "$ADFLOW_URL/devkit/install.sh" 2>>"$LOG"; }

fn_ensure_adflow_cli() {   # adflow ставится напрямую с AdFlow (прокси не нужен)
    [ -x /usr/local/bin/adflow ] && return 0
    command -v python3 >/dev/null 2>&1 || fn_prepare_minimal
    fn_fetch_adflow_cli
}
fn_fetch_adflow_cli() {   # скачать во временный файл, проверить, что это python, и только потом подменить (обрыв не оставит битый adflow)
    local t; t=$(mktemp); spin "Утилита adflow" "curl -fsSL --max-time 60 '$ADFLOW_URL/devkit/cli' -o '$t' && python3 -m py_compile '$t' && install -m 755 '$t' /usr/local/bin/adflow"; local rc=$?; rm -f "$t" "${t}c" 2>/dev/null; return $rc
}

fn_proxy_from_adflow() {   # параметры SOCKS5 из AdFlow по личному ключу → PROXY_* (первый) и PROXY_LIST (все); 0 — получены
    fn_ensure_adflow_cli || return 1
    if [ -z "${ADFLOW_DEV_KEY:-}" ] && [ ! -s /root/.config/mw-devkit/key ]; then
        info "${C_DIM}настройки сети хранятся в AdFlow и выдаются после входа в DevKit${C_NC}"
        $OPT_YES && { warn "--yes: вход в DevKit интерактивный — сначала adflow login, затем повторите"; return 1; }
        if ask "Войти в DevKit сейчас? Код придёт в Битрикс24 (Y/n):" Y; then fn_devkit_login root || return 1; else return 1; fi
    fi
    local js; js=$(adflow proxy 2>>"$LOG") || return 1
    [ "$(echo "$js" | fn_json configured)" = "True" ] || { warn "в AdFlow прокси не настроен (devkit.proxy)"; return 1; }
    # items — список с резервами (AdFlow ≥ 2026-09-01); старый ответ без items читаем как один прокси
    PROXY_LIST=$(echo "$js" | python3 -c '
import sys, json
d = json.load(sys.stdin)
items = d.get("items") or [{k: d.get(k) for k in ("host", "port", "user", "pass")}]
for i in items:
    if i.get("host"):
        print("\t".join([str(i.get(k) or "") for k in ("host", "port", "user", "pass", "label")]))
')
    [ -n "$PROXY_LIST" ] || { warn "AdFlow не вернул ни одного прокси"; return 1; }
    fn_proxy_take "$(echo "$PROXY_LIST" | head -1)"
    local n; n=$(echo "$PROXY_LIST" | wc -l)
    ok "Параметры прокси получены из AdFlow: ${PROXY_IP}:${PROXY_PORT}$([ "$n" -gt 1 ] && echo " (+$((n-1)) резервных)")"
}

fn_proxy_take() {   # строка "host\tport\tuser\tpass\tlabel" → PROXY_*
    IFS=$'\t' read -r PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_LABEL <<<"$1"
    [ -z "$PROXY_PORT" ] && PROXY_PORT=1080
    [ -z "$PROXY_USER" ] && PROXY_USER=proxyuser
}

fn_tcp_open() {   # 0 — TCP до $1:$2 встал. Отделяет «порт закрыт» от «прокси не принял пароль»: до SOCKS дело не доходит
    timeout "${3:-8}" bash -c "cat < /dev/null > /dev/tcp/$1/$2" 2>/dev/null
}

fn_proxy_why() {   # человеческая причина отказа: писать «проверьте пароль», когда не встал даже TCP, — вредный совет
    if ! fn_tcp_open "$PROXY_IP" "$PROXY_PORT" 8; then
        # SYN ушёл, ответа нет. Виноват либо прокси, либо хостинг ЭТОГО сервера: многие провайдеры режут исходящие
        # на 22 и 1080 (антибрут и открытые прокси). Отличаем по github: 443 — связность, 22 — режут ли нестандартные порты.
        if ! fn_tcp_open 140.82.121.4 443 6; then
            echo "с этого сервера не открывается даже github.com:443 — сети нет или её режет файрвол сервера"
        elif ! fn_tcp_open 140.82.121.4 22 6; then
            echo "хостинг этого сервера режет исходящие на нестандартные порты: закрыт и ${PROXY_PORT}, и github.com:22, при живом 443. Прокси, скорее всего, работает — нужен его адрес на 443/8443 (логин и пароль здесь ни при чём)"
        else
            echo "порт ${PROXY_IP}:${PROXY_PORT} не отвечает, хотя исходящие с сервера не режутся — прокси выключен или закрыт его файрволом (логин и пароль здесь ни при чём)"
        fi
    elif ! fn_curl_px -sS -o /dev/null --connect-timeout 10 --max-time 20 https://registry.npmjs.org/-/ping 2>>"$LOG"; then
        echo "прокси ${PROXY_IP}:${PROXY_PORT} отвечает, но соединение не проходит — обычно неверный логин/пароль или прокси не выпускает наружу"
    else
        echo "прокси ${PROXY_IP}:${PROXY_PORT} работает, но claude.ai и registry.npmjs.org через него не открылись"
    fi
}

fn_proxy_pick() {   # перебор PROXY_LIST: берём первый живой. Один упавший прокси не должен останавливать установку
    local line first=true
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        fn_proxy_take "$line"
        $first || info "Пробую резервный прокси ${PROXY_IP}:${PROXY_PORT}${PROXY_LABEL:+ ($PROXY_LABEL)}…"
        first=false
        if fn_proxy_test; then return 0; fi
        warn "$(fn_proxy_why)"
    done <<<"$PROXY_LIST"
    return 1
}

fn_setup_proxy() {
    step "Сеть"
    command -v curl >/dev/null 2>&1 || fn_prepare_minimal
    if [ -n "${LD_PRELOAD:-}${ALL_PROXY:-}${HTTPS_PROXY:-}${https_proxy:-}" ] || [ -s "$HOME/.curlrc" ]; then
        info "${C_DIM}установщик запущен с прокси в окружении — прямую доступность проверяю без него${C_NC}"
    fi
    if [ "$OPT_PROXY" = "none" ]; then USE_PROXY_FLAG=false; PREFIX=""; ok "Прямое соединение (--no-proxy)."; fn_direct_test; return 0; fi
    if [ "$OPT_PROXY" = "adflow" ]; then fn_proxy_from_adflow || { err "Не удалось получить прокси из AdFlow"; exit 1; }
    elif [ -n "$OPT_PROXY" ]; then
        PROXY_IP=$(echo "$OPT_PROXY" | cut -d: -f1); PROXY_PORT=$(echo "$OPT_PROXY" | cut -d: -s -f2); PROXY_PASS=$(echo "$OPT_PROXY" | cut -d: -s -f3-)
    elif fn_api_direct_ok && { fn_direct_test; $NATIVE_OK; }; then   # и api.anthropic.com, и claude.ai отвечают без proxychains (claude.ai нужен для `claude /login`)
        if fn_proxy_read_existing; then
            # Связность — не единственная причина прокси: с ним у Anthropic видно зарубежный IP. Решает владелец сервера;
            # по умолчанию (и в неинтерактивном режиме) остаёмся на прокси, который на сервере уже настроен.
            choose "Anthropic отвечает и напрямую, и через настроенный прокси ${PROXY_IP}:${PROXY_PORT}. Как ходить?" 1 \
                   "Через прокси — как настроено на сервере (зарубежный IP)" \
                   "Напрямую — быстрее, но Anthropic видит IP сервера"
            if [ "$CHOSEN" = "1" ]; then
                if fn_proxy_test; then fn_proxy_finish; return 0; fi
                warn "$(fn_proxy_why) — работаем напрямую"
            else
                info "${C_DIM}идём напрямую, конфиг прокси не трогаю${C_NC}"
            fi
        else
            ok "API Anthropic и claude.ai открыты напрямую — прокси не нужен"
        fi
        PROXY_IP=""; PROXY_PASS=""; USE_PROXY_FLAG=false; PREFIX=""; return 0
    elif fn_proxy_read_existing; then   # напрямую доступно не всё (API или claude.ai закрыт), а прокси уже настроен: молча проверяем; вопрос — только если он не работает
        info "Прокси ${PROXY_IP}:${PROXY_PORT} уже настроен, проверяю…"
        if fn_proxy_test; then fn_proxy_finish; return 0; fi
        warn "$(fn_proxy_why)"
        choose "Сеть:" 1 "Настроить прокси заново" "Работать без прокси"
        case "$CHOSEN" in 2) USE_PROXY_FLAG=false; PREFIX=""; PROXY_IP=""; PROXY_PASS=""; fn_direct_test; return 0;; esac; PROXY_IP=""
    fi
    if [ -z "$PROXY_IP" ] && [ "$OPT_PROXY" != "none" ]; then
        if fn_adflow_direct; then
            choose "claude.ai отсюда не открывается. Прокси:" 1 "Взять из AdFlow (после входа в DevKit)" "Ввести вручную" "Работать без прокси"
            case "$CHOSEN" in 1) fn_proxy_from_adflow || warn "не получилось — введите вручную";; 3) USE_PROXY_FLAG=false; PREFIX=""; fn_direct_test; return 0;; esac
        fi
    fi
    if [ -z "$PROXY_IP" ]; then
        if $OPT_YES; then USE_PROXY_FLAG=false; PREFIX=""; warn "Прокси не задан — прямое соединение."; fn_direct_test; return 0; fi
        echo; fn_read PROXY_INPUT "   ${C_BOLD}SOCKS5 прокси IP:порт${C_NC} ${C_DIM}(Enter — без прокси)${C_NC}: "
        if [ -z "$PROXY_INPUT" ]; then USE_PROXY_FLAG=false; PREFIX=""; warn "Прямое соединение."; fn_direct_test; return 0; fi
        PROXY_IP=$(echo "$PROXY_INPUT" | cut -d: -f1); PROXY_PORT=$(echo "$PROXY_INPUT" | cut -d: -s -f2); [ -z "$PROXY_PORT" ] && PROXY_PORT=1080
        fn_read PROXY_PASS "   Пароль $PROXY_USER (Enter — без пароля): " -s
    fi
    [ -z "$PROXY_PORT" ] && PROXY_PORT=1080
    case "$PROXY_PASS$PROXY_USER" in *[[:space:]]*) err "Логин/пароль прокси с пробелами proxychains не поддерживает."; exit 1;; esac
    info "Проверка прокси ${PROXY_IP}:${PROXY_PORT}…"
    if [ -n "$PROXY_LIST" ]; then
        fn_proxy_pick || { err "Ни один прокси из AdFlow не отвечает. Последняя причина: $(fn_proxy_why)"; err "Проверить и починить: AdFlow → Настройки → devkit.proxy; сам прокси-сервер — служба SOCKS и правила файрвола."; exit 1; }
    elif ! fn_proxy_test; then
        err "Прокси не пропустил запрос: $(fn_proxy_why)"; exit 1
    fi
    fn_proxy_finish
}
fn_proxy_finish() {   # прокси проверен: proxychains, конфиги (свой и личные копии пользователям), флаги
    $NATIVE_OK || info "${C_DIM}claude.ai через этот прокси закрыт — Claude поставим через npm${C_NC}"

    if ! command -v proxychains4 >/dev/null 2>&1; then
        [ "$PKG_MANAGER" = "apt" ] && run "apt-get update"
        fn_ensure_epel proxychains-ng
        SPIN_TIMEOUT=0 spin "proxychains-ng" "fn_pkg_install proxychains-ng || fn_pkg_install proxychains4" || { err "Не удалось установить proxychains-ng (см. $LOG)"; exit 1; }
        command -v proxychains4 >/dev/null 2>&1 || $OPT_DRY || { err "proxychains4 не появился после установки (см. $LOG)"; exit 1; }
    fi
    # ВАЖНО: без proxy_dns. С ним proxychains подменяет DNS фальшивыми адресами 224.x — на них падает npm (ECONNREFUSED 224.0.0.1)
    # и молча виснет Claude Code («No response from API», инцидент 2026-08-26). DNS резолвится локально, через прокси идёт только TCP.
    fn_proxy_conf_path
    fn_write_proxychains_conf "$PROXYCHAINS_CONF_FILE" root
    ok "Сеть: через прокси ${PROXY_IP}:${PROXY_PORT} (проверен)"
    USE_PROXY_FLAG=true; PREFIX="proxychains4 -q "
    # /etc/proxychains*.conf с паролем — только root (600). Пользователям, у которых есть Claude, — личная копия ~/.proxychains/proxychains.conf (proxychains-ng читает её первой)
    local h u; for h in /home/*; do
        { [ -d "$h/.claude/projects" ] || [ -s "$h/.config/mw-devkit/key" ] || [ -x "$h/.local/bin/claude" ]; } || continue
        u=$(fn_owner_of "$h"); [ -n "$u" ] && [ "$u" != root ] || continue
        fn_write_proxychains_conf "$h/.proxychains/proxychains.conf" "$u" && info "${C_DIM}$u: личная копия настроек прокси в ~/.proxychains/${C_NC}"
    done
}
fn_proxychains_conf_text() { printf '# %s: настройки прокси для Claude Code (без proxy_dns — с ним Claude виснет)\nstrict_chain\nquiet_mode\nremote_dns_subnet 224\ntcp_read_time_out 15000\ntcp_connect_time_out 8000\n[ProxyList]\nsocks5 %s %s %s %s\n' "$MARK" "$PROXY_IP" "$PROXY_PORT" "$PROXY_USER" "$PROXY_PASS"; }
fn_conf_usable() {   # $1 файл: конфиг уже годится — тот же прокси, без proxy_dns (Claude с ним виснет) и с quiet_mode
    # (без него каждая команда под proxychains печатает «[proxychains] DLL init» — мусор в выводе и в контексте Claude).
    [ -f "$1" ] || return 1
    grep -qE "^[[:space:]]*socks[45][[:space:]]+$PROXY_IP[[:space:]]+$PROXY_PORT([[:space:]]|$)" "$1" 2>/dev/null || return 1
    grep -qE '^[[:space:]]*quiet_mode([[:space:]]|$)' "$1" 2>/dev/null || return 1
    ! grep -qE '^[[:space:]]*proxy_dns([[:space:]]|$)' "$1" 2>/dev/null
}
fn_write_proxychains_conf() {   # $1 файл $2 владелец: пишет без eval; чужой (не наш) конфиг — бэкап; годится как есть или не меняется — не трогаем
    local f="$1" u="$2" new; new=$(fn_proxychains_conf_text)
    if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$new" ]; then return 0; fi
    if fn_conf_usable "$f"; then info "${C_DIM}$f уже настроен на ${PROXY_IP}:${PROXY_PORT} — оставляю как есть${C_NC}"; return 0; fi
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] записать $f (socks5 $PROXY_IP $PROXY_PORT $PROXY_USER ***)${C_NC}"; return 0; }
    if [ -f "$f" ] && ! grep -q "$MARK" "$f"; then cp -p "$f" "$f.bak.$TS"; info "${C_DIM}прежний $f сохранён как $f.bak.$TS${C_NC}"; fi
    mkdir -p "$(dirname "$f")" && printf '%s\n' "$new" > "$f" && chmod 600 "$f" && chown "$u:" "$f" "$(dirname "$f")" 2>/dev/null
    echo "$(date '+%F %T') записан $f (socks5 $PROXY_IP $PROXY_PORT $PROXY_USER ***)" >> "$LOG"
}
fn_owner_of() {   # владелец домашнего каталога; каталог root-а в /home/<user> → сам <user>; несуществующий пользователь (UNKNOWN) → пусто
    local o; o=$(stat -c %U "$1" 2>/dev/null); if [ "$o" = root ] && [[ "$1" == /home/* ]] && id "$(basename "$1")" >/dev/null 2>&1; then o=$(basename "$1"); fi
    id "$o" >/dev/null 2>&1 && echo "$o"; }

# ==============================================================================
# DOCKER
# ==============================================================================
fn_install_docker() {
    step "Docker"
    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker добавляет репозиторий, ставит dockerd и меняет правила iptables (цепочки DOCKER, FORWARD DROP)."
        systemctl is-active --quiet firewalld 2>/dev/null && warn "На сервере активен firewalld — после установки Docker проверьте доступность сайта и форвардинг."
        command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active && warn "Активен ufw — Docker обходит его правила для опубликованных портов."
        ask "Ставить Docker на этот сервер? (y/N):" N || { warn "Docker пропущен."; return 1; }
        if [ "$PKG_MANAGER" = "apt" ]; then
            SPIN_TIMEOUT=900 spin "Установка Docker (get.docker.com)" "${PREFIX}bash -c 'curl -fsSL https://get.docker.com | bash'" || exit 1
        else
            SPIN_TIMEOUT=0 spin "yum-utils" fn_pkg_install yum-utils || true
            run "${PREFIX}yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
            SPIN_TIMEOUT=0 spin "docker-ce, containerd, compose" fn_pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin || { err "Установка Docker не удалась"; exit 1; }
        fi
        run "systemctl enable --now docker"
        ok "Docker установлен."
    else
        ok "Docker уже установлен: $(docker --version 2>/dev/null)"
    fi
    if ! docker compose version >/dev/null 2>&1; then
        local plug=/usr/libexec/docker/cli-plugins; run "mkdir -p '$plug'"
        run "${PREFIX}curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o $plug/docker-compose && chmod +x $plug/docker-compose"
    fi
    if $USE_PROXY_FLAG; then
        warn "Внимание: dockerd не умеет SOCKS5 — образы (postgres, caddy) тянутся напрямую. Если реестр недоступен, нужен HTTP-прокси в /etc/systemd/system/docker.service.d/http-proxy.conf."
    fi
}

# ==============================================================================
# NODE SANDBOX И CLAUDE CODE
# ==============================================================================
fn_install_nodejs_sandboxed() {   # ставит песочницу; если есть, но старше NODE_MAJOR — обновляет атомарно (.new → подмена, старая в .old до fn_node_sandbox_commit)
    if [ -x "$NODE_DIR/bin/node" ]; then
        local cur; cur=$("$NODE_DIR/bin/node" -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
        [ "${cur:-0}" -ge "$NODE_MAJOR" ] 2>/dev/null && return 0
        warn "Node.js в песочнице v${cur:-?} — Claude Code требует ≥ $NODE_MAJOR, обновляю (старая сохраняется до успешной установки Claude)"
    fi
    STEP_TOTAL=$((STEP_TOTAL+1)); step "Node.js $NODE_VER (песочница $NODE_DIR)"
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] скачать Node.js $NODE_VER и распаковать в $NODE_DIR${C_NC}"; return 0; }
    local tmp; tmp=$(mktemp -d); TMP_DIRS+=("$tmp")
    local file url tarflag
    if fn_is_centos7; then
        file="node-${NODE_VER}-linux-x64-glibc-217.tar.gz"; url="https://unofficial-builds.nodejs.org/download/release/${NODE_VER}/${file}"; tarflag="-xzf"
        info "CentOS 7 (glibc 2.17) — неофициальная сборка."
    else
        file="node-${NODE_VER}-linux-x64.tar.xz"; url="https://nodejs.org/dist/${NODE_VER}/${file}"; tarflag="-xJf"
    fi
    SPIN_TIMEOUT=600 spin "Скачивание Node.js $NODE_VER" "$(fn_net_prefix "$url")curl -fsSL --retry 2 '$url' -o '$tmp/$file'" || { rm -rf "$tmp"; return 1; }
    [ -s "$tmp/$file" ] || { err "архив Node.js пустой — сеть до nodejs.org недоступна (см. $LOG)"; rm -rf "$tmp"; return 1; }
    rm -rf "$NODE_DIR.new"; mkdir -m 755 -p "$NODE_DIR.new"
    run "tar $tarflag '$tmp/$file' -C '$NODE_DIR.new' --strip-components=1"; rm -rf "$tmp"
    "$NODE_DIR.new/bin/node" -v >>"$LOG" 2>&1 || { err "Node.js не распаковался или не запускается (см. $LOG)"; rm -rf "$NODE_DIR.new"; return 1; }
    if [ -d "$NODE_DIR" ]; then rm -rf "$NODE_DIR.old"; mv "$NODE_DIR" "$NODE_DIR.old"; fi
    mv "$NODE_DIR.new" "$NODE_DIR"
    ok "Node.js $("$NODE_DIR/bin/node" --version 2>/dev/null)"
}
fn_node_sandbox_commit()   { rm -rf "$NODE_DIR.old" 2>/dev/null; return 0; }
fn_node_sandbox_rollback() { [ -d "$NODE_DIR.old" ] || return 0; rm -rf "$NODE_DIR"; mv "$NODE_DIR.old" "$NODE_DIR"; warn "Claude не установился — песочница Node возвращена к прежней версии"; }

fn_claude_version() {   # $1 путь, $2 владелец: бинарники из чужих каталогов запускаем ТОЛЬКО от их владельца — не исполнять чужой код от root
    local p="$1" o="${2:-root}" out=""; [ -n "$p" ] && [ -x "$p" ] || return 0
    local real; real=$(readlink -f "$p"); [[ "$real" == /home/* ]] && [ "$o" = root ] && o=$(fn_owner_of "/home/$(echo "$real" | cut -d/ -f3)")
    if [ "$o" = root ]; then out=$(timeout 20 "$p" --version 2>/dev/null)
    else out=$(timeout 20 runuser -u "$o" -- "$p" --version 2>/dev/null || timeout 20 su -s /bin/bash "$o" -c "'$p' --version" 2>/dev/null); fi
    printf '%s' "$out" | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# Поиск всех установок Claude Code: путь | тип | версия | владелец
fn_discover_claude() {
    local found=()
    local homes=(/root); for h in /home/*; do [ -d "$h" ] && homes+=("$h"); done
    for h in "${homes[@]}"; do
        local owner; owner=$(fn_owner_of "$h"); [ -n "$owner" ] || continue
        [ -x "$h/.local/bin/claude" ] && found+=("$h/.local/bin/claude|native|$(fn_claude_version "$h/.local/bin/claude" "$owner")|$owner")
        if [ -x "$h/.claude/local/claude" ]; then found+=("$h/.claude/local/claude|npm-local|$(fn_claude_version "$h/.claude/local/claude" "$owner")|$owner")
        elif [ -x "$h/.claude/local/node_modules/.bin/claude" ]; then found+=("$h/.claude/local/node_modules/.bin/claude|npm-local|$(fn_claude_version "$h/.claude/local/node_modules/.bin/claude" "$owner")|$owner"); fi
    done
    [ -x "$NODE_DIR/bin/claude" ] && found+=("$NODE_DIR/bin/claude|npm-sandbox|$(PATH="$NODE_DIR/bin:$PATH" fn_claude_version "$NODE_DIR/bin/claude")|root")
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
        SPIN_TIMEOUT=600 spin "Claude Code, нативный установщик ($u)" "su -s /bin/bash - '$u' -c '${PREFIX}bash -c \"curl -fsSL --max-time 60 https://claude.ai/install.sh | bash\"'" || return 1
    fi
    $OPT_DRY || [ -x "$home/.local/bin/claude" ]
}

fn_system_node_ok() { command -v node >/dev/null 2>&1 && [ "$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)" -ge "$NODE_MAJOR" ] 2>/dev/null; }

fn_install_claude_npm() {   # второй способ: npm из registry.npmjs.org — системный Node ≥ NODE_MAJOR (с npm) или песочница /opt/vibe-node
    local npm_bin="" node_hint=""
    if fn_system_node_ok && command -v npm >/dev/null 2>&1; then npm_bin=$(command -v npm); node_hint="системный Node $(node -v 2>/dev/null)"
    else fn_install_nodejs_sandboxed || return 1; npm_bin="$NODE_DIR/bin/npm"; node_hint="песочница $NODE_DIR"; fi
    if ! SPIN_TIMEOUT=900 spin "Claude Code через npm ($node_hint)" "PATH='$(dirname "$npm_bin"):$PATH' $(fn_npm_cmd "$npm_bin" install -g @anthropic-ai/claude-code@latest)"; then fn_node_sandbox_rollback; return 1; fi
    $OPT_DRY && return 0
    local bin; bin="$(PATH="$(dirname "$npm_bin"):$PATH" "$npm_bin" prefix -g 2>/dev/null)/bin/claude"
    [ -x "$bin" ] || bin="$(dirname "$npm_bin")/claude"
    [ -x "$bin" ] || { err "после npm install бинарник claude не найден"; fn_node_sandbox_rollback; return 1; }
    fn_node_sandbox_commit
    fn_backup_foreign /usr/local/bin/claude
    if [[ "$bin" == "$NODE_DIR/"* ]]; then
        run "cat > /usr/local/bin/claude <<'EOF'
#!/bin/bash
# $MARK: обёртка Claude Code из песочницы $NODE_DIR (создана установщиком MEDIA WORKS)
unset NODE_ENV NODE_PATH
export PATH=\"$NODE_DIR/bin:\$PATH\"
exec $NODE_DIR/bin/claude \"\$@\"
EOF
chmod 755 /usr/local/bin/claude"
    elif [ "$bin" != "/usr/local/bin/claude" ]; then run "ln -sfn '$bin' /usr/local/bin/claude"; fi
    return 0
}

fn_is_ours() {   # $1 файл — создан нами? (маркер в тексте обёртки или файл-маркер рядом для бинарных копий)
    [ -e "$1" ] || return 1; [ -L "$1" ] && return 0
    head -c 400 "$1" 2>/dev/null | grep -q "$MARK" && return 0
    [ -f "$(dirname "$1")/.$(basename "$1").$MARK" ]
}
fn_backup_foreign() {   # $1 файл: если есть и не наш — не затирать молча, а отложить в .bak.<время>
    [ -e "$1" ] && ! fn_is_ours "$1" || return 0
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] $1 не наш — бэкап $1.bak.$TS${C_NC}"; return 0; }
    mv -f "$1" "$1.bak.$TS" && warn "$1 создан не нами — сохранён как $1.bak.$TS"
}

fn_fix_claude_path() {   # старые ссылки npm (/usr/bin/claude → node_modules) после замены нативной: перевести на /usr/local/bin/claude
    for lnk in /usr/bin/claude /usr/local/bin/claude; do
        if [ -L "$lnk" ] && [ ! -e "$lnk" ]; then run "rm -f '$lnk'"; fi
    done
    if [ ! -e /usr/bin/claude ] && [ -x /usr/local/bin/claude ]; then run "ln -s /usr/local/bin/claude /usr/bin/claude"; fi
    hash -r 2>/dev/null
}

fn_expose_claude_globally() {   # /usr/local/bin/claude — копия нативного бинарника root (обёртка невозможна: /root закрыт для других), обновляется, когда источник изменился
    local src="$1" dst=/usr/local/bin/claude
    [ -x "$src" ] || return 0
    if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    fn_backup_foreign "$dst"
    run "rm -f '$dst' && install -m 755 '$src' '$dst' && printf '%s\n' 'копия $src' > '/usr/local/bin/.claude.$MARK'"
}

fn_install_claude_smart() {   # auto: нативный → при недоступности/ошибке npm; --method native|npm — принудительно
    step "Claude Code"
    local method="$OPT_METHOD"
    fn_is_centos7 && method="npm"
    if [ "$method" = "auto" ]; then $NATIVE_OK && method="native" || method="npm"; fi
    if [ "$method" = "native" ]; then
        if fn_install_claude_native_for root; then fn_expose_claude_globally /root/.local/bin/claude
        else warn "нативная установка не удалась — пробую через npm"; fn_install_claude_npm || { err "Claude Code не установлен ни одним способом (см. $LOG)"; return 1; }; fi
    else
        fn_install_claude_npm || { err "npm-установка не удалась (см. $LOG)"; return 1; }
    fi
    fn_fix_claude_path
    $OPT_DRY && return 0
    local v; v=$(fn_claude_version /usr/local/bin/claude); [ -z "$v" ] && v=$(fn_claude_version "$(command -v claude 2>/dev/null)")
    ok "Claude Code ${C_BOLD}${v:-?}${C_NC} установлен"
}

# ==============================================================================
# МАСТЕР ОБНОВЛЕНИЯ: Claude Code + миграция backlog-add + DevKit (диалоговый)
# ==============================================================================
PLAN=()            # строки плана «что сделаем»
PLAN_RISKY=false   # есть ли в плане что-то, что стоит подтвердить (замена установки, вход, отключение старого, Docker)
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
    local latest; latest=$($(fn_net_prefix "https://registry.npmjs.org/-/ping")curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null </dev/null | grep -oE '"version": *"[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    local i=0
    while IFS='|' read -r p t v o; do [[ "$t" == wrapper || "$t" == symlink* ]] && continue; i=$((i+1))
        local mark=""
        if [ "$t" = native ]; then mark="${C_DIM}официальный канал обновлений${C_NC}"
        elif [ -n "$latest" ] && [ "$v" = "$latest" ]; then mark="${C_GREEN}$S_OK актуальная${C_NC}"
        elif [ -n "$latest" ]; then mark="${C_YELLOW}есть новее: $latest${C_NC}"; fi
        printf '   %s%s%s  Claude Code %s%s%s %s %s%s%s   %s\n' "$C_CYAN" "$i" "$C_NC" "$C_BOLD" "${v:-?}" "$C_NC" "$S_DOT" "$C_DIM" "$(fn_type_label "$t"), $o" "$C_NC" "$mark"
        printf '      %s%s%s\n' "$C_DIM" "$p" "$C_NC"; done <<<"$list"
    # решение без лишних вопросов: актуальная npm-установка — ничего; нативная — тихий «claude update» (он сам решает, есть ли новее);
    # npm-установка со старой версией — один вопрос на всё; «решить по каждой» — только если установок несколько
    local outdated=0 n_inst=0
    while IFS='|' read -r p t v o; do [[ "$t" == wrapper || "$t" == symlink* ]] && continue; n_inst=$((n_inst+1))
        [ "$t" != native ] && [ -n "$latest" ] && [ "$v" != "$latest" ] && outdated=$((outdated+1)); done <<<"$list"
    local mode=a
    if [ "$outdated" -gt 0 ]; then
        if [ "$n_inst" -gt 1 ]; then choose "Есть новее ($latest):" 1 "Обновить все установки" "Решить по каждой" "Оставить как есть"; case "$CHOSEN" in 1) mode=a;; 2) mode=o;; *) mode=n;; esac
        else ask "Обновить Claude Code до $latest? (Y/n):" Y && mode=a || mode=n; fi
    else ok "Claude Code актуален"; fi
    while IFS='|' read -r p t v o; do
        [[ "$t" == wrapper || "$t" == symlink* ]] && continue      # обёртки/симлинки обновляются вместе с целью
        if $OPT_YES && ! $OPT_ALL_USERS && [ "$o" != root ]; then info "${C_DIM}$o: установка другого пользователя — в --yes не трогаю (нужен --all-users)${C_NC}"; continue; fi
        local act="skip"
        if [ "$t" = native ]; then act="update"                                           # официальный канал: дёшево и безопасно, без вопросов
        elif [ -n "$latest" ] && [ "$v" = "$latest" ]; then act="skip"
        elif [ "$mode" = a ]; then
            if [[ "$t" == npm-global || "$t" == npm-local ]] && ! fn_is_centos7 && $NATIVE_OK; then act="native"; else act="update"; fi
        elif [ "$mode" = o ]; then
            if [[ "$t" == npm-global || "$t" == npm-local ]] && ! fn_is_centos7 && $NATIVE_OK; then
                choose "Claude ${v:-?} ($(fn_type_label "$t"), $o):" 1 "Заменить официальной установкой Anthropic" "Обновить как есть, через npm" "Не трогать"
                case "$CHOSEN" in 1) act="native";; 2) act="update";; *) act="skip";; esac
            else
                choose "Claude ${v:-?} ($(fn_type_label "$t"), $o):" 1 "Обновить через npm" "Не трогать"
                case "$CHOSEN" in 1) act="update";; *) act="skip";; esac
            fi
        fi
        [ "$act" = "skip" ] && continue
        PLAN_CLAUDE+=("$p|$t|$o|$act")
        case "$act" in
            update) [ "$t" = native ] && PLAN+=("Проверить обновления официального Claude Code ($o)") || PLAN+=("Обновить Claude Code до $latest ($(fn_type_label "$t"), $o)");;
            native) PLAN+=("Перейти на официальный Claude Code, старую npm-установку убрать ($o)"); PLAN_RISKY=true;;
            npm) PLAN+=("Переустановить Claude Code через npm ($o)"); PLAN_RISKY=true;;
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
    projects=$(timeout 20 find "$h" /home /opt /var/www -maxdepth 3 -name .mw-devkit -user "$(fn_owner_of "$h")" 2>/dev/null | wc -l)
    echo "$key|$legacy|$projects"
}

fn_wizard_devkit() {
    step "MW DevKit"
    info "${C_DIM}вход по рабочему e-mail (код в Битрикс24); права — по роли в проекте; скилл и хуки — из AdFlow${C_NC}"
    local users=("root|/root"); for h in /home/*; do
        [ -d "$h/.claude" ] || continue
        [ -n "$(fn_owner_of "$h")" ] || continue
        if [ -d "$h/.claude/projects" ] || [ -s "$h/.config/mw-devkit/key" ] || [ -d "$h/.claude/skills/backlog-add" ]; then users+=("$(fn_owner_of "$h")|$h")
        else info "${C_DIM}$(fn_owner_of "$h"): каталог ~/.claude есть, но Claude под этим пользователем не запускался — пропускаю${C_NC}"; fi
    done
    for ent in "${users[@]}"; do IFS='|' read -r u h <<<"$ent"; IFS='|' read -r k l pr <<<"$(fn_user_devkit_state "$h")"
        printf '   %s%s%s  %s%s%s %s %s\n' "$C_CYAN" "$S_DOT" "$C_NC" "$C_BOLD" "$u" "$C_NC" "$S_DOT" "$([ $k = yes ] && echo "${C_GREEN}подключён${C_NC}" || echo "не подключён")$([ $l = yes ] && echo ", старый backlog-add (Google-таблица)")$([ "$pr" -gt 0 ] && echo ", проектов: $pr")"; done
    for ent in "${users[@]}"; do
        IFS='|' read -r u h <<<"$ent"; IFS='|' read -r k l pr <<<"$(fn_user_devkit_state "$h")"
        local dk="skip" lg="keep"
        if $OPT_YES && ! $OPT_ALL_USERS && [ "$u" != root ]; then info "${C_DIM}$u: в --yes настройки другого пользователя не трогаю (нужен --all-users)${C_NC}"; PLAN_USERS+=("$u|$h|skip|keep"); continue; fi
        if [ "$k" = yes ]; then dk="update"                                       # обновление скилла/хуков идемпотентно — без вопросов
        else
            if $OPT_YES; then warn "$u: DevKit не подключён — вход интерактивный, выполните позже: adflow login && adflow update"
            else choose "$u — подключить DevKit?" "$([ "$u" = root ] && echo 1 || echo 2)" "Да, сейчас (e-mail, код придёт в Битрикс24)" "Позже"; [ "$CHOSEN" = 1 ] && { dk="login"; PLAN_RISKY=true; }; fi
        fi
        if [ "$l" = yes ]; then
            if $OPT_KEEP_LEGACY; then lg="keep"
            else choose "$u — старый backlog-add (Google-таблица):" "$([ "$dk" = skip ] && echo 2 || echo 1)" "Отключить — журнал теперь ведёт DevKit" "Оставить"; [ "$CHOSEN" = 1 ] && { lg="off"; PLAN_RISKY=true; }; fi
        fi
        PLAN_USERS+=("$u|$h|$dk|$lg")
        case "$dk" in login) PLAN+=("Подключить $u к DevKit (вход по e-mail, код из Битрикс24)");; update) PLAN+=("Обновить инструкции и хуки DevKit для $u");; esac
        [ "$lg" = off ] && PLAN+=("Отключить старый backlog-add у $u (бэкап сохраняется)")
    done
}

fn_npm_update_failed() {   # npm не обновил Claude: где можно — официальный установщик, иначе внятная ошибка
    if $NATIVE_OK && ! fn_is_centos7; then warn "npm не сработал — пробую официальный установщик Anthropic"; fn_install_claude_native_for "${1:-root}" && { [ "${1:-root}" = root ] && fn_expose_claude_globally /root/.local/bin/claude; return 0; }; fi
    err "Claude Code не обновлён (подробности: $LOG)"; return 1
}

fn_apply_claude() {
    for ent in "${PLAN_CLAUDE[@]}"; do
        IFS='|' read -r p t o act <<<"$ent"
        case "$act" in
            native) if { [ "$o" = root ] && [ -x /root/.local/bin/claude ]; } || fn_install_claude_native_for "$o"; then
                        [ "$o" = root ] && fn_expose_claude_globally /root/.local/bin/claude
                        if [ "$t" = npm-global ] && command -v npm >/dev/null 2>&1; then spin "Убираю старую npm-установку" "${PREFIX}npm -g uninstall @anthropic-ai/claude-code" || true; fi
                    else warn "нативная не удалась — второй способ: npm"; fn_install_claude_npm || err "Claude для $o не обновлён (см. $LOG)"; fi ;;
            npm) fn_install_claude_npm || err "npm-установка не удалась (см. $LOG)" ;;
            install) fn_install_claude_smart || err "Claude Code не установлен (см. $LOG)" ;;
            update)
                case "$t" in
                    native)
                        if [ "$o" = root ]; then { SPIN_TIMEOUT=600 spin "claude update ($o)" "${PREFIX}'$p' update" || fn_install_claude_native_for root || fn_install_claude_npm; } && fn_expose_claude_globally /root/.local/bin/claude
                        else SPIN_TIMEOUT=600 spin "claude update ($o)" "su -s /bin/bash - '$o' -c '${PREFIX}\"$p\" update'" || fn_install_claude_native_for "$o" || warn "Claude для $o не обновлён (см. $LOG)"; fi ;;
                    npm-sandbox) fn_install_nodejs_sandboxed || { fn_npm_update_failed "$o"; continue; }
                                 SPIN_TIMEOUT=900 spin "npm install (песочница)" "PATH='$NODE_DIR/bin:$PATH' $(fn_npm_cmd "$NODE_DIR/bin/npm" install -g @anthropic-ai/claude-code@latest)" || fn_npm_update_failed "$o" ;;
                    npm-global) SPIN_TIMEOUT=900 spin "npm install -g @anthropic-ai/claude-code@latest" "$(fn_npm_cmd "$(command -v npm)" install -g @anthropic-ai/claude-code@latest)" || fn_npm_update_failed "$o" ;;
                    npm-local) if fn_install_claude_native_for "$o"; then local uh; uh=$(getent passwd "$o" | cut -d: -f6); [ -d "$uh/.claude/local" ] && run "mv '$uh/.claude/local' '$uh/.claude/local.disabled.$TS'" && info "$o: старая установка ~/.claude/local отключена (alias claude в ~/.bashrc уберите вручную)"
                               else warn "не удалось обновить для $o"; fi ;;
                esac ;;
        esac
    done
    if [ -L /usr/local/bin/claude ] && [[ "$(readlink -f /usr/local/bin/claude)" == /root/* ]]; then fn_expose_claude_globally /root/.local/bin/claude; fi
    [ -f "/usr/local/bin/.claude.$MARK" ] && [ -x /root/.local/bin/claude ] && fn_expose_claude_globally /root/.local/bin/claude   # копия могла отстать после claude update
    fn_fix_claude_path
}

fn_migrate_legacy_backlog() {   # $1 home $2 user
    local h="$1" u="$2"
    [ -d "$h/.claude/skills/backlog-add" ] && run "mv '$h/.claude/skills/backlog-add' '$h/.claude/skills/backlog-add.disabled.$TS'"
    if grep -qs 'check_backlog_called' "$h/.claude/settings.json"; then
        run "cp -p '$h/.claude/settings.json' '$h/.claude/settings.json.bak.$TS' && python3 - '$h/.claude/settings.json' <<'PY'
import json,os,sys; p=sys.argv[1]; d=json.load(open(p,encoding='utf-8')); h=d.get('hooks',{})
for ev in list(h): h[ev]=[x for x in h[ev] if not any('check_backlog_called' in (c.get('command') or '') for c in x.get('hooks',[]))]; h[ev] or h.pop(ev)
t=p+'.tmp'; json.dump(d,open(t,'w',encoding='utf-8'),ensure_ascii=False,indent=2); os.replace(t,p)
PY
chown --reference='$h/.claude/settings.json.bak.$TS' '$h/.claude/settings.json'"
    fi
    [ -d "$h/.claude/sheets_sync" ] && info "${C_DIM}$u: sheets_sync и его cron оставлены — выключите после первого закрытого таска в AdFlow${C_NC}"
    ok "Старый backlog-add у $u отключён — журнал работ теперь ведёт DevKit"
}

fn_as_user() {   # выполнить от пользователя в текущем каталоге: shell не из passwd (nologin у bitrix/www-data), аргументы экранированы
    local u="$1"; shift; if [ "$u" = root ]; then "$@"; return; fi
    local d; d=$(pwd -P); local cmd; cmd=$(printf '%q ' "$@")
    su -s /bin/bash - "$u" -c "test -x '$d'" 2>/dev/null || { err "$u не имеет доступа к каталогу $d — запустите установщик из каталога проекта этого пользователя"; return 1; }
    su -s /bin/bash - "$u" -c "cd '$d' && $cmd"
}
fn_json() { python3 -c "
import sys,json
d=json.load(sys.stdin)
if '$1'=='error' and isinstance(d,dict) and 'error' not in d and isinstance(d.get('detail'),str): d={'error': d['detail']}
for k in '$1'.split('.'):
    d=d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" 2>/dev/null; }

fn_devkit_login() {   # $1 = пользователь: вход по e-mail → код → выбор проекта (только коды, один раз) → привязка каталога → код ПМа
    local u="$1" out state
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] adflow login ($u) в $(pwd -P)${C_NC}"; return 0; }
    echo; printf '   %sВход в DevKit%s — %s: код придёт вам в Битрикс24 и на почту; затем выберите проект для каталога %s\n' "$C_BOLD" "$C_NC" "$u" "$(pwd -P)"
    fn_read email "   Рабочий e-mail: "; [ -z "$email" ] && { warn "e-mail не введён — пропускаю"; return 1; }
    out=$(fn_as_user "$u" adflow login --email "$email" <"$IN" 2> >(tee -a "$LOG" >&2)) || { local e; e=$(echo "$out" | fn_json error); err "Вход не выполнен: ${e:-ошибка утилиты adflow, подробности: $LOG}"; return 1; }
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
    out=$(fn_as_user "$u" adflow update 2>>"$LOG") || { local e; e=$(echo "$out" | fn_json error); warn "$u: инструкции не обновились: ${e:-см. $LOG}"; return 1; }
    ok "Инструкции и хуки Claude обновлены ${C_DIM}(версия $(echo "$out" | fn_json version))${C_NC}"
}

fn_apply_devkit() {
    command -v python3 >/dev/null 2>&1 || fn_prepare_minimal
    fn_fetch_adflow_cli || return 1
    $OPT_DRY || python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null || { err "adflow требует Python 3.6+ (сейчас $(python3 --version 2>&1))"; return 1; }
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
    PLAN=(); PLAN_CLAUDE=(); PLAN_USERS=(); PLAN_RISKY=false
    fn_wizard_claude
    fn_wizard_devkit
    step "План"
    if [ ${#PLAN[@]} -eq 0 ]; then ok "Всё актуально, делать нечего."; return 0; fi
    local n=0; for x in "${PLAN[@]}"; do n=$((n+1)); printf '   %s%s%s %s\n' "$C_CYAN" "$S_OK" "$C_NC" "$x"; done
    $OPT_DRY && info "${C_DIM}режим проверки: команды только печатаются${C_NC}"
    if $PLAN_RISKY; then ask "Поехали? (Y/n):" Y || { warn "Отменено."; return 0; }; fi   # обновления безопасны и обратимы — без переспроса
    [ ${#PLAN_CLAUDE[@]} -gt 0 ] && { step "Claude Code"; fn_apply_claude; }
    step "MW DevKit"; fn_apply_devkit
}

# совместимость: старые имена
fn_update_all_claude() { fn_update_wizard; }
fn_setup_devkit() {
    PLAN=(); PLAN_CLAUDE=(); PLAN_USERS=(); PLAN_RISKY=false; fn_wizard_devkit
    [ ${#PLAN[@]} -eq 0 ] && return 0
    fn_apply_devkit   # всё, что здесь, пользователь уже выбрал вопросами выше — второй раз не спрашиваем
}

# ==============================================================================
# PRESALE DEMO STACK
# ==============================================================================
fn_deploy_presale_stack() {
    step "Presale Demo Stack ($DEMO_DIR)"
    if fn_is_centos7; then err "Presale-стек требует Python ≥ 3.9 и современный Docker — на CentOS 7 не поддерживается."; return 1; fi
    $OPT_DRY && { echo "   ${C_DIM}[dry-run] развернуть демо-стек в $DEMO_DIR (Caddy :80/:443, Postgres 127.0.0.1:5432, FastAPI, Vite)${C_NC}"; return 0; }
    local busy; busy=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(80|443)$' | tr '\n' ' ')
    if [ -n "$busy" ]; then err "Порты 80/443 уже заняты ($busy) — Caddy демо-стека не поднимется и может мешать сайту. Освободите порты или разверните стек на другом сервере."; return 1; fi
    if [ -d "$DEMO_DIR/frontend" ]; then
        ask "Стек уже развёрнут в $DEMO_DIR. Пересоздать? Код frontend/backend уедет в бэкап *.bak.$TS, база Postgres останется (y/N):" N || return 0
        run "mv '$DEMO_DIR/frontend' '$DEMO_DIR/frontend.bak.$TS'"; [ -d "$DEMO_DIR/backend" ] && run "cp -a '$DEMO_DIR/backend' '$DEMO_DIR/backend.bak.$TS'"
    fi
    fn_install_nodejs_sandboxed || return 1
    local APP_DOMAIN="$OPT_DOMAIN" DB_PASS="$OPT_DBPASS"
    [ -z "$DB_PASS" ] && [ -f "$DEMO_DIR/backend/.env" ] && DB_PASS=$(sed -nE 's#^DATABASE_URL=.*://[^:]+:([^@]*)@.*#\1#p' "$DEMO_DIR/backend/.env" | head -n 1) && [ -n "$DB_PASS" ] && info "${C_DIM}пароль Postgres взят из существующего backend/.env${C_NC}"
    if [ -z "$APP_DOMAIN" ]; then $OPT_YES && APP_DOMAIN=localhost || { fn_read APP_DOMAIN "Домен для Caddy (по умолчанию localhost): "; APP_DOMAIN=${APP_DOMAIN:-localhost}; }; fi
    if [ -z "$DB_PASS" ]; then
        if $OPT_YES; then DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20); else fn_read DB_PASS "Пароль PostgreSQL (Enter — сгенерировать): " -s; DB_PASS=${DB_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}; fi
    fi
    mkdir -p "$DEMO_DIR"/{docker,backend}; chmod 750 "$DEMO_DIR/docker"
    ( umask 077

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
    )
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
      && HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= ${PREFIX}pip install --upgrade pip >>"$LOG" 2>&1 \
      && HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= ${PREFIX}pip install "fastapi[standard]" "psycopg[binary]" sqlalchemy python-dotenv >>"$LOG" 2>&1 ) || { err "pip install не удался (см. $LOG)"; return 1; }
    ( umask 077; cat > "$DEMO_DIR/backend/.env" <<EOF
DATABASE_URL=postgresql+psycopg://vibe_admin:${DB_PASS}@localhost:5432/vibe_db
EOF
    )
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
    ( cd "$DEMO_DIR" && export PATH="$NODE_DIR/bin:$PATH" CI=1 && eval "$(fn_npm_cmd "$NODE_DIR/bin/npx" --yes create-vite@6 frontend --template react-ts)" </dev/null >>"$LOG" 2>&1 ) \
      || { err "create-vite не создал фронтенд (см. $LOG)"; return 1; }
    [ -d "$DEMO_DIR/frontend" ] || { err "Каталог frontend не появился"; return 1; }
    ( cd "$DEMO_DIR/frontend" && export PATH="$NODE_DIR/bin:$PATH" && eval "$(fn_npm_cmd "$NODE_DIR/bin/npm" install)" >>"$LOG" 2>&1 \
      && eval "$(fn_npm_cmd "$NODE_DIR/bin/npm" install recharts lucide-react tailwindcss @tailwindcss/vite)" >>"$LOG" 2>&1 ) || { err "npm install не удался (см. $LOG)"; return 1; }
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
    local cv; cv=$(fn_claude_version /usr/local/bin/claude); [ -z "$cv" ] && cv=$(fn_claude_version "$(command -v claude 2>/dev/null)")
    local who=""; [ -s /root/.config/mw-devkit/key ] && who=$(adflow whoami 2>/dev/null | fn_json employee)
    echo; hr
    printf '   %s%s%s  %sВсё готово%s\n' "$C_GREEN" "$S_OK" "$C_NC" "$C_BOLD" "$C_NC"
    echo
    if [ -n "$cv" ]; then printf '   %sClaude Code%s     версия %s\n' "$C_BOLD" "$C_NC" "$cv"; else printf '   %sClaude Code%s     не установлен\n' "$C_BOLD" "$C_NC"; fi
    if [ -n "$who" ]; then printf '   %sDevKit%s          подключён как %s\n' "$C_BOLD" "$C_NC" "$who"; else printf '   %sDevKit%s          не подключён %s(adflow login)%s\n' "$C_BOLD" "$C_NC" "$C_DIM" "$C_NC"; fi
    $USE_PROXY_FLAG && printf '   %sСеть%s            через прокси %s:%s\n' "$C_BOLD" "$C_NC" "$PROXY_IP" "$PROXY_PORT"
    echo
    local pc=""; $USE_PROXY_FLAG && pc="proxychains4 "
    printf '   %sЧто дальше%s\n' "$C_BOLD" "$C_NC"
    printf '   %s1%s  Запустите %s%sclaude%s, внутри — команда %s/login%s\n' "$C_CYAN" "$C_NC" "$C_BOLD" "$pc" "$C_NC" "$C_BOLD" "$C_NC"
    printf '   %s2%s  Другой проект/каталог: %sadflow login%s там же %s(выбор проекта показывается только после кода входа)%s\n' "$C_CYAN" "$C_NC" "$C_BOLD" "$C_NC" "$C_DIM" "$C_NC"
    printf '   %s3%s  Работайте как обычно, в конце скажите Claude %s«закрой таск»%s\n' "$C_CYAN" "$C_NC" "$C_BOLD" "$C_NC"
    printf '   %sОт root без запросов подтверждения: IS_SANDBOX=1 %sclaude --dangerously-skip-permissions%s\n' "$C_DIM" "$pc" "$C_NC"
    local baks; baks=$(ls -d /usr/local/bin/claude.bak.$TS /etc/proxychains*.conf.bak.$TS /root/.proxychains/proxychains.conf.bak.$TS /home/*/.proxychains/proxychains.conf.bak.$TS /root/.claude/settings.json.bak.$TS 2>/dev/null | tr '\n' ' ')
    [ -n "$baks" ] && printf '   %sПрежние версии файлов сохранены: %s%s\n' "$C_DIM" "$baks" "$C_NC"
    echo; printf '   %sЕсли в этой же сессии «claude» не находится — выполните hash -r или откройте новый терминал. Лог: %s%s\n' "$C_DIM" "$LOG" "$C_NC"
    hr
}

fn_interactive_menu() {
    fn_show_logo
    local existing; existing=$(fn_discover_claude | grep -vE '\|(wrapper|symlink)' | head -n 3)
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
    [ -z "$CHOICE" ] && fn_read CHOICE "   ${S_ARR} "
    case "$CHOICE" in
        1) fn_require_project_dir; STEP_TOTAL=4; fn_setup_proxy; fn_prepare_minimal; fn_install_claude_smart || exit 1; fn_setup_devkit ;;
        2) STEP_TOTAL=7; fn_setup_proxy; fn_prepare_full; fn_install_docker || exit 1; fn_install_claude_smart || exit 1; fn_deploy_presale_stack; fn_setup_devkit ;;
        3) fn_require_project_dir; STEP_TOTAL=6; fn_setup_proxy; fn_prepare_full; fn_install_docker || true; fn_install_claude_smart || exit 1; fn_setup_devkit ;;
        4) STEP_TOTAL=1; fn_setup_proxy; exit 0 ;;
        5) fn_require_project_dir; STEP_TOTAL=7; fn_setup_proxy; fn_prepare_minimal; fn_update_wizard ;;
        0) echo "Отмена."; exit 0 ;;
        *) err "Введите номер пункта 0–5."; exit 1 ;;
    esac
    fn_finish_message
    if [ "$CHOICE" = "2" ] && [ -x "$DEMO_DIR/start_vibe.sh" ] && ! $OPT_YES && ! $OPT_DRY; then
        ask "Запустить демо-стенд сейчас? (Y/n):" Y && { info "${C_DIM}Ctrl+b, d — отключиться от tmux${C_NC}"; "$DEMO_DIR/start_vibe.sh"; }
    fi
}

fn_parse_args "$@"
fn_check_root
fn_detect_os
fn_interactive_menu
