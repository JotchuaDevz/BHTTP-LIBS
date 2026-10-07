#!/bin/bash

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

HEX_VER="2.0"
LIB_DIR="/usr/local/lib/hex"
HEX_DIR="/etc/hex"
LOG_FILE="/var/log/hex-installation.log"
CACHE_DIR="/tmp/hex-cache"
RAW_BASE="https://raw.githubusercontent.com/JotchuaDevz/BHTTP-LIBS/refs/heads/main"
BHTTP_FILE="bhttp-server-v2.4.1-btun-compat-keepalive-linux"
HCR_FILE="hcr-server-linux"

write_lib() {
cat > "$LIB_DIR/ui.sh" <<'EOF_LIB'
shopt -s extglob
export LC_ALL=C.UTF-8 2>/dev/null

HEX_DIR="/etc/hex"
CONF="$HEX_DIR/hex.conf"
USER_DB="$HEX_DIR/users.txt"
LOG_FILE="/var/log/hex-installation.log"
BHTTP_UNIT="bhttp-server.service"
HCR_UNIT="hcr-server.service"
W=64
HEX_VER="2.0"
STEP_N=0
STEP_TOTAL=0

ACC=$'\e[38;5;44m'
RED=$'\e[38;5;203m'
GREEN=$'\e[38;5;84m'
YELLOW=$'\e[38;5;221m'
CYAN=$'\e[38;5;51m'
WHITE=$'\e[38;5;255m'
GRIS=$'\e[38;5;245m'
BOLD=$'\e[1m'
NC=$'\e[0m'
BG_ACC=$'\e[48;5;44m'
BLACK=$'\e[38;5;16m'

load_conf() {
    [ -f "$CONF" ] && . "$CONF"
    : "${BHTTP_PORT:=80}"
    : "${HCR_PORT:=8080}"
    : "${SSH_PORT:=22}"
}

save_conf() {
    mkdir -p "$HEX_DIR"
    printf 'BHTTP_PORT=%s\nHCR_PORT=%s\nSSH_PORT=%s\n' "$BHTTP_PORT" "$HCR_PORT" "$SSH_PORT" > "$CONF"
}

hline() {
    local s="" i
    for ((i = 0; i < $1; i++)); do s+="─"; done
    printf '%s' "$s"
}

ui_top() { printf '%s╭%s╮%s\n' "$ACC" "$(hline $W)" "$NC"; }
ui_sep() { printf '%s├%s┤%s\n' "$ACC" "$(hline $W)" "$NC"; }
ui_bot() { printf '%s╰%s╯%s\n' "$ACC" "$(hline $W)" "$NC"; }

ui_row() {
    local plain="${1//$'\e['*([0-9;])m/}" pad
    pad=$((W - 2 - ${#plain}))
    ((pad < 0)) && pad=0
    printf '%s│%s %s%*s %s│%s\n' "$ACC" "$NC" "$1" "$pad" "" "$ACC" "$NC"
}

ui_title() {
    local t="$1" l r len
    len=$((${#t} + 4))
    l=$(((W - len) / 2))
    r=$((W - len - l))
    printf '%s│%s%*s%s◆%s %s%s%s %s◆%s%*s%s│%s\n' "$ACC" "$NC" "$l" "" "$ACC" "$NC" "$BOLD$WHITE" "$t" "$NC" "$ACC" "$NC" "$r" "" "$ACC" "$NC"
}

ui_center() {
    local plain="${1//$'\e['*([0-9;])m/}" l
    l=$(((W - 2 - ${#plain}) / 2))
    ((l < 0)) && l=0
    ui_row "$(printf '%*s' "$l" '')$1"
}

ui_screen() {
    clear
    ui_top
    ui_title "$1"
    ui_sep
}

ui_banner() {
    local sub="$1" line i=0
    local logo=(
        "██╗  ██╗███████╗██╗  ██╗"
        "██║  ██║██╔════╝╚██╗██╔╝"
        "███████║█████╗   ╚███╔╝ "
        "██╔══██║██╔══╝   ██╔██╗ "
        "██║  ██║███████╗██╔╝ ██╗"
        "╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝"
    )
    local grad=(51 50 44 38 33 27)
    ui_top
    ui_row ""
    for line in "${logo[@]}"; do
        ui_center $'\e[38;5;'"${grad[i]}"'m'"$line$NC"
        i=$((i + 1))
    done
    ui_row ""
    ui_center "${GRIS}$sub${NC}"
    ui_row ""
}

ui_section() { ui_row "  ${ACC}▍${NC}${BOLD}${WHITE}$1${NC}"; }
ui_kv() { ui_row "    ${GRIS}$(printf '%-12s' "$1")${NC}$2"; }
ui_opt() { ui_row "  ${BG_ACC}${BLACK}${BOLD} $1 ${NC}  $2"; }

ui_opt2() {
    local pad=$((26 - ${#2})) left right=""
    ((pad < 0)) && pad=0
    left="  ${BG_ACC}${BLACK}${BOLD} $1 ${NC}  $2$(printf '%*s' "$pad" '')"
    [ -n "$3" ] && right="  ${BG_ACC}${BLACK}${BOLD} $3 ${NC}  $4"
    ui_row "$left$right"
}

ui_ok() { printf '  %s✓%s %s\n' "$GREEN" "$NC" "$1"; }
ui_err() { printf '  %s✗%s %s%s%s\n' "$RED" "$NC" "$RED" "$1" "$NC"; }
ui_warn() { printf '  %s!%s %s%s%s\n' "$YELLOW" "$NC" "$YELLOW" "$1" "$NC"; }
ui_info() { printf '  %s•%s %s%s%s\n' "$CYAN" "$NC" "$GRIS" "$1" "$NC"; }

ask() {
    printf '\n  %s╰─❯%s %s' "$ACC" "$NC" "$1"
    IFS= read -r "$2"
}

ask_secret() {
    printf '\n  %s╰─❯%s %s' "$ACC" "$NC" "$1"
    IFS= read -rs "$2"
    echo
}

pause() {
    printf '\n  %sEnter para continuar...%s' "$GRIS" "$NC"
    read -r _
}

badge() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        printf '%s%s● ACTIVO%s  ' "$BOLD" "$GREEN" "$NC"
    else
        printf '%s%s● INACTIVO%s' "$BOLD" "$RED" "$NC"
    fi
}

port_in_use() { [ -n "$(ss -H -ltn "sport = :$1" 2>/dev/null)" ]; }

port_owner() {
    ss -H -ltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -n1 | sed 's/users:(("//; s/"$//'
}

listen_badge() {
    local o
    if port_in_use "$1"; then
        o=$(port_owner "$1")
        printf '%s● sí%s %s(%s)%s' "$GREEN" "$NC" "$GRIS" "${o:-?}" "$NC"
    else
        printf '%s● no%s' "$RED" "$NC"
    fi
}

find_free_port() {
    local p="${1:-1024}" avoid="$2" i=0
    [ "$p" -lt 1 ] && p=1
    while [ "$i" -lt 200 ] && [ "$p" -le 65535 ]; do
        if [ "$p" != "$avoid" ] && [ "$p" != "$SSH_PORT" ] && ! port_in_use "$p"; then
            printf '%s' "$p"
            return 0
        fi
        p=$((p + 1))
        i=$((i + 1))
    done
    return 1
}

arch_tag() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) echo "Arquitectura no soportada: $(uname -m)" >&2; return 1 ;;
    esac
}

server_ip() {
    local ip
    ip=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null)
    [[ "$ip" =~ ^[0-9.]+$ ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "$ip"
}

detect_ssh_port() {
    local p
    p=$(/usr/sbin/sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    printf '%s' "${p:-22}"
}

svc_rows() {
    ui_kv "BHTTP" "$(badge "$BHTTP_UNIT")  ${GRIS}│${NC}  ${YELLOW}:$BHTTP_PORT${NC}"
    ui_kv "HCR" "$(badge "$HCR_UNIT")  ${GRIS}│${NC}  ${YELLOW}:$HCR_PORT${NC}"
    ui_kv "SSH" "$(badge ssh.service)  ${GRIS}│${NC}  ${YELLOW}:$SSH_PORT${NC}"
}

open_port() {
    local p="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$p"/tcp >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    fi
    return 0
}

write_unit() {
    local unit="$1" desc="$2" ident="$3" exec_line="$4"
    cat > "/etc/systemd/system/$unit" <<EOF
[Unit]
Description=$desc
After=network-online.target ssh.service sshd.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=$exec_line
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$ident

[Install]
WantedBy=multi-user.target
EOF
}

fetch_bin() {
    local url="$1" dest="$2" tmp size magic rc
    tmp=$(mktemp "${CACHE_DIR:-/tmp}/dl.XXXXXX") || return 1
    if ! curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 -o "$tmp" "$url"; then
        echo "Fallo la descarga: $url"
        rm -f "$tmp"
        return 1
    fi
    size=$(stat -c%s "$tmp")
    magic=$(head -c4 "$tmp" | od -An -tx1 | tr -d ' \n')
    if [ "$size" -lt 100000 ] || [ "$magic" != "7f454c46" ]; then
        echo "El archivo descargado no es un binario ELF valido ($size bytes). Puntero Git LFS o pagina HTML."
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$tmp"
    timeout 3 "$tmp" --help >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
        echo "El binario no se puede ejecutar en este sistema (rc=$rc). Arquitectura o libc incompatible."
        rm -f "$tmp"
        return 1
    fi
    install -m 755 "$tmp" "$dest"
    rm -f "$tmp"
}

bin_state() {
    local magic
    if [ ! -f "$1" ]; then
        printf '%s✗ no existe%s' "$RED" "$NC"
        return
    fi
    magic=$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')
    if [ "$magic" != "7f454c46" ]; then
        printf '%s✗ no es ELF%s' "$RED" "$NC"
    elif [ ! -x "$1" ]; then
        printf '%s✗ sin permiso de ejecución%s' "$RED" "$NC"
    else
        printf '%s✓ ok%s' "$GREEN" "$NC"
    fi
}

diagnose_hint() {
    local unit="$1" logs l
    logs=$(journalctl -u "$unit" -n 12 --no-pager -o cat 2>/dev/null)
    if [ -n "$logs" ]; then
        printf '%s\n' "$logs" | tail -n 6 | while IFS= read -r l; do
            printf '      %s%s%s\n' "$GRIS" "${l:0:96}" "$NC"
        done
    fi
    case "$logs" in
        *"already in use"*|*"address in use"*) ui_warn "El puerto está ocupado por otro proceso" ;;
        *"exec format error"*) ui_warn "Binario de otra arquitectura" ;;
        *"flag provided but not defined"*|*"unknown flag"*|*"unknown option"*|*"Usage"*) ui_warn "El binario no acepta esos parámetros" ;;
        *"ermission denied"*) ui_warn "Permisos insuficientes" ;;
    esac
}

run_step() {
    local msg="$1" pid rc i=0 tag=""
    shift
    if [ "$STEP_TOTAL" -gt 0 ]; then
        STEP_N=$((STEP_N + 1))
        tag=$(printf '%s[%d/%d]%s ' "$GRIS" "$STEP_N" "$STEP_TOTAL" "$NC")
    fi
    local spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    ( "$@" ) >>"$LOG_FILE" 2>&1 &
    pid=$!
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s%s' "$CYAN" "${spin[i % 10]}" "$NC" "$tag" "$msg"
        i=$((i + 1))
        sleep 0.1
    done
    wait "$pid"
    rc=$?
    tput cnorm 2>/dev/null
    printf '\r\033[K'
    if [ "$rc" -eq 0 ]; then
        ui_ok "$tag$msg"
    else
        ui_err "$tag$msg"
        tail -n 5 "$LOG_FILE" | while IFS= read -r l; do
            printf '      %s%s%s\n' "$GRIS" "${l:0:96}" "$NC"
        done
    fi
    return "$rc"
}
EOF_LIB
}

write_menu() {
cat > /usr/local/bin/hex_menu <<'EOF_MENU'
#!/bin/bash

. /usr/local/lib/hex/ui.sh

if [ "$EUID" -ne 0 ]; then
    echo "Requiere permisos de root"
    exit 1
fi

load_conf
SERVER_IP=$(server_ip)

svc_action() {
    local action="$1" unit="$2" label="$3" attempt
    if [ "$action" = "stop" ]; then
        systemctl stop "$unit" >/dev/null 2>&1
        sleep 1
        ui_ok "$label detenido"
        return
    fi
    for attempt in 1 2; do
        systemctl reset-failed "$unit" >/dev/null 2>&1
        systemctl "$action" "$unit" >/dev/null 2>&1
        sleep 1
        if systemctl is-active --quiet "$unit"; then
            ui_ok "$label activo"
            return
        fi
        [ "$attempt" -eq 1 ] && ui_warn "No respondió, reintentando..."
    done
    ui_err "$label no inició tras 2 intentos"
    diagnose_hint "$unit"
}

change_port() {
    local label="$1" unit="$2" portvar="$3" newp old="${!3}" owner sug
    while true; do
        sug=$(find_free_port $((old + 1)) "$old")
        ui_screen "CAMBIAR PUERTO · $label"
        ui_row ""
        ui_kv "Actual" "${YELLOW}$old${NC}  $(listen_badge "$old")"
        [ -n "$sug" ] && ui_kv "Sugerido" "${GREEN}$sug${NC} ${GRIS}(libre)${NC}"
        ui_row ""
        ui_bot
        ask "Nuevo puerto ${GRIS}(Enter = $sug, 0 = cancelar)${NC}: " newp
        if [ -z "$newp" ] && [ -n "$sug" ]; then
            newp="$sug"
        fi
        if [ "$newp" = "0" ]; then
            ui_warn "Cancelado"
            return 1
        fi
        if ! [[ "$newp" =~ ^[0-9]+$ ]] || [ "$newp" -lt 1 ] || [ "$newp" -gt 65535 ]; then
            ui_err "Puerto inválido, usa un número entre 1 y 65535"
            continue
        fi
        if [ "$newp" = "$old" ]; then
            ui_warn "Es el mismo puerto actual, nada que cambiar"
            return 0
        fi
        if [ "$newp" = "$SSH_PORT" ]; then
            ui_err "Ese puerto lo usa SSH, elige otro"
            continue
        fi
        if port_in_use "$newp"; then
            owner=$(port_owner "$newp")
            ui_err "El puerto $newp está en uso por ${owner:-otro proceso}${sug:+ · prueba $sug}"
            continue
        fi
        break
    done
    printf -v "$portvar" '%s' "$newp"
    save_conf
    sed -i "s|--listen :[0-9]*|--listen :$newp|" "/etc/systemd/system/$unit"
    systemctl daemon-reload
    open_port "$newp"
    svc_action restart "$unit" "$label"
}

manage_service() {
    local label="$1" unit="$2" portvar="$3" opt port
    while true; do
        load_conf
        port="${!portvar}"
        ui_screen "GESTIONAR $label"
        ui_row ""
        ui_kv "Estado" "$(badge "$unit")"
        ui_kv "Puerto" "${YELLOW}$port${NC}"
        ui_kv "Escuchando" "$(listen_badge "$port")"
        ui_row ""
        ui_sep
        ui_opt "1" "Iniciar"
        ui_opt "2" "Detener"
        ui_opt "3" "Reiniciar"
        ui_opt "4" "Cambiar puerto"
        ui_opt "5" "Ver estado"
        ui_opt "0" "Atrás"
        ui_bot
        ask "Opción: " opt
        echo
        case "$opt" in
            1) svc_action start "$unit" "$label"; pause ;;
            2) svc_action stop "$unit" "$label"; pause ;;
            3) svc_action restart "$unit" "$label"; pause ;;
            4) change_port "$label" "$unit" "$portvar"; pause ;;
            5) systemctl status "$unit" --no-pager; pause ;;
            0) return ;;
            *) ui_err "Opción inválida"; pause ;;
        esac
    done
}

user_in_db() { awk -F: -v u="$1" '$1==u{f=1} END{exit !f}' "$USER_DB" 2>/dev/null; }

db_remove() {
    local tmp
    tmp=$(mktemp)
    awk -F: -v u="$1" '$1!=u' "$USER_DB" > "$tmp"
    cat "$tmp" > "$USER_DB"
    rm -f "$tmp"
}

user_card() {
    echo
    ui_top
    ui_title "CUENTA LISTA"
    ui_sep
    ui_kv "IP" "${YELLOW}$SERVER_IP${NC}"
    ui_kv "BHTTP" "${YELLOW}$BHTTP_PORT${NC}"
    ui_kv "HCR" "${YELLOW}$HCR_PORT${NC}"
    ui_kv "SSH" "${YELLOW}$SSH_PORT${NC}"
    ui_kv "Usuario" "${YELLOW}$1${NC}"
    ui_kv "Contraseña" "${YELLOW}$2${NC}"
    ui_kv "Expira" "${YELLOW}$3${NC}"
    ui_bot
}

add_user() {
    local u p d exp re_user re_pass
    re_user='^[a-z_][a-z0-9_-]{2,31}$'
    re_pass='^[^:[:space:]]{4,64}$'
    ui_screen "AGREGAR USUARIO"
    ui_row ""
    ui_bot
    ask "Usuario: " u
    if ! [[ "$u" =~ $re_user ]]; then
        ui_err "Usuario inválido (3-32 caracteres: minúsculas, números, _ y -)"
        pause
        return
    fi
    if id "$u" >/dev/null 2>&1; then
        ui_err "Ese usuario ya existe en el sistema"
        pause
        return
    fi
    ask_secret "Contraseña: " p
    if ! [[ "$p" =~ $re_pass ]]; then
        ui_err "Contraseña inválida (4-64 caracteres, sin espacios ni dos puntos)"
        pause
        return
    fi
    ask "Validez (días): " d
    if ! [[ "$d" =~ ^[0-9]+$ ]] || [ "$d" -lt 1 ] || [ "$d" -gt 3650 ]; then
        ui_err "Días inválidos"
        pause
        return
    fi
    exp=$(date -d "+$d days" +%Y-%m-%d)
    if ! useradd -M -s /bin/false -e "$exp" "$u"; then
        ui_err "No se pudo crear el usuario"
        pause
        return
    fi
    if ! printf '%s:%s\n' "$u" "$p" | chpasswd; then
        userdel -f "$u" >/dev/null 2>&1
        ui_err "No se pudo asignar la contraseña"
        pause
        return
    fi
    printf '%s:%s:%s\n' "$u" "$p" "$exp" >> "$USER_DB"
    user_card "$u" "$p" "$exp"
    pause
}

list_users() {
    local u p exp left n=0 color
    ui_screen "USUARIOS"
    if [ ! -s "$USER_DB" ]; then
        ui_row ""
        ui_row "  ${YELLOW}No hay usuarios registrados${NC}"
        ui_row ""
        ui_bot
        return
    fi
    ui_row "  ${GRIS}$(printf '%-4s %-18s %-12s %s' '#' 'USUARIO' 'EXPIRA' 'RESTAN')${NC}"
    while IFS=: read -r u p exp; do
        [ -z "$u" ] && continue
        n=$((n + 1))
        left=$(((($(date -d "$exp" +%s) - $(date +%s)) / 86400) + 1))
        if [ "$left" -le 0 ]; then
            color="$RED"
            left="expirado"
        elif [ "$left" -le 3 ]; then
            color="$YELLOW"
            left="${left}d"
        else
            color="$GREEN"
            left="${left}d"
        fi
        ui_row "  $(printf '%-4s %-18s %-12s' "$n" "$u" "$exp")${color}${left}${NC}"
    done < "$USER_DB"
    ui_bot
}

pick_user() {
    local input="$1" name
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        name=$(sed -n "${input}p" "$USER_DB" | cut -d: -f1)
    else
        name="$input"
    fi
    printf '%s' "$name"
}

renew_user() {
    local input u d exp
    list_users
    [ -s "$USER_DB" ] || { pause; return; }
    ask "Usuario o número a renovar: " input
    u=$(pick_user "$input")
    if [ -z "$u" ] || ! user_in_db "$u"; then
        ui_err "Usuario no encontrado"
        pause
        return
    fi
    ask "Días desde hoy: " d
    if ! [[ "$d" =~ ^[0-9]+$ ]] || [ "$d" -lt 1 ] || [ "$d" -gt 3650 ]; then
        ui_err "Días inválidos"
        pause
        return
    fi
    exp=$(date -d "+$d days" +%Y-%m-%d)
    chage -E "$exp" "$u"
    local tmp
    tmp=$(mktemp)
    awk -F: -v OFS=: -v u="$u" -v e="$exp" '$1==u{$3=e}1' "$USER_DB" > "$tmp"
    cat "$tmp" > "$USER_DB"
    rm -f "$tmp"
    ui_ok "$u renovado hasta $exp"
    pause
}

delete_user() {
    local input u
    list_users
    [ -s "$USER_DB" ] || { pause; return; }
    ask "Usuario o número a eliminar: " input
    u=$(pick_user "$input")
    if [ -z "$u" ] || ! user_in_db "$u"; then
        ui_err "Usuario no encontrado"
        pause
        return
    fi
    pkill -KILL -u "$u" 2>/dev/null
    userdel -f "$u" >/dev/null 2>&1
    db_remove "$u"
    ui_ok "Usuario $u eliminado"
    pause
}

users_menu() {
    local opt
    while true; do
        ui_screen "USUARIOS SSH"
        ui_row ""
        ui_opt "1" "Agregar usuario"
        ui_opt "2" "Listar usuarios"
        ui_opt "3" "Renovar usuario"
        ui_opt "4" "Eliminar usuario"
        ui_opt "0" "Atrás"
        ui_bot
        ask "Opción: " opt
        case "$opt" in
            1) add_user ;;
            2) list_users; pause ;;
            3) renew_user ;;
            4) delete_user ;;
            0) return ;;
            *) ui_err "Opción inválida"; pause ;;
        esac
    done
}

logs_menu() {
    local opt
    while true; do
        ui_screen "LOGS"
        ui_row ""
        ui_opt "1" "BHTTP · últimas 50 líneas"
        ui_opt "2" "HCR · últimas 50 líneas"
        ui_opt "3" "BHTTP · en vivo (Ctrl+C para salir)"
        ui_opt "4" "HCR · en vivo (Ctrl+C para salir)"
        ui_opt "0" "Atrás"
        ui_bot
        ask "Opción: " opt
        echo
        case "$opt" in
            1) journalctl -u "$BHTTP_UNIT" -n 50 --no-pager; pause ;;
            2) journalctl -u "$HCR_UNIT" -n 50 --no-pager; pause ;;
            3) trap ':' INT; journalctl -fu "$BHTTP_UNIT"; trap - INT ;;
            4) trap ':' INT; journalctl -fu "$HCR_UNIT"; trap - INT ;;
            0) return ;;
            *) ui_err "Opción inválida"; pause ;;
        esac
    done
}

diagnose() {
    local entry label unit port bin pa
    load_conf
    ui_screen "DIAGNÓSTICO"
    for entry in "BHTTP|$BHTTP_UNIT|$BHTTP_PORT|/opt/bhttp/bhttp-server" "HCR|$HCR_UNIT|$HCR_PORT|/opt/hcr/hcr-server"; do
        IFS='|' read -r label unit port bin <<<"$entry"
        ui_row ""
        ui_row "  ${BOLD}${WHITE}$label${NC}"
        ui_kv "Servicio" "$(badge "$unit")"
        ui_kv "Habilitado" "$(systemctl is-enabled "$unit" 2>/dev/null || echo no)"
        ui_kv "Binario" "$(bin_state "$bin")"
        ui_kv "Puerto $port" "$(listen_badge "$port")"
    done
    pa=$(/usr/sbin/sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    ui_row ""
    ui_row "  ${BOLD}${WHITE}SSH${NC}"
    ui_kv "Servicio" "$(badge ssh.service)"
    ui_kv "Puerto" "${YELLOW}$SSH_PORT${NC}  $(listen_badge "$SSH_PORT")"
    ui_kv "Contraseña" "${pa:-?}"
    ui_row ""
    ui_bot
    for entry in "$BHTTP_UNIT" "$HCR_UNIT"; do
        if ! systemctl is-active --quiet "$entry"; then
            echo
            ui_err "$entry está inactivo"
            diagnose_hint "$entry"
        fi
    done
    pause
}

uninstall() {
    local c du u p exp
    ui_screen "DESINSTALAR"
    ui_row ""
    ui_row "  ${YELLOW}!${NC}  Se eliminarán servicios, binarios y configuración"
    ui_row ""
    ui_bot
    ask "Escribe CONFIRMAR para continuar: " c
    if [ "$c" != "CONFIRMAR" ]; then
        ui_warn "Cancelado"
        pause
        return
    fi
    ask "¿Eliminar también los usuarios SSH creados? (s/N): " du
    if [[ "$du" =~ ^[sSyY]$ ]] && [ -f "$USER_DB" ]; then
        while IFS=: read -r u p exp; do
            [ -z "$u" ] && continue
            pkill -KILL -u "$u" 2>/dev/null
            userdel -f "$u" >/dev/null 2>&1
        done < "$USER_DB"
    fi
    systemctl disable --now "$BHTTP_UNIT" "$HCR_UNIT" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$BHTTP_UNIT" "/etc/systemd/system/$HCR_UNIT"
    rm -rf /opt/bhttp /opt/hcr /etc/bhttp /etc/hcr /var/log/bhttp /var/log/hcr
    systemctl daemon-reload >/dev/null 2>&1
    rm -rf "$HEX_DIR" /usr/local/lib/hex
    rm -f /usr/bin/hex_menu /usr/local/bin/hex_menu
    echo
    ui_ok "Desinstalado completamente"
    echo
    exit 0
}

main_menu() {
    local opt
    while true; do
        load_conf
        clear
        ui_banner "TUNNEL MANAGER  ·  BHTTP + HCR"
        ui_sep
        ui_row ""
        ui_section "SERVIDOR"
        ui_kv "IP" "${YELLOW}$SERVER_IP${NC}"
        ui_kv "Usuarios" "${YELLOW}$(grep -c . "$USER_DB" 2>/dev/null || echo 0)${NC}"
        ui_row ""
        ui_section "SERVICIOS"
        svc_rows
        ui_row ""
        ui_sep
        ui_row ""
        ui_opt2 "1" "Gestionar BHTTP" "4" "Ver logs"
        ui_opt2 "2" "Gestionar HCR" "5" "Diagnóstico"
        ui_opt2 "3" "Usuarios SSH" "6" "Desinstalar"
        ui_row ""
        ui_opt "0" "Salir"
        ui_row ""
        ui_sep
        ui_center "${GRIS}Hex Applications  ·  v$HEX_VER${NC}"
        ui_bot
        ask "Opción: " opt
        case "$opt" in
            1) manage_service "BHTTP" "$BHTTP_UNIT" BHTTP_PORT ;;
            2) manage_service "HCR" "$HCR_UNIT" HCR_PORT ;;
            3) users_menu ;;
            4) logs_menu ;;
            5) diagnose ;;
            6) uninstall ;;
            0) clear; exit 0 ;;
            *) ui_err "Opción inválida"; pause ;;
        esac
    done
}

main_menu
EOF_MENU
chmod +x /usr/local/bin/hex_menu
ln -sf /usr/local/bin/hex_menu /usr/bin/hex_menu
}

install_deps() {
    command -v apt-get >/dev/null 2>&1 || { echo "Solo se soporta Debian/Ubuntu (apt-get)"; return 1; }
    apt-get -o DPkg::Lock::Timeout=120 update -y
    apt-get -o DPkg::Lock::Timeout=120 install -y curl ca-certificates iproute2 iptables openssh-server procps
}

setup_ssh() {
    local pa
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || return 1
    pa=$(/usr/sbin/sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    if [ "$pa" != "yes" ]; then
        if [ -d /etc/ssh/sshd_config.d ]; then
            printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-hex.conf
        else
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        fi
        /usr/sbin/sshd -t || return 1
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
        pa=$(/usr/sbin/sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
        if [ "$pa" != "yes" ]; then
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
            /usr/sbin/sshd -t || return 1
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || return 1
        fi
    fi
    return 0
}

free_port() {
    local p="$1" owner svc=""
    owner=$(port_owner "$p")
    case "$owner" in
        nginx) svc=nginx ;;
        apache2) svc=apache2 ;;
        httpd) svc=httpd ;;
        caddy) svc=caddy ;;
        lighttpd) svc=lighttpd ;;
    esac
    [ -n "$svc" ] && systemctl disable --now "$svc" >/dev/null 2>&1
    sleep 1
    ! port_in_use "$p"
}

prompt_port() {
    local var="$1" label="$2" other="$3" def="${!1}" input p owner sug
    if port_in_use "$def"; then
        sug=$(find_free_port $((def + 1)) "$other")
        if [ -n "$sug" ]; then
            ui_warn "El puerto $def ya está en uso para $label, sugerido: $sug"
            def="$sug"
        fi
    fi
    if ! { : </dev/tty; } 2>/dev/null; then
        if port_in_use "$def"; then
            free_port "$def" || ui_warn "Puerto $def en uso por $(port_owner "$def"); $label podría no iniciar"
        fi
        printf -v "$var" '%s' "$def"
        return 0
    fi
    while true; do
        printf '  %s❯%s Puerto para %s%s%s %s[%s]%s: ' "$ACC" "$NC" "$BOLD" "$label" "$NC" "$GRIS" "$def" "$NC"
        read -r input </dev/tty
        p="${input:-$def}"
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            ui_err "Puerto inválido, usa un número entre 1 y 65535"
            continue
        fi
        if [ -n "$other" ] && [ "$p" = "$other" ]; then
            ui_err "El puerto $p ya lo usa el otro servicio, elige uno distinto"
            continue
        fi
        if [ "$p" = "$SSH_PORT" ]; then
            ui_err "El puerto $p es el de SSH, elige otro"
            continue
        fi
        if port_in_use "$p"; then
            owner=$(port_owner "$p")
            sug=$(find_free_port $((p + 1)) "$other")
            ui_err "El puerto $p está en uso por ${owner:-otro proceso}, elige otro${sug:+ (libre: $sug)}"
            continue
        fi
        printf -v "$var" '%s' "$p"
        ui_ok "$label usará el puerto $p"
        return 0
    done
}

install_bhttp() {
    local arch
    arch=$(arch_tag) || return 1
    mkdir -p /opt/bhttp /etc/bhttp /var/log/bhttp
    systemctl stop "$BHTTP_UNIT" 2>/dev/null
    fetch_bin "$RAW_BASE/${BHTTP_FILE}-${arch}" /opt/bhttp/bhttp-server || return 1
    write_unit "$BHTTP_UNIT" "BHTTP Server" bhttp "/opt/bhttp/bhttp-server --listen :$BHTTP_PORT --target 127.0.0.1:$SSH_PORT" || return 1
    systemctl daemon-reload
    systemctl enable "$BHTTP_UNIT"
}

install_hcr() {
    local arch
    arch=$(arch_tag) || return 1
    mkdir -p /opt/hcr /etc/hcr /var/log/hcr
    systemctl stop "$HCR_UNIT" 2>/dev/null
    fetch_bin "$RAW_BASE/${HCR_FILE}-${arch}" /opt/hcr/hcr-server || return 1
    write_unit "$HCR_UNIT" "HCR Server" hcr "/opt/hcr/hcr-server --listen :$HCR_PORT --target 127.0.0.1:$SSH_PORT --transport plain" || return 1
    systemctl daemon-reload
    systemctl enable "$HCR_UNIT"
}

open_ports() {
    open_port "$BHTTP_PORT"
    open_port "$HCR_PORT"
}

start_service() {
    local unit="$1" label="$2" port="$3" i attempt
    [ -f "/etc/systemd/system/$unit" ] || { ui_err "$label no está instalado"; return 1; }
    for attempt in 1 2; do
        systemctl reset-failed "$unit" >/dev/null 2>&1
        systemctl restart "$unit" >/dev/null 2>&1
        for i in 1 2 3 4 5 6; do
            sleep 1
            if systemctl is-active --quiet "$unit" && port_in_use "$port"; then
                ui_ok "$label activo y escuchando en :$port"
                return 0
            fi
        done
        [ "$attempt" -eq 1 ] && ui_warn "$label no respondió, reintentando..."
    done
    ui_err "$label no inició correctamente tras 2 intentos"
    diagnose_hint "$unit"
    return 1
}

summary() {
    local fail="$1"
    echo
    ui_top
    if [ "$fail" -eq 1 ]; then
        ui_title "INSTALACIÓN CON ERRORES"
    else
        ui_title "INSTALACIÓN COMPLETADA"
    fi
    ui_sep
    ui_row ""
    ui_section "CONEXIÓN"
    ui_kv "IP" "${YELLOW}$(server_ip)${NC}"
    ui_row ""
    ui_section "SERVICIOS"
    svc_rows
    ui_row ""
    ui_sep
    ui_row ""
    ui_center "Administra todo con  ${YELLOW}${BOLD}hex_menu${NC}"
    ui_center "${GRIS}Log: $LOG_FILE${NC}"
    ui_row ""
    ui_bot
    echo
}

main() {
    local fail=0 failed_units=()
    if [ "$EUID" -ne 0 ]; then
        echo "Este script requiere permisos de root"
        exit 1
    fi

    mkdir -p "$LIB_DIR" "$HEX_DIR" "$CACHE_DIR"
    write_lib
    . "$LIB_DIR/ui.sh"
    : > "$LOG_FILE"
    load_conf

    clear
    ui_banner "INSTALADOR  ·  BHTTP + HCR  ·  v$HEX_VER"
    ui_bot
    echo
    STEP_TOTAL=6

    run_step "Instalando dependencias" install_deps || { ui_info "Detalles en $LOG_FILE"; exit 1; }
    run_step "Configurando OpenSSH" setup_ssh || { ui_info "Detalles en $LOG_FILE"; exit 1; }
    SSH_PORT=$(detect_ssh_port)

    systemctl stop "$BHTTP_UNIT" "$HCR_UNIT" >/dev/null 2>&1
    ui_info "Configuración de puertos (Enter para usar el valor entre corchetes)"
    prompt_port BHTTP_PORT BHTTP ""
    prompt_port HCR_PORT HCR "$BHTTP_PORT"
    echo
    save_conf
    touch "$USER_DB"
    chmod 600 "$USER_DB"

    run_step "Instalando BHTTP" install_bhttp || fail=1
    run_step "Instalando HCR" install_hcr || fail=1
    run_step "Abriendo puertos en el firewall" open_ports
    run_step "Creando panel hex_menu" write_menu

    echo
    start_service "$BHTTP_UNIT" "BHTTP" "$BHTTP_PORT" || { fail=1; failed_units+=("$BHTTP_UNIT"); }
    start_service "$HCR_UNIT" "HCR" "$HCR_PORT" || { fail=1; failed_units+=("$HCR_UNIT"); }

    summary "$fail"
    if [ "$fail" -eq 1 ]; then
        ui_warn "Los siguientes servicios no quedaron activos:"
        for u in "${failed_units[@]}"; do
            echo
            ui_err "$u"
            diagnose_hint "$u"
        done
        echo
        ui_info "El servicio se reinicia solo (Restart=always), puede que levante en unos segundos"
        ui_info "Revisa con: systemctl status <servicio>  o abre hex_menu → Diagnóstico"
    fi
    exit "$fail"
}

main "$@"
