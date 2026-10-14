#!/system/bin/sh
# docker-fix 模块 action 脚本
# 在 KernelSU 模块管理界面点击"运行"按钮时执行
# 具备自愈能力：检测嵌套多重挂载并重建为单一干净挂载
export PATH=/system/bin:/system/xbin:/system_ext/bin:/data/adb/ksu/bin:$PATH

IMG=/data/adb/docker-data.img
ROOT=/data/adb/docker/lib/docker
MODULE=/data/adb/modules/dockerd
LOG=/data/adb/modules/docker-fix/action.log

echo "=== docker-fix action 开始 $(date) ===" > $LOG

# 挂载层数（不用 mountpoint，Android 上不可靠）
mount_layers() {
    grep -c " $ROOT " /proc/mounts 2>/dev/null
}

# 卸掉所有挂载层 + 清理所有关联旧 loop
clean_all() {
    i=0
    while [ $i -lt 8 ]; do
        umount $ROOT 2>/dev/null || break
        sleep 1
        i=$((i + 1))
    done
    losetup -j $IMG 2>/dev/null | cut -d: -f1 | while read dev; do
        losetup -d $dev 2>/dev/null
    done
}

# 单一干净挂载
do_mount() {
    DEV=$(losetup -f 2>/dev/null)
    if [ -z "$DEV" ]; then
        echo "!!! 无法找到空闲 loop 设备" | tee -a $LOG
        return 1
    fi
    echo "  使用 loop 设备: $DEV" | tee -a $LOG
    if ! losetup $DEV $IMG 2>> $LOG; then
        echo "!!! losetup 失败" | tee -a $LOG
        return 1
    fi
    sleep 1
    if ! mount -t ext4 -o "noatime,nodiratime,context=\"u:object_r:adb_data_file:s0\"" $DEV $ROOT 2>> $LOG; then
        echo "!!! 挂载失败 (I/O error)" | tee -a $LOG
        echo "!!! 原因: F2FS + loop 驱动无法读取稀疏文件" | tee -a $LOG
        echo "!!! 解决: cp 转换为非稀疏格式后重试" | tee -a $LOG
        losetup -d $DEV 2>/dev/null
        return 1
    fi
    return 0
}

# 检查镜像文件
if [ ! -f "$IMG" ]; then
    echo "!!! 镜像文件不存在: $IMG" | tee -a $LOG
    exit 1
fi
echo "✓ 镜像文件存在 ($(ls -lh $IMG | awk '{print $5}'))" | tee -a $LOG

# 检查是否为稀疏文件
actual=$(stat -c %b $IMG 2>/dev/null)
blocksize=$(stat -c %B $IMG 2>/dev/null)
apparent=$(stat -c %s $IMG 2>/dev/null)
if [ -n "$actual" ] && [ -n "$blocksize" ] && [ -n "$apparent" ]; then
    real=$((actual * blocksize))
    if [ "$real" -lt "$apparent" ]; then
        echo "⚠ 检测到稀疏文件 (实际: $((real/1073741824))G, 表观: $((apparent/1073741824))G)" | tee -a $LOG
        echo "  稀疏文件可能导致 loop 挂载 I/O error，建议 cp 转换为非稀疏格式" | tee -a $LOG
    fi
fi

LAYERS=$(mount_layers)
[ -z "$LAYERS" ] && LAYERS=0
echo "当前挂载层数: $LAYERS" | tee -a $LOG

if [ "$LAYERS" -gt 1 ]; then
    # 嵌套双重挂载：dockerd 看到的是空数据视图，必须拆掉重建
    echo "⚠ 检测到 $LAYERS 层嵌套挂载，重启 dockerd 并清理重建..." | tee -a $LOG
    pkill -9 dockerd containerd 2>/dev/null
    sleep 3
    clean_all
    LAYERS=0
fi

if [ "$LAYERS" -eq 0 ]; then
    echo "→ 尝试挂载..." | tee -a $LOG
    if do_mount; then
        echo "✓ 挂载成功" | tee -a $LOG
    else
        exit 1
    fi
else
    echo "✓ 已挂载: $(grep " $ROOT " /proc/mounts | head -1)" | tee -a $LOG
fi

# 检查内容
echo "  顶层内容: $(ls $ROOT | wc -l) 项" | tee -a $LOG
echo "  VFS 层数: $(ls -1 $ROOT/vfs/dir 2>/dev/null | wc -l)" | tee -a $LOG

# 启动 dockerd
echo "→ 启动 dockerd..." | tee -a $LOG
rm -f $MODULE/disable 2>/dev/null

D=/data/adb/docker/bin/docker
if pgrep -x dockerd >/dev/null 2>&1; then
    echo "✓ dockerd 已在运行 (PID $(pgrep -x dockerd))" | tee -a $LOG
    img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
    if [ "$img_count" -eq 0 ]; then
        echo "  镜像数为 0，重启 dockerd..." | tee -a $LOG
        pkill -9 dockerd containerd 2>/dev/null
        sleep 3
        rm -f /data/adb/docker/run/docker.sock 2>/dev/null
        /data/adb/docker/scripts/start.sh >> $LOG 2>&1
        sleep 8
    fi
else
    rm -f /data/adb/docker/run/docker.sock 2>/dev/null
    /data/adb/docker/scripts/start.sh >> $LOG 2>&1
    sleep 8
fi

# 验证
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
