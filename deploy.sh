#!/usr/bin/env bash
# =============================================================================
# Mixtile 2-in-1 Zigbee & Z-Wave mPCIe Module — Automated Deployment Script
#
# Deploys Home Assistant Container + zwave-js-ui on Ubuntu/Armbian hosts.
# Assumes the Mixtile 2-in-1 module (CH343 USB Dual Serial, 1a86:55d2) is
# physically installed.
#
# Usage: sudo ./deploy.sh
#   Fully interactive — no command-line options needed.
#   Docker installed? Skipped. HA already onboarded? Skipped.
#   Config exists? Backed up. Everything is idempotent.
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- constants ----
MIXTILE_VID="1a86"
MIXTILE_PID="55d2"
# Use the real user's home even when run with sudo
_REAL_HOME="$(getent passwd "${SUDO_USER:-$USER}" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
DEFAULT_INSTALL_DIR="$_REAL_HOME/homeassistant"
DEFAULT_TIMEZONE="Asia/Shanghai"
DEFAULT_HA_USER="admin"
ZWAVE_UI_PORT="8091"
ZWAVE_WS_PORT="3000"
HA_PORT="8123"
MAX_WAIT_SECONDS=600
POLL_INTERVAL=5

# ---- flags ----
NEED_RELOGIN=false

# ---- color helpers ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }
detail()  { echo -e "        $*"; }

die() {
    error "$*"
    exit 1
}

# ---- helpers ----

check_command() {
    command -v "$1" &>/dev/null
}

# Wait for a URL to return HTTP 2xx/3xx, with timeout.
wait_for_http() {
    local url="$1"
    local desc="$2"
    local max_sec="${3:-$MAX_WAIT_SECONDS}"
    local elapsed=0

    info "等待 $desc 就绪 ($url)..."
    while [ "$elapsed" -lt "$max_sec" ]; do
        if curl -sSf -o /dev/null -w "%{http_code}" --connect-timeout 3 "$url" 2>/dev/null | grep -qE '^(2|3)[0-9][0-9]$'; then
            success "$desc 已就绪 (${elapsed}s)"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    error "$desc 在 ${max_sec}s 内未就绪"
    return 1
}

# Wait for a TCP port to be open.
wait_for_port() {
    local host="$1"
    local port="$2"
    local desc="$3"
    local max_sec="${4:-$MAX_WAIT_SECONDS}"
    local elapsed=0

    info "等待 $desc ($host:$port)..."
    while [ "$elapsed" -lt "$max_sec" ]; do
        if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            success "$desc 端口已开放 (${elapsed}s)"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    error "$desc 端口在 ${max_sec}s 内未开放"
    return 1
}

# Check if a string exists in docker container logs.
check_container_log() {
    local container="$1"
    local pattern="$2"
    docker_cmd logs --tail=500 "$container" 2>&1 | grep -q "$pattern"
}

# Confirm with user.
confirm() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer
    read -r -p "$prompt " answer </dev/tty
    answer="${answer:-$default}"
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# Generate random password.
gen_password() {
    if check_command openssl; then
        openssl rand -hex 8
    else
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16
    fi
}

# Run a command with docker group if needed. After usermod, the current
# shell may not have the docker group yet; use sudo as fallback.
docker_cmd() {
    if docker ps &>/dev/null 2>&1; then
        docker "$@"
    else
        sudo docker "$@"
    fi
}

docker_compose() {
    if docker ps &>/dev/null 2>&1; then
        docker compose "$@"
    else
        sudo docker compose "$@"
    fi
}

# ---- banner ----

show_banner() {
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  Mixtile 2-in-1 Zigbee & Z-Wave 自动部署脚本            ║"
    echo "║  Home Assistant Container + zwave-js-ui                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_help() {
    echo "用法: sudo ./$SCRIPT_NAME"
    echo ""
    echo "全自动部署 Mixtile 2-in-1 Zigbee & Z-Wave 模块。"
    echo "所有配置通过交互式提示输入，均有默认值可直接回车确认。"
    echo "重复运行安全——已完成的步骤会自动跳过。"
}

# ============================================================================
# Phase 1: Environment Detection
# ============================================================================

phase1_detect() {
    step "Phase 1: 环境检测"

    # -- sudo check --
    info "检查 sudo 权限..."
    if ! sudo -n true 2>/dev/null; then
        echo -n "        "
        sudo true || die "需要 sudo 权限，请确认当前用户在 sudoers 中"
    fi
    success "sudo 权限 OK"

    # -- OS / arch --
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="${NAME:-Unknown}"
        OS_VERSION="${VERSION_ID:-Unknown}"
    else
        OS_NAME="Unknown"
        OS_VERSION="Unknown"
    fi
    ARCH="$(uname -m)"
    info "操作系统: $OS_NAME $OS_VERSION ($ARCH)"
    success "OS 检测完成"

    # -- Docker --
    DOCKER_INSTALLED=false
    if check_command docker; then
        DOCKER_VERSION="$(docker --version 2>/dev/null || echo 'unknown')"
        info "Docker: $DOCKER_VERSION"
        DOCKER_INSTALLED=true
    else
        warn "Docker 未安装"
    fi

    if check_command docker && docker compose version &>/dev/null 2>&1; then
        COMPOSE_VERSION="$(docker compose version 2>/dev/null || echo 'unknown')"
        info "Docker Compose: $COMPOSE_VERSION"
    elif check_command docker-compose; then
        COMPOSE_VERSION="$(docker-compose --version 2>/dev/null || echo 'unknown')"
        info "Docker Compose (v1): $COMPOSE_VERSION"
    else
        warn "Docker Compose 未安装"
    fi

    # -- Mixtile module --
    MIXTILE_FOUND=false
    if check_command lsusb; then
        if lsusb 2>/dev/null | grep -qi "${MIXTILE_VID}:${MIXTILE_PID}"; then
            MIXTILE_FOUND=true
            success "Mixtile 模块: 已找到 (${MIXTILE_VID}:${MIXTILE_PID})"
        else
            warn "Mixtile 模块: 未检测到 (${MIXTILE_VID}:${MIXTILE_PID})"
        fi
    else
        warn "lsusb 不可用，跳过 Mixtile 模块检测"
    fi

    # -- Serial ports --
    ZWAVE_PORT=""
    ZIGBEE_PORT=""
    if [ -d /dev/serial/by-id ]; then
        ZWAVE_PORT=$(find /dev/serial/by-id/ -name "*USB_Dual_Serial*if00" 2>/dev/null | head -1 || true)
        ZIGBEE_PORT=$(find /dev/serial/by-id/ -name "*USB_Dual_Serial*if02" 2>/dev/null | head -1 || true)
    fi

    if [ -n "$ZWAVE_PORT" ]; then
        success "Z-Wave 串口:  $ZWAVE_PORT"
    else
        warn "Z-Wave 串口:  未自动检测到（if00）"
    fi

    if [ -n "$ZIGBEE_PORT" ]; then
        success "Zigbee 串口:  $ZIGBEE_PORT"
    else
        warn "Zigbee 串口:  未自动检测到（if02）"
    fi

    # Fallback: try /dev/ttyACM* or /dev/ttyUSB*
    if [ -z "$ZWAVE_PORT" ] || [ -z "$ZIGBEE_PORT" ]; then
        warn "尝试在 /dev/ttyACM* / /dev/ttyUSB* 中查找..."
        local devs
        devs=$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true)
        if [ -n "$devs" ]; then
            detail "可用设备: $devs"
        else
            detail "无 /dev/ttyACM* 或 /dev/ttyUSB* 设备"
        fi
    fi

    # -- ModemManager --
    MODEMMANAGER_PRESENT=false
    if dpkg -s modemmanager &>/dev/null 2>&1; then
        MODEMMANAGER_PRESENT=true
        warn "ModemManager: 已安装（将通过 udev 规则使其跳过 Mixtile 设备）"
    else
        success "ModemManager: 未安装"
    fi

    # -- Hardware check: fail early if module not found --
    if [ "$MIXTILE_FOUND" = false ]; then
        echo ""
        error "未检测到 Mixtile 模块 (${MIXTILE_VID}:${MIXTILE_PID})"
        error "请确认模块已正确插入 mPCIe 插槽"
        if ! confirm "是否忽略并继续？[y/N]:" "N"; then
            exit 1
        fi
    fi

    if [ -z "$ZWAVE_PORT" ] || [ -z "$ZIGBEE_PORT" ]; then
        echo ""
        error "未完整检测到 Mixtile 双串口设备"
        error "请确认 udev 规则是否正确，或 USB 线缆是否已连接"
        if ! confirm "是否忽略并继续？[y/N]:" "N"; then
            exit 1
        fi
    fi
}

# ============================================================================
# Phase 2: Interactive Configuration
# ============================================================================

phase2_config() {
    step "Phase 2: 交互式配置"

    echo ""
    echo -e "${BOLD}=== Mixtile 2-in-1 部署配置 ===${NC}"
    echo ""

    # Show detected info
    echo -e "  ${CYAN}[检测]${NC} 操作系统: ${BOLD}$OS_NAME $OS_VERSION${NC} ($ARCH)"
    if [ "$MIXTILE_FOUND" = true ]; then
        echo -e "  ${GREEN}[检测]${NC} Mixtile 模块: 已找到 (${MIXTILE_VID}:${MIXTILE_PID})"
    else
        echo -e "  ${YELLOW}[检测]${NC} Mixtile 模块: 未检测到"
    fi
    [ -n "$ZWAVE_PORT" ]  && echo -e "  ${GREEN}[检测]${NC} Z-Wave 串口:  $ZWAVE_PORT"
    [ -n "$ZIGBEE_PORT" ] && echo -e "  ${GREEN}[检测]${NC} Zigbee 串口:  $ZIGBEE_PORT"

    echo ""

    # -- Install directory --
    read -r -p "安装目录 [$DEFAULT_INSTALL_DIR]: " INSTALL_DIR </dev/tty
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    # Expand ~
    INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

    # -- Timezone --
    read -r -p "时区 [$DEFAULT_TIMEZONE]: " TZ_INPUT </dev/tty
    TZ="${TZ_INPUT:-$DEFAULT_TIMEZONE}"

    # -- HA username --
    read -r -p "HA 管理员用户名 [$DEFAULT_HA_USER]: " HA_USER </dev/tty
    HA_USER="${HA_USER:-$DEFAULT_HA_USER}"

    # -- HA password --
    read -r -s -p "HA 管理员密码 (留空自动生成) []: " HA_PASSWORD </dev/tty
    echo ""
    if [ -z "$HA_PASSWORD" ]; then
        HA_PASSWORD="$(gen_password)"
        HA_PASSWORD_GENERATED=true
    else
        HA_PASSWORD_GENERATED=false
    fi

    # -- Boot auto-start --
    if confirm "开机自启动（断电/重启后自动恢复 Docker 与 HA 容器）[Y/n]:" "Y"; then
        ENABLE_BOOT_START=true
    else
        ENABLE_BOOT_START=false
    fi

    # -- Z-Wave/Zigbee serial ports --
    if [ -z "$ZWAVE_PORT" ]; then
        read -r -p "Z-Wave 串口路径: " ZWAVE_PORT </dev/tty
    fi
    if [ -z "$ZIGBEE_PORT" ]; then
        read -r -p "Zigbee 串口路径: " ZIGBEE_PORT </dev/tty
    fi

    # -- Summary --
    echo ""
    echo -e "${BOLD}=== 配置确认 ===${NC}"
    echo -e "  安装目录: ${BOLD}$INSTALL_DIR${NC}"
    echo -e "  时区:     ${BOLD}$TZ${NC}"
    echo -e "  HA 用户:  ${BOLD}$HA_USER${NC}"
    if [ "$HA_PASSWORD_GENERATED" = true ]; then
        echo -e "  HA 密码:  ${BOLD}${YELLOW}$HA_PASSWORD${NC} ${RED}(自动生成 — 请妥善保存!)${NC}"
    else
        echo -e "  HA 密码:  ${BOLD}(已输入)${NC}"
    fi
    echo -e "  Z-Wave:   ${BOLD}$ZWAVE_PORT${NC}"
    echo -e "  Zigbee:   ${BOLD}$ZIGBEE_PORT${NC}"
    if [ "$ENABLE_BOOT_START" = true ]; then
        echo -e "  开机自启: ${BOLD}是${NC}（Docker 守护进程；容器随其自动恢复）"
    else
        echo -e "  开机自启: ${BOLD}否${NC}"
    fi
    echo ""

    if ! confirm "确认开始部署？[Y/n]:" "Y"; then
        info "已取消"
        exit 0
    fi

    echo ""
}

# ============================================================================
# Phase 3: System Preparation
# ============================================================================

phase3_prepare() {
    step "Phase 3: 系统准备"

    NEED_RELOGIN=false

    # -- Install Docker --
    if [ "$DOCKER_INSTALLED" = true ]; then
        info "Docker 已安装，跳过"
    else
        info "安装 Docker Engine..."
        curl -fsSL https://get.docker.com | sudo sh || die "Docker 安装失败"
        success "Docker Engine 安装完成"
    fi

    # -- Install docker-compose-plugin --
    if sudo docker compose version &>/dev/null 2>&1; then
        info "Docker Compose 插件已安装，跳过"
    else
        info "安装 docker-compose-plugin..."
        if check_command apt-get; then
            sudo apt-get update -qq
            sudo apt-get install -y -qq docker-compose-plugin || die "docker-compose-plugin 安装失败"
        else
            warn "非 apt 系统，请手动安装 docker-compose-plugin"
        fi
        success "docker-compose-plugin 安装完成"
    fi

    # -- Ensure python3 (phase7 onboarding depends on it for JSON handling) --
    if check_command python3; then
        info "python3: $(python3 --version 2>&1)"
    else
        info "python3 未安装，正在安装..."
        if check_command apt-get; then
            sudo apt-get update -qq
            sudo apt-get install -y -qq python3 || die "python3 安装失败（phase7 onboarding 依赖它）"
        else
            die "未找到 python3 且非 apt 系统，请手动安装 python3 后重试"
        fi
        success "python3 已安装"
    fi

    # -- Enable Docker boot auto-start --
    if [ "${ENABLE_BOOT_START:-true}" = true ]; then
        if check_command systemctl; then
            info "启用 Docker 开机自启..."
            local sc_out
            if sc_out="$(sudo systemctl enable --now docker 2>&1)"; then
                success "Docker 已设为开机自启（容器将随守护进程自动恢复）"
            else
                warn "无法启用 Docker 开机自启"
                detail "失败原因: ${sc_out:-未知}"
                detail "请手动执行: sudo systemctl enable --now docker"
            fi
        else
            warn "systemctl 不可用，跳过开机自启设置（该系统可能未使用 systemd）"
            detail "如需开机自启，请参考对应 init 系统的手动配置"
        fi
    else
        info "未启用开机自启"
        detail "如需启用: sudo systemctl enable --now docker"
    fi

    # -- Add user to groups --
    local CURRENT_USER="${SUDO_USER:-$USER}"

    if groups "$CURRENT_USER" 2>/dev/null | grep -qv docker; then
        info "将 $CURRENT_USER 加入 docker 组..."
        sudo usermod -aG docker "$CURRENT_USER" || warn "无法将用户加入 docker 组"
        NEED_RELOGIN=true
    else
        info "用户已在 docker 组中"
    fi

    if groups "$CURRENT_USER" 2>/dev/null | grep -qv dialout; then
        info "将 $CURRENT_USER 加入 dialout 组..."
        sudo usermod -aG dialout "$CURRENT_USER" || warn "无法将用户加入 dialout 组"
        NEED_RELOGIN=true
    else
        info "用户已在 dialout 组中"
    fi

    if [ "$NEED_RELOGIN" = true ]; then
        warn "用户组已更新，可能需要重新登录才能生效"
        warn "如果 docker 命令失败，请退出并重新登录后再运行本脚本"
    fi

    # -- Handle ModemManager --
    # Instead of purging ModemManager (which may be needed for other devices),
    # we add ENV{ID_MM_DEVICE_IGNORE}="1" to the udev rule so ModemManager
    # skips Mixtile serial ports entirely.
    if [ "$MODEMMANAGER_PRESENT" = true ]; then
        info "ModemManager 已安装 — 将通过 udev 规则使其跳过 Mixtile 设备"
    else
        info "ModemManager 未安装，跳过"
    fi

    # -- udev rules --
    # ID_MM_DEVICE_IGNORE tells ModemManager to never probe this device.
    local UDEV_FILE="/etc/udev/rules.d/99-mixtile-serial.rules"
    local UDEV_CONTENT='# Mixtile 2-in-1 Zigbee & Z-Wave mPCIe Module (CH343 USB Dual Serial)\n# if00 -> Z-Wave, if02 -> Zigbee\n# ID_MM_DEVICE_IGNORE prevents ModemManager from probing these ports\nSUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d2", ENV{ID_MM_DEVICE_IGNORE}="1", SYMLINK+="mixtile_%n", MODE="0666"\n'

    if [ -f "$UDEV_FILE" ]; then
        info "udev 规则已存在: $UDEV_FILE"
        if confirm "是否覆盖？[y/N]:" "N"; then
            echo -e "$UDEV_CONTENT" | sudo tee "$UDEV_FILE" > /dev/null
            sudo udevadm control --reload-rules
            sudo udevadm trigger
            success "udev 规则已更新"
        else
            info "保留现有 udev 规则"
        fi
    else
        info "创建 udev 规则..."
        echo -e "$UDEV_CONTENT" | sudo tee "$UDEV_FILE" > /dev/null
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        success "udev 规则已创建"
    fi
}

# ============================================================================
# Phase 4: Generate Config Files
# ============================================================================

phase4_generate() {
    step "Phase 4: 生成配置文件"

    # -- Create directories --
    mkdir -p "$INSTALL_DIR/config"
    mkdir -p "$INSTALL_DIR/zwavejs"
    info "目录已准备: $INSTALL_DIR"

    # -- Backup existing configs --
    local TIMESTAMP
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

    if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        local DC_BACKUP="$INSTALL_DIR/docker-compose.yml.bak.$TIMESTAMP"
        cp "$INSTALL_DIR/docker-compose.yml" "$DC_BACKUP"
        info "已备份 docker-compose.yml → $(basename "$DC_BACKUP")"
    fi

    if [ -f "$INSTALL_DIR/zwavejs/settings.json" ]; then
        local SJ_BACKUP="$INSTALL_DIR/zwavejs/settings.json.bak.$TIMESTAMP"
        cp "$INSTALL_DIR/zwavejs/settings.json" "$SJ_BACKUP"
        info "已备份 settings.json → $(basename "$SJ_BACKUP")"
    fi

    # -- Generate SESSION_SECRET --
    local SESSION_SECRET
    SESSION_SECRET="$(gen_password)"

    # -- Generate docker-compose.yml --
    info "生成 docker-compose.yml..."
    cat > "$INSTALL_DIR/docker-compose.yml" << YAMLEOF
services:
  zwave-js-ui:
    image: zwavejs/zwave-js-ui:latest
    container_name: zwave-js-ui
    restart: unless-stopped
    tty: true
    stop_signal: SIGINT
    environment:
      TZ: $TZ
      SESSION_SECRET: $SESSION_SECRET
      ZWAVEJS_EXTERNAL_CONFIG: /usr/src/app/store/.config-db
    devices:
      - $ZWAVE_PORT:/dev/zwave
    volumes:
      - ./zwavejs:/usr/src/app/store
    ports:
      - "$ZWAVE_UI_PORT:$ZWAVE_UI_PORT"
      - "$ZWAVE_WS_PORT:$ZWAVE_WS_PORT"

  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    privileged: true
    network_mode: host
    environment:
      TZ: $TZ
      DISABLE_JEMALLOC: "true"
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    devices:
      - $ZIGBEE_PORT:/dev/ttyACM1
    depends_on:
      - zwave-js-ui
YAMLEOF
    success "docker-compose.yml 已生成"

    # -- Generate settings.json (serverEnabled/serverPort in "zwave" object!) --
    if [ -f "$INSTALL_DIR/zwavejs/settings.json" ]; then
        if confirm "settings.json 已存在，是否覆盖？[y/N]:" "N"; then
            info "覆盖 settings.json..."
        else
            info "保留现有 settings.json"
            success "配置文件生成完成"
            return 0
        fi
    fi

    info "生成 settings.json (serverEnabled/serverPort 在 zwave 对象内)..."
    cat > "$INSTALL_DIR/zwavejs/settings.json" << EOF
{
  "zwave": {
    "deviceConfigPriorityDir": "/usr/src/app/store/config",
    "enableSoftReset": true,
    "port": "/dev/zwave",
    "commandsTimeout": 30,
    "rf": {
      "region": "EU"
    },
    "serverEnabled": true,
    "serverPort": 3000
  },
  "backup": {
    "nvmBackup": false,
    "storeBackup": false
  },
  "mqtt": {
    "disabled": true
  }
}
EOF
    success "settings.json 已生成"
}

# ============================================================================
# Phase 5: Start Containers
# ============================================================================

phase5_start() {
    step "Phase 5: 启动容器"

    cd "$INSTALL_DIR"

    # -- Pull images --
    info "拉取容器镜像..."
    docker_compose pull || warn "拉取镜像有警告，继续尝试启动..."

    # -- Start --
    info "启动容器..."
    docker_compose up -d || die "容器启动失败，请检查日志"

    # -- Fix ownership if sudo was used for docker --
    if ! docker ps &>/dev/null 2>&1; then
        # sudo was used, fix volume ownership
        local CURRENT_USER="${SUDO_USER:-$USER}"
        sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR/config" "$INSTALL_DIR/zwavejs" 2>/dev/null || true
    fi

    # -- Wait for zwave-js-ui --
    wait_for_http "http://127.0.0.1:$ZWAVE_UI_PORT" "Z-Wave JS UI" "$MAX_WAIT_SECONDS" || {
        warn "Z-Wave JS UI 启动超时，查看日志: docker logs zwave-js-ui"
    }

    # -- Wait for HA onboarding API --
    wait_for_http "http://127.0.0.1:$HA_PORT/api/onboarding" "Home Assistant Onboarding API" "$MAX_WAIT_SECONDS" || {
        warn "HA 启动超时，查看日志: docker logs homeassistant"
    }
}

# ============================================================================
# Phase 6: Z-Wave JS Config Verification
# ============================================================================

phase6_zwave_verify() {
    step "Phase 6: Z-Wave JS 配置验证"

    cd "$INSTALL_DIR"

    # -- Wait for Z-Wave driver ready --
    info "等待 Z-Wave driver ready..."
    local elapsed=0
    local driver_ready=false
    while [ "$elapsed" -lt 120 ]; do
        if check_container_log "zwave-js-ui" "Z-Wave driver is ready"; then
            driver_ready=true
            success "Z-Wave driver is ready (${elapsed}s)"
            break
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    if [ "$driver_ready" = false ]; then
        warn "Z-Wave driver 未在 120s 内就绪，检查: docker logs zwave-js-ui"
    fi

    # -- Verify WS Server listening --
    if check_container_log "zwave-js-ui" "ZwaveJS server listening"; then
        success "Z-Wave JS WebSocket Server 正在监听"
    else
        warn "Z-Wave JS WebSocket Server 未监听！"

        # Auto-fix: ensure settings.json is correct
        local settings_file="$INSTALL_DIR/zwavejs/settings.json"
        if [ -f "$settings_file" ]; then
            info "尝试自动修复 settings.json (serverEnabled/serverPort 必须在 zwave 对象内)..."

            # Use python3 to safely fix the JSON if available
            if check_command python3; then
                python3 -c "
import json, sys
with open('$settings_file') as f:
    s = json.load(f)
zw = s.setdefault('zwave', {})
zw['serverEnabled'] = True
zw['serverPort'] = 3000
# Remove from zwavejs object if present (common pitfall)
if 'zwavejs' in s and isinstance(s['zwavejs'], dict):
    s['zwavejs'].pop('serverEnabled', None)
    s['zwavejs'].pop('serverPort', None)
with open('$settings_file', 'w') as f:
    json.dump(s, f, indent=2)
"
                success "settings.json 已自动修复"
            else
                warn "python3 不可用，请手动检查 settings.json:"
                detail "serverEnabled 和 serverPort 必须在 \"zwave\" 对象内（非 \"zwavejs\"）"
            fi

            info "重启 zwave-js-ui 使配置生效..."
            docker_compose restart zwave-js-ui
            sleep 10

            if check_container_log "zwave-js-ui" "ZwaveJS server listening"; then
                success "修复成功！Z-Wave JS WebSocket Server 正在监听"
            else
                warn "自动修复未能解决问题，请手动检查"
                detail "docker logs zwave-js-ui 2>&1 | grep -i listening"
            fi
        fi
    fi

    # -- Verify port 3000 is open --
    if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/$ZWAVE_WS_PORT" 2>/dev/null; then
        success "Z-Wave WebSocket 端口 $ZWAVE_WS_PORT 可达"
    else
        warn "端口 $ZWAVE_WS_PORT 不可达，请检查防火墙和容器状态"
    fi
}

# ============================================================================
# Phase 7: HA Onboarding (REST API)
# ============================================================================

phase7_onboarding() {
    step "Phase 7: HA Onboarding"

    local HA_BASE="http://127.0.0.1:$HA_PORT"
    local CLIENT_ID="http://127.0.0.1:$HA_PORT/"
    local TOKEN=""
    local REFRESH_TOKEN=""

    # -- Check if onboarding is needed --
    info "检查 HA Onboarding 状态..."
    local onboarding_status
    onboarding_status=$(curl -sS "$HA_BASE/api/onboarding" 2>/dev/null || true)

    if [ -z "$onboarding_status" ]; then
        error "无法访问 HA Onboarding API"
        return 1
    fi

    # Check if all onboarding steps are done
    if ! echo "$onboarding_status" | grep -q '"done":false'; then
        info "HA 已完成所有 onboarding 步骤，跳过"
        warn "已初始化的 HA 需要通过 Web UI 手动添加集成"
        return 0
    fi

    # ---- Step 1: Create user (if not done) ----
    if echo "$onboarding_status" | python3 -c "
import sys,json
steps=json.load(sys.stdin)
user_step=[s for s in steps if s['step']=='user']
sys.exit(0 if user_step and not user_step[0]['done'] else 1)
" 2>/dev/null; then
        info "创建管理员用户: $HA_USER"
        # Build JSON via python3 to safely escape special chars in password/username
        local user_payload
        user_payload="$(python3 -c 'import json,sys; print(json.dumps({"language":"zh-Hans","client_id":sys.argv[1],"name":sys.argv[2],"username":sys.argv[2],"password":sys.argv[3]}))' "$CLIENT_ID" "$HA_USER" "$HA_PASSWORD" 2>/dev/null || true)"
        local user_response
        user_response=$(curl -sS -X POST "$HA_BASE/api/onboarding/users" \
            -H "Content-Type: application/json" \
            -d "$user_payload" 2>/dev/null || true)

        local AUTH_CODE
        AUTH_CODE=$(echo "$user_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('auth_code',''))" 2>/dev/null || true)

        if [ -z "$AUTH_CODE" ]; then
            error "创建用户失败: $user_response"
            warn "请手动通过 Web 完成 onboarding: $HA_BASE"
            return 1
        fi
        success "管理员用户已创建"

        # Exchange auth_code for access_token + refresh_token
        info "获取认证令牌..."
        local token_response
        token_response=$(curl -sS -X POST "$HA_BASE/auth/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "grant_type=authorization_code" \
            --data-urlencode "code=$AUTH_CODE" \
            --data-urlencode "client_id=$CLIENT_ID" 2>/dev/null || true)

        TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
        REFRESH_TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null || true)

        if [ -z "$TOKEN" ]; then
            error "无法获取认证令牌"
            warn "跳过 API 配置，请通过 Web UI 完成: $HA_BASE"
            return 1
        fi
        success "认证令牌已获取"
    else
        info "用户已创建，跳过"
        warn "无法为新初始化后的用户自动获取令牌"
        warn "请通过 Web UI 完成: $HA_BASE"
        return 0
    fi

    # ---- Helper: refresh access token (tokens expire in 30min) ----
    local AUTH_HEADER="Authorization: Bearer $TOKEN"

    refresh_token_if_needed() {
        if [ -z "$REFRESH_TOKEN" ]; then return 0; fi
        local new_resp
        new_resp=$(curl -sS -X POST "$HA_BASE/auth/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "grant_type=refresh_token" \
            --data-urlencode "refresh_token=$REFRESH_TOKEN" \
            --data-urlencode "client_id=$CLIENT_ID" 2>/dev/null || true)
        local new_token
        new_token=$(echo "$new_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
        if [ -n "$new_token" ]; then
            TOKEN="$new_token"
            AUTH_HEADER="Authorization: Bearer $TOKEN"
        fi
    }

    # ---- Step 2: Core config ----
    info "配置核心设置 (时区: $TZ)..."
    local core_payload
    core_payload="$(python3 -c 'import json,sys; print(json.dumps({"language":"zh-Hans","location":{"name":"Home"},"time_zone":sys.argv[1],"unit_system":"metric","currency":"CNY"}))' "$TZ" 2>/dev/null || true)"
    curl -sS -X POST "$HA_BASE/api/onboarding/core_config" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$core_payload" 2>/dev/null || warn "核心配置有警告"
    success "核心设置已配置"

    # ---- Step 3: Analytics ----
    info "配置分析选项..."
    curl -sS -X POST "$HA_BASE/api/onboarding/analytics" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d '{"analytics": false}' 2>/dev/null || true
    success "分析选项已配置"

    # ---- Step 4: Complete integration onboarding ----
    info "完成 Onboarding 集成步骤..."
    local int_resp
    int_resp=$(curl -sS -X POST "$HA_BASE/api/onboarding/integration" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"redirect_uri\": \"$CLIENT_ID\", \"client_id\": \"$CLIENT_ID\"}" 2>/dev/null || true)
    success "Onboarding 已完成"

    # Refresh token after onboarding (integration step returns a new auth_code,
    # but the current token should still work)
    refresh_token_if_needed

    # ---- Step 5: Add ZHA integration ----
    info "添加 ZHA 集成..."
    add_zha_integration "$AUTH_HEADER" "$HA_BASE" || warn "ZHA 自动添加未成功，请通过 Web UI 手动添加"

    # ---- Step 6: Add Z-Wave JS integration ----
    info "添加 Z-Wave JS 集成..."
    add_zwave_integration "$AUTH_HEADER" "$HA_BASE" || warn "Z-Wave 自动添加未成功，请通过 Web UI 手动添加"
}

# ---- ZHA Integration (3-step config flow via API) ----

add_zha_integration() {
    local auth="$1"
    local base="$2"

    # Step 0: Check if ZHA is already configured
    local existing
    existing=$(curl -sS -X GET "$base/api/config/config_entries/entry" \
        -H "$auth" 2>/dev/null || true)
    if echo "$existing" | grep -q '"domain":"zha"'; then
        info "ZHA 集成已配置，跳过"
        return 0
    fi

    # Step 1: Start config flow
    local flow_response
    flow_response=$(curl -sS -X POST "$base/api/config/config_entries/flow" \
        -H "$auth" \
        -H "Content-Type: application/json" \
        -d '{"handler": "zha"}' 2>/dev/null || true)

    local flow_id
    flow_id=$(echo "$flow_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('flow_id',''))" 2>/dev/null || true)

    if [ -z "$flow_id" ]; then
        warn "无法启动 ZHA config flow: $flow_response"
        detail "请手动添加: Settings → Devices & services → Add Integration → ZHA"
        return 1
    fi

    info "ZHA config flow 已启动 (flow_id: ${flow_id:0:8}...)"

    # Step 2: Select serial port (/dev/ttyACM1 is the container-mapped path)
    local step_response
    step_response=$(curl -sS -X POST "$base/api/config/config_entries/flow/$flow_id" \
        -H "$auth" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"/dev/ttyACM1\"}" 2>/dev/null || true)

    local step_type
    step_type=$(echo "$step_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || true)

    # Step 3: HA returns a "menu" step asking for setup strategy
    if [ "$step_type" = "menu" ]; then
        info "选择推荐配置策略..."
        step_response=$(curl -sS -X POST "$base/api/config/config_entries/flow/$flow_id" \
            -H "$auth" \
            -H "Content-Type: application/json" \
            -d '{"next_step_id": "setup_strategy_recommended"}' 2>/dev/null || true)
        step_type=$(echo "$step_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || true)
    fi

    # Step 4: If type is "progress", poll until it completes (network formation)
    if [ "$step_type" = "progress" ]; then
        info "ZHA 正在创建 Zigbee 网络（这可能需要 30-60 秒）..."
        local progress_elapsed=0
        while [ "$progress_elapsed" -lt 120 ]; do
            sleep 5
            progress_elapsed=$((progress_elapsed + 5))
            # Re-fetch the flow to check if it progressed
            step_response=$(curl -sS -X GET "$base/api/config/config_entries/flow/$flow_id" \
                -H "$auth" 2>/dev/null || true)
            step_type=$(echo "$step_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || true)
            if [ "$step_type" = "create_entry" ]; then
                break
            fi
        done
    fi

    if [ "$step_type" = "create_entry" ]; then
        success "ZHA 集成已添加"
    else
        warn "ZHA config flow 结果: type=$step_type"
        detail "请通过 Web UI 确认 ZHA 集成状态"
    fi
}

# ---- Z-Wave JS Integration (API) ----

add_zwave_integration() {
    local auth="$1"
    local base="$2"

    # Check if Z-Wave is already configured
    local existing
    existing=$(curl -sS -X GET "$base/api/config/config_entries/entry" \
        -H "$auth" 2>/dev/null || true)
    if echo "$existing" | grep -q '"domain":"zwave_js"'; then
        info "Z-Wave JS 集成已配置，跳过"
        return 0
    fi

    # Start config flow
    local flow_response
    flow_response=$(curl -sS -X POST "$base/api/config/config_entries/flow" \
        -H "$auth" \
        -H "Content-Type: application/json" \
        -d '{"handler": "zwave_js"}' 2>/dev/null || true)

    local flow_id
    flow_id=$(echo "$flow_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('flow_id',''))" 2>/dev/null || true)

    if [ -z "$flow_id" ]; then
        warn "无法启动 Z-Wave config flow: $flow_response"
        detail "请手动添加: Settings → Devices & services → Add Integration → Z-Wave"
        return 1
    fi

    info "Z-Wave config flow 已启动 (flow_id: ${flow_id:0:8}...)"

    # Submit WebSocket URL
    local step_response
    step_response=$(curl -sS -X POST "$base/api/config/config_entries/flow/$flow_id" \
        -H "$auth" \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"ws://127.0.0.1:$ZWAVE_WS_PORT\"}" 2>/dev/null || true)

    if echo "$step_response" | grep -q '"type":"create_entry"'; then
        success "Z-Wave JS 集成已添加"
    else
        warn "Z-Wave config flow 结果: $step_response"
        detail "请通过 Web UI 确认 Z-Wave 集成状态"
    fi
}

# ============================================================================
# Phase 8: Verification + Summary
# ============================================================================

phase8_verify() {
    step "Phase 8: 验证 + 部署摘要"

    cd "$INSTALL_DIR"

    # ---- Container status ----
    echo ""
    echo -e "${BOLD}--- 容器状态 ---${NC}"
    docker_compose ps 2>/dev/null || {
        warn "无法获取容器状态"
        return 1
    }

    # Check both containers are Up
    if docker_compose ps 2>/dev/null | grep -q "homeassistant.*Up"; then
        success "homeassistant 容器运行中"
    else
        error "homeassistant 容器未运行"
    fi

    if docker_compose ps 2>/dev/null | grep -q "zwave-js-ui.*Up"; then
        success "zwave-js-ui 容器运行中"
    else
        error "zwave-js-ui 容器未运行"
    fi

    # ---- Port checks ----
    echo ""
    echo -e "${BOLD}--- 端口检测 ---${NC}"

    if curl -sSf -o /dev/null "http://127.0.0.1:$HA_PORT" 2>/dev/null; then
        success "Home Assistant: http://127.0.0.1:$HA_PORT ✓"
    else
        warn "Home Assistant 端口 $HA_PORT 不可达"
    fi

    if curl -sSf -o /dev/null "http://127.0.0.1:$ZWAVE_UI_PORT" 2>/dev/null; then
        success "Z-Wave JS UI:  http://127.0.0.1:$ZWAVE_UI_PORT ✓"
    else
        warn "Z-Wave JS UI 端口 $ZWAVE_UI_PORT 不可达"
    fi

    if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/$ZWAVE_WS_PORT" 2>/dev/null; then
        success "Z-Wave WebSocket: 127.0.0.1:$ZWAVE_WS_PORT ✓"
    else
        warn "Z-Wave WebSocket 端口 $ZWAVE_WS_PORT 不可达"
    fi

    # ---- Serial device mapping ----
    echo ""
    echo -e "${BOLD}--- 串口映射 ---${NC}"

    if docker_cmd exec zwave-js-ui ls -l /dev/zwave &>/dev/null; then
        success "Z-Wave 容器串口: /dev/zwave ✓"
    else
        warn "Z-Wave 容器串口映射可能有问题"
    fi

    if docker_cmd exec homeassistant ls -l /dev/ttyACM1 &>/dev/null; then
        success "Zigbee 容器串口: /dev/ttyACM1 ✓"
    else
        warn "Zigbee 容器串口映射可能有问题"
    fi

    # ---- Boot auto-start ----
    echo ""
    echo -e "${BOLD}--- 开机自启 ---${NC}"
    if check_command systemctl; then
        local docker_autostart
        docker_autostart="$(systemctl is-enabled docker 2>/dev/null || echo unknown)"
        case "$docker_autostart" in
            enabled)
                success "Docker 守护进程: 已开机自启 (enabled) ✓"
                ;;
            disabled|masked)
                warn "Docker 守护进程: 未开机自启 ($docker_autostart)"
                detail "如需启用: sudo systemctl enable --now docker"
                ;;
            *)
                info "Docker 守护进程自启状态: $docker_autostart"
                ;;
        esac
        success "容器重启策略: restart: unless-stopped（守护进程启动后容器自动恢复）"
    else
        warn "systemctl 不可用，无法检测开机自启状态"
    fi

    # ---- Integration check (if we have auth) ----
    echo ""
    echo -e "${BOLD}--- 集成状态 ---${NC}"

    # Check onboarding status via API
    local onboard_check
    onboard_check=$(curl -sS "http://127.0.0.1:$HA_PORT/api/onboarding" 2>/dev/null || true)
    if [ -n "$onboard_check" ]; then
        if echo "$onboard_check" | grep -q '"user"'; then
            warn "HA Onboarding 未完成（user 步骤待处理）"
        else
            success "HA Onboarding: 已完成"
        fi
    fi

    # ---- Log highlights ----
    echo ""
    echo -e "${BOLD}--- Z-Wave 日志检查 ---${NC}"

    if check_container_log "zwave-js-ui" "Z-Wave driver is ready"; then
        success "Z-Wave driver: ready ✓"
    else
        warn "Z-Wave driver: 可能尚未就绪"
    fi

    if check_container_log "zwave-js-ui" "listening"; then
        success "Z-Wave JS Server: listening ✓"
    else
        warn "Z-Wave JS Server: 可能未监听"
    fi

    # ---- Final Summary ----
    local host_ip
    host_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' 2>/dev/null || echo "<主机IP>")

    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              部署完成！Deployment Complete               ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    printf "║  %-52s ║\n" "Home Assistant:  http://$host_ip:$HA_PORT"
    printf "║  %-52s ║\n" "Z-Wave JS UI:    http://$host_ip:$ZWAVE_UI_PORT"
    printf "║  %-52s ║\n" "Z-Wave WebSocket: ws://127.0.0.1:$ZWAVE_WS_PORT"
    printf "║  %-52s ║\n" ""
    printf "║  %-52s ║\n" "用户名: $HA_USER"
    if [ "$HA_PASSWORD_GENERATED" = true ]; then
        printf "║  %-52s ║\n" "密码:   $HA_PASSWORD  ← 自动生成"
    else
        printf "║  %-52s ║\n" "密码:   (已输入)"
    fi
    printf "║  %-52s ║\n" ""
    printf "║  %-52s ║\n" "安装目录: $INSTALL_DIR"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [ "$HA_PASSWORD_GENERATED" = true ]; then
        echo -e "${RED}${BOLD}⚠ 请妥善保存上述密码！密码由 openssl rand -hex 8 生成，不会再次显示。${NC}"
        echo ""
    fi

    echo -e "${YELLOW}提示:${NC}"
    echo "  查看 HA 日志:     docker logs -f homeassistant"
    echo "  查看 Z-Wave 日志: docker logs -f zwave-js-ui"
    echo "  重启服务:         cd $INSTALL_DIR && docker compose restart"
    echo "  停止服务:         cd $INSTALL_DIR && docker compose down"
    echo "  重置 HA 密码:     docker exec -it homeassistant python3 -m homeassistant --script auth --config /config change_password <用户> <新密码>"
    echo ""

    # Suggest ownership fix if sudo was used
    if ! docker ps &>/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ 检测到使用 sudo 运行 docker，配置文件可能由 root 拥有。${NC}"
        echo "  修复权限:  sudo chown -R \$USER:\$USER $INSTALL_DIR"
        echo ""
    fi

    if [ "$NEED_RELOGIN" = true ]; then
        warn "建议退出并重新登录，使 docker/dialout 组权限生效"
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    show_banner

    phase1_detect
    phase2_config
    phase3_prepare
    phase4_generate
    phase5_start
    phase6_zwave_verify
    phase7_onboarding
    phase8_verify
}

main "$@"
