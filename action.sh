#!/system/bin/sh
# docker-fix 模块 action 脚本（点击"运行"按钮）
# 自愈流程：精确停进程 -> 单层挂载 -> 干净启动 dockerd -> 验证
export PATH=/system/bin:/system/xbin:/system_ext/bin:/data/adb/ksu/bin:$PATH
export DOCKER_HOST=unix:///data/adb/docker/run/docker.sock

IMG=/data/adb/docker-data.img
ROOT=/data/adb/docker/lib/docker
RUNDIR=/data/adb/docker/run
MODULE=/data/adb/modules/dockerd
LOG=/data/adb/modules/docker-fix/action.log

echo "=== docker-fix action 开始 $(date) ===" > $LOG

mount_layers() {
    grep -c " $ROOT " /proc/mounts 2>/dev/null
}

# 停 inotifyd + 按 PID 杀 dockerd/containerd（toybox pkill 多 pattern 会静默失败）
kill_docker_all() {
    for p in $(pgrep -f dockerd.inotify); do
        kill -9 "$p" 2>/dev/null
    done
    for p in $(pgrep -x dockerd) $(pgrep -x containerd); do
        kill -9 "$p" 2>/dev/null
    done
    i=0
    while [ $i -lt 10 ]; do
        if [ -z "$(pgrep -x dockerd)" ] && [ -z "$(pgrep -x containerd)" ]; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
}

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
        echo "!!! 若是稀疏文件所致: cp 转换为非稀疏格式后重试" | tee -a $LOG
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

# 稀疏文件检查
actual=$(stat -c %b $IMG 2>/dev/null)
blocksize=$(stat -c %B $IMG 2>/dev/null)
apparent=$(stat -c %s $IMG 2>/dev/null)
if [ -n "$actual" ] && [ -n "$blocksize" ] && [ -n "$apparent" ]; then
    real=$((actual * blocksize))
    if [ "$real" -lt "$apparent" ]; then
        echo "⚠ 稀疏文件 (实际: $((real/1073741824))G, 表观: $((apparent/1073741824))G)，可能引发 loop 挂载 I/O error" | tee -a $LOG
    fi
fi

LAYERS=$(mount_layers)
[ -z "$LAYERS" ] && LAYERS=0
echo "当前挂载层数: $LAYERS" | tee -a $LOG

D=/data/adb/docker/bin/docker
if [ "$LAYERS" -gt 1 ]; then
    echo "⚠ 嵌套挂载 $LAYERS 层，停进程并清理重建..." | tee -a $LOG
    kill_docker_all
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

echo "  顶层内容: $(ls $ROOT | wc -l) 项, VFS 层: $(ls -1 $ROOT/vfs/dir 2>/dev/null | wc -l)" | tee -a $LOG

# 干净启动：先停干净所有 docker 进程再拉起，避免双实例抢 sock/pidfile
img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
if [ "$img_count" -eq 0 ]; then
    echo "→ 停净旧实例后启动 dockerd..." | tee -a $LOG
    kill_docker_all
    rm -f $RUNDIR/docker.sock $RUNDIR/docker.pid $RUNDIR/dockerd.pid 2>/dev/null
else
    echo "✓ dockerd 正常 (镜像数 $img_count)，无需重启" | tee -a $LOG
    rm -f $MODULE/disable 2>/dev/null
    echo "=== 完成 ===" | tee -a $LOG
    echo "镜像数: $img_count" | tee -a $LOG
    exit 0
fi

rm -f $MODULE/disable 2>/dev/null
/data/adb/docker/scripts/start.sh >> $LOG 2>&1
sleep 20

IMG_COUNT=$($D images 2>/dev/null | tail -n +2 | wc -l)
CTR_COUNT=$($D ps -a 2>/dev/null | tail -n +2 | wc -l)
echo "=== 完成 ===" | tee -a $LOG
echo "镜像数: $IMG_COUNT" | tee -a $LOG
echo "容器数: $CTR_COUNT" | tee -a $LOG

if [ "$IMG_COUNT" -gt 0 ]; then
    echo "✓ Docker 正常: $IMG_COUNT 镜像 / $CTR_COUNT 容器" | tee -a $LOG
else
    echo "⚠ Docker 运行但镜像数为 0，检查挂载层数: $(mount_layers)" | tee -a $LOG
fi

echo "=== docker-fix action 完成 ===" | tee -a $LOG
