#!/system/bin/sh
# 卸载时清理：
#  1) 把 logo 分区还原成备份里的原厂镜像（否则第一屏会一直是改过的）
#  2) 守卫脚本（位于模块外的 post-fs-data.d / service.d）
#  3) 守卫信息
# 注意两点：
#   - 只有「确实还原成功」才拆守卫。万一还原失败（比如备份被删了），
#     守卫是唯一的退路，必须留着，下次开机还会再试。
#   - 备份在 /data/adb/bootlogo-safety/，和素材库 /data/adb/bootlogos 分开，
#     删素材库不会把保命措施一起删掉。
MODDIR=${0%/*}
restored=no
if [ -x "$MODDIR/bin/ctl.sh" ]; then
  echo "序章：正在还原原厂 logo 分区…"
  out=$("$MODDIR/bin/ctl.sh" restore 2>&1)
  echo "$out"
  case "$out" in *"OK restored="*) restored=yes ;; esac
fi

if [ "$restored" = "yes" ]; then
  rm -f /data/adb/post-fs-data.d/xuzhang-guard.sh /data/adb/service.d/xuzhang-guard.sh 2>/dev/null
  rm -f /data/adb/bootlogo-safety/guard.info 2>/dev/null
  echo "序章：已还原原厂第一屏并清理守卫脚本，重启后生效"
else
  echo "序章：还原原厂第一屏没成功！守卫脚本保留着，下次开机还会再试一次。"
  echo "      备份在 /data/adb/bootlogo-safety/original-partition.img，别删这个目录。"
fi