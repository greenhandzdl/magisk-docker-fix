#!/system/bin/sh
# docker-fix service 脚本
# 开机后最终挂载尝试 + 启动 dockerd
# 防双重挂载：用 /proc/mounts 检查，多层嵌套时强制重建单一挂载
export PATH=/system/bin:/system/xbin:/system_ext/bin:/data/adb/ksu/bin:$PATH

IMG=/data/adb/docker-data.img
ROOT=/data/adb/docker/lib/docker
MODULE=/data/adb/modules/dockerd
LOG=/data/adb/modules/docker-fix/service.log

echo "=== service 开始 $(date) ===" > $LOG

# 等待 boot_completed
while [ "$(getprop sys.boot_completed)" != 1 ]; do
    sleep 1
done
sleep 20
echo "boot_completed 就绪" >> $LOG

# 挂载层数（Android 无可靠 mountpoint 命令，直接查 /proc/mounts）
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
        return 1
    fi
    losetup $DEV $IMG 2>/dev/null || return 1
    sleep 1
    mount -t ext4 -o "noatime,nodiratime,context=\"u:object_r:adb_data_file:s0\"" $DEV $ROOT 2>/dev/null
    if [ $? -ne 0 ]; then
        losetup -d $DEV 2>/dev/null
        return 1
    fi
    return 0
}

LAYERS=$(mount_layers)
[ -z "$LAYERS" ] && LAYERS=0
echo "当前挂载层数: $LAYERS" >> $LOG

if [ "$LAYERS" -gt 1 ]; then
    # post-fs-data 与 service 竞态导致双重嵌套挂载，全部拆掉重建
    echo "检测到 $LAYERS 层嵌套挂载，清理重建..." >> $LOG
    pkill -9 dockerd containerd 2>/dev/null
    sleep 3
    clean_all
    LAYERS=0
fi

if [ "$LAYERS" -eq 0 ]; then
    echo "开始挂载..." >> $LOG
    i=0
    while [ $i -lt 10 ]; do
        if do_mount; then
            echo "挂载成功 (尝试 $i)" >> $LOG
            break
        fi
        i=$((i + 1))
        sleep 2
    done

    if [ "$(mount_layers)" = "0" ]; then
        echo "挂载失败，禁用 dockerd 模块" >> $LOG
        touch $MODULE/disable 2>/dev/null
        exit 1
    fi
fi

# 等待文件系统就绪
sleep 5
echo "启动 dockerd..." >> $LOG

# 启动 dockerd
rm -f $MODULE/disable 2>/dev/null
rm -f /data/adb/docker/run/docker.sock 2>/dev/null
/data/adb/docker/scripts/start.sh >> $LOG 2>&1

# 等待并检查
sleep 30
D=/data/adb/docker/bin/docker
img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
echo "30s 后镜像数: $img_count" >> $LOG

if [ "$img_count" -eq 0 ]; then
    # 先确认不是又出现了嵌套挂载
    LAYERS=$(mount_layers)
    echo "镜像数为 0（当前挂载层数: $LAYERS），重启 dockerd..." >> $LOG
    if [ "$LAYERS" -gt 1 ]; then
        clean_all
        do_mount
    fi
    pkill -9 dockerd containerd 2>/dev/null
    sleep 5
    rm -f /data/adb/docker/run/docker.sock 2>/dev/null
    /data/adb/docker/scripts/start.sh >> $LOG 2>&1
    sleep 30
    img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
    echo "重启后镜像数: $img_count" >> $LOG
fi

echo "=== service 完成 ===" >> $LOG
