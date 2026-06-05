# Ubuntu + HA Container 部署 Mixtile 2-in-1 Zigbee/Z-Wave 模块

本文说明如何在 Ubuntu 主机上使用 Docker 方式部署 Home Assistant Container，并验证 Mixtile 2-in-1 Zigbee & Z-Wave mPCIe 模块。

适用目标：
- Ubuntu / Armbian 主机
- Mixtile 2-in-1 Zigbee & Z-Wave mPCIe Interface Module
- Home Assistant Container（不是 HAOS）
- Zigbee 使用 ZHA
- Z-Wave 使用独立 `zwave-js-ui` 容器

> HA Container 没有 Add-ons / Supervisor，所以 Z-Wave JS 需要单独用 Docker 容器运行。

> 🚀 **一键部署**：本文档的所有步骤（环境检测、Docker 安装、配置生成、HA 初始化、集成添加）均可通过自动化脚本完成，详见 [自动部署脚本](#15-自动部署脚本推荐)。

---

## 1. 前置条件

### 1.1 安装 Docker Engine

> ⚠️ 必须使用 Docker **Engine**，不能使用 Docker **Desktop**。要求版本 ≥ 23.0.0。

如果尚未安装 Docker：

```bash
# 官方一键安装脚本（适用于大多数 Linux 发行版）
curl -fsSL https://get.docker.com | sudo sh

# 将当前用户加入 docker 组（免 sudo）
sudo usermod -aG docker $USER
newgrp docker

# 验证
docker --version
docker compose version
```

如需手动安装或使用其他方式，参考 [Docker 官方文档](https://docs.docker.com/engine/install/)。

### 1.2 安装 Docker Compose 插件

Docker Compose V2 已作为 Docker CLI 插件内置，安装 Docker Engine 后通常已包含。验证：

```bash
docker compose version
```

如果未安装：

```bash
sudo apt-get update
sudo apt-get install docker-compose-plugin
```

### 1.3 处理 ModemManager

ModemManager 可能会占用 USB 串口设备，导致 ZHA 无法初始化。

**推荐方式：通过 udev 规则让 ModemManager 跳过 Mixtile 设备**（不卸载，不影响系统其他设备）：

```bash
# 在下面的 §3.1 udev 规则中加入 ENV{ID_MM_DEVICE_IGNORE}="1" 即可
```

如果确定不需要 ModemManager，也可以直接卸载：

```bash
sudo apt-get purge modemmanager
```

## 2. 确认硬件识别

模块走 mini-PCIe 的 USB 线路，在 Ubuntu 上通常会枚举成两个串口。

```bash
lsusb
ls -l /dev/serial/by-id/
ls -l /dev/ttyACM* /dev/ttyUSB* 2>/dev/null
```

参考本次验证环境：

```text
/dev/serial/by-id/usb-1a86_USB_Dual_Serial_588D059787-if00 -> ../../ttyACM0
/dev/serial/by-id/usb-1a86_USB_Dual_Serial_588D059787-if02 -> ../../ttyACM1
```

端口用途：

```text
if00 / ttyACM0: Z-Wave
if02 / ttyACM1: Zigbee / ZHA
```

> ⚠️ 实际部署时**优先使用 `/dev/serial/by-id/...`**，不要依赖 `/dev/ttyACM0`、`/dev/ttyACM1`，因为重启后编号可能变化。下文所有配置均使用 by-id 路径。

## 3. 串口权限配置

确保运行 Docker 的用户有权限访问串口设备：

```bash
sudo usermod -aG dialout $USER
newgrp dialout
```

验证权限：

```bash
ls -l /dev/serial/by-id/usb-1a86_USB_Dual_Serial_*
# 应看到 crw-rw---- ，所属组为 dialout
```

### 3.1 udev 规则（可选，推荐）

为 Mixtile 模块创建固定的符号链接和权限规则，确保每次开机设备路径一致且权限正确。

同时通过 `ID_MM_DEVICE_IGNORE` 告诉 ModemManager 跳过这些串口，避免 ModemManager 探测时抢占 Zigbee/Z-Wave 串口：

```bash
sudo tee /etc/udev/rules.d/99-mixtile-serial.rules << 'EOF'
# Mixtile 2-in-1 Zigbee & Z-Wave mPCIe Module (CH343 USB Dual Serial)
# if00 -> Z-Wave, if02 -> Zigbee
# ID_MM_DEVICE_IGNORE prevents ModemManager from probing these ports
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d2", ENV{ID_MM_DEVICE_IGNORE}="1", SYMLINK+="mixtile_%n", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
```

重新插拔模块或重启后，可以通过 `/dev/mixtile_0`、`/dev/mixtile_2` 等路径访问。

## 4. 准备目录

```bash
mkdir -p ~/homeassistant/config
mkdir -p ~/homeassistant/zwavejs
cd ~/homeassistant
```

## 5. Docker Compose

创建 `~/homeassistant/docker-compose.yml`：

```yaml
services:
  zwave-js-ui:
    image: zwavejs/zwave-js-ui:latest
    container_name: zwave-js-ui
    restart: unless-stopped
    tty: true
    stop_signal: SIGINT
    environment:
      TZ: Asia/Shanghai
      SESSION_SECRET: change-this-session-secret
      ZWAVEJS_EXTERNAL_CONFIG: /usr/src/app/store/.config-db
    devices:
      - /dev/serial/by-id/usb-1a86_USB_Dual_Serial_588D059787-if00:/dev/zwave
    volumes:
      - ./zwavejs:/usr/src/app/store
    ports:
      - "8091:8091"
      - "3000:3000"

  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    privileged: true
    network_mode: host
    environment:
      TZ: Asia/Shanghai
      DISABLE_JEMALLOC: "true"
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    devices:
      - /dev/serial/by-id/usb-1a86_USB_Dual_Serial_588D059787-if02:/dev/ttyACM1
    depends_on:
      - zwave-js-ui
```

> 按你的实际 `ls -l /dev/serial/by-id/` 输出替换两个设备路径。

**配置说明：**

| 配置项 | 说明 |
|--------|------|
| `privileged: true` | HA 需要特权模式访问硬件 |
| `network_mode: host` | HA 要求使用主机网络，端口映射不可靠 |
| `/run/dbus:/run/dbus:ro` | 可选，蓝牙集成需要 |
| `stop_signal: SIGINT` | Z-Wave JS UI 需要优雅关闭以避免数据损坏 |
| `DISABLE_JEMALLOC` | 避免 ARM64 设备上 jemalloc 页面大小不兼容报错 |
| `ZWAVEJS_EXTERNAL_CONFIG` | Z-Wave JS 配置数据库路径 |

启动：

```bash
cd ~/homeassistant
docker compose up -d
docker compose ps
```

预期输出：

```text
NAME            IMAGE                                    STATUS
homeassistant   ghcr.io/home-assistant/home-assistant    Up
zwave-js-ui     zwavejs/zwave-js-ui                      Up
```

## 6. Home Assistant 初始化

### 6.1 首次启动等待

HA 首次启动需要下载并安装核心组件（约 700 MB），耗时 5–10 分钟。查看进度：

```bash
docker logs -f homeassistant
```

等待看到 `Home Assistant is up and running` 后继续。

### 6.2 创建管理员账户

浏览器打开：

```text
http://<Ubuntu主机IP>:8123
```

按引导完成：

1. 选择 **Create my smart home**
2. 填写姓名、用户名（小写无空格）、密码 — 这是管理员账户，请妥善保存
3. 设置家庭位置（用于时区、天气等）
4. 是否分享匿名数据（可选，默认关闭）

> ⚠️ 密码无法找回，只能通过命令行重置（见常见问题章节）。

如果需要通过命令行重置密码：

```bash
docker exec -it homeassistant python3 -m homeassistant --script auth --config /config change_password <用户名> <新密码>
```

## 7. 配置 Z-Wave JS UI

Z-Wave JS UI 有两种配置方式：**配置文件方式**（推荐，可完全自动化）和 **Web 界面方式**。

### 7.1 配置文件方式（推荐）

容器首次启动后，在 `~/homeassistant/zwavejs/` 下创建 `settings.json`：

```bash
cat > ~/homeassistant/zwavejs/settings.json << 'EOF'
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
```

> ⚠️ **重要**：`serverEnabled` 和 `serverPort` 必须放在 `zwave` 对象内，不是放在 `zwavejs` 对象内。放错位置会导致 Z-Wave JS Server 不启动，HA 无法连接。

然后重启容器使配置生效：

```bash
cd ~/homeassistant
docker compose restart zwave-js-ui
```

### 7.2 Web 界面方式

浏览器打开：

```text
http://<Ubuntu主机IP>:8091
```

进入 **Settings**，配置：

| 设置项 | 值 |
|--------|-----|
| Z-Wave > Serial Port | `/dev/zwave` |
| Z-Wave > RF Region | `Europe` |
| Z-Wave > Security Keys | 点击 Generate 生成 S0/S2 keys，**务必保存好这些密钥** |
| Z-Wave > Server Enabled | `✓` 勾选（启用 Z-Wave JS WebSocket Server） |
| Z-Wave > Server Port | `3000` |
| MQTT | `Disabled`（除非你有 MQTT broker） |

### 7.3 验证

重启后检查日志：

```bash
docker logs -f zwave-js-ui
```

正常应看到以下关键信息：

```text
Z-Wave driver is ready
ZwaveJS server listening on <all interfaces>:3000
The controller is using RF region Europe
```

**如果只看到 `Z-Wave driver is ready` 但没有 `ZwaveJS server listening`**，说明 WS Server 没有启动。检查 `settings.json` 中 `serverEnabled` 是否在 `zwave` 对象内。

> 如果 Z-Wave 适配器未被识别，检查 USB 连接线和串口映射是否正确。

## 8. 配置 Home Assistant 集成

### 8.1 Zigbee / ZHA

ZHA 是 HA 内置集成，无需额外容器，只需要串口设备映射正确。

在 Home Assistant UI：

```text
Settings > Devices & services > Add integration > 搜索 "Zigbee" > 选择 "Zigbee Home Automation"
```

配置：

| 设置项 | 值 |
|--------|-----|
| Serial device path | `/dev/ttyACM1` |
| Setup strategy | 选择推荐策略（Recommended） |

> 新版 HA 会自动检测 Radio type（EZSP），无需手动选择波特率和流控。提交后 HA 会自动创建 Zigbee 网络，等待约 30-60 秒完成。

### 8.2 Z-Wave

在 Home Assistant UI：

```text
Settings > Devices & services > Add integration > 搜索 "Z-Wave" > 选择 "Z-Wave"
```

> ⚠️ HA Container 没有 Supervisor，**必须取消勾选** "Use the Z-Wave JS Supervisor add-on"。

连接地址填写：

```text
ws://127.0.0.1:3000
```

> 因为 HA 容器使用了 `network_mode: host`，所以直接用 `127.0.0.1`。如果 HA 和 zwave-js-ui 在同一个 Docker bridge 网络中，则使用 `ws://zwave-js-ui:3000`。

提交后等待 Z-Wave 控制器连接成功。

## 9. 添加设备

### 9.1 添加 Zigbee 设备

```text
Settings > Devices & services > Devices 标签 > ADD DEVICE
选择 "Add Zigbee device"
按照设备说明进入配对模式
```

### 9.2 添加 Z-Wave 设备

```text
Settings > Devices & services > Devices 标签 > ADD DEVICE
选择 "Add Z-Wave device"
按照设备说明进入配对模式
```

或在 Z-Wave JS UI (`http://<Ubuntu主机IP>:8091`) 中管理设备。

## 10. 验证

### 10.1 容器状态

```bash
cd ~/homeassistant
docker compose ps
```

应看到：

```text
homeassistant   Up
zwave-js-ui     Up
```

### 10.2 端口可达

```bash
curl -sI http://127.0.0.1:8123 | head -1   # Home Assistant（应返回 HTTP/1.1 200）
curl -sI http://127.0.0.1:8091 | head -1   # Z-Wave JS UI（应返回 HTTP/1.1 200）
timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/3000" && echo "port 3000 open"  # Z-Wave JS WebSocket
```

预期：

```text
8123: Home Assistant 可访问
8091: Z-Wave JS UI 可访问
3000: Z-Wave JS WebSocket 可连接
```

如果端口不通，检查防火墙：

```bash
sudo ufw allow 8123/tcp
sudo ufw allow 8091/tcp
sudo ufw allow 3000/tcp
```

### 10.3 串口映射

```bash
docker exec zwave-js-ui ls -l /dev/zwave
docker exec homeassistant ls -l /dev/ttyACM1
```

两个设备都应存在且可访问。

### 10.4 Home Assistant 日志

```bash
docker logs --tail=200 homeassistant
```

重点确认**没有**以下错误：

```text
Waiting for integrations to complete setup: zha
serial port busy
permission denied
```

### 10.5 Z-Wave 日志

```bash
docker logs --tail=200 zwave-js-ui
```

重点确认：

```text
Z-Wave driver is ready
ZwaveJS server listening on 0.0.0.0:3000
The controller is using RF region Europe
```

## 11. 更新

### 11.1 更新 Home Assistant

```bash
cd ~/homeassistant
docker compose pull homeassistant
docker compose up -d homeassistant
```

HA 会自动迁移数据库，首次启动可能需要几分钟。查看日志确认启动完成：

```bash
docker logs -f homeassistant
```

### 11.2 更新 Z-Wave JS UI

```bash
cd ~/homeassistant
docker compose pull zwave-js-ui
docker compose up -d zwave-js-ui
```

### 11.3 更新所有容器

```bash
cd ~/homeassistant
docker compose pull
docker compose up -d
```

## 12. 常见问题

### HA 登录密码忘记

Home Assistant 不保存明文密码，只保存哈希。可在容器内重置：

```bash
docker exec -it homeassistant python3 -m homeassistant --script auth --config /config change_password <用户名> <新密码>
```

### ZHA 初始化卡住

检查 Zigbee 串口是否被其他服务占用：

```bash
docker ps
sudo lsof /dev/serial/by-id/usb-1a86_USB_Dual_Serial_588D059787-if02
```

同一时间只能有一个服务使用 Zigbee 串口。不要同时运行 ZHA 和 Zigbee2MQTT 占用同一个设备。

如果问题持续，确认 ModemManager 未占用串口：

```bash
dpkg -l | grep modemmanager
# 如果存在，确认 udev 规则中有 ENV{ID_MM_DEVICE_IGNORE}="1"（见 §3.1）
# 或者直接卸载：
sudo apt-get purge modemmanager
```

### Z-Wave JS UI 能打开，但 HA Z-Wave 集成连不上

首先确认 Z-Wave JS Server 是否真正启动（这是最常见的坑）：

```bash
docker logs zwave-js-ui 2>&1 | grep "listening"
```

必须看到 `ZwaveJS server listening on <all interfaces>:3000`。如果只看到 `Listening on port 8091`（Web UI），说明 WS Server 没有启动。

**排查步骤：**

1. 检查 `settings.json` 中 `serverEnabled` 是否在 `zwave` 对象内（不是 `zwavejs`）：

```bash
cat ~/homeassistant/zwavejs/settings.json | python3 -c "
import sys, json
s = json.load(sys.stdin)
zw = s.get('zwave', {})
print(f'serverEnabled: {zw.get(\"serverEnabled\", \"未设置\")}')
print(f'serverPort: {zw.get(\"serverPort\", \"未设置\")}')
"
```

2. 确认端口可达：

```bash
timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/3000" && echo "port open" || echo "port closed"
```

3. HA 使用 `network_mode: host` 时，WebSocket 地址应为 `ws://127.0.0.1:3000`。

### Z-Wave 节点显示 dead

如果控制器已 ready，但某个节点 dead，通常是该 Z-Wave 设备离线、距离过远或不在同一频段。先确认控制器区域为 `Europe`，再单独处理节点。

添加新设备时如果配对失败，可以先执行 **排除**（Remove Failed Node）再重新添加。

### ARM64 设备出现 jemalloc 报错

在 ARM64 SoC 上如果看到 `<jemalloc>: Unsupported system page size`，在 docker-compose.yml 的 homeassistant 环境变量中添加：

```yaml
environment:
  TZ: Asia/Shanghai
  DISABLE_JEMALLOC: "true"
```

### 容器无法访问串口设备

确认设备映射和权限：

```bash
# 检查宿主机设备是否存在
ls -l /dev/serial/by-id/usb-1a86_USB_Dual_Serial_*

# 检查 Docker 用户是否在 dialout 组
groups $(whoami)

# 临时修复权限
sudo chmod 666 /dev/serial/by-id/usb-1a86_USB_Dual_Serial_*
```

### 重启后串口编号变化

这正是使用 `/dev/serial/by-id/...` 路径的原因。如果 by-id 路径也变了，说明 USB 设备被重新枚举了。检查：

```bash
ls -l /dev/serial/by-id/
```

并更新 docker-compose.yml 中的设备路径。

## 13. 完整验证清单

部署完成后，按以下清单逐项确认：

```text
[ ] Docker 和 Docker Compose 已安装
[ ] Mixtile 模块已识别，两个串口设备存在
[ ] docker compose up -d 启动成功，两个容器状态为 Up
[ ] HA Web 界面 http://<IP>:8123 可访问
[ ] Z-Wave JS UI http://<IP>:8091 可访问
[ ] HA 已创建管理员账户并完成初始化
[ ] Z-Wave JS UI 中控制器状态为 ready，协议版本和 RF Region 正确
[ ] ZHA 集成已添加，Zigbee 网络创建成功
[ ] Z-Wave 集成已添加，通过 WebSocket 连接到 zwave-js-ui 成功
[ ] （可选）已添加至少一个 Zigbee 或 Z-Wave 设备验证通信正常
```

## 14. 部署结论模板

```text
Ubuntu 主机已通过 Docker 部署 HA Container + zwave-js-ui。
Mixtile 2-in-1 模块两个串口均可被容器访问。
Zigbee 使用 ZHA，串口 /dev/serial/by-id/...-if02。
Z-Wave 使用 zwave-js-ui，串口 /dev/serial/by-id/...-if00。
Z-Wave 控制器识别正常，协议版本 x.xx.x，RF Region 为 Europe。
HA Web: http://<Ubuntu主机IP>:8123
Z-Wave JS UI: http://<Ubuntu主机IP>:8091
```

## 15. 自动部署脚本（推荐）

本仓库提供一键自动化部署脚本 `deploy.sh`，自动完成上述所有步骤：

- 自动检测 Mixtile 硬件和串口路径
- 安装 Docker / Docker Compose
- 生成 docker-compose.yml 和 settings.json
- 启动容器并等待就绪
- 通过 REST API 完成 HA Onboarding（创建用户、配置时区）
- 自动添加 ZHA 和 Z-Wave JS 集成
- 全程交互确认，有默认值可直接回车

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/evtest-hash/mixtile-2-in-1/main/deploy.sh | sudo bash
```

或先下载再执行（推荐，可先审查脚本内容）：

```bash
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/evtest-hash/mixtile-2-in-1/main/deploy.sh
chmod +x deploy.sh
sudo ./deploy.sh
```

### 使用方法

直接运行即可，所有配置通过交互式提示输入，均有默认值可直接回车。重复运行安全——已完成的步骤会自动跳过。

```bash
sudo ./deploy.sh
```

## 参考

- Mixtile 2-in-1 Zigbee & Z-Wave mPCIe Interface Module: https://www.mixtile.com/store/accessory/mixtile-2-in-1-zigbee-z-wave-mpcie-interface-module/
- Mixtile Zigbee/Z-Wave setup: https://www.mixtile.com/docs/setting-up-zigbee-and-z-wave-in-home-assistant/
- Home Assistant Container: https://www.home-assistant.io/installation/linux/
- Home Assistant Onboarding: https://www.home-assistant.io/getting-started/onboarding/
- Home Assistant Z-Wave: https://www.home-assistant.io/integrations/zwave_js/
- Home Assistant ZHA: https://www.home-assistant.io/integrations/zha/
- Z-Wave JS UI: https://zwave-js.github.io/zwave-js-ui/
