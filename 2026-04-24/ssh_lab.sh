#!/bin/bash
# ssh_lab.sh - Ejecutar desde cada máquina Kali del alumno
# Descripción: Gestor de túneles SSH hacia servidor Ubuntu compartido

set -e

# ==================== CONFIGURACIÓN POR ALUMNO ====================
# 👉 CADA ALUMNO DEBE EDITAR ESTAS 2 LÍNEAS 👇
STUDENT_ID="01"                    # 01, 02, 03... hasta 10
UBUNTU_SERVER_IP="192.168.99.50"   # ← IP de tu máquina Ubuntu servidora

# Configuración derivada (no tocar normalmente)
VM_USER="student${STUDENT_ID}"
VM_PASSWORD="lab2025"
VM_PORT=22

SSH_KEY_PRIV="$HOME/.ssh/id_rsa_lab"
SSH_KEY_PUB="${SSH_KEY_PRIV}.pub"

# Puertos LOCALES (en la máquina Kali del alumno) - NO CONFLICTIVOS
TUNNEL_PORT_LOCAL=9090
TUNNEL_PORT_DYNAMIC=9092

# Puertos REMOTOS (en el servidor Ubuntu) - ÚNICOS POR ALUMNO para -R
# Fórmula: 9090 + ID del alumno → student01=9091, student02=9092, etc.
REMOTE_PORT_BASE=9090
TUNNEL_PORT_REMOTE=$((REMOTE_PORT_BASE + 10#${STUDENT_ID}))

# Servicio local del alumno (para túnel -R)
LOCAL_SERVICE_PORT=3000
WEB_PORT_VM=8080  # Servicio web en la VM (compartido, solo lectura)

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o LogLevel=ERROR"

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== LOGGING ====================
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "\n${BLUE}╔════════════════════════════╗${NC}"; \
              echo -e "${BLUE}║  $1  ║${NC}"; \
              echo -e "${BLUE}╚════════════════════════════╝${NC}\n"; }

# ==================== FUNCIONES ====================

setup_auth() {
    log_info "Configurando autenticación para $VM_USER@$UBUNTU_SERVER_IP..."
    
    [[ ! -f "$SSH_KEY_PRIV" ]] && ssh-keygen -t ed25519 -f "$SSH_KEY_PRIV" -N "" -C "student_${STUDENT_ID}" >/dev/null 2>&1
    
    # Intentar ssh-copy-id, fallback con password
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
    
    # Verificar conexión
    if ssh -i "$SSH_KEY_PRIV" -p "$VM_PORT" $SSH_OPTS "$VM_USER@$UBUNTU_SERVER_IP" echo "OK" &>/dev/null; then
        log_info "✓ Conexión SSH funcional."
    else
        log_error "✗ Fallo de autenticación."
        exit 1
    fi
}

start_web_in_vm() {
    # Inicia servicio web en la VM SOLO si no está ya corriendo (para no duplicar)
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
    echo "   ⚠️  Puerto único asignado: $TUNNEL_PORT_REMOTE (evita conflictos)"
    
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
  local     : Solo túnel -L (acceder a servicio web de la VM)
  dynamic   : Solo proxy -D (navegar/red desde la VM)
  remote    : Solo túnel -R (exponer tu servicio local a la VM)
  all       : Los 3 túneles simultáneos (recomendado)
  status    : Ver túneles activos
  help      : Esta ayuda

Ejemplo:
  $0 all     # Establece los 3 túneles
  $0 status  # Verifica qué túneles están activos

Configuración actual:
  Alumno: $STUDENT_ID
  Usuario VM: $VM_USER
  Servidor: $UBUNTU_SERVER_IP
  Puertos locales: $TUNNEL_PORT_LOCAL (-L), $TUNNEL_PORT_DYNAMIC (-D)
  Puerto remoto (-R): $TUNNEL_PORT_REMOTE → localhost:$LOCAL_SERVICE_PORT

EOF
}

# ==================== MAIN ====================
main() {
    log_title "LAB SSH TUNNELS - Alumno #$STUDENT_ID"
    
    MODE="${1:-all}"
    
    case $MODE in
        help|--help|-h) show_help; exit 0 ;;
        status) 
            echo "🔍 Túneles activos en tu Kali:"
            ss -tlnp | grep -E "909[0-2]|3000" || echo "  (ninguno)"
            exit 0 ;;
    esac
    
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