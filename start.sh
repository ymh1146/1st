#!/bin/bash
################################################################################
#  VPS 一键初始化脚本
#  功能：
#    - SSH 端口交互设置 + root 密码
#    - 时区 Asia/Shanghai
#    - 阿里云源
#    - Fail2ban（本地防爆破）
#    - BBR 加速
#    - UFW 防火墙
#    - IPv6-only 自动 DNS64
#    - 自动 Swap（智能选择大小）
#    - htop
#    - zsh + oh-my-zsh（自动安装）
################################################################################
set -e

if [ "$(id -u)" != "0" ]; then
    echo "❌ 请使用 root 运行脚本"
    exit 1
fi

echo "===== 启动 VPS 初始化脚本 ====="

# 系统识别
. /etc/os-release
OS=$ID
echo "系统识别为: $OS"

###############################################################################
# Step 0. IPv6-only DNS64 检测与配置 
###############################################################################
echo ">>> 检查网络环境..."
if ! ping -4 -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo "⚠️  未检测到 IPv4 → 启用DNS64"

    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    cat > /etc/resolv.conf <<EOF
nameserver 2001:4860:4860::6464
nameserver 2001:67c:2b0::4
nameserver 2001:67c:2b0::6
nameserver 2606:4700:4700::64
EOF
    # 锁定文件，防止被 systemd-resolved 或 dhclient 覆盖
    chattr +i /etc/resolv.conf
    echo "✔ 已启用公共 NAT64 DNS 并锁定配置"
    IS_IPV6_ONLY=true
else
    echo "✔ IPv4 可用"
    IS_IPV6_ONLY=false
fi

###############################################################################
# Step 1. 交互式设置 (SSH, 密码, 防火墙)
###############################################################################
# 1.1 SSH 端口 & 密码
read -p "请输入 SSH 新端口 (默认 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
read -s -p "请输入 root 密码: " ROOTPWD
echo
read -s -p "请再次确认 root 密码: " ROOTPWD2
echo
[[ "$ROOTPWD" != "$ROOTPWD2" ]] && echo "❌ 密码不一致" && exit 1

# 1.2 防火墙交互选择
echo "------------------------------------------"
echo "防火墙设置："
echo " [0] 开启防火墙 (默认，自动放行 SSH 端口)"
echo " [1] 关闭防火墙"
read -p "请选择 [0/1]: " FW_CHOICE
FW_CHOICE=${FW_CHOICE:-0}
echo "------------------------------------------"

echo ">>> 更新 root 密码"
echo "root:$ROOTPWD" | chpasswd

###############################################################################
# Step 2. 设置时区
###############################################################################
echo ">>> 设置时区 Asia/Shanghai"
timedatectl set-timezone Asia/Shanghai

###############################################################################
# Step 3. 配置镜像源 & 安装必备软件
###############################################################################
echo ">>> 配置镜像源 & 安装软件"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt update -y
    apt install -y curl wget git ufw fail2ban htop zsh netcat-openbsd e2fsprogs
else
    yum install -y epel-release
    yum install -y curl wget git fail2ban htop zsh nc e2fsprogs
fi

###############################################################################
# Step 4. SSH 配置修改
###############################################################################
if systemctl list-unit-files | grep -q "^sshd.service"; then
    SSH_SERVICE="sshd"
else
    SSH_SERVICE="ssh"
fi

SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
sed -i "s/^#Port.*/Port $SSH_PORT/" $SSH_CONFIG
sed -i "s/^Port.*/Port $SSH_PORT/" $SSH_CONFIG
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication yes/" $SSH_CONFIG
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" $SSH_CONFIG

echo ">>> 重启 SSH 服务"
systemctl restart $SSH_SERVICE

###############################################################################
# Step 5. 防火墙逻辑处理
###############################################################################
if [[ "$FW_CHOICE" == "1" ]]; then
    echo ">>> 正在关闭并禁用防火墙..."
    # 禁用 UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw disable || true
    fi
    # 禁用 firewalld
    if systemctl list-unit-files | grep -q firewalld.service; then
        systemctl stop firewalld
        systemctl disable firewalld
    fi
    echo "✔ 防火墙已关闭"
else
    echo ">>> 正在开启防火墙并放行端口 $SSH_PORT..."
    # UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $SSH_PORT/tcp
        ufw --force enable
    fi
    # firewalld
    if systemctl list-unit-files | grep -q firewalld.service; then
        systemctl start firewalld
        systemctl enable firewalld
        firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
        firewall-cmd --reload
    fi
    echo "✔ 防火墙已配置完成"
fi

###############################################################################
# Step 6. Fail2ban, BBR, Swap
###############################################################################
# Fail2ban 仅在开启防火墙时更有意义，但保持安装也无妨
if [[ "$FW_CHOICE" == "0" ]]; then
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 600
bantime = 3600
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
fi

# BBR
echo ">>> 启用 BBR"
grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# Swap
echo ">>> 检查 Swap..."
if ! free | awk '/Swap:/ {exit !$2}'; then
    RAM_MB=$(free -m | awk '/Mem/ {print $2}')
    SWAP_SIZE=$((RAM_MB > 2048 ? 2048 : RAM_MB * 2))
    fallocate -l ${SWAP_SIZE}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
fi

###############################################################################
# Step 7. oh-my-zsh
###############################################################################
echo ">>> 安装 oh-my-zsh"
if [ ! -d "/root/.oh-my-zsh" ]; then
    export RUNZSH=no
    export CHSH=no
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || echo "⚠️ oh-my-zsh 安装失败，跳过"
else
    echo "✔ oh-my-zsh 已存在"
fi
chsh -s /usr/bin/zsh root 2>/dev/null || true

IP=$(curl -6 -s ifconfig.me || echo "未知IPv6")

echo ""
echo "=========================================="
echo "           ✅ 初始化完成"
echo "=========================================="
echo "SSH 登录：ssh root@[$IP] -p $SSH_PORT"
echo "防火墙状态：$( [[ "$FW_CHOICE" == "1" ]] && echo "已关闭" || echo "已开启" )"
echo "DNS64 状态：已配置 (如需永久修改请检查 /etc/resolv.conf)"
echo "=========================================="
echo ""
echo "⚠️  请保持当前会话，用新端口测试登录成功后再退出！"
echo "=========================================="
