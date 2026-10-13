# Magisk Docker Fix

修复 F2FS 上 Docker data-root loop ext4 镜像挂载 I/O error。

## 前置要求

- **repotitan 的 dockerd 模块**：从 [magisk-docker](https://github.com/repotitan/magisk-docker) 获取
- **Docker data-root 镜像**：`/data/adb/docker-data.img`（ext4，**必须非稀疏格式**）
- **KernelSU 或 Magisk**

## 问题根因

F2FS 文件系统的垃圾回收（GC）机制与 loop 驱动对稀疏文件（sparse file）的读取不兼容。当 Docker data-root 以稀疏 ext4 镜像形式存储在 F2FS 分区上时，loop 设备无法读取镜像的 superblock，导致挂载失败（I/O error）。

**已验证**：将稀疏镜像转换为非稀疏格式后，loop 挂载完全正常。

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
DEV=$(losetup -f); losetup $DEV $IMG
mkdir -p /data/adb/docker/lib/docker
mount -t ext4 -o "context=\"u:object_r:adb_data_file:s0\"" $DEV /data/adb/docker/lib/docker
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

- [repotitan/magisk-docker](https://github.com/repotitan/magisk-docker) - Docker for Android

## License

MIT
