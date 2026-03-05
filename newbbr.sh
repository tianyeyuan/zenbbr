#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 开启严格模式 (set -euo pipefail)
set -euo pipefail

#=================================================
#	System: CentOS 6/7, Debian 8+, Ubuntu 16+
#	Description: 一键全自动优化加速你的服务器
#	Version: 1.2.0
#=================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

sh_ver="1.2.0"
LOG_FILE="/var/log/zenbbr.log"

DRY_RUN=0
AUTO_YES=0
BBR_ONLY=0

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes|-y)
            AUTO_YES=1
            shift
            ;;
        --bbr-only)
            BBR_ONLY=1
            shift
            ;;
        --help|-h)
            echo "用法: bash newbbr.sh [选项]"
            echo "选项:"
            echo "  --dry-run   只检查不改动"
            echo "  --yes, -y   无人值守自动确认"
            echo "  --bbr-only  仅开启BBR，不做系统源和内核改动"
            echo "  --help, -h  显示此帮助信息"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

log_info() {
    echo -e "${GREEN}${1}${PLAIN}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $(echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo -e "${RED}${1}${PLAIN}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $(echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    echo -e "${YELLOW}${1}${PLAIN}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $(echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_FILE" 2>/dev/null || true
}

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    log_error "错误：请使用root用户运行此脚本"
    exit 1
fi

# 系统信息
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
elif [[ -f /etc/redhat-release ]]; then
    OS="centos"
    VER=$(grep -oE '[0-9]+' /etc/redhat-release | head -1 || true)
else
    log_error "不支持的系统"
    exit 1
fi

# 架构检测
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    ARCH_NAME="amd64"
else
    ARCH_NAME="$ARCH"
fi

log_info "检测到系统: $OS $VER ($ARCH)"

# ========== 基础工具函数 ==========

# 检查必要依赖并自动安装
check_dependencies() {
    log_info "检查系统依赖..."
    
    local PKG_MANAGER=""
    local PKG_INSTALL=""
    local DEPS=""

    if [[ "$OS" =~ centos|rhel|fedora ]]; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        DEPS="ca-certificates wget curl"
    elif [[ "$OS" =~ debian|ubuntu ]]; then
        PKG_MANAGER="apt-get"
        PKG_INSTALL="apt-get install -y"
        DEPS="ca-certificates wget curl"
    else
        log_warn "未知包管理器，跳过依赖检查"
        return 0
    fi
    
    local need_install=()
    for dep in $DEPS; do
        local installed=0
        if [[ "$dep" == "ca-certificates" ]]; then
            if rpm -q ca-certificates &>/dev/null || \
               dpkg -l ca-certificates 2>/dev/null | grep -q "^ii" || \
               [[ -f /etc/ssl/certs/ca-certificates.crt || -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
                installed=1
            fi
        else
            if command -v "$dep" &>/dev/null; then
                installed=1
            fi
        fi
        [[ $installed -eq 0 ]] && need_install+=("$dep")
    done
    
    if [[ ${#need_install[@]} -gt 0 ]]; then
        log_warn "缺少依赖: ${need_install[*]}"
        log_info "正在自动安装依赖..."
        
        if [[ $DRY_RUN -eq 1 ]]; then
            log_info "[DRY-RUN] 将执行: $PKG_INSTALL ${need_install[*]}"
            return 0
        fi
        
        if [[ "$OS" =~ centos|rhel|fedora ]]; then
            $PKG_INSTALL "${need_install[@]}" || true
            update-ca-trust force-enable 2>/dev/null || true
        elif [[ "$OS" =~ debian|ubuntu ]]; then
            apt-get update -qq || true
            $PKG_INSTALL "${need_install[@]}" || true
            update-ca-certificates 2>/dev/null || true
        fi
        
        if command -v curl &>/dev/null && command -v wget &>/dev/null; then
            log_info "依赖安装完成"
        else
            log_error "依赖安装失败，可能影响脚本运行"
        fi
    else
        log_info "所有依赖已安装"
    fi
}

# 检查虚拟化类型（返回全局变量 VIRT_TYPE）
VIRT_TYPE="unknown"
check_virt() {
    log_info "检查虚拟化类型..."
    
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE=$(systemd-detect-virt || true)
    elif command -v virt-what &>/dev/null; then
        VIRT_TYPE=$(virt-what | head -1 || true)
    else
        if grep -q "openvz" /proc/vz/version 2>/dev/null || grep -q "openvz" /proc/cpuinfo 2>/dev/null; then
            VIRT_TYPE="openvz"
        fi
    fi
    
    log_info "虚拟化类型: ${VIRT_TYPE}"
    
    if [[ "$VIRT_TYPE" == "openvz" ]]; then
        log_error "╔════════════════════════════════════════════╗"
        log_error "║  警告：检测到OpenVZ虚拟化                 ║"
        log_error "║  OpenVZ容器无法更换内核，无法启用BBR      ║"
        log_error "║  建议：更换为KVM/Xen虚拟化的VPS           ║"
        log_error "╚════════════════════════════════════════════╝"
        if [[ $AUTO_YES -eq 0 ]]; then
            local continue_openvz
            read -p "是否继续（可能失败）? [y/N]: " continue_openvz || true
            [[ ! "${continue_openvz:-N}" =~ ^[Yy]$ ]] && exit 1
        fi
    fi
}

# 检查/boot分区空间
check_boot_space() {
    log_info "检查/boot分区空间..."
    
    local boot_available
    boot_available=$(df -m /boot 2>/dev/null | tail -1 | awk '{print $4}' || true)
    
    if [[ -n "$boot_available" && "$boot_available" =~ ^[0-9]+$ ]]; then
        if [[ "$boot_available" -lt 100 ]]; then
            log_warn "警告：/boot分区空间不足 (可用: ${boot_available}MB)"
            log_warn "建议：先清理旧内核释放空间，或确保有至少100MB可用空间"
            if [[ $AUTO_YES -eq 0 ]]; then
                local continue_boot
                read -p "是否继续? [y/N]: " continue_boot || true
                [[ ! "${continue_boot:-N}" =~ ^[Yy]$ ]] && exit 1
            fi
        else
            log_info "/boot分区空间充足 (可用: ${boot_available}MB)"
        fi
    fi
}

# 检查网络连接
check_network() {
    log_info "检查网络连接..."
    
    local mirrors=(
        "https://mirrors.aliyun.com"
        "https://mirrors.163.com"
        "https://mirrors.tuna.tsinghua.edu.cn"
        "https://www.baidu.com"
    )
    
    for mirror in "${mirrors[@]}"; do
        if curl -I -s --max-time 10 "$mirror" > /dev/null 2>&1 || curl -s --max-time 10 "$mirror" > /dev/null 2>&1; then
            log_info "网络连接正常（${mirror}）"
            return 0
        fi
    done
    
    if ping -c 2 8.8.8.8 > /dev/null 2>&1; then
        log_warn "网络连接正常但HTTPS访问受限"
        return 0
    else
        log_error "网络连接失败，请检查网络设置。"
        return 1 || true
    fi
}

# 修复CentOS死源
fixCentOSRepo() {
    [[ ! "$OS" =~ centos ]] && return 0
    [[ "$VER" != "6" && "$VER" != "7" && "$VER" != "8" ]] && return 0
    
    if [[ $BBR_ONLY -eq 1 ]]; then
        log_warn "启用 --bbr-only 模式，跳过更换 CentOS 系统源。"
        return 0
    fi
    
    if [[ $AUTO_YES -eq 0 ]]; then
        echo -e "${YELLOW}检测到 CentOS ${VER}，官方源可能已停服。${PLAIN}"
        local change_repo
        read -p "是否需要切换到 Vault/阿里云 源以保证包管理器可用？[Y/n]: " change_repo || true
        [[ "${change_repo:-Y}" =~ ^[Nn]$ ]] && return 0
        
        echo -e "${YELLOW}警告：部分 Vault 源需要设置 gpgcheck=0，关闭 GPG 签名校验存在供应链安全风险。${PLAIN}"
        local confirm_risk
        read -p "是否知晓风险并确认继续？[Y/n]: " confirm_risk || true
        [[ "${confirm_risk:-Y}" =~ ^[Nn]$ ]] && return 0
    fi
    
    log_info "正在切换 CentOS ${VER} 源..."
    
    local backup_dir="/etc/yum.repos.d/backup_$(date +%s)"
    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] 会将现有 .repo 备份至 ${backup_dir} 并写入 Vault 源配置"
        return 0
    fi
    
    mkdir -p "$backup_dir"
    cp -rp /etc/yum.repos.d/*.repo "$backup_dir"/ 2>/dev/null || true
    mv /etc/yum.repos.d/CentOS-*.repo "$backup_dir"/ 2>/dev/null || true
    
    if [[ "$VER" == "7" ]]; then
        cat > /etc/yum.repos.d/CentOS-Vault.repo <<'EOF'
[base]
name=CentOS-7-Vault-Base
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/$basearch/
gpgcheck=0
enabled=1
[updates]
name=CentOS-7-Vault-Updates
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/$basearch/
gpgcheck=0
enabled=1
[extras]
name=CentOS-7-Vault-Extras
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/$basearch/
gpgcheck=0
enabled=1
EOF
    elif [[ "$VER" == "6" ]]; then
        cat > /etc/yum.repos.d/CentOS-Vault.repo <<'EOF'
[base]
name=CentOS-6-Vault-Base
baseurl=https://mirrors.aliyun.com/centos-vault/6.10/os/$basearch/
gpgcheck=0
enabled=1
[updates]
name=CentOS-6-Vault-Updates
baseurl=https://mirrors.aliyun.com/centos-vault/6.10/updates/$basearch/
gpgcheck=0
enabled=1
EOF
    elif [[ "$VER" == "8" ]]; then
        cat > /etc/yum.repos.d/CentOS-Vault.repo <<'EOF'
[baseos]
name=CentOS-8-Vault-BaseOS
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/BaseOS/$basearch/os/
gpgcheck=0
enabled=1
[appstream]
name=CentOS-8-Vault-AppStream
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/AppStream/$basearch/os/
gpgcheck=0
enabled=1
[extras]
name=CentOS-8-Vault-Extras
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/extras/$basearch/os/
gpgcheck=0
enabled=1
EOF
    fi
    yum clean all >/dev/null 2>&1 || true
    log_info "CentOS ${VER} Vault源配置已完成（原文件已备份至 ${backup_dir}）"
}

# ========== BBR 核心函数 ==========

check_bbr_status() {
    local param
    param=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || true)
    [[ "$param" == "bbr" ]]
}

# 获取内核信息（静默版本，不输出任何东西）
# 返回: 0=最佳(5.4+), 1=可用(4.9+), 2=不支持
get_kernel_bbr_level() {
    local kernel_version major minor
    kernel_version=$(uname -r | cut -d- -f1)
    major=$(echo "$kernel_version" | cut -d. -f1 || true)
    minor=$(echo "$kernel_version" | cut -d. -f2 || true)
    
    if [[ -z "$major" ]] || [[ -z "$minor" ]]; then
        return 2
    fi
    
    if [[ "$major" -gt 5 ]] || [[ "$major" -eq 5 && "$minor" -ge 4 ]]; then
        return 0
    elif [[ "$major" -eq 4 && "$minor" -ge 9 ]]; then
        return 1
    else
        return 2
    fi
}

# 带日志输出的内核检测
check_kernel_native_bbr() {
    local kernel_version major minor
    kernel_version=$(uname -r | cut -d- -f1)
    major=$(echo "$kernel_version" | cut -d. -f1 || true)
    minor=$(echo "$kernel_version" | cut -d. -f2 || true)
    
    if [[ -z "$major" ]] || [[ -z "$minor" ]]; then
        return 1
    fi
    
    if [[ "$major" -gt 5 ]] || [[ "$major" -eq 5 && "$minor" -ge 4 ]]; then
        log_info "当前内核 $kernel_version 原生支持BBR（最佳）"
        return 0
    elif [[ "$major" -eq 4 && "$minor" -ge 9 ]]; then
        log_warn "当前内核 $kernel_version 支持BBR（建议升级到5.4+）"
        return 0
    else
        log_error "当前内核 $kernel_version 不支持BBR，需要升级"
        return 1
    fi
}

enable_bbr() {
    if check_bbr_status; then
        log_info "BBR已经启用，无需执行额外配置"
        return 0
    fi
    
    if ! check_kernel_native_bbr; then
        log_warn "需要升级内核才能启用BBR"
        return 1
    fi
    
    log_info "正在配置 BBR..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] 将生成 /etc/sysctl.d/99-bbr.conf 并 sysctl -p 使其生效"
        return 0
    fi
    
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
# BBR配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 基础网络优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
EOF
    
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    
    if check_bbr_status; then
        log_info "╔════════════════════════════════════════════╗"
        log_info "║  BBR启用成功！                            ║"
        log_info "║  您的网络加速已生效                       ║"
        log_info "╚════════════════════════════════════════════╝"
        return 0
    else
        log_error "BBR启用失败，请检查内核版本"
        return 1
    fi
}

# ========== 智能诊断（核心决策引擎） ==========

smart_diagnose() {
    echo ""
    echo -e "${BLUE}╔═════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║              🔍 VPS 智能体检报告               ║${PLAIN}"
    echo -e "${BLUE}╚═════════════════════════════════════════════════╝${PLAIN}"
    echo ""
    
    # 第一层：收集信息
    local kernel_version congestion qdisc bbr_loaded bbr_enabled kernel_level
    kernel_version=$(uname -r)
    congestion=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || true)
    qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || true)
    bbr_loaded=0
    lsmod | grep -q bbr && bbr_loaded=1
    bbr_enabled=0
    check_bbr_status && bbr_enabled=1
    
    # 获取内核级别
    kernel_level=2
    get_kernel_bbr_level && kernel_level=0 || kernel_level=$?
    
    echo -e "  ${GREEN}系统${PLAIN}          $OS $VER ($ARCH)"
    echo -e "  ${GREEN}内核${PLAIN}          $kernel_version"
    echo -e "  ${GREEN}虚拟化${PLAIN}        $VIRT_TYPE"
    echo -e "  ${GREEN}拥塞算法${PLAIN}      ${congestion:-未设置}"
    echo -e "  ${GREEN}队列算法${PLAIN}      ${qdisc:-未设置}"
    echo -e "  ${GREEN}BBR模块${PLAIN}        $([ $bbr_loaded -eq 1 ] && echo '✅ 已加载' || echo '❌ 未加载')"
    echo -e "  ${GREEN}BBR状态${PLAIN}        $([ $bbr_enabled -eq 1 ] && echo '✅ 已启用' || echo '❌ 未启用')"
    echo ""
    
    # 第二层：三层决策判断
    echo -e "${BLUE}────────── 诊断结论 ──────────${PLAIN}"
    echo ""
    
    # A. 已启用且正常
    if [[ $bbr_enabled -eq 1 && $bbr_loaded -eq 1 ]]; then
        echo -e "  ${GREEN}✅ BBR 已正常运行，无需任何操作！${PLAIN}"
        echo ""
        echo -e "  当前状态最优，拥塞算法=${GREEN}bbr${PLAIN}，模块已加载。"
        echo -e "  您的网络已在最佳加速状态。"
        echo ""
        return 0
    fi
    
    if [[ $bbr_enabled -eq 1 && $bbr_loaded -eq 0 ]]; then
        echo -e "  ${YELLOW}⚠️  BBR 已配置但模块未加载${PLAIN}"
        echo ""
        echo -e "  sysctl 配置显示 bbr，但 lsmod 未检测到 tcp_bbr 模块。"
        echo -e "  建议：重启系统后重新检查，或选择菜单 2 重新启用。"
        echo ""
        return 0
    fi
    
    # B. 内核支持但未启用
    if [[ $kernel_level -le 1 && $bbr_enabled -eq 0 ]]; then
        echo -e "  ${GREEN}✅ 推荐启用 BBR${PLAIN}"
        echo ""
        if [[ $kernel_level -eq 0 ]]; then
            echo -e "  当前内核 ${GREEN}${kernel_version}${PLAIN} 完美支持 BBR（5.4+最佳版本）。"
        else
            echo -e "  当前内核 ${YELLOW}${kernel_version}${PLAIN} 支持 BBR（4.9+ 基础支持）。"
        fi
        echo -e "  ${GREEN}只需一步配置即可启用，无需升级内核，零风险。${PLAIN}"
        echo ""
        
        if [[ $AUTO_YES -eq 1 ]]; then
            echo -e "  ${BLUE}[--yes] 自动执行启用...${PLAIN}"
            enable_bbr || true
        else
            local do_enable
            read -p "  是否立即启用 BBR？[Y/n]: " do_enable || true
            if [[ "${do_enable:-Y}" =~ ^[Yy]$ ]]; then
                enable_bbr || true
            fi
        fi
        return 0
    fi
    
    # C. 内核不支持 → 收益评估
    if [[ $kernel_level -eq 2 ]]; then
        echo -e "  ${YELLOW}⚠️  当前内核不支持 BBR，需要评估升级收益${PLAIN}"
        echo ""
        echo -e "  当前内核 ${RED}${kernel_version}${PLAIN} 版本过低（需要 4.9+）。"
        echo ""
        
        # 收益评估
        echo -e "${BLUE}────────── 收益评估 ──────────${PLAIN}"
        echo ""
        
        local benefit_score=0
        local benefit_reasons=()
        local risk_reasons=()
        
        # 高延迟场景判断（通过 ping 外部服务器）
        local avg_rtt
        avg_rtt=$(ping -c 3 -W 3 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print int($5)}' || echo "0")
        if [[ "$avg_rtt" -gt 100 ]]; then
            benefit_score=$((benefit_score + 3))
            benefit_reasons+=("高延迟环境 (RTT≈${avg_rtt}ms)，BBR 可提升 30-50% 吞吐量")
        elif [[ "$avg_rtt" -gt 30 ]]; then
            benefit_score=$((benefit_score + 1))
            benefit_reasons+=("中等延迟环境 (RTT≈${avg_rtt}ms)，BBR 有一定提升")
        else
            benefit_reasons+=("低延迟环境 (RTT≈${avg_rtt}ms)，BBR 提升可能不明显")
        fi
        
        # 虚拟化类型
        if [[ "$VIRT_TYPE" == "openvz" ]]; then
            risk_reasons+=("OpenVZ 虚拟化无法更换内核，升级必定失败")
        elif [[ "$VIRT_TYPE" == "kvm" || "$VIRT_TYPE" == "none" ]]; then
            benefit_score=$((benefit_score + 1))
            benefit_reasons+=("虚拟化类型 ($VIRT_TYPE) 完全支持内核升级")
        fi
        
        # 系统兼容性
        if [[ "$OS" =~ debian|ubuntu ]]; then
            benefit_score=$((benefit_score + 2))
            benefit_reasons+=("$OS 系统内核升级成熟稳定，风险极低")
        elif [[ "$OS" =~ centos ]]; then
            if [[ -n "$VER" && "$VER" -ge 8 ]] 2>/dev/null; then
                risk_reasons+=("CentOS 8+ 已停服，升级内核风险极高，强烈不推荐")
            elif [[ "$VER" == "7" ]]; then
                benefit_score=$((benefit_score + 1))
                benefit_reasons+=("CentOS 7 可通过 ELRepo 升级，有一定风险但可行")
            else
                risk_reasons+=("CentOS $VER 版本过旧，升级内核风险较高")
            fi
        fi
        
        # 输出评估条目
        for reason in "${benefit_reasons[@]}"; do
            echo -e "  ${GREEN}＋${PLAIN} $reason"
        done
        for reason in "${risk_reasons[@]}"; do
            echo -e "  ${RED}－${PLAIN} $reason"
        done
        echo ""
        
        # 给出总结性建议
        echo -e "${BLUE}────────── 操作建议 ──────────${PLAIN}"
        echo ""
        
        if [[ ${#risk_reasons[@]} -gt 0 && "$VIRT_TYPE" == "openvz" ]]; then
            echo -e "  ${RED}❌ 不建议操作${PLAIN}"
            echo -e "  OpenVZ 虚拟化无法更换内核，BBR 无法启用。"
            echo -e "  建议更换为 KVM/Xen 虚拟化的 VPS。"
        elif [[ "$OS" =~ centos ]] && [[ -n "$VER" && "$VER" -ge 8 ]] 2>/dev/null; then
            echo -e "  ${RED}❌ 不建议操作${PLAIN}"
            echo -e "  CentOS 8+ 已停服，升级内核极易导致系统损坏。"
            echo -e "  强烈建议迁移到 Ubuntu 22.04+ 或 Debian 12+ 后再操作。"
        elif [[ $benefit_score -ge 4 ]]; then
            echo -e "  ${GREEN}✅ 推荐升级内核并启用 BBR${PLAIN}"
            echo -e "  您的环境能从 BBR 获得明显收益，且升级风险可控。"
            echo -e "  请选择菜单 ${GREEN}3${PLAIN} 进行内核升级。"
        elif [[ $benefit_score -ge 2 ]]; then
            echo -e "  ${YELLOW}⚠️  可选操作（收益不确定）${PLAIN}"
            echo -e "  BBR 可能带来一定提升，但也需承担内核升级的风险。"
            echo -e "  如果是生产环境，建议先在测试机上验证。"
            echo -e "  如确定要升级，请选择菜单 ${YELLOW}3${PLAIN}。"
        else
            echo -e "  ${YELLOW}⚠️  不建议折腾${PLAIN}"
            echo -e "  当前网络环境下 BBR 的收益可能不明显。"
            echo -e "  升级内核存在一定风险，建议维持现状。"
        fi
        echo ""
        return 0
    fi
}

# ========== 内核升级函数 ==========

upgrade_kernel_debian() {
    log_info "正在为 $OS $VER 验证内核状态..."
    
    local current_kernel major minor
    current_kernel=$(uname -r | cut -d- -f1)
    major=$(echo "$current_kernel" | cut -d. -f1 || true)
    minor=$(echo "$current_kernel" | cut -d. -f2 || true)
    
    if [[ -n "$major" ]] && [[ -n "$minor" ]]; then
        if [[ "$major" -gt 5 ]] || [[ "$major" -eq 5 && "$minor" -ge 4 ]]; then
            log_info "当前内核 $current_kernel 已是最新并支持BBR，无需升级"
            enable_bbr || true
            return 0
        fi
    fi
    
    if [[ $BBR_ONLY -eq 1 ]]; then
        log_warn "启用 --bbr-only 模式，拒绝更换 apt 源及升级内核。"
        return 0
    fi
    
    local change_repo="Y"
    if [[ $AUTO_YES -eq 0 ]]; then
        read -p "是否切换到国内镜像源加速内核下载？[Y/n]: " change_repo || true
        change_repo=${change_repo:-Y}
    fi
    
    if [[ "$change_repo" =~ ^[Yy]$ ]]; then
        log_info "备份当前 apt 源并切换为国内阿里云镜像..."
        local backup_suffix="bak_$(date +%s)"
        
        if [[ $DRY_RUN -eq 1 ]]; then
            log_info "[DRY-RUN] 会备份 /etc/apt/sources.list 及 sources.list.d 下的文件，并替换 url"
        else
            cp /etc/apt/sources.list "/etc/apt/sources.list.${backup_suffix}" 2>/dev/null || true
            if [[ "$OS" == "ubuntu" ]]; then
                sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null || true
                sed -i 's|http://security.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null || true
            elif [[ "$OS" == "debian" ]]; then
                sed -i 's|http://deb.debian.org|https://mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null || true
                sed -i 's|http://security.debian.org|https://mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null || true
            fi
            
            # 兼容 Debian 12+ 的 .sources 格式
            if [[ -d /etc/apt/sources.list.d ]]; then
                find /etc/apt/sources.list.d/ -type f \( -name "*.list" -o -name "*.sources" \) | while read -r f; do
                    cp "$f" "${f}.${backup_suffix}" 2>/dev/null || true
                    sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g' "$f" 2>/dev/null || true
                    sed -i 's|http://security.ubuntu.com|https://mirrors.aliyun.com|g' "$f" 2>/dev/null || true
                    sed -i 's|http://deb.debian.org|https://mirrors.aliyun.com|g' "$f" 2>/dev/null || true
                    sed -i 's|http://security.debian.org|https://mirrors.aliyun.com|g' "$f" 2>/dev/null || true
                done
            fi
        fi
    fi
    
    log_info "更新软件包列表并准备安装..."
    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] 执行 apt-get update 及 apt-get install 对应内核包"
        return 0
    fi
    
    apt-get update -qq || true
    
    local DPKG_ARCH
    DPKG_ARCH=$(dpkg --print-architecture)
    
    set +e
    if [[ "$OS" == "ubuntu" ]]; then
        if [[ "$VER" =~ ^(20|22|24) ]]; then
            log_info "安装最新 generic 内核..."
            apt-get install -y linux-generic
        elif [[ "$VER" == "18" ]]; then
            log_info "安装 HWE 内核(5.4)..."
            apt-get install -y --install-recommends linux-generic-hwe-18.04
        else
            log_info "安装 HWE 内核..."
            apt-get install -y --install-recommends linux-generic-hwe-16.04 2>/dev/null || \
            apt-get install -y linux-generic
        fi
    elif [[ "$OS" == "debian" ]]; then
        log_info "安装最新内核（架构: $DPKG_ARCH）..."
        apt-get install -y "linux-image-$DPKG_ARCH"
    fi
    local ret=$?
    set -e
    
    if [[ $ret -eq 0 ]]; then
        log_info "╔════════════════════════════════════════════╗"
        log_info "║  内核升级完成！                           ║"
        log_info "║  需要重启系统才能使用新内核               ║"
        log_info "║  重启后再次运行脚本选 1 即可启用 BBR      ║"
        log_info "╚════════════════════════════════════════════╝"
        return 0
    else
        log_error "内核升级失败"
        return 1
    fi
}

upgrade_kernel_centos() {
    if [[ -n "$VER" && "$VER" -ge 8 ]] 2>/dev/null; then
        echo ""
        log_error "╔══════════════════════════════════════════════════════╗"
        log_error "║      ⚠  不支持 CentOS ${VER} 及以上版本升级内核        ║"
        log_error "╠══════════════════════════════════════════════════════╣"
        log_error "║  CentOS 8+ 官方已停止维护，ELRepo 支持不稳定，      ║"
        log_error "║  强行升级内核极易导致系统损坏或无法启动。            ║"
        log_error "║                                                      ║"
        log_info  "║  推荐更换为以下系统后再使用本脚本：                 ║"
        log_info  "║    ✔  Ubuntu 20.04 / 22.04 / 24.04               ║"
        log_info  "║    ✔  Debian 10 / 11 / 12                        ║"
        log_info  "║                                                      ║"
        log_info  "║  如需继续使用 CentOS，可考虑迁移到：               ║"
        log_info  "║    ✔  Rocky Linux 8/9  （CentOS 官方替代品）      ║"
        log_info  "║    ✔  AlmaLinux 8/9                               ║"
        log_error "╚══════════════════════════════════════════════════════╝"
        echo ""
        if [[ $AUTO_YES -eq 0 ]]; then
            local key
            read -n1 -rp "按任意键继续..." key || true
        fi
        return 1
    fi

    log_info "正在为 CentOS $VER 检测内核并准备升级..."
    
    local current_kernel major minor
    current_kernel=$(uname -r | cut -d- -f1)
    major=$(echo "$current_kernel" | cut -d. -f1 || true)
    minor=$(echo "$current_kernel" | cut -d. -f2 || true)
    
    if [[ -n "$major" ]] && [[ -n "$minor" ]]; then
        if [[ "$major" -gt 5 ]] || [[ "$major" -eq 5 && "$minor" -ge 4 ]]; then
            log_info "当前内核 $current_kernel 已支持BBR，无需额外升级"
            enable_bbr || true
            return 0
        fi
    fi
    
    fixCentOSRepo
    
    if [[ "$VER" == "7" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            log_info "[DRY-RUN] 将会安装 elrepo 源, yum 下载内核, 生成正确环境的 grub.cfg"
            return 0
        fi
        
        log_info "配置yum参数（防止下载超时）..."
        grep -q "^timeout=" /etc/yum.conf || echo "timeout=30" >> /etc/yum.conf
        grep -q "^retries=" /etc/yum.conf || echo "retries=3" >> /etc/yum.conf
        
        log_info "安装ELRepo源..."
        rpm --import https://mirrors.aliyun.com/elrepo/RPM-GPG-KEY-elrepo.org 2>/dev/null || \
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org || true
        
        yum install -y https://mirrors.aliyun.com/elrepo/elrepo/el7/x86_64/RPMS/elrepo-release-7.0-6.el7.elrepo.noarch.rpm 2>/dev/null || \
        yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm || true
        
        log_info "清理yum缓存..."
        yum clean all || true
        
        log_warn "╔════════════════════════════════════════════════════╗"
        log_warn "║  正在下载内核（6.x），文件较大约150-200MB        ║"
        log_warn "║  预计需要3-10分钟，请耐心等待...                  ║"
        log_warn "║  脚本会自动重试，如长时间无进度可Ctrl+C中断      ║"
        log_warn "╚════════════════════════════════════════════════════╝"
        echo ""
        
        local attempt=1
        local max_attempts=3
        local success=0
        
        while [[ $attempt -le $max_attempts ]]; do
            log_info "尝试安装内核 (第 $attempt/$max_attempts 次)..."
            
            set +e
            yum --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel
            local install_ret=$?
            set -e
            
            if [[ $install_ret -eq 0 ]]; then
                success=1
                break
            else
                log_error "安装失败，准备重试..."
                yum clean all || true
                attempt=$((attempt + 1))
                [[ $attempt -le $max_attempts ]] && sleep 3
            fi
        done
        
        if [[ $success -eq 1 ]]; then
            log_info "配置GRUB启动项..."
            
            local grub_cfg="/boot/grub2/grub.cfg"
            if [[ -d /sys/firmware/efi ]]; then
                if [[ -f /boot/efi/EFI/centos/grub.cfg ]]; then
                    grub_cfg="/boot/efi/EFI/centos/grub.cfg"
                elif [[ -f /boot/efi/EFI/redhat/grub.cfg ]]; then
                    grub_cfg="/boot/efi/EFI/redhat/grub.cfg"
                fi
            fi
            
            grub2-set-default 0 || true
            grub2-mkconfig -o "$grub_cfg" || true
            
            log_info "╔════════════════════════════════════════════╗"
            log_info "║  内核升级完成！                           ║"
            log_info "║  需要重启系统才能使用新内核               ║"
            log_info "║  重启后再次运行脚本选 1 即可启用 BBR      ║"
            log_info "╚════════════════════════════════════════════╝"
            return 0
        else
            log_error "╔═══════════════════════════════════════════════════╗"
            log_error "║  内核升级失败（尝试${max_attempts}次后仍失败）    ║"
            log_error "║                                                   ║"
            log_error "║  建议手动操作：                                   ║"
            log_error "║  1. yum clean all                                 ║"
            log_error "║  2. yum --enablerepo=elrepo-kernel install -y kernel-ml ║"
            log_error "║                                                   ║"
            log_error "║  或者考虑升级到 Rocky Linux / AlmaLinux           ║"
            log_error "╚═══════════════════════════════════════════════════╝"
            return 1
        fi
    else
        log_error "CentOS $VER 不支持自动升级内核"
        return 1
    fi
}

# 升级内核（统一入口，自动判断发行版）
upgrade_kernel() {
    echo ""
    log_warn "╔════════════════════════════════════════════════════╗"
    log_warn "║  ⚠  内核升级为高风险操作，请确认以下事项：       ║"
    log_warn "║  1. 已备份重要数据                               ║"
    log_warn "║  2. 有 VNC/IPMI 等带外管理方式可恢复             ║"
    log_warn "║  3. 非关键业务高峰期                             ║"
    log_warn "╚════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ $AUTO_YES -eq 0 ]]; then
        local confirm_upgrade
        read -p "确认要升级内核？[y/N]: " confirm_upgrade || true
        if [[ ! "${confirm_upgrade:-N}" =~ ^[Yy]$ ]]; then
            log_warn "已取消内核升级"
            return 0
        fi
    fi
    
    check_boot_space
    
    if [[ "$OS" =~ debian|ubuntu ]]; then
        upgrade_kernel_debian || true
    elif [[ "$OS" =~ centos|rhel ]]; then
        upgrade_kernel_centos || true
    else
        log_error "当前系统 $OS 不支持自动升级内核"
        return 1
    fi
    
    local reboot_now="N"
    if [[ $AUTO_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
        read -p "是否现在重启系统? [y/N]: " reboot_now || true
        reboot_now=${reboot_now:-N}
    fi
    [[ "$reboot_now" =~ ^[Yy]$ ]] && reboot
}

# ========== 旧内核清理 ==========

remove_old_kernels() {
    log_info "检测并尝试卸载旧内核..."
    
    if [[ "$OS" =~ centos|rhel ]]; then
        local installed_kernels kernel_count
        installed_kernels=$(rpm -qa | grep ^kernel-[0-9] | sort -V || true)
        kernel_count=$(echo "$installed_kernels" | grep -c . || echo 0)
        
        if [[ "$kernel_count" -gt 2 ]]; then
            log_info "发现 $kernel_count 个内核，将仅保留最新2个"
            log_warn "将要删除的较低版本内核："
            echo "$installed_kernels" | head -n -2
            
            local confirm_remove="Y"
            if [[ $AUTO_YES -eq 0 ]]; then
                read -p "确认删除这些旧内核？[y/N]: " confirm_remove || true
                confirm_remove=${confirm_remove:-N}
            fi
            
            if [[ "$confirm_remove" =~ ^[Yy]$ ]]; then
                local old_kernels
                old_kernels=$(echo "$installed_kernels" | head -n -2)
                if [[ -n "$old_kernels" ]]; then
                    if [[ $DRY_RUN -eq 1 ]]; then
                        log_info "[DRY-RUN] 将删除: ${old_kernels}"
                    else
                        echo "$old_kernels" | xargs yum remove -y || true
                        log_info "旧内核清理完成"
                    fi
                fi
            else
                log_warn "取消卸载操作"
            fi
        else
            log_info "无需清理旧内核（当前: $kernel_count 个）"
        fi
    elif [[ "$OS" =~ debian|ubuntu ]]; then
        local current_kernel installed_kernels
        current_kernel=$(uname -r)
        installed_kernels=$(dpkg -l | awk '/^ii  linux-image-[0-9]/ {print $2}' || true)
        
        log_warn "当前运行内核: $current_kernel"
        log_warn "系统中已发现的内核："
        echo "$installed_kernels"
        
        local confirm_remove="Y"
        if [[ $AUTO_YES -eq 0 ]]; then
            read -p "是否清理非当前运行的所有旧内核？[y/N]: " confirm_remove || true
            confirm_remove=${confirm_remove:-N}
        fi
        
        if [[ "$confirm_remove" =~ ^[Yy]$ ]]; then
            for kernel in $installed_kernels; do
                if [[ "$kernel" != *"$current_kernel"* ]]; then
                    if [[ $DRY_RUN -eq 1 ]]; then
                        log_info "[DRY-RUN] 将移除旧内核: $kernel"
                    else
                        log_info "正在移除内核: $kernel"
                        apt-get purge -y "$kernel" 2>/dev/null || true
                    fi
                fi
            done
            if [[ $DRY_RUN -eq 0 ]]; then
                apt-get autoremove -y || true
                log_info "旧内核清理完成"
            fi
        else
            log_warn "取消卸载操作"
        fi
    fi
}

# ========== 状态显示 ==========

show_status() {
    echo -e "\n${BLUE}==================== 系统状态 ====================${PLAIN}"
    echo -e "${GREEN}系统:${PLAIN} $OS $VER"
    echo -e "${GREEN}架构:${PLAIN} $ARCH"
    echo -e "${GREEN}内核:${PLAIN} $(uname -r)"
    
    if check_bbr_status; then
        echo -e "${GREEN}BBR状态:${PLAIN} ✅ 已启用"
    else
        echo -e "${GREEN}BBR状态:${PLAIN} ❌ 未启用"
    fi
    
    if lsmod | grep -q bbr; then
        echo -e "${GREEN}BBR模块:${PLAIN} ✅ 已加载"
    else
        echo -e "${GREEN}BBR模块:${PLAIN} ❌ 未加载"
    fi
    
    local qdisc congestion
    qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || true)
    echo -e "${GREEN}队列算法:${PLAIN} ${qdisc:-未设置}"
    
    congestion=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || true)
    echo -e "${GREEN}拥塞算法:${PLAIN} ${congestion:-未设置}"
    
    echo -e "${BLUE}=================================================${PLAIN}\n"
}

# ========== 主菜单（while 循环，非递归） ==========

show_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔═════════════════════════════════════════════════╗${PLAIN}"
        echo -e "${BLUE}║       BBR一键加速脚本 v${sh_ver}               ║${PLAIN}"
        echo -e "${BLUE}║       智能诊断 · 按需加速 · 安全可控           ║${PLAIN}"
        echo -e "${BLUE}╚═════════════════════════════════════════════════╝${PLAIN}"
        echo ""
        echo -e " ${GREEN}1.${PLAIN} 🔍 智能诊断 ${YELLOW}(推荐 — 先体检再决定)${PLAIN}"
        echo -e " ${GREEN}2.${PLAIN} ⚡ 仅启用BBR ${YELLOW}(内核已支持时零风险)${PLAIN}"
        echo -e " ${GREEN}3.${PLAIN} 🔧 升级内核后启用BBR ${RED}(高风险)${PLAIN}"
        echo -e " ${GREEN}4.${PLAIN} 🧹 清理旧内核 ${YELLOW}(释放/boot空间)${PLAIN}"
        echo -e " ${GREEN}5.${PLAIN} 📊 查看状态"
        echo " ─────────────"
        echo -e " ${GREEN}0.${PLAIN} 退出"
        echo ""
        
        local choice
        read -p " 请选择操作 [0-5]: " choice || true
        choice=${choice:-0}
        
        case $choice in
            1)
                smart_diagnose
                ;;
            2)
                if check_kernel_native_bbr; then
                    enable_bbr || true
                else
                    log_warn "当前内核不支持BBR，请先选择 1 进行智能诊断评估"
                fi
                ;;
            3)
                upgrade_kernel
                ;;
            4)
                remove_old_kernels || true
                ;;
            5)
                show_status
                ;;
            0)
                log_info "感谢使用！日志详见 $LOG_FILE"
                exit 0
                ;;
            *)
                log_error "无效选择，请输入 0-5 之间的数字"
                ;;
        esac
        
        echo ""
        if [[ $AUTO_YES -eq 0 ]]; then
            read -p " 按回车键返回主菜单..." || true
        else
            sleep 2
        fi
    done
}

# ========== 脚本入口 ==========

echo -e "${BLUE}╔═════════════════════════════════════════════════╗${PLAIN}"
echo -e "${BLUE}║            执行初始检测...                      ║${PLAIN}"
echo -e "${BLUE}╚═════════════════════════════════════════════════╝${PLAIN}"
echo ""

check_dependencies || true
check_network || true
check_virt || true
fixCentOSRepo || true

echo ""
log_info "系统预检完成！"
sleep 1

# 命令行自动化模式
if [[ $DRY_RUN -eq 1 || $AUTO_YES -eq 1 || $BBR_ONLY -eq 1 ]]; then
    log_info "当前使用命令行参数模式 [--dry-run / --yes / --bbr-only]"
    log_info "自动执行智能诊断..."
    smart_diagnose
    exit 0
fi

# 交互式菜单
show_menu
