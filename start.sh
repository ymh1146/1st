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
# Step 3. 阿里源 + 基础软件
###############################################################################
echo ">>> 配置阿里源 & 更新系统 & 安装软件"

if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.bak
    CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)

cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME} main restricted universe multiverse
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME}-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME}-security main restricted universe multiverse
EOF

    apt update -y
    apt install -y curl wget git ufw fail2ban htop zsh netcat-openbsd
else
    yum install -y epel-release
    yum install -y curl wget git fail2ban htop zsh nc
fi


###############################################################################
# Step 4. 自动检测 SSH 服务名（关键修复）
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
    ufw reload || ufw enable <<< "y"
fi

# firewalld
if systemctl list-unit-files | grep -q firewalld.service; then
    systemctl start firewalld
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    firewall-cmd --reload
fi


###############################################################################
# Step 7. 检查 SSH 是否监听新端口（核心安全逻辑）
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

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

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
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
else
    echo "✔ 已存在 Swap"
fi


###############################################################################
# Step 11. IPv6-only DNS64
###############################################################################
echo ">>> 检查 IPv4 连接..."

if ! ping -4 -c 1 1.1.1.1 >/dev/null 2>&1; then
    echo "未检测到 IPv4 → 启用 DNS64"
cat > /etc/resolv.conf <<EOF
nameserver 2606:4700:4700::64
nameserver 2001:67c:27e4::64
EOF
    echo "✔ 已启用 DNS64"
fi


###############################################################################
# Step 12. oh-my-zsh
###############################################################################
echo ">>> 安装 oh-my-zsh"

export RUNZSH=no
export CHSH=no

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

chsh -s /usr/bin/zsh root



###############################################################################
# 完成
###############################################################################
IP=$(curl -s ifconfig.me)

echo "===== 初始化完成 ====="
echo "SSH 登录：ssh root@${IP} -p ${SSH_PORT}"
echo "请保持当前会话，确认新端口已可用后再退出!"
echo "===== 初始化完成 ====="
echo "SSH 登录：ssh root@${IP} -p ${SSH_PORT}"
echo "请保持此 SSH 连接，确认新端口可成功登录后再退出！"
