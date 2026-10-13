#!/system/bin/sh
# docker-fix 模块 action 脚本
# 在 KernelSU 模块管理界面点击"运行"按钮时执行
export PATH=/system/bin:/system/xbin:/system_ext/bin:/data/adb/ksu/bin:$PATH

IMG=/data/adb/docker-data.img
ROOT=/data/adb/docker/lib/docker
MODULE=/data/adb/modules/dockerd
LOG=/data/adb/modules/docker-fix/action.log

echo "=== docker-fix action 开始 $(date) ===" > $LOG

# 检查镜像文件
if [ ! -f "$IMG" ]; then
    echo "!!! 镜像文件不存在: $IMG" | tee -a $LOG
    exit 1
fi
echo "✓ 镜像文件存在 ($(ls -lh $IMG | awk '{print $5}'))" | tee -a $LOG

# 检查是否为稀疏文件
actual=$(du -b $IMG 2>/dev/null | awk '{print $1}')
apparent=$(ls -l $IMG 2>/dev/null | awk '{print $5}')
if [ "$actual" != "$apparent" ] && [ -n "$actual" ] && [ -n "$apparent" ]; then
    echo "⚠ 检测到稀疏文件 (实际: $((actual/1024/1024/1024))G, 表观: $((apparent/1024/1024/1024))G)" | tee -a $LOG
    echo "  稀疏文件可能导致 loop 挂载 I/O error" | tee -a $LOG
    echo "  建议转换为非稀疏格式" | tee -a $LOG
fi

# 清理所有 stale loop 设备
echo "→ 清理 stale loop 设备..." | tee -a $LOG
losetup -j $IMG 2>/dev/null | cut -d: -f1 | while read dev; do
    echo "  解除 $dev" >> $LOG
    losetup -d $dev 2>/dev/null
done
sleep 2

# 检查是否已挂载
if mountpoint -q $ROOT 2>/dev/null; then
    echo "✓ 已挂载: $(mount | grep "on $ROOT" | head -1)" | tee -a $LOG
else
    echo "→ 尝试挂载..." | tee -a $LOG
    
    # 查找空闲 loop 设备
    DEV=$(losetup -f 2>/dev/null)
    if [ -z "$DEV" ]; then
        echo "!!! 无法找到空闲 loop 设备" | tee -a $LOG
        exit 1
    fi
    echo "  使用 loop 设备: $DEV" | tee -a $LOG
    
    # 关联镜像
    losetup $DEV $IMG 2>> $LOG
    if [ $? -ne 0 ]; then
        echo "!!! losetup 失败" | tee -a $LOG
        exit 1
    fi
    sleep 1
    
    # 挂载
    mount -t ext4 -o "noatime,nodiratime,context=\"u:object_r:adb_data_file:s0\"" $DEV $ROOT 2>> $LOG
    if [ $? -eq 0 ]; then
        echo "✓ 挂载成功" | tee -a $LOG
    else
        echo "!!! 挂载失败 (I/O error)" | tee -a $LOG
        echo "!!! 原因: F2FS + loop 驱动无法读取稀疏文件" | tee -a $LOG
        echo "!!! 解决: 转换为非稀疏格式" | tee -a $LOG
        echo "  命令: cp /data/adb/docker-data.img /data/adb/docker-data.img.nosparse" | tee -a $LOG
        echo "        mv /data/adb/docker-data.img.nosparse /data/adb/docker-data.img" | tee -a $LOG
        losetup -d $DEV 2>/dev/null
        exit 1
    fi
fi

# 检查内容
echo "  顶层内容: $(ls $ROOT | wc -l) 项" | tee -a $LOG
echo "  VFS 层数: $(ls -1 $ROOT/vfs/dir 2>/dev/null | wc -l)" | tee -a $LOG

# 启动 dockerd
echo "→ 启动 dockerd..." | tee -a $LOG
rm -f $MODULE/disable 2>/dev/null

# 检查是否已在运行
if pgrep -x dockerd >/dev/null 2>&1; then
    echo "✓ dockerd 已在运行 (PID $(pgrep -x dockerd))" | tee -a $LOG
    
    # 检查镜像数，如果为 0 则重启
    D=/data/adb/docker/bin/docker
    img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
    if [ "$img_count" -eq 0 ]; then
        echo "  镜像数为 0，重启 dockerd..." | tee -a $LOG
        pkill -9 dockerd containerd 2>/dev/null
        sleep 3
        /data/adb/docker/scripts/start.sh >> $LOG 2>&1
        sleep 8
    fi
else
    /data/adb/docker/scripts/start.sh >> $LOG 2>&1
    sleep 8
fi

# 验证
D=/data/adb/docker/bin/docker
IMG_COUNT=$($D images 2>/dev/null | tail -n +2 | wc -l)
CTR_COUNT=$($D ps -a 2>/dev/null | tail -n +2 | wc -l)
echo "=== 完成 ===" | tee -a $LOG
echo "镜像数: $IMG_COUNT" | tee -a $LOG
echo "容器数: $CTR_COUNT" | tee -a $LOG

if [ "$IMG_COUNT" -gt 0 ]; then
    echo "✓ Docker 正常: $IMG_COUNT 镜像 / $CTR_COUNT 容器" | tee -a $LOG
else
    echo "⚠ Docker 运行但镜像数为 0" | tee -a $LOG
fi

echo "=== docker-fix action 完成 ===" | tee -a $LOG
