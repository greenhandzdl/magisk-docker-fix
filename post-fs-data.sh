#!/system/bin/sh
# docker-fix post-fs-data 脚本
# 开机时快速尝试挂载（此时 loop 节点可能没建完，只试 2 轮）
# 注意：只有确认完全未挂载才动手，绝不叠加第二层挂载
export PATH=/system/bin:/system/xbin:/system_ext/bin:/data/adb/ksu/bin:$PATH

IMG=/data/adb/docker-data.img
ROOT=/data/adb/docker/lib/docker
LOG=/data/adb/modules/docker-fix/post-fs-data.log

echo "=== post-fs-data 开始 $(date) ===" > $LOG

# 已有任何一层挂载就直接退出，把后续处理留给 service.sh
if grep -q " $ROOT " /proc/mounts 2>/dev/null; then
    echo "已挂载（层数: $(grep -c " $ROOT " /proc/mounts)），跳过" >> $LOG
    exit 0
fi

# 检查镜像文件
if [ ! -f "$IMG" ]; then
    echo "镜像文件不存在" >> $LOG
    exit 1
fi

# 快速尝试挂载（只试 2 轮）
i=0
while [ $i -lt 2 ]; do
    # 每轮开头重新确认，防止竞态窗口内被别人抢先挂载
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

echo "快速尝试失败，等待 service.d 阶段" >> $LOG
