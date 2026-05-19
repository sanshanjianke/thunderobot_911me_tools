#!/bin/bash
# Thunderobot 911ME / Clevo NH58DXQ-H 系统控制脚本
# 功能: 风扇控制 + NVIDIA 显卡电源管理
# 用法: sudo fan [选项]
# 参考: https://blog.csdn.net/sanshanjianke/article/details/160636544

set -e

EC_PROBE="ec_probe -e dev_port"
FDAT="0xF9"
FCMD="0xF8"
EC_CMD_VAL="0xD7"
NVIDIA_PCI="0000:01:00.0"
VERSION="1.0"

###############################################################################
# 帮助
###############################################################################

usage() {
    echo "Thunderobot 911ME 系统控制脚本 v$VERSION"
    echo ""
    echo "=== 风扇控制 ==="
    echo "  -l, --low           静音模式   (FDAT=0x02)"
    echo "  -b, --balanced      平衡模式   (FDAT=0x08)"
    echo "  -p, --perf          高性能模式 (FDAT=0x10)"
    echo "  -a, --auto          自动模式   (FDAT=0x15)"
    echo "  -c, --custom N      自定义 FDAT 值 (0-255, 十进制或 0x 十六进制)"
    echo "  -s, --status        查看风扇+显卡状态"
    echo "  -m, --monitor       实时监控 EC 风扇寄存器"
    echo ""
    echo "=== NVIDIA 显卡 ==="
    echo "  --gpu-info          查看显卡详细信息"
    echo "  --gpu-save          启用显卡省电模式 (运行时生效)"
    echo "  --gpu-perf          显卡性能模式 (保持活跃)"
    echo "  --gpu-monitor       实时监控显卡温度/功耗"
    echo "  --gpu-setup         安装显卡省电配置 (modprobe.d + udev, 需重启)"
    echo "  --gpu-offload APP   用独显运行指定程序 (PRIME 加速)"
    echo ""
    echo "=== 其他 ==="
    echo "  -h, --help          显示帮助信息"
    echo ""
    echo "示例:"
    echo "  sudo fan -b                     # 风扇平衡模式"
    echo "  sudo fan --gpu-save             # 显卡省电"
    echo "  sudo fan --gpu-info             # 查看显卡状态"
    echo "  sudo fan --gpu-offload glxinfo  # 用独显运行程序"
    exit 0
}

###############################################################################
# 工具函数
###############################################################################

parse_val() {
    local v="$1"
    if [[ "$v" =~ ^0[xX] ]]; then
        printf '%d' "$v"
    else
        echo "$v"
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请用 sudo 运行此脚本"
        echo "用法: sudo $(basename "$0") [选项]"
        exit 1
    fi
}

###############################################################################
# 风扇功能
###############################################################################

set_fan() {
    local mode_name="$1"
    local fdat_val="$2"
    echo -n "设置风扇为${mode_name}模式 (FDAT=0x$(printf '%02X' "$fdat_val"))... "
    $EC_PROBE write $FDAT "$fdat_val"
    $EC_PROBE write $FCMD "$EC_CMD_VAL"
    echo "完成"
}

show_fan_status() {
    local out fdat_val
    out=$($EC_PROBE read $FDAT 2>/dev/null)
    fdat_val=$(echo "$out" | awk '{print $1}')
    echo "风扇 FDAT: 0x$(printf '%02X' "$fdat_val") ($fdat_val)"
    case "$fdat_val" in
        2)   echo "风扇模式: 静音" ;;
        8)   echo "风扇模式: 平衡" ;;
        16)  echo "风扇模式: 高性能" ;;
        21)  echo "风扇模式: 自动" ;;
        28)  echo "风扇模式: 自动 (初始值)" ;;
        *)   echo "风扇模式: 未知/自定义" ;;
    esac
}

monitor_fan() {
    echo "实时监控 EC 风扇寄存器 (Ctrl+C 退出)..."
    printf "%-10s %-8s %-8s\n" "时间" "FDAT" "FCMD"
    echo "-------------------------------"
    while true; do
        local fdat fcmd raw
        raw=$($EC_PROBE read $FDAT 2>/dev/null)
        fdat=$(echo "$raw" | awk '{print $1}')
        raw=$($EC_PROBE read $FCMD 2>/dev/null)
        fcmd=$(echo "$raw" | awk '{print $1}')
        printf "%-10s 0x%-6X 0x%-6X\n" "$(date +%H:%M:%S)" "$fdat" "$fcmd"
        sleep 1
    done
}

###############################################################################
# NVIDIA 显卡功能
###############################################################################

gpu_info() {
    echo "========== NVIDIA 显卡信息 =========="
    echo ""
    nvidia-smi --query-gpu=name,temperature.gpu,power.draw,utilization.gpu,memory.used,memory.total,pstate,clocks.current.sm,clocks.current.memory --format=csv 2>/dev/null | column -t -s','
    echo ""
    echo "--- 电源状态 ---"
    local ctrl status
    ctrl=$(cat /sys/bus/pci/devices/${NVIDIA_PCI}/power/control 2>/dev/null || echo "N/A")
    status=$(cat /sys/bus/pci/devices/${NVIDIA_PCI}/power/runtime_status 2>/dev/null || echo "N/A")
    echo "PCI runtime 控制: $ctrl"
    echo "PCI runtime 状态: $status"
    echo ""
    echo "--- 模块参数 ---"
    local dpm modeset
    dpm=$(cat /sys/module/nvidia/parameters/NVreg_DynamicPowerManagement 2>/dev/null || echo "未设置")
    modeset=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo "N/A")
    echo "DynamicPowerManagement: $dpm"
    echo "DRM modeset: $modeset"
    echo ""
    echo "--- Intel 集显 ---"
    if [ -e /sys/class/drm/card0/device/vendor ]; then
        echo "驱动: $(basename "$(readlink -f /sys/class/drm/card0/device/driver)" 2>/dev/null)"
        cat /sys/class/drm/card0/device/vendor /sys/class/drm/card0/device/device 2>/dev/null
    fi
}

gpu_save() {
    echo "=== 启用 NVIDIA 显卡省电模式 ==="
    echo ""
    # 开启持久模式 (允许省电)
    nvidia-smi -pm 1 2>/dev/null && echo "[OK] 持久模式已开启" || echo "[!] 持久模式设置失败"

    # 设置 PCI runtime PM 为 auto
    echo "auto" > /sys/bus/pci/devices/${NVIDIA_PCI}/power/control 2>/dev/null && \
        echo "[OK] PCI runtime PM 设为 auto" || \
        echo "[!] PCI runtime PM 设置失败"

    # 降低显存频率 (P8 状态)
    nvidia-smi -ac UNRESTRICTED 2>/dev/null || true

    echo ""
    echo "当前状态:"
    nvidia-smi --query-gpu=power.draw,temperature.gpu --format=csv,noheader 2>/dev/null

    echo ""
    echo "提示: 如需 GPU 空闲时深度休眠 (D3), 请运行 'sudo fan --gpu-setup' 后重启"
}

gpu_perf() {
    echo "=== NVIDIA 显卡性能模式 ==="
    echo ""

    # 关闭持久模式的省电限制
    nvidia-smi -pm 0 2>/dev/null && echo "[OK] 持久模式已关闭" || true

    # 设置 PCI runtime PM 为 on
    echo "on" > /sys/bus/pci/devices/${NVIDIA_PCI}/power/control 2>/dev/null && \
        echo "[OK] PCI runtime PM 设为 on (保持活跃)" || \
        echo "[!] PCI runtime PM 设置失败"

    echo ""
    echo "当前状态:"
    nvidia-smi --query-gpu=power.draw,temperature.gpu,clocks.current.sm --format=csv,noheader 2>/dev/null
}

gpu_monitor() {
    echo "NVIDIA 显卡实时监控 (Ctrl+C 退出)"
    echo ""
    printf "%-10s %-8s %-8s %-8s %-8s\n" "时间" "温度" "功耗" "GPU% " "显存"
    echo "-------------------------------------------------"
    while true; do
        local data
        data=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null)
        if [ -n "$data" ]; then
            IFS=',' read -r temp power util mem <<< "$data"
            printf "%-10s %-7s°C %-7sW %-7s%% %-7sMiB\n" \
                "$(date +%H:%M:%S)" "$(echo "$temp" | tr -d ' ')" \
                "$(echo "$power" | tr -d ' ')" "$(echo "$util" | tr -d ' ')" "$(echo "$mem" | tr -d ' ')"
        fi
        sleep 1
    done
}

gpu_setup() {
    echo "=== 安装 NVIDIA 省电配置 ==="
    echo ""

    # 1. modprobe 配置
    local MODPROBE_FILE="/etc/modprobe.d/nvidia-power.conf"
    cat > /tmp/nvidia-power.conf << 'MODEOF'
# NVIDIA 动态电源管理: 启用 D3 深度休眠
options nvidia NVreg_DynamicPowerManagement=0x03
# nvidia-drm modeset (通常已默认启用)
options nvidia-drm modeset=1
MODEOF

    if [ -f "$MODPROBE_FILE" ]; then
        echo "[*] $MODPROBE_FILE 已存在, 备份到 ${MODPROBE_FILE}.bak"
        cp "$MODPROBE_FILE" "${MODPROBE_FILE}.bak"
    fi
    cp /tmp/nvidia-power.conf "$MODPROBE_FILE" && echo "[OK] 写入 $MODPROBE_FILE"
    rm -f /tmp/nvidia-power.conf

    # 2. udev 规则
    local UDEV_FILE="/etc/udev/rules.d/80-nvidia-pm.rules"
    cat > /tmp/80-nvidia-pm.rules << 'UDEVEOF'
# NVIDIA GPU PCI 电源管理 - 允许自动挂起
SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{power/control}="auto"
UDEVEOF

    if [ -f "$UDEV_FILE" ]; then
        echo "[*] $UDEV_FILE 已存在, 备份"
        cp "$UDEV_FILE" "${UDEV_FILE}.bak"
    fi
    cp /tmp/80-nvidia-pm.rules "$UDEV_FILE" && echo "[OK] 写入 $UDEV_FILE"
    rm -f /tmp/80-nvidia-pm.rules

    # 3. 更新 initramfs (因为 nouveau 黑名单)
    echo ""
    echo -n "正在更新 initramfs..."
    update-initramfs -u 2>/dev/null && echo " 完成" || echo " 跳过"

    # 4. 重载 udev
    udevadm control --reload-rules 2>/dev/null && echo "[OK] udev 规则已重载"

    echo ""
    echo "==============================================="
    echo "  配置已安装, 请重启使 DynamicPowerManagement 生效"
    echo "  sudo reboot"
    echo "==============================================="
}

gpu_offload() {
    local app="$1"
    if [ -z "$app" ]; then
        echo "用法: sudo fan --gpu-offload <程序名>"
        echo "示例: sudo fan --gpu-offload glxinfo"
        exit 1
    fi
    shift
    echo "用 NVIDIA 独显运行: $app $*"
    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia "$app" "$@"
}

###############################################################################
# 综合状态
###############################################################################

show_all_status() {
    echo "========== 系统状态总览 =========="
    echo ""
    show_fan_status
    echo ""
    gpu_info
}

###############################################################################
# 主入口
###############################################################################

require_root

case "${1:-}" in
    # 风扇
    -l|--low)           set_fan "静音" 0x02 ;;
    -b|--balanced)      set_fan "平衡" 0x08 ;;
    -p|--perf)          set_fan "高性能" 0x10 ;;
    -a|--auto)          set_fan "自动" 0x15 ;;
    -c|--custom)
        if [ -z "${2:-}" ]; then
            echo "错误: -c 需要提供 FDAT 值"
            exit 1
        fi
        fdat_dec=$(parse_val "$2")
        if [ "$fdat_dec" -lt 0 ] || [ "$fdat_dec" -gt 255 ]; then
            echo "错误: FDAT 值必须在 0-255 之间"
            exit 1
        fi
        set_fan "自定义" "$fdat_dec"
        ;;
    -m|--monitor)       monitor_fan ;;

    # GPU
    --gpu-info)         gpu_info ;;
    --gpu-save)         gpu_save ;;
    --gpu-perf)         gpu_perf ;;
    --gpu-monitor)      gpu_monitor ;;
    --gpu-setup)        gpu_setup ;;
    --gpu-offload)
        shift
        gpu_offload "$@"
        ;;

    # 综合
    -s|--status)        show_all_status ;;

    # 帮助
    -h|--help|"")       usage ;;
    *)
        echo "错误: 未知选项 '$1'"
        usage
        ;;
esac
