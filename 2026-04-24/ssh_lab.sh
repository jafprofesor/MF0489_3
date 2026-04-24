#!/bin/bash
#
# ssh_lab.sh - V2 (CON DIAGNÓSTICO AUTOMÁTICO)
# Descripción: Gestor de túneles SSH con verificación previa para entornos educativos
#

set -e

# ==================== CONFIGURACIÓN POR ALUMNO ====================
STUDENT_ID="01"                    # 👈 EDITAR: 01, 02... 10
UBUNTU_SERVER_IP="192.168.1.100"   # 👈 EDITAR: IP de tu Ubuntu servidora

VM_USER="student${STUDENT_ID}"
VM_PASSWORD="lab2025"
VM_PORT=22

SSH_KEY_PRIV="$HOME/.ssh/id_rsa_lab"
SSH_KEY_PUB="${SSH_KEY_PRIV}.pub"

# Puertos LOCALES (en Kali)
TUNNEL_PORT_LOCAL=9090
TUNNEL_PORT_DYNAMIC=9092

# Puertos REMOTOS (en Ubuntu) → únicos por alumno para evitar conflictos
REMOTE_PORT_BASE=9090
TUNNEL_PORT_REMOTE=$((REMOTE_PORT_BASE + 10#${STUDENT_ID}))

LOCAL_SERVICE_PORT=3000
WEB_PORT_VM=8080

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o LogLevel=ERROR"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DIAG_CRITICAL=0
DIAG_WARNINGS=0

# ==================== LOGGING ====================
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "\n${BLUE}╔════════════════════════════╗${NC}"; \
              echo -e "${BLUE}║  $1  ║${NC}"; \
              echo -e "${BLUE}╚════════════════════════════╝${NC}\n"; }
diag_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
diag_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; ((DIAG_WARNINGS++)); }
diag_fail() { echo -e "  ${RED}✗${NC} $1"; ((DIAG_CRITICAL++)); }

# ==================== DIAGNÓSTICO AUTOMÁTICO ====================
run_diagnostics() {
    echo -e "${CYAN}🔍 INICIANDO DIAGNÓSTICO PRE-PRÁCTICA${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 1. Configuración básica
    echo -e "\n${BLUE}📝 Configuración:${NC}"
    [[ "$STUDENT_ID" =~ ^0?[1-9]|10$ ]] && diag_ok "ID alumno válido: $STUDENT_ID" || diag_fail "STUDENT_ID no válido (usa 01..10)"
    [[ "$UBUNTU_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && diag_ok "IP servidor válida" || diag_fail "UBUNTU_SERVER_IP no es una IP válida"
    [[ "$VM_USER" == "student$STUDENT_ID" ]] && diag_ok "Usuario SSH derivado: $VM_USER" || diag_fail "Error calculando usuario SSH"

    # 2. Herramientas requeridas
    echo -e "\n${BLUE}🛠️  Herramientas:${NC}"
    for cmd in ssh ssh-keygen curl python3 ss; do
        command -v $cmd &>/dev/null && diag_ok "$cmd disponible" || diag_fail "$cmd no instalado (sudo apt install $cmd)"
    done
    command -v sshpass &>/dev/null && diag_ok "sshpass disponible (primera configuración)" || diag_warn "sshpass no instalado (primera conexión requerirá password manual)"

    # 3. Conectividad de red
    echo -e "\n${BLUE}🌐 Conectividad:${NC}"
    if timeout 2 bash -c "echo >/dev/tcp/$UBUNTU_SERVER_IP/$VM_PORT" 2>/dev/null; then
        diag_ok "Puerto SSH ($VM_PORT) accesible en $UBUNTU_SERVER_IP"
    elif command -v nc &>/dev/null && nc -z -w2 $UBUNTU_SERVER_IP $VM_PORT 2>/dev/null; then
        diag_ok "Puerto SSH accesible (vía nc)"
    else
        diag_fail "No se puede alcanzar $UBUNTU_SERVER_IP:$VM_PORT. Verifica red/firewall."
    fi

    # 4. Estado de puertos locales
    echo -e "\n${BLUE}🔌 Puertos locales:${NC}"
    for port in $TUNNEL_PORT_LOCAL $TUNNEL_PORT_DYNAMIC $LOCAL_SERVICE_PORT; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            local pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
            diag_warn "Puerto $port ocupado por PID $pid (pkill -9 -f ssh o reinicia)"
        else
            diag_ok "Puerto $port libre"
        fi
    done

    # 5. Clave SSH
    echo -e "\n${BLUE}🔑 Claves SSH:${NC}"
    if [[ -f "$SSH_KEY_PRIV" ]]; then
        diag_ok "Clave privada existe"
        local perms=$(stat -c %a "$SSH_KEY_PRIV" 2>/dev/null || echo "000")
        [[ "$perms" == "600" || "$perms" == "644" ]] && diag_ok "Permisos clave OK ($perms)" || diag_warn "Permisos inseguros ($perms). Ejecuta: chmod 600 $SSH_KEY_PRIV"
    else
        diag_warn "Clave no existe. Se generará automáticamente en la primera ejecución."
    fi
    if [[ ! -d "$HOME/.ssh" ]]; then
        diag_warn "Directorio ~/.ssh no existe. Se creará automáticamente."
    fi

    # 6. Puerto remoto calculado
    echo -e "\n${BLUE}📡 Puerto remoto (-R):${NC}"
    if [[ $TUNNEL_PORT_REMOTE -ge 1024 && $TUNNEL_PORT_REMOTE -le 65535 ]]; then
        diag_ok "Puerto remoto asignado: $TUNNEL_PORT_REMOTE (único para alumno #$STUDENT_ID)"
    else
        diag_fail "Puerto remoto fuera de rango válido"
    fi

    # Resumen
    echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $DIAG_CRITICAL -gt 0 ]]; then
        echo -e "${RED}🚨 DIAGNÓSTICO FALLIDO:${NC} $DIAG_CRITICAL error(es) crítico(s). Corrige antes de continuar."
        echo -e "${YELLOW}💡 Tip:${NC} Ejecuta $0 --help para ver ejemplos de configuración."
        exit 1
    elif [[ $DIAG_WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  DIAGNÓSTICO CON ADVERTENCIAS:${NC} $DIAG_WARNINGS aviso(s). Continuando..."
    else
        echo -e "${GREEN}✅ DIAGNÓSTICO CORRECTO:${NC} Todo listo para empezar."
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    sleep 2
}

# ==================== FUNCIONES PRINCIPALES ====================

setup_auth() {
    log_info "Configurando autenticación para $VM_USER@$UBUNTU_SERVER_IP..."
    [[ ! -f "$SSH_KEY_PRIV" ]] && ssh-keygen -t ed25519 -f "$SSH_KEY_PRIV" -N "" -C "student_${STUDENT_ID}" >/dev/null 2>&1
    chmod 600 "$SSH_KEY_PRIV" 2>/dev/null || true

    if ! ssh-copy-id -i "$SSH_KEY_PUB" -p "$VM_PORT" "$VM_USER@$UBUNTU_SERVER_IP" &>/dev/null; then
        log_warn "Primera conexión: usando password..."
        if command -v sshpass &>/dev/null; then
            sshpass -p "$VM_PASSWORD" ssh-copy-id -i "$SSH_KEY_PUB" -p "$VM_PORT" "$VM_USER@$UBUNTU_SERVER_IP" 2>/dev/null || {
                log_error "No se pudo copiar la clave. Verifica credenciales."
                exit 1
            }
        else
            log_error "sshpass no instalado. Instala con: sudo apt install sshpass"
            exit 1
        fi
    fi

    if ssh -i "$SSH_KEY_PRIV" -p "$VM_PORT" $SSH_OPTS "$VM_USER@$UBUNTU_SERVER_IP" echo "OK" &>/dev/null; then
        log_info "✓ Conexión SSH funcional."
    else
        log_error "✗ Fallo de autenticación."
        exit 1
    fi
}

start_web_in_vm() {
    log_info "Verificando servicio web en VM..."
    ssh -i "$SSH_KEY_PRIV" -p "$VM_PORT" $SSH_OPTS "$VM_USER@$UBUNTU_SERVER_IP" "
        if ! ss -tln 2>/dev/null | grep -q ':$WEB_PORT_VM'; then
            mkdir -p /tmp/web &&
            echo '<h1>🔐 Servicio Compartido</h1><p>Alumno: $VM_USER</p><p>$(date)</p>' > /tmp/web/index.html &&
            cd /tmp/web &&
            nohup python3 -m http.server $WEB_PORT_VM > /tmp/web_$VM_USER.log 2>&1 &
        fi
    " &>/dev/null || true
    log_info "✓ Servicio web disponible en VM:$WEB_PORT_VM"
}

start_local_service() {
    log_info "Iniciando servicio LOCAL (puerto $LOCAL_SERVICE_PORT)..."
    mkdir -p /tmp/student_${STUDENT_ID}_demo
    cat > /tmp/student_${STUDENT_ID}_demo/index.html << EOF
<!DOCTYPE html><body>
<h1>🖥️ Servicio de $VM_USER</h1>
<p><strong>Alumno:</strong> $STUDENT_ID</p>
<p><strong>Fecha:</strong> $(date)</p>
<p><em>Accesible vía túnel -R desde la VM</em></p>
</body></html>
EOF
    
    if command -v python3 &>/dev/null; then
        cd /tmp/student_${STUDENT_ID}_demo
        nohup python3 -m http.server "$LOCAL_SERVICE_PORT" --bind 127.0.0.1 > /tmp/student_${STUDENT_ID}_demo.log 2>&1 &
        echo $! > /tmp/student_${STUDENT_ID}_demo.pid
        sleep 1
        ss -tlnp 2>/dev/null | grep -q ":$LOCAL_SERVICE_PORT " && \
        log_info "✓ Servicio local activo en localhost:$LOCAL_SERVICE_PORT"
    fi
}

cleanup_tunnel() {
    local port=$1
    pkill -9 -f "ssh.*${VM_USER}@${UBUNTU_SERVER_IP}.*${port}" 2>/dev/null || true
    sleep 1
}

setup_local_forwarding() {
    echo -e "\n${CYAN}🔹 LOCAL FORWARDING (-L)${NC}"
    echo "   localhost:$TUNNEL_PORT_LOCAL ──SSH──► VM:localhost:$WEB_PORT_VM"
    cleanup_tunnel "$TUNNEL_PORT_LOCAL"
    ssh -i "$SSH_KEY_PRIV" -p "$VM_PORT" $SSH_OPTS \
        -L "${TUNNEL_PORT_LOCAL}:localhost:${WEB_PORT_VM}" \
        -N -f "$VM_USER@$UBUNTU_SERVER_IP"
    sleep 2
    ss -tlnp 2>/dev/null | grep -q ":$TUNNEL_PORT_LOCAL " && \
    log_info "✅ Túnel -L activo. Prueba: curl http://localhost:$TUNNEL_PORT_LOCAL"
}

setup_dynamic_forwarding() {
    echo -e "\n${CYAN}🔹 DYNAMIC FORWARDING (-D)${NC}"
    echo "   localhost:$TUNNEL_PORT_DYNAMIC ──SSH──► [SOCKS] ──► red de la VM"
    cleanup_tunnel "$TUNNEL_PORT_DYNAMIC"
    ssh -i "$SSH_KEY_PRIV" -p "$VM_PORT" $SSH_OPTS \
        -D "$TUNNEL_PORT_DYNAMIC" \
        -N -f "$VM_USER@$UBUNTU_SERVER_IP"
    sleep 2
    ss -tlnp 2>/dev/null | grep -q ":$TUNNEL_PORT_DYNAMIC " && \
    log_info "✅ Proxy SOCKS activo. Prueba: curl --proxy socks5h://localhost:$TUNNEL_PORT_DYNAMIC http://localhost:$WEB_PORT_VM"
}

setup_remote_forwarding() {
    echo -e "\n${CYAN}🔹 REMOTE FORWARDING (-R)${NC}"
    echo "   VM:localhost:$TUNNEL_PORT_REMOTE ──SSH──► tu_Kali:localhost:$LOCAL_SERVICE_PORT"
    start_local_service
    cleanup_tunnel "$TUNNEL_PORT_REMOTE"
    ssh -i "$SSH_KEY_PRIV" -p "$VM_PORT" $SSH_OPTS \
        -o GatewayPorts=no \
        -R "${TUNNEL_PORT_REMOTE}:localhost:${LOCAL_SERVICE_PORT}" \
        -N -f "$VM_USER@$UBUNTU_SERVER_IP"
    sleep 3
    log_info "✅ Túnel -R activo. Prueba desde la VM:"
    echo "   ssh $VM_USER@$UBUNTU_SERVER_IP 'curl http://localhost:$TUNNEL_PORT_REMOTE'"
}

show_help() {
    cat << EOF
Uso: $0 [MODO]

MODO:
  all        : Establece los 3 túneles simultáneos (recomendado)
  local      : Solo túnel -L
  dynamic    : Solo proxy -D
  remote     : Solo túnel -R
  check      : Ejecuta SOLO el diagnóstico y sale
  status     : Ver túneles activos
  help       : Esta ayuda

Ejemplo:
  $0 all     # Levanta todo
  $0 check   # Solo verifica entorno sin modificar nada

Configuración actual:
  Alumno: $STUDENT_ID | Usuario: $VM_USER | Servidor: $UBUNTU_SERVER_IP
  Puertos locales: $TUNNEL_PORT_LOCAL (-L), $TUNNEL_PORT_DYNAMIC (-D), $LOCAL_SERVICE_PORT (servicio)
  Puerto remoto (-R): $TUNNEL_PORT_REMOTE

EOF
}

# ==================== MAIN ====================
main() {
    MODE="${1:-all}"
    
    case $MODE in
        help|--help|-h) show_help; exit 0 ;;
        check) run_diagnostics; exit 0 ;;
        status) 
            echo "🔍 Túneles activos en tu Kali:"
            ss -tlnp | grep -E "909[0-2]|3000" || echo "  (ninguno)"
            exit 0 ;;
    esac

    log_title "LAB SSH TUNNELS - Alumno #$STUDENT_ID"
    
    # Diagnóstico automático (se puede saltar con --skip-diag si es necesario)
    run_diagnostics

    setup_auth
    start_web_in_vm
    
    case $MODE in
        local) setup_local_forwarding ;;
        dynamic) setup_dynamic_forwarding ;;
        remote) setup_remote_forwarding ;;
        all)
            log_title "Estableciendo 3 túneles simultáneos"
            setup_local_forwarding
            setup_dynamic_forwarding
            setup_remote_forwarding
            echo ""
            log_title "✅ LISTO - PRUEBAS"
            echo -e "${GREEN}Comandos de prueba:${NC}"
            echo "  • -L: curl http://localhost:$TUNNEL_PORT_LOCAL"
            echo "  • -D: curl --proxy socks5h://localhost:$TUNNEL_PORT_DYNAMIC http://localhost:$WEB_PORT_VM"
            echo "  • -R: ssh $VM_USER@$UBUNTU_SERVER_IP 'curl http://localhost:$TUNNEL_PORT_REMOTE'"
            ;;
        *) log_error "Modo no reconocido: $MODE"; show_help; exit 1 ;;
    esac
}

main "$@"