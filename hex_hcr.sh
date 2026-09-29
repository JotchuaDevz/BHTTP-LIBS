#!/bin/bash

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[38;5;203m'
GREEN='\033[38;5;84m'
YELLOW='\033[38;5;221m'
CYAN='\033[38;5;51m'
WHITE='\033[38;5;255m'
NC='\033[0m'
BOLD='\033[1m'
ACC='\033[38;5;44m'
GRIS='\033[38;5;245m'

BHTTP_PORT=80
HCR_PORT=8080
BHTTP_VER="1.2.0"
HCR_VER="1.0.0"
CACHE_DIR="/tmp/hex-cache"
LOG_FILE="/var/log/hex-installation.log"
USER_DB="/etc/hex/users.txt"

mkdir -p "$CACHE_DIR" >/dev/null 2>&1
: > "$LOG_FILE" 2>/dev/null

ui_top() { echo -e "${ACC}╔════════════════════════════════════════════════════════════╗${NC}"; }
ui_sep() { echo -e "${ACC}╠════════════════════════════════════════════════════════════╣${NC}"; }
ui_bot() { echo -e "${ACC}╚════════════════════════════════════════════════════════════╝${NC}"; }
ui_fila() { echo -e "${ACC}║${NC} $1 ${ACC}║${NC}"; }
ui_titulo() { printf "${ACC}║${NC}                     ${WHITE}${BOLD}%s${NC}                     ${ACC}║${NC}\n" "$1"; }
ui_ok() { echo -e "     ${GREEN}✓${NC} ${WHITE}$1${NC}"; }
ui_error() { echo -e "     ${RED}✗${NC} ${RED}$1${NC}"; }
ui_info() { echo -e "     ${CYAN}ℹ${NC} ${GRIS}$1${NC}"; }

si_existe_binario() {
    if command -v "$1" >/dev/null 2>&1 || [ -f "$2" ] 2>/dev/null; then
        return 0
    fi
    return 1
}

descargar_archivo() {
    local url="$1" destino="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 300 --retry 2 -o "$destino" "$url" 2>/dev/null
    else
        wget -q --timeout=20 --tries=3 -O "$destino" "$url" 2>/dev/null
    fi
}

instalar_dependencias() {
    clear
    ui_top
    ui_titulo "INSTALANDO DEPENDENCIAS"
    ui_sep
    
    ui_info "Actualizando repositorios..."
    apt-get update -y >/dev/null 2>&1
    
    ui_info "Instalando paquetes necesarios..."
    apt-get install -y curl wget systemd iptables >/dev/null 2>&1
    
    ui_ok "Dependencias instaladas"
    ui_sep
    ui_fila ""
}

instalar_bhttp() {
    clear
    ui_top
    ui_titulo "INSTALANDO BHTTP"
    ui_sep
    
    case "$(uname -m)" in
        x86_64|amd64) BHTTP_ARCH="amd64" ;;
        aarch64|arm64) BHTTP_ARCH="arm64" ;;
        *) ui_error "Arquitectura no soportada"; exit 1 ;;
    esac
    
    mkdir -p /opt/bhttp >/dev/null 2>&1
    mkdir -p /etc/bhttp >/dev/null 2>&1
    mkdir -p /var/log/bhttp >/dev/null 2>&1
    
    ui_info "Descargando BHTTP..."
    
    BHTTP_BIN="/opt/bhttp/bhttp-server"
    BHTTP_FILENAME="bhttp-server-v2.4.1-btun-compat-keepalive-linux-${BHTTP_ARCH}"
    BHTTP_URL="https://raw.githubusercontent.com/JotchuaDevz/BHTTP-LIBS/refs/heads/main/${BHTTP_FILENAME}"
    
    if [ ! -f "$BHTTP_BIN" ]; then
        descargar_archivo "$BHTTP_URL" "$BHTTP_BIN" 2>>$LOG_FILE
        
        if [ -f "$BHTTP_BIN" ] && [ -s "$BHTTP_BIN" ]; then
            chmod +x "$BHTTP_BIN"
            ui_ok "BHTTP descargado"
        else
            ui_error "No se pudo descargar BHTTP"
            exit 1
        fi
    fi
    
    cat > /etc/systemd/system/bhttp-server.service <<EOF
[Unit]
Description=BHTTP Server
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
ExecStart=$BHTTP_BIN --listen :$BHTTP_PORT --target 127.0.0.1:22
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bhttp

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable bhttp-server.service >/dev/null 2>&1
    
    iptables -C INPUT -p tcp --dport $BHTTP_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $BHTTP_PORT -j ACCEPT >/dev/null 2>&1
    

    
    ui_ok "BHTTP configurado en puerto $BHTTP_PORT"
    ui_sep
    ui_fila ""
}

instalar_hcr() {
    clear
    ui_top
    ui_titulo "INSTALANDO HCR"
    ui_sep
    
    case "$(uname -m)" in
        x86_64|amd64) HCR_ARCH="amd64" ;;
        aarch64|arm64) HCR_ARCH="arm64" ;;
        *) ui_error "Arquitectura no soportada"; exit 1 ;;
    esac
    
    mkdir -p /opt/hcr >/dev/null 2>&1
    mkdir -p /etc/hcr >/dev/null 2>&1
    mkdir -p /var/log/hcr >/dev/null 2>&1
    
    ui_info "Descargando HCR..."
    
    HCR_BIN="/opt/hcr/hcr-server"
    HCR_FILENAME="hcr-server-linux-${HCR_ARCH}"
    HCR_URL="https://raw.githubusercontent.com/JotchuaDevz/BHTTP-LIBS/refs/heads/main/${HCR_FILENAME}"
    
    if [ ! -f "$HCR_BIN" ]; then
        descargar_archivo "$HCR_URL" "$HCR_BIN" 2>>$LOG_FILE
        
        if [ -f "$HCR_BIN" ] && [ -s "$HCR_BIN" ]; then
            chmod +x "$HCR_BIN"
            ui_ok "HCR descargado"
        else
            ui_error "No se pudo descargar HCR"
            exit 1
        fi
    fi
    
    cat > /etc/systemd/system/hcr-server.service <<EOF
[Unit]
Description=HCR Server
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
ExecStart=$HCR_BIN --listen :$HCR_PORT --target 127.0.0.1:22 --transport plain
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hcr

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hcr-server.service >/dev/null 2>&1
    
    iptables -C INPUT -p tcp --dport $HCR_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $HCR_PORT -j ACCEPT >/dev/null 2>&1
    

    
    ui_ok "HCR configurado en puerto $HCR_PORT"
    ui_sep
    ui_fila ""
}

crear_menu() {
    clear
    ui_top
    ui_titulo "CREANDO MENÚ"
    ui_sep
    
    mkdir -p /etc/hex >/dev/null 2>&1
    touch "$USER_DB"
    chmod 600 "$USER_DB"
    
    cat > /usr/local/bin/hex_menu <<'EOF_MENU'
#!/bin/bash

RED='\033[38;5;203m'
GREEN='\033[38;5;84m'
YELLOW='\033[38;5;221m'
BLUE='\033[38;5;39m'
CYAN='\033[38;5;51m'
WHITE='\033[38;5;255m'
NC='\033[0m'
BOLD='\033[1m'
ACC='\033[38;5;44m'
GRIS='\033[38;5;245m'

BHTTP_PORT=80
HCR_PORT=8080
BHTTP_UNIT="bhttp-server.service"
HCR_UNIT="hcr-server.service"
USER_DB="/etc/hex/users.txt"

pause_return() {
    echo ""
    echo -e "  ${CYAN}Presiona ENTER para continuar...${NC}"
    read -r
}

ui_top() { echo -e "${ACC}╔════════════════════════════════════════════════════════════╗${NC}"; }
ui_sep() { echo -e "${ACC}╠════════════════════════════════════════════════════════════╣${NC}"; }
ui_bot() { echo -e "${ACC}╚════════════════════════════════════════════════════════════╝${NC}"; }
ui_fila() { echo -e "${ACC}║${NC} $1 ${ACC}║${NC}"; }
ui_titulo() { printf "${ACC}║${NC}                     ${WHITE}${BOLD}%s${NC}                     ${ACC}║${NC}\n" "$1"; }
ui_opcion() { printf "     ${CYAN}[${NC}${YELLOW}$1${NC}${CYAN}]${NC}  $2\n"; }

menu_principal() {
    clear
    ui_top
    ui_titulo "HEX MANAGER"
    ui_sep
    
    bhttp_state=$(systemctl is-active $BHTTP_UNIT 2>/dev/null || echo "inactivo")
    hcr_state=$(systemctl is-active $HCR_UNIT 2>/dev/null || echo "inactivo")
    
    [ "$bhttp_state" = "active" ] && bhttp_status="${GREEN}● ACTIVO${NC}" || bhttp_status="${RED}● INACTIVO${NC}"
    [ "$hcr_state" = "active" ] && hcr_status="${GREEN}● ACTIVO${NC}" || hcr_status="${RED}● INACTIVO${NC}"
    
    ui_fila ""
    ui_fila "  ${CYAN}BHTTP${NC} - Puerto $BHTTP_PORT  $bhttp_status"
    ui_fila "  ${CYAN}HCR${NC}   - Puerto $HCR_PORT  $hcr_status"
    ui_fila ""
    ui_sep
    
    ui_opcion "1" "Gestionar BHTTP"
    ui_opcion "2" "Gestionar HCR"
    ui_opcion "3" "Agregar usuario"
    ui_opcion "4" "Eliminar usuario"
    ui_opcion "5" "Ver logs"
    ui_opcion "6" "Desinstalar"
    ui_opcion "0" "Salir"
    
    ui_bot
    echo ""
    echo -ne "  ${CYAN}►${NC} Selecciona opción: "
    read -r opcion
    
    case "$opcion" in
        1) menu_bhttp ;;
        2) menu_hcr ;;
        3) agregar_usuario ;;
        4) eliminar_usuario ;;
        5) ver_logs ;;
        6) desinstalar ;;
        0) exit 0 ;;
        *) echo -e "  ${RED}✗ Opción inválida${NC}"; pause_return; menu_principal ;;
    esac
}

menu_bhttp() {
    while true; do
        clear
        ui_top
        ui_titulo "GESTIÓN BHTTP"
        ui_sep
        
        bhttp_state=$(systemctl is-active $BHTTP_UNIT 2>/dev/null || echo "inactivo")
        [ "$bhttp_state" = "active" ] && bhttp_status="${GREEN}● ACTIVO${NC}" || bhttp_status="${RED}● INACTIVO${NC}"
        
        ui_fila "  Estado: $bhttp_status  │  Puerto: ${YELLOW}$BHTTP_PORT${NC}"
        ui_sep
        ui_fila ""
        
        ui_opcion "1" "Iniciar"
        ui_opcion "2" "Detener"
        ui_opcion "3" "Reiniciar"
        ui_opcion "4" "Ver estado"
        ui_opcion "0" "Atrás"
        
        ui_bot
        echo ""
        echo -ne "  ${CYAN}►${NC} Selecciona opción: "
        read -r opt
        
        case "$opt" in
            1) systemctl start $BHTTP_UNIT; echo -e "  ${GREEN}✓ BHTTP iniciado${NC}"; pause_return ;;
            2) systemctl stop $BHTTP_UNIT; echo -e "  ${GREEN}✓ BHTTP detenido${NC}"; pause_return ;;
            3) systemctl restart $BHTTP_UNIT; echo -e "  ${GREEN}✓ BHTTP reiniciado${NC}"; pause_return ;;
            4) echo ""; systemctl status $BHTTP_UNIT --no-pager; pause_return ;;
            0) break ;;
            *) echo -e "  ${RED}✗ Opción inválida${NC}"; pause_return ;;
        esac
    done
    menu_principal
}

menu_hcr() {
    while true; do
        clear
        ui_top
        ui_titulo "GESTIÓN HCR"
        ui_sep
        
        hcr_state=$(systemctl is-active $HCR_UNIT 2>/dev/null || echo "inactivo")
        [ "$hcr_state" = "active" ] && hcr_status="${GREEN}● ACTIVO${NC}" || hcr_status="${RED}● INACTIVO${NC}"
        
        ui_fila "  Estado: $hcr_status  │  Puerto: ${YELLOW}$HCR_PORT${NC}"
        ui_sep
        ui_fila ""
        
        ui_opcion "1" "Iniciar"
        ui_opcion "2" "Detener"
        ui_opcion "3" "Reiniciar"
        ui_opcion "4" "Ver estado"
        ui_opcion "0" "Atrás"
        
        ui_bot
        echo ""
        echo -ne "  ${CYAN}►${NC} Selecciona opción: "
        read -r opt
        
        case "$opt" in
            1) systemctl start $HCR_UNIT; echo -e "  ${GREEN}✓ HCR iniciado${NC}"; pause_return ;;
            2) systemctl stop $HCR_UNIT; echo -e "  ${GREEN}✓ HCR detenido${NC}"; pause_return ;;
            3) systemctl restart $HCR_UNIT; echo -e "  ${GREEN}✓ HCR reiniciado${NC}"; pause_return ;;
            4) echo ""; systemctl status $HCR_UNIT --no-pager; pause_return ;;
            0) break ;;
            *) echo -e "  ${RED}✗ Opción inválida${NC}"; pause_return ;;
        esac
    done
    menu_principal
}

agregar_usuario() {
    clear
    ui_top
    ui_titulo "AGREGAR USUARIO"
    ui_sep
    
    echo ""
    echo -ne "  ${WHITE}Usuario:${NC} "
    read -r new_user
    
    if grep -qw "^$new_user:" "$USER_DB" 2>/dev/null; then
        echo -e "  ${RED}✗ El usuario ya existe${NC}"
        pause_return
        menu_principal
        return
    fi
    
    echo -ne "  ${WHITE}Contraseña:${NC} "
    read -rs new_pass
    echo ""
    
    echo -ne "  ${WHITE}Validez (días):${NC} "
    read -r days
    
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo -e "  ${RED}✗ Número inválido${NC}"
        pause_return
        menu_principal
        return
    fi
    
    exp_date=$(date -d "+${days} days" +"%Y-%m-%d")
    echo "${new_user}:${new_pass}:${exp_date}" >> "$USER_DB"
    
    echo ""
    echo -e "  ${GREEN}✓ Usuario creado exitosamente${NC}"
    echo ""
    echo -e "  ${BOLD}IP:${NC}              $(hostname -I | awk '{print $1}')"
    echo -e "  ${BOLD}BHTTP Puerto:${NC}   ${YELLOW}$BHTTP_PORT${NC}"
    echo -e "  ${BOLD}HCR Puerto:${NC}     ${YELLOW}$HCR_PORT${NC}"
    echo -e "  ${BOLD}Usuario:${NC}        ${YELLOW}${new_user}${NC}"
    echo -e "  ${BOLD}Contraseña:${NC}     ${YELLOW}${new_pass}${NC}"
    echo -e "  ${BOLD}Fecha Expiración:${NC} ${YELLOW}${exp_date}${NC}"
    echo ""
    
    pause_return
    menu_principal
}

eliminar_usuario() {
    clear
    ui_top
    ui_titulo "ELIMINAR USUARIO"
    ui_sep
    
    if [ ! -s "$USER_DB" ]; then
        echo -e "  ${YELLOW}No hay usuarios registrados${NC}"
        pause_return
        menu_principal
        return
    fi
    
    echo ""
    echo -e "  ${CYAN}Usuarios activos:${NC}"
    echo ""
    cat -n "$USER_DB" | awk -F: '{printf "    ${YELLOW}[%s]${NC} %s (Exp: %s)\n", NR, $1, $3}' | sed "s/\${YELLOW}/\x1b[38;5;221m/g; s/\${NC}/\x1b[0m/g"
    echo ""
    
    echo -ne "  ${WHITE}Usuario a eliminar:${NC} "
    read -r del_user
    
    if ! grep -qw "^$del_user:" "$USER_DB" 2>/dev/null; then
        echo -e "  ${RED}✗ El usuario no existe${NC}"
        pause_return
        menu_principal
        return
    fi
    
    sed -i "/^$del_user:/d" "$USER_DB"
    echo -e "  ${GREEN}✓ Usuario eliminado${NC}"
    
    pause_return
    menu_principal
}

ver_logs() {
    clear
    ui_top
    ui_titulo "VER LOGS"
    ui_sep
    ui_fila ""
    
    ui_opcion "1" "BHTTP (últimas 50 líneas)"
    ui_opcion "2" "HCR (últimas 50 líneas)"
    ui_opcion "3" "BHTTP (todas)"
    ui_opcion "4" "HCR (todas)"
    ui_opcion "0" "Atrás"
    
    ui_bot
    echo ""
    echo -ne "  ${CYAN}►${NC} Selecciona opción: "
    read -r opt
    
    case "$opt" in
        1) echo ""; journalctl -u $BHTTP_UNIT -n 50 --no-pager; pause_return ;;
        2) echo ""; journalctl -u $HCR_UNIT -n 50 --no-pager; pause_return ;;
        3) journalctl -u $BHTTP_UNIT --no-pager | less ;;
        4) journalctl -u $HCR_UNIT --no-pager | less ;;
        0) ;;
        *) echo -e "  ${RED}✗ Opción inválida${NC}"; pause_return ;;
    esac
    
    menu_principal
}

desinstalar() {
    clear
    ui_top
    ui_titulo "DESINSTALAR"
    ui_sep
    ui_fila ""
    ui_fila "  ${YELLOW}⚠${NC}  Estás a punto de desinstalar"
    ui_fila ""
    ui_sep
    
    echo ""
    echo -ne "  ${RED}✗ Escriba${NC} ${YELLOW}${BOLD}CONFIRMAR${NC} ${RED}para continuar:${NC} "
    read -r confirm
    
    if [ "$confirm" = "CONFIRMAR" ]; then
        echo -e "  ${CYAN}Deteniendo servicios...${NC}"
        systemctl stop $BHTTP_UNIT 2>/dev/null || true
        systemctl stop $HCR_UNIT 2>/dev/null || true
        
        echo -e "  ${CYAN}Deshabilitando servicios...${NC}"
        systemctl disable $BHTTP_UNIT 2>/dev/null || true
        systemctl disable $HCR_UNIT 2>/dev/null || true
        
        echo -e "  ${CYAN}Eliminando archivos...${NC}"
        rm -f /etc/systemd/system/bhttp-server.service
        rm -f /etc/systemd/system/hcr-server.service
        rm -rf /opt/bhttp
        rm -rf /opt/hcr
        rm -rf /etc/bhttp
        rm -rf /etc/hcr
        rm -rf /etc/hex
        rm -f /usr/local/bin/hex_menu
        rm -f /usr/bin/hex_menu
        
        systemctl daemon-reload >/dev/null 2>&1
        
        echo ""
        echo -e "  ${GREEN}✓ Desinstalado completamente${NC}"
        echo ""
        exit 0
    else
        echo -e "  ${YELLOW}⚠ Cancelado${NC}"
        pause_return
        menu_principal
    fi
}

if [ "$EUID" -ne 0 ]; then
    echo -e "  ${RED}✗ Requiere permisos de root${NC}"
    exit 1
fi

menu_principal
EOF_MENU

    chmod +x /usr/local/bin/hex_menu
    cp /usr/local/bin/hex_menu /usr/bin/hex_menu 2>/dev/null
    
    ui_ok "Menú creado con gestor de usuarios"
    ui_sep
    ui_fila ""
}

iniciar_servicios() {
    clear
    ui_top
    ui_titulo "INICIANDO SERVICIOS"
    ui_sep
    
    ui_info "Iniciando BHTTP..."
    systemctl start bhttp-server.service >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet bhttp-server.service; then
        ui_ok "BHTTP activo"
    else
        ui_error "BHTTP no inició"
    fi
    
    ui_info "Iniciando HCR..."
    systemctl start hcr-server.service >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet hcr-server.service; then
        ui_ok "HCR activo"
    else
        ui_error "HCR no inició"
    fi
    
    ui_sep
    ui_fila ""
}

resumen_final() {
    clear
    ui_top
    ui_titulo "INSTALACIÓN COMPLETADA"
    ui_sep
    
    bhttp_state=$(systemctl is-active bhttp-server.service 2>/dev/null || echo "inactivo")
    hcr_state=$(systemctl is-active hcr-server.service 2>/dev/null || echo "inactivo")
    
    [ "$bhttp_state" = "active" ] && bhttp_status="${GREEN}● ACTIVO${NC}" || bhttp_status="${RED}● INACTIVO${NC}"
    [ "$hcr_state" = "active" ] && hcr_status="${GREEN}● ACTIVO${NC}" || hcr_status="${RED}● INACTIVO${NC}"
    
    ui_fila ""
    ui_fila "  ${CYAN}BHTTP${NC} - Puerto $BHTTP_PORT  $bhttp_status"
    ui_fila "  ${CYAN}HCR${NC}   - Puerto $HCR_PORT  $hcr_status"
    ui_fila ""
    ui_sep
    ui_fila "  ${GRIS}Comando:${NC}  ${YELLOW}${BOLD}hex_menu${NC}  o  ${YELLOW}${BOLD}sudo hex_menu${NC}"
    ui_fila "  ${GRIS}Logs:${NC}     ${YELLOW}/var/log/hex-installation.log${NC}"
    ui_fila ""
    ui_bot
    echo ""
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Este script requiere permisos de root${NC}"
    exit 1
fi

clear
instalar_dependencias
instalar_bhttp
instalar_hcr
crear_menu
iniciar_servicios
resumen_final
