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

# 必须 root 运行
if [ "$(id -u)" != "0" ]; then
    echo "❌ 请使用 root 执行此脚本！"
    exit 1
fi

echo "===== VPS 初始化脚本启动 ====="

# 识别系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别系统"
    exit 1
fi

echo "系统识别为: $OS"

########################################
# Step 1. SSH 端口输入
########################################
read -p "请输入 SSH 新端口（如 2288）：" SSH_PORT
[[ -z "$SSH_PORT" ]] && echo "❌ 端口不能为空" && exit 1

########################################
# Step 2. 设置 root 密码
########################################
read -s -p "请输入 root 密码：" ROOTPWD
echo
read -s -p "请再次输入 root 密码：" ROOTPWD2
echo
[[ "$ROOTPWD" != "$ROOTPWD2" ]] && echo "❌ 密码不一致" && exit 1

echo ">>> 更新 root 密码"
echo "root:$ROOTPWD" | chpasswd

########################################
# Step 3. 设置时区
########################################
echo ">>> 设置时区为 Asia/Shanghai"
timedatectl set-timezone Asia/Shanghai

########################################
# Step 4. 替换阿里云源
########################################
echo ">>> 替换为阿里云镜像源"

case "$OS" in
    ubuntu|debian)
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
        [[ -z "$CODENAME" ]] && CODENAME=$(lsb_release -sc)
cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME} main restricted universe multiverse
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME}-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/${OS}/ ${CODENAME}-security main restricted universe multiverse
EOF
        apt update -y
        apt install -y curl wget git ufw fail2ban htop zsh
        ;;
    centos|rhel|rocky|almalinux)
        cd /etc/yum.repos.d/
        mkdir -p bak
        mv *.repo bak/
        curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
        yum makecache
        yum install -y curl wget git fail2ban htop zsh
        ;;
    *)
        echo "⚠️ 未知系统，跳过源替换"
        ;;
esac

########################################
# Step 5. SSH 配置
########################################

echo ">>> 配置 SSH"

SSH_CONFIG="/etc/ssh/sshd_config"
cp $SSH_CONFIG ${SSH_CONFIG}.bak

sed -i "s/^#Port.*/Port ${SSH_PORT}/" $SSH_CONFIG
sed -i "s/^Port.*/Port ${SSH_PORT}/" $SSH_CONFIG
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication yes/" $SSH_CONFIG
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication yes/" $SSH_CONFIG

systemctl restart sshd || {
    echo "❌ SSH 重启失败，恢复原配置"
    mv ${SSH_CONFIG}.bak $SSH_CONFIG
    exit 1
}

########################################
# Step 6. Fail2ban（本地防爆破）
########################################

echo ">>> 配置 Fail2ban"

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

########################################
# Step 7. 启用 BBR
########################################

echo ">>> 启用 BBR 加速"

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

########################################
# Step 8. UFW 防火墙
########################################

if command -v ufw >/dev/null 2>&1; then
    echo ">>> 配置 UFW 防火墙"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ${SSH_PORT}/tcp
    ufw enable <<< "y"
fi

########################################
# Step 9. Swap 自动创建
########################################

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

    echo "创建 ${SWAP_SIZE}MB Swap..."
    fallocate -l ${SWAP_SIZE}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
else
    echo "系统已有 Swap，跳过"
fi

########################################
# Step 10. IPv6-only 自动 DNS64
########################################

echo ">>> 检查 IPv4..."

if ! ping -4 -c 1 1.1.1.1 >/dev/null 2>&1; then
    echo "未检测到 IPv4，启用 DNS64..."

cat > /etc/resolv.conf <<EOF
nameserver 2606:4700:4700::64
nameserver 2001:67c:27e4::64
EOF

fi

########################################
# Step 11. 安装 oh-my-zsh
########################################

echo ">>> 安装 oh-my-zsh"

export RUNZSH=no
export CHSH=no
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

chsh -s /usr/bin/zsh root

########################################
# 完成
########################################

IP=$(curl -s ifconfig.me)
echo "===== 初始化完成 ====="
echo "SSH 登录：ssh root@${IP} -p ${SSH_PORT}"
echo "请保持当前 SSH 连接，确认新端口可用后再退出！"
