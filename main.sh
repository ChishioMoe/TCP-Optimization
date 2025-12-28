#!/bin/bash

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 sudo 运行此脚本"
  exit 1
fi

echo "--- 正在初始化 Debian 12 深度优化脚本 ---"

# 1. 环境准备：安装必要工具
echo "[1/5] 正在安装依赖工具 (bc, cpufrequtils)..."
apt-get update && apt-get install -y bc cpufrequtils

# 2. 获取用户输入并计算 BDP (TCP 窗口)
echo "[2/5] 配置 TCP 动态缓冲区..."
read -p "请输入本地下载带宽 (Mbps): " local_bw
read -p "请输入服务器带宽 (Mbps): " server_bw
read -p "请输入到服务器的延迟 (ms): " latency

min_bw=$(( local_bw < server_bw ? local_bw : server_bw ))
bdp_x=$(echo "($min_bw * 1000 * $latency) / 8" | bc)

# 设置保底值
if [ "$bdp_x" -lt 131072 ]; then bdp_x=131072; fi
echo "计算得出的最大缓冲区 (x): $bdp_x 字节"

# 3. 写入内核参数 (sysctl)
echo "[3/5] 正在优化内核参数并开启 BBR..."
cp /etc/sysctl.conf /etc/sysctl.conf.bak_$(date +%Y%m%d_%H%M%S)

cat << EOL > /etc/sysctl.conf
# 基础内核优化
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 1
kernel.printk = 3 4 1 3
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0

# 内存优化
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.panic_on_oom = 1
vm.overcommit_memory = 1
vm.min_free_kbytes = 54326

# 网络核心参数
net.core.default_qdisc = cake
net.core.netdev_max_backlog = 5000
net.core.rmem_max = $bdp_x
net.core.wmem_max = $bdp_x
net.core.rmem_default = 87380
net.core.wmem_default = 65536
net.core.somaxconn = 1024

# TCP 缓冲区设置 (基于 BDP 计算)
net.ipv4.tcp_rmem = 4096 87380 $bdp_x
net.ipv4.tcp_wmem = 4096 16384 $bdp_x

# TCP 性能与加速
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1

# 路由与邻居表优化
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
EOL

sysctl -p

# 4. 优化文件描述符 (Limits)
echo "[4/5] 正在优化文件描述符限制 (ulimit)..."
cat << EOF > /etc/security/limits.d/99-performance.conf
* soft nofile 512000
* hard nofile 512000
* soft nproc 512000
* hard nproc 512000
root soft nofile 512000
root hard nofile 512000
EOF

# 5. CPU 高性能模式与网卡队列长度
echo "[5/5] 正在配置 CPU 调度器与网卡队列..."

# 设置 CPU 高性能模式
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
systemctl restart cpufrequtils

# 设置网卡队列长度 (立即生效 + 写入开机启动)
# 自动检测默认网卡名
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -n "$INTERFACE" ]; then
    ifconfig $INTERFACE txqueuelen 5000
    # 写入 rc.local 或 crontab 以实现重启自启 (Debian 12 推荐方式)
    (crontab -l 2>/dev/null; echo "@reboot /sbin/ifconfig $INTERFACE txqueuelen 5000") | crontab -
    echo "网卡 $INTERFACE 的队列长度已设为 5000 并配置自启"
else
    echo "警告：未能识别默认网卡，txqueuelen 设置失败"
fi

echo "------------------------------------------------"
echo "✅ 所有深度优化已完成！"
echo "💡 请注意：文件描述符限制 (ulimit) 需要在您下次重新登录 SSH 时生效。"
echo "------------------------------------------------"
