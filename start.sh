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
echo "===== 启动安全版 VPS 初始化脚本 ====="
# 系统识别
. /etc/os-release
OS=$ID
echo "系统识别为: $OS"
###############################################################################
# Step 0. 【最先执行】IPv6-only DNS64 检测与配置
###############################################################################
echo ">>> 检查网络环境..."
if ! ping -4 -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo "⚠️ 未检测到 IPv4 → 启用公共 NAT64 网关"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<EOF
nameserver 2001:67c:2b0::4
nameserver 2001:67c:27e4::64
nameserver 2606:4700:4700::64
EOF
    # 临时锁定，防止被 systemd-resolved 覆盖
    chattr +i /etc/resolv.conf
    echo "✔ 已启用公共 NAT64 DNS"
    IS_IPV6_ONLY=true
else
    echo "✔ IPv4 可用"
    IS_IPV6_ONLY=false
fi
###############################################################################
# Step 1. SSH 端口 & 密码输入
###############################################################################
read -p "请输入 SSH 新端口（如 2288）: " SSH_PORT
[[ -z "$SSH_PORT" ]] && echo "❌ 端口不能为空" && exit 1
read -s -p "请输入 root 密码: " ROOTPWD
echo
read -s -p "请再次确认 root 密码: " ROOTPWD2
echo
[[ "$ROOTPWD" != "$ROOTPWD2" ]] && echo "❌ 密码不一致" && exit 1
echo ">>> 更新 root 密码"
echo "root:$ROOTPWD" | chpasswd
###############################################################################
# Step 2. 设置时区
###############################################################################
echo ">>> 设置时区 Asia/Shanghai"
timedatectl set-timezone Asia/Shanghai
###############################################################################
# Step 3. 配置镜像源（IPv6 兼容）
###############################################################################
echo ">>> 配置镜像源 & 更新系统 & 安装软件"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
    CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
    if [[ "$IS_IPV6_ONLY" == "true" ]]; then
        # 使用官方源（支持 IPv6）
        echo ">>> 使用 Debian/Ubuntu 官方源（支持 IPv6）"
        if [[ "$OS" == "debian" ]]; then
            cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian/ ${CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ ${CODENAME}-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security/ ${CODENAME}-security main contrib non-free-firmware
EOF
        else
            cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF
        fi
    else
        # IPv4 可用，使用阿里云源
        echo ">>> 使用阿里云源"
        cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME} main restricted universe multiverse
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME}-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME}-security main restricted universe multiverse
EOF
    fi
    apt update -y
    apt install -y curl wget git ufw fail2ban htop zsh netcat-openbsd
else
    yum install -y epel-release
    yum install -y curl wget git fail2ban htop zsh nc
fi
###############################################################################
# Step 4. 自动检测 SSH 服务名
###############################################################################
if systemctl list-unit-files | grep -q "^sshd.service"; then
    SSH_SERVICE="sshd"
else
    SSH_SERVICE="ssh"
fi
echo "SSH 服务名为: $SSH_SERVICE"
###############################################################################
# Step 5. 修改 SSH 配置 + 回滚保护
###############################################################################
SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
sed -i "s/^#Port.*/Port $SSH_PORT/" $SSH_CONFIG
sed -i "s/^Port.*/Port $SSH_PORT/" $SSH_CONFIG
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication yes/" $SSH_CONFIG
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" $SSH_CONFIG
echo ">>> 重启 SSH 服务"
if ! systemctl restart $SSH_SERVICE; then
    echo "❌ SSH 重启失败 → 恢复原配置"
    mv ${SSH_CONFIG}.bak $SSH_CONFIG
    systemctl restart $SSH_SERVICE
    exit 1
fi
###############################################################################
# Step 6. 自动开放 SSH 端口（UFW/firewalld）
###############################################################################
echo ">>> 自动放行 SSH 新端口"
# UFW
if command -v ufw >/dev/null 2>&1; then
    ufw allow $SSH_PORT/tcp
    ufw --force enable
fi
# firewalld
if systemctl list-unit-files | grep -q firewalld.service; then
    systemctl start firewalld
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    firewall-cmd --reload
fi
###############################################################################
# Step 7. 检查 SSH 是否监听新端口
###############################################################################
echo ">>> 检查 SSH 新端口是否监听中..."
sleep 1
LISTEN_CHECK=$(ss -tln | grep ":$SSH_PORT " || true)
if [[ -z "$LISTEN_CHECK" ]]; then
    echo "❌ SSH 新端口未监听 → 自动回滚配置!"
    mv ${SSH_CONFIG}.bak $SSH_CONFIG
    systemctl restart $SSH_SERVICE
    exit 1
fi
echo "✔ SSH 新端口监听成功"
###############################################################################
# Step 8. Fail2ban（本地防爆破）
###############################################################################
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
###############################################################################
# Step 9. 启用 BBR
###############################################################################
echo ">>> 启用 BBR"
# 避免重复添加
grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
###############################################################################
# Step 10. 自动创建 Swap
###############################################################################
echo ">>> 检查 Swap..."
if ! free | awk '/Swap:/ {exit !$2}'; then
    RAM_MB=$(free -m | awk '/Mem/ {print $2}')
    if [ $RAM_MB -le 1024 ]; then
        SWAP_SIZE=2048
    elif [ $RAM_MB -le 2048 ]; then
        SWAP_SIZE=4096
    else
        SWAP_SIZE=2048
    fi
    echo ">>> 创建 ${SWAP_SIZE}MB Swap"
    fallocate -l ${SWAP_SIZE}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
else
    echo "✔ 已存在 Swap"
fi
###############################################################################
# Step 11. oh-my-zsh
###############################################################################
echo ">>> 安装 oh-my-zsh"
if [ ! -d "/root/.oh-my-zsh" ]; then
    export RUNZSH=no
    export CHSH=no
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || echo "⚠️ oh-my-zsh 安装失败，跳过"
else
    echo "✔ oh-my-zsh 已存在，跳过安装"
fi
chsh -s /usr/bin/zsh root 2>/dev/null || true
###############################################################################
# 完成
###############################################################################
# IPv6-only 时使用 IPv6 地址
if [[ "$IS_IPV6_ONLY" == "true" ]]; then
    IP=$(curl -6 -s ifconfig.me || ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
else
    IP=$(curl -s ifconfig.me)
fi
echo ""
echo "=========================================="
echo "         ✅ 初始化完成"
echo "=========================================="
echo "SSH 登录命令："
if [[ "$IS_IPV6_ONLY" == "true" ]]; then
    echo "  ssh root@${IP} -p ${SSH_PORT}"
    echo "  或: ssh -6 root@[${IP}] -p ${SSH_PORT}"
else
    echo "  ssh root@${IP} -p ${SSH_PORT}"
fi
echo ""
echo "⚠️  请保持当前会话，用新端口测试登录成功后再退出！"
echo "=========================================="
