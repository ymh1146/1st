自用小鸡初始化脚本

运行：

```
bash <(curl -fsSL https://raw.githubusercontent.com/ymh1146/1st/refs/heads/main/start.sh)
```

ipv6运行：

```
bash <(curl -6 -fsSL https://raw.githubusercontent.com/ymh1146/1st/refs/heads/main/start.sh)
```

***

VPS 一键初始化脚本
功能：
- SSH 端口交互设置 + root 密码
- 时区 Asia/Shanghai
- 阿里云源
- Fail2ban（本地防爆破）
- BBR 加速
- UFW 防火墙
- IPv6-only 自动 DNS64
- 自动 Swap（智能选择大小）
- htop
- zsh + oh-my-zsh（自动安装）
