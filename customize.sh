#!/system/bin/sh
ui_print "***************************"
ui_print " 序章 · HyperOS 开机第一屏管理器"
ui_print "***************************"
ui_print "- 第一屏素材库：/data/adb/bootlogos"
ui_print "- 生效位置：logo 分区（bootloader 直接读，重启即见）"
ui_print "***************************"

MODDIR="${MODPATH:-${0%/*}}"
LIB=/data/adb/bootlogos
STATE="$MODDIR/var/state"

mkdir -p "$MODDIR/var/logs" "$STATE" "$LIB" 2>/dev/null
chmod 0755 "$MODDIR"/*.sh "$MODDIR/bin/ctl.sh" 2>/dev/null
chmod 0644 "$MODDIR/module.prop" "$MODDIR/webroot/index.html" 2>/dev/null

# ---- 内置第一屏入库（已存在同名文件则跳过，保护用户自己的图）----
seeded=0
for f in "$MODDIR"/logos/*.bmp; do
  [ -f "$f" ] || continue
  n=$(basename "$f")
  if [ ! -f "$LIB/$n" ]; then
    cp -f "$f" "$LIB/$n" 2>/dev/null && chmod 0644 "$LIB/$n" 2>/dev/null && seeded=$((seeded + 1))
  fi
done
[ "$seeded" -gt 0 ] && ui_print "- 内置第一屏入库：$seeded 个"

count=$(ls "$LIB"/*.bmp 2>/dev/null | wc -l | tr -d ' ')
ui_print "- 素材库现有 $count 张"

# ---- 升级安装时沿用旧模块里的选择与槽位设置 ----
OLD_STATE="/data/adb/modules/custom_bootlogo/var/state"
if [ ! -s "$STATE/selected.txt" ] && [ -s "$OLD_STATE/selected.txt" ]; then
  cp -f "$OLD_STATE/selected.txt" "$STATE/selected.txt" 2>/dev/null
  [ -s "$OLD_STATE/order.txt" ] && cp -f "$OLD_STATE/order.txt" "$STATE/order.txt" 2>/dev/null
  [ -s "$OLD_STATE/slots.txt" ] && cp -f "$OLD_STATE/slots.txt" "$STATE/slots.txt" 2>/dev/null
  ui_print "- 已沿用上次的选择：$(cat "$STATE/selected.txt" 2>/dev/null)"
fi

# ---- 先备份原厂 logo 分区（动分区前的保命措施，装的时候就做掉）----
if [ -x "$MODDIR/bin/ctl.sh" ]; then
  bk=$("$MODDIR/bin/ctl.sh" backup 2>/dev/null)
  case "$bk" in
    OK*) ui_print "- logo 分区已备份：$(echo "$bk" | sed 's/.*=//')"
         ui_print "  存的是当前分区内容；如果之前用别的工具改过第一屏，这份也是改过的" ;;
    *)   ui_print "- 警告：原厂 logo 分区备份失败，未备份前不会写入分区" ;;
  esac
fi

# ---- 自动判定该改哪些槽位（界面里不出现这个概念，装的时候就定好）----
if [ -x "$MODDIR/bin/ctl.sh" ]; then
  sa=$("$MODDIR/bin/ctl.sh" slots auto 2>/dev/null)
  case "$sa" in
    OK*) ui_print "- 会自动替换的槽位：$(echo "$sa" | sed 's/OK slots=//')（含与开机图同一张图的其他状态）" ;;
    *)   ui_print "- 警告：槽位自动判定失败，只替换第 1 个（正常开机 logo）" ;;
  esac
fi

# ---- 安装守卫脚本（模块被关闭时靠它把分区还原成原厂）----
if [ -x "$MODDIR/bin/ctl.sh" ]; then
  "$MODDIR/bin/ctl.sh" guard >/dev/null 2>&1
fi
guard_n=0
for d in /data/adb/post-fs-data.d /data/adb/service.d; do
  [ -f "$d/xuzhang-guard.sh" ] && guard_n=$((guard_n + 1))
done
[ "$guard_n" -gt 0 ] && ui_print "- 守卫脚本已装好（关掉模块后开机会回原厂第一屏）"

ui_print "- 装完重启，打开模块的「设置」就是界面"