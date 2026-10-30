# Magisk Docker Fix

修复 F2FS 上 Docker data-root loop ext4 镜像挂载 I/O error。

## 前置要求

- **mgksu 的 dockerd 模块**：从 [dockerd](https://github.com/mgksu/dockerd) 获取
- **Docker data-root 镜像**：`/data/adb/docker-data.img`（ext4，**必须非稀疏格式**）
- **KernelSU 或 Magisk**

## 问题根因

共有两类，表现都是 `mount: I/O error` / `EXT4-fs: unable to read superblock`，但成因完全不同：

### 1. 镜像文件 SELinux 标签（2026-10-30 定位）

`/data/adb/docker-data.img` 默认标签是 `adb_data_file`，而 loop 驱动的 kworker 以
`u:r:kernel:s0` 读取该文件时**没有读权限**：

```
avc: denied { read } for comm="kworker/u16:3" path="/data/adb/docker-data.img"
     scontext=u:r:kernel:s0 tcontext=u:object_r:adb_data_file:s0 tclass=file permissive=0
```

被拒的读预取直接以 `Buffer I/O error on dev loopN, logical block 0` 返回，ext4 读不到
superblock，挂载失败，`service.sh` 随后 `touch dockerd/disable` 把 dockerd 也停掉。

- 触发条件：任何一次 `restorecon`（改机、刷 ROM、手动 `restorecon -R /data/adb`）
  都会把标签改回 `adb_data_file`
- 修复：挂载前 `chcon u:object_r:magisk_file:s0 /data/adb/docker-data.img`（脚本已内置）
- 判别：`dmesg | grep 'avc.*kernel'`

### 2. 稀疏文件（F2FS + loop）

F2FS 的 GC 与 loop 驱动对稀疏文件（sparse file）的读取不兼容，loop 同样读不到
superblock。将镜像转换为非稀疏格式后恢复正常（见下文命令）。

### 关于挂载选项

`mount -o context=...` 在部分 ROM（如 crDroid 16）上会返回 `EACCES`，脚本已改为普通
挂载；镜像内部标签用 `restorecon -R /data/adb/docker/lib/docker` 一次性写入 ext4 xattr
即可持久保留，之后普通挂载也能保持正确标签。

## 安装

```bash
git clone https://github.com/greenhandzdl/magisk-docker-fix.git
cd magisk-docker-fix
adb push . /data/local/tmp/docker-fix/
adb shell "su -c '
cp -r /data/local/tmp/docker-fix /data/adb/modules/docker-fix
chmod 755 /data/adb/modules/docker-fix/*.sh
chmod 644 /data/adb/modules/docker-fix/module.prop
rm -rf /data/local/tmp/docker-fix
'"
```

## 使用

1. 打开 KernelSU/Magisk → 模块 → **Docker Fix** → 点击 **运行**
2. 或命令行：`su -c 'sh /data/adb/modules/docker-fix/action.sh'`

模块自动完成：清理 stale loop 设备 → 挂载镜像 → 启动 dockerd → 验证数据

开机时 `service.sh` 也会自动尝试挂载并启动 dockerd。

## 转换稀疏镜像

```bash
# 检查
su -c '
IMG=/data/adb/docker-data.img
blocks=$(stat -c %b $IMG); blocksize=$(stat -c %B $IMG)
actual=$((blocks * blocksize)); apparent=$(stat -c %s $IMG)
echo "实际: $((actual/1073741824))G / 表观: $((apparent/1073741824))G"
[ "$actual" -lt "$apparent" ] && echo "⚠ 稀疏文件" || echo "✓ 非稀疏"
'

# 转换（需要额外 50G 空间，约 1-2 分钟）
su -c 'cp /data/adb/docker-data.img /data/adb/docker-data.img.tmp && mv /data/adb/docker-data.img.tmp /data/adb/docker-data.img'
```

## 创建非稀疏镜像

```bash
su -c '
IMG=/data/adb/docker-data.img
dd if=/dev/zero of=$IMG bs=1M count=51200  # 50G 非稀疏
mkfs.ext4 $IMG
chcon u:object_r:magisk_file:s0 $IMG        # 关键：否则 loop 读被 SELinux 拒
DEV=$(losetup -f); losetup $DEV $IMG
mkdir -p /data/adb/docker/lib/docker
mount -t ext4 -o noatime,nodiratime $DEV /data/adb/docker/lib/docker
restorecon -R /data/adb/docker/lib/docker   # 把标签写进 ext4 xattr，之后持久有效
chmod 711 /data/adb/docker/lib/docker
'
```

## 文件结构

| 文件 | 用途 |
|------|------|
| `action.sh` | 一键修复（按钮点击） |
| `service.sh` | 开机 boot_completed 后挂载+启动 |
| `post-fs-data.sh` | 开机早期快速挂载尝试 |
| `module.prop` | 模块元数据 |

## 致谢

- [mgksu/dockerd](https://github.com/mgksu/dockerd) - Docker for Android

## License

MIT
