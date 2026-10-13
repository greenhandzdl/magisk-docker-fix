#!/system/bin/sh
# docker-fix service 脚本
# 开机后最终挂载尝试 + 启动 dockerd
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

# 如果已挂载则跳过
if mountpoint -q $ROOT 2>/dev/null; then
    echo "已挂载" >> $LOG
else
    echo "开始挂载..." >> $LOG
    
    # 尝试 10 轮
    i=0
    while [ $i -lt 10 ]; do
        DEV=$(losetup -f 2>/dev/null)
        if [ -n "$DEV" ]; then
            losetup $DEV $IMG 2>/dev/null
            if mount -t ext4 -o "noatime,nodiratime,context=\"u:object_r:adb_data_file:s0\"" $DEV $ROOT 2>/dev/null; then
                echo "挂载成功 (尝试 $i)" >> $LOG
                break
            fi
            losetup -d $DEV 2>/dev/null
        fi
        i=$((i + 1))
        sleep 2
    done
    
    if ! mountpoint -q $ROOT 2>/dev/null; then
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
/data/adb/docker/scripts/start.sh >> $LOG 2>&1

# 等待并检查
sleep 30
D=/data/adb/docker/bin/docker
img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
echo "30s 后镜像数: $img_count" >> $LOG

if [ "$img_count" -eq 0 ]; then
    echo "镜像数为 0，重启 dockerd..." >> $LOG
    pkill -9 dockerd containerd 2>/dev/null
    sleep 5
    /data/adb/docker/scripts/start.sh >> $LOG 2>&1
    sleep 30
    img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
    echo "重启后镜像数: $img_count" >> $LOG
fi

echo "=== service 完成 ===" >> $LOG
