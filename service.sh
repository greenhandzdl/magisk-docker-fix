#!/system/bin/sh
# docker-fix service 脚本
# 开机后挂载 data-root 镜像 + 启动 dockerd
# 教训(2026-10-14)：
#   1. ksud 会执行 service.d/post-fs-data.d 下所有文件(不筛 .bak)，旧遗留脚本
#      曾与本脚本并发挂载造成嵌套两层，已移入 /data/adb/docker/legacy/
#   2. toybox pkill 只接受一个 pattern，'pkill -9 dockerd containerd' 静默失败，
#      必须按 pgrep 拿到的 PID 逐个 kill
#   3. dockerd.inotify 监听 disable 文件增删会自动 start/stop dockerd，
#      操作 disable 前必须先杀掉 inotifyd，否则会并发拉起第二个 dockerd
#   4. 只有确认 dockerd/containerd 全部死亡后才能删 docker.sock/pidfile，
#      否则活 daemon 的 sock 被删，CLI 永久断连
# 教训(2026-10-30)：
#   1. 镜像文件默认标签 adb_data_file 会被 kernel 域拒读(loop 的 kworker 读预取
#      返回 EIO -> "unable to read superblock")，挂载必然失败；必须先把镜像标成
#      magisk_file。restorecon/重装镜像都可能改回去，故每次挂载前都修一次
#   2. mount -o context=... 在本 ROM 上返回 EACCES，改用普通挂载：镜像内部标签
#      已由 restorecon 持久化进 ext4 xattr，不依赖挂载选项
export PATH=/system/bin:/system/xbin:/system_ext/bin:/data/adb/ksu/bin:$PATH
export DOCKER_HOST=unix:///data/adb/docker/run/docker.sock

IMG=/data/adb/docker-data.img
ROOT=/data/adb/docker/lib/docker
RUNDIR=/data/adb/docker/run
MODULE=/data/adb/modules/dockerd
LOG=/data/adb/modules/docker-fix/service.log

echo "=== service 开始 $(date) ===" > $LOG

# 等待 boot_completed
while [ "$(getprop sys.boot_completed)" != 1 ]; do
    sleep 1
done
sleep 20
echo "boot_completed 就绪" >> $LOG

mount_layers() {
    grep -c " $ROOT " /proc/mounts 2>/dev/null
}

# 停 inotifyd + 按 PID 杀 dockerd/containerd，等待全部退出
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
    echo "dockerd/containerd 已停止 (等待 $i 轮)" >> $LOG
}

# 卸掉所有挂载层 + 清理所有关联旧 loop（仅在 dockerd 已死时调用）
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

# 镜像内部标签缺失时后台补（仅新格式化/新拷贝的镜像会走到）
fix_inner_labels() {
    case "$(ls -Zd $ROOT 2>/dev/null)" in
        *unlabeled*)
            echo "镜像内部标签缺失，后台 restorecon..." >> $LOG
            (restorecon -R $ROOT >> $LOG 2>&1) &
            ;;
    esac
}

do_mount() {
    # kernel 域无权读 adb_data_file，loop 预读会 EIO
    chcon u:object_r:magisk_file:s0 $IMG 2>/dev/null
    DEV=$(losetup -f 2>/dev/null)
    [ -z "$DEV" ] && return 1
    losetup $DEV $IMG 2>/dev/null || return 1
    sleep 1
    if ! mount -t ext4 -o "noatime,nodiratime" $DEV $ROOT 2>>$LOG; then
        losetup -d $DEV 2>/dev/null
        return 1
    fi
    fix_inner_labels
    return 0
}

# 清残留 sock/pid（进程已死才允许）
rm_stale_files() {
    rm -f $RUNDIR/docker.sock $RUNDIR/docker.pid $RUNDIR/dockerd.pid 2>/dev/null
}

LAYERS=$(mount_layers)
[ -z "$LAYERS" ] && LAYERS=0
echo "当前挂载层数: $LAYERS" >> $LOG

if [ "$LAYERS" -gt 1 ]; then
    echo "检测到 $LAYERS 层嵌套挂载，清理重建..." >> $LOG
    kill_docker_all
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

# 文件系统就绪；确保只有一个 dockerd 实例：先停干净，再启动
sleep 5
kill_docker_all
rm_stale_files
rm -f $MODULE/disable 2>/dev/null
echo "启动 dockerd..." >> $LOG
/data/adb/docker/scripts/start.sh >> $LOG 2>&1

sleep 30
D=/data/adb/docker/bin/docker
img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
echo "30s 后镜像数: $img_count, 挂载层数: $(mount_layers)" >> $LOG

if [ "$img_count" -eq 0 ]; then
    echo "镜像数为 0，全流程重来一遍..." >> $LOG
    kill_docker_all
    # 层数异常则重建挂载
    LAYERS=$(mount_layers)
    if [ "$LAYERS" -ne 1 ]; then
        clean_all
        do_mount
    fi
    rm_stale_files
    /data/adb/docker/scripts/start.sh >> $LOG 2>&1
    sleep 30
    img_count=$($D images 2>/dev/null | tail -n +2 | wc -l)
    echo "重启后镜像数: $img_count" >> $LOG
fi

echo "=== service 完成 ===" >> $LOG
