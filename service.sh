#!/system/bin/sh
# late_start 兜底：ROM 更新/其它工具可能把 logo 分区刷回原厂，这里对一次账再补写
MODDIR=${0%/*}
mkdir -p "$MODDIR/var/logs" 2>/dev/null
exec >>"$MODDIR/var/logs/service.log" 2>&1
sleep 20
echo "[$(date '+%Y-%m-%d %H:%M:%S')] service check"
"$MODDIR/bin/ctl.sh" bootcheck