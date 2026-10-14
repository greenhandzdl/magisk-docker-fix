#!/system/bin/sh
# docker-fix post-fs-data 脚本
# 开机早期快速尝试挂载（loop 节点可能没建完，只试 2 轮）
# 只在完全未挂载时动手；已有任何一层就交给 service.sh 处理
export PATH=/system/bin:/system/xbin:/system_ext/bin:/data/adb/ksu/bin:$PATH

IMG=/data/adb/docker-data.img
ROOT=/data/adb/docker/lib/docker
LOG=/data/adb/modules/docker-fix/post-fs-data.log

echo "=== post-fs-data 开始 $(date) ===" > $LOG

if grep -q " $ROOT " /proc/mounts 2>/dev/null; then
    echo "已挂载（层数: $(grep -c " $ROOT " /proc/mounts)），跳过" >> $LOG
    exit 0
fi

if [ ! -f "$IMG" ]; then
    echo "镜像文件不存在" >> $LOG
    exit 1
fi

# 挂载前释放未挂载的残留旧 loop，避免叠加关联
losetup -j $IMG 2>/dev/null | cut -d: -f1 | while read dev; do
    losetup -d $dev 2>/dev/null
done

i=0
while [ $i -lt 2 ]; do
    if grep -q " $ROOT " /proc/mounts 2>/dev/null; then
        echo "等待期间已被挂载，退出" >> $LOG
        exit 0
    fi
    DEV=$(losetup -f 2>/dev/null)
    if [ -n "$DEV" ]; then
        losetup $DEV $IMG 2>/dev/null
        if mount -t ext4 -o "noatime,nodiratime,context=\"u:object_r:adb_data_file:s0\"" $DEV $ROOT 2>/dev/null; then
            echo "挂载成功 (尝试 $i)" >> $LOG
            exit 0
        fi
        losetup -d $DEV 2>/dev/null
    fi
    i=$((i + 1))
    sleep 1
done

echo "快速尝试失败，等待 service 阶段" >> $LOG
