#!/system/bin/sh
# 序章 - 开机第一屏（bootloader logo）管理器 - 控制脚本
# 用法: ctl.sh {list|status|info|slots|select N|import PATH|delete N|scan|ls DIR|reset|order NAME...|backup|restore|guard|unguard|deploy|bootcheck}
#
# 和启幕最大的区别：第一屏是 bootloader 读 logo 分区显示的，运行时拦不住，
# 只能直接写那个分区。所以这里每一步都以「别把分区写坏」为前提：
#   - 动分区前必须先有完整备份，没备份就拒绝写
#   - 只改识别出来的目标槽位（每槽位一张 BMP），分区其余部分一个字节都不碰
#   - 替换图必须和槽位里的原图同宽高、同色深（字节长度一致）才能原地覆盖
#   - 槽位位置不写死：从头部魔数推起，每个槽位再用 BMP 头逐项校验，校验不过就停
#   - 目标槽位由用户选定（默认第 1 个），因为解锁 BL 的机器实际显示的是「带解锁标记」那张
#
# 几处踩过坑的地方，改的时候注意：
#   - 别用 ${var%%|*} 这种带 | 的参数展开，Android 的 mksh 会把模式里的 | 当"或"运算符
#   - 文本文件必须 LF，CRLF 会让 mksh 解析出错
#   - dd 写大块要用 bs=4096 以上；bs=1 写 7.7MB 会慢到不可接受
#   - 反过来，dd 的 skip 对块设备会走 lseek，所以 bs=1 skip=<大偏移> 读几个字节是快的；
#     但 bs=1 count=<大数> 会变成几百万次单字节读（7.7MB 实测 55 秒），
#     要裁剪长度请用 head -c（实测 0.07 秒，结果一致）
#   - 槽位偏移都是 4096 对齐的（实测 0x5000、0x770000…），所以按 4K 扇区算 seek

MODDIR=${0%/*}
MODDIR=${MODDIR%/bin}
LIB_DIR="/data/adb/bootlogos"
# 备份和守卫要用的信息单独放一个目录，不放素材库里 —— 素材库是用户内容，
# 用户删掉它不该把「还原原厂」的能力一起删掉
SAFETY_DIR="/data/adb/bootlogo-safety"
BACKUP_DIR="$SAFETY_DIR"
BACKUP_IMG="$SAFETY_DIR/original-partition.img"
GUARD_INFO="$SAFETY_DIR/guard.info"
STATE_DIR="$MODDIR/var/state"
LOG_DIR="$MODDIR/var/logs"
SELECTED_FILE="$STATE_DIR/selected.txt"
STAMP_FILE="$STATE_DIR/applied.stamp"
SLOTS_FILE="$STATE_DIR/slots.txt"
ORDER_FILE="$STATE_DIR/order.txt"
RESTORE_NAME="恢复原厂第一屏"
SCAN_DIRS="/sdcard/Download /storage/emulated/0/Download /sdcard /data/local/tmp"
LOGO_MAGIC_OFF=16384          # 头部魔数偏移（实测 0x4000）
SECT=4096                     # 槽位按 4K 对齐

mkdir -p "$LIB_DIR" "$STATE_DIR" "$LOG_DIR" 2>/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_DIR/ctl.log" 2>/dev/null; }

# ---------- 工具（参数展开，不派生子进程） ----------
name_of() { n=${1##*/}; printf '%s\n' "${n%.bmp}"; }
file_size() { wc -c <"$1" 2>/dev/null | tr -d ' '; }
sanitize_name() { printf '%s' "$1" | tr -d '\t\r\n' | sed 's/[*?[\]|\\]/_/g' | cut -c1-60; }
md5_of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# ---------- logo 分区 ----------
logo_part() {
  for p in /dev/block/by-name/logo /dev/block/bootdevice/by-name/logo; do
    [ -e "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
part_size() { blockdev --getsize64 "$1" 2>/dev/null; }
screen_wh() { wm size 2>/dev/null | sed -n 's/.*Physical size: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' | head -1; }

# 读 1 个 / 2 个 / 4 个字节
rd() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null; }
rd2() { rd "$1" "$2" 2; }
rd_u32() { rd "$1" "$2" 4 | od -An -tu4 2>/dev/null | tr -d ' '; }
rd_w() { rd "$1" "$2" 2 | od -An -tu2 2>/dev/null | tr -d ' '; }

# ---------- 解析分区里的槽位 ----------
# 输出每行：idx  offset  w  h  bpp  blen（blen = 该 BMP 的字节长度）
# 依据实测结构：0x4000 处是 "LOGO!!!!"，其后第 1 个 u32 是「首槽位偏移/4096」，
# 第 2 个 u32 是「块大小/4096」。槽位连续排列，逐个用 BMP 头校验。
parse_slots() {
  lp=$(logo_part) || { log "logo partition not found"; return 1; }
  [ -r "$lp" ] || { log "logo partition not readable"; return 1; }
  psz=$(part_size "$lp"); [ -n "$psz" ] && [ "$psz" -gt 0 ] || { log "cannot get partition size"; return 1; }

  magic=$(rd "$lp" "$LOGO_MAGIC_OFF" 8)
  [ "$magic" = "LOGO!!!!" ] || { log "logo magic mismatch at $LOGO_MAGIC_OFF"; return 1; }

  base4=$(rd_u32 "$lp" $((LOGO_MAGIC_OFF + 8)))
  blk4=$(rd_u32 "$lp" $((LOGO_MAGIC_OFF + 12)))
  case "$base4" in ''|*[!0-9]*) return 1 ;; esac
  case "$blk4"  in ''|*[!0-9]*) return 1 ;; esac
  [ "$base4" -gt 0 ] && [ "$blk4" -gt 0 ] || return 1

  off=$((base4 * SECT)); blk=$((blk4 * SECT))
  [ $((off + blk)) -le "$psz" ] || { log "slot table out of range"; return 1; }

  idx=0
  while [ $((off + 54)) -le "$psz" ]; do
    m=$(rd2 "$lp" "$off")
    [ "$m" = "BM" ] || break                       # 不是 BMP 就到此为止（不再往下猜）
    dib=$(rd_u32 "$lp" $((off + 14)))
    w=$(rd_u32 "$lp" $((off + 18)))
    hs=$(rd_u32 "$lp" $((off + 22)))
    bpp=$(rd_w  "$lp" $((off + 28)))
    case "$dib" in 40|108|124) ;; *) break ;; esac
    case "$w" in ''|*[!0-9]*) break ;; esac
    case "$hs" in ''|*[!0-9]*) break ;; esac
    case "$bpp" in 16|24|32) ;; *) break ;; esac
    [ "$w" -gt 0 ] && [ "$w" -lt 20000 ] || break
    [ "$hs" -gt 0 ] && [ "$hs" -lt 20000 ] || break

    # BMP 实际长度 = 文件头(14) + DIB + 调色板 + 像素数据（行按 4 字节对齐）
    rowsz=$(( ((w * bpp + 31) / 32) * 4 ))
    pal=0
    [ "$bpp" -le 8 ] && pal=$(( (1 << bpp) * 4 ))
    blen=$(( 14 + dib + pal + rowsz * hs ))
    [ "$blen" -le "$blk" ] || break                # 装不进块里 → 说明推算错了，停
    [ $((off + blen)) -le "$psz" ] || break

    idx=$((idx + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$off" "$w" "$hs" "$bpp" "$blen"
    off=$((off + blk))
  done
  [ "$idx" -gt 0 ] || { log "no valid slot found"; return 1; }
  [ "$idx" -gt 0 ]
}

# 按编号取槽位行
slot_at() { parse_slots 2>/dev/null | awk -F'\t' -v i="$1" '$1 == i {print; exit}'; }

# ---------- 目标槽位 ----------
# 默认只有第 1 个（正常开机 logo）。解锁 BL 的机器实际显示的是「带解锁标记」那张，
# 界面上会把所有槽位列出来让用户勾选。
# ---------- 自动判定该改哪些槽位 ----------
# 「槽位」是实现细节，不该让用户操心，所以默认自己判断：
#   第 1 个（正常开机 logo）+ 所有「和它几乎是同一张图」的槽位
# —— 同一张图的不同状态（典型是解锁 BL 时显示的那张，只多了个解锁小标记）逐字节差异很小，
# 而诊断性质的屏（FASTBOOT、系统损坏提示）是完全不同的图，差异明显更大，不会被误伤。
# 判据用有界 cmp：数到阈值就停（head 会提前关闭管道），避免大图拖慢。
AUTO_DIFF_PERMIL=155      # 千分比阈值 1.55%（本机实测：目标 1.298%，最近的诊断屏 1.805%）
detect_targets() {
  lp=$(logo_part) || return 1
  rows=$(parse_slots 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1
  b_off=$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1{print $2}')
  b_len=$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1{print $6}')
  case "$b_off" in ''|*[!0-9]*) return 1 ;; esac
  case "$b_len" in ''|*[!0-9]*) return 1 ;; esac

  mkdir -p "$SAFETY_DIR" 2>/dev/null
  t="$SAFETY_DIR/.slot1.$$.tmp"
  dd if="$lp" bs="$SECT" skip=$((b_off / SECT)) count=$(( (b_len + SECT - 1) / SECT )) 2>/dev/null | head -c "$b_len" >"$t" || { rm -f "$t"; return 1; }
  [ -s "$t" ] || { rm -f "$t"; return 1; }

  res="$SAFETY_DIR/.detect.$$.tmp"
  printf '1\n' >"$res" 2>/dev/null || { rm -f "$t"; return 1; }
  limit=$(( b_len * AUTO_DIFF_PERMIL / 10000 ))
  [ "$limit" -gt 0 ] || limit=1
  printf '%s\n' "$rows" | while IFS='	' read -r i o w h b bl; do
    [ "$i" -gt 1 ] || continue
    [ "$bl" = "$b_len" ] || continue          # 几何不同就不可能是同一张图的变体
    c="$SAFETY_DIR/.slotk.$$.tmp"
    dd if="$lp" bs="$SECT" skip=$((o / SECT)) count=$(( (bl + SECT - 1) / SECT )) 2>/dev/null | head -c "$bl" >"$c" 2>/dev/null || continue
    n=$(cmp -l "$t" "$c" 2>/dev/null | head -n "$limit" | wc -l | tr -d ' ')
    rm -f "$c" 2>/dev/null
    [ -n "$n" ] && [ "$n" -lt "$limit" ] && printf '%s\n' "$i" >>"$res"
  done
  rm -f "$t" 2>/dev/null
  out=$(tr '\n' ' ' <"$res" 2>/dev/null)
  rm -f "$res" 2>/dev/null
  [ -n "$out" ] || out="1 "
  printf '%s\n' "$out"
}

slots_target() {
  if [ -s "$SLOTS_FILE" ]; then
    tr -d '\r' <"$SLOTS_FILE" 2>/dev/null | awk 'NF{printf "%s ", $1}'
    return 0
  fi
  # 没设过就自动判定一次并缓存下来（安装时已经算过，正常不会再走这里）
  d=$(detect_targets 2>/dev/null)
  [ -n "$d" ] || d="1 "
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s\n' "$d" | tr ' ' '\n' | awk 'NF' >"$SLOTS_FILE" 2>/dev/null
  log "auto targets:$d"
  printf '%s\n' "$d"
}

cmd_slots() {
  if [ "$1" = "auto" ]; then
    # 强制重新自动判定（安装时跑一次；诊断屏/变体变了也可以手动重跑）
    rm -f "$SLOTS_FILE" 2>/dev/null
    d=$(detect_targets) || { echo "ERROR 自动判定失败"; return 1; }
    printf '%s\n' "$d" | tr ' ' '\n' | awk 'NF' >"$SLOTS_FILE" 2>/dev/null
    log "auto targets:$d"
    echo "OK slots=$d"
    return 0
  fi
  if [ "$1" = "set" ]; then
    shift
    if [ "$#" -eq 0 ]; then echo "ERROR 至少要选一个槽位"; return 1; fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    tmp="$STATE_DIR/.slots.$$.tmp"
    : >"$tmp" 2>/dev/null || { echo "ERROR 无法写入槽位设置"; return 1; }
    for i in "$@"; do
      case "$i" in ''|*[!0-9]*) continue ;; esac
      # slot_at 找不到时 awk 仍然返回 0，所以必须看输出是否为空，不能只看退出码
      [ -n "$(slot_at "$i")" ] && printf '%s\n' "$i" >>"$tmp"
    done
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "ERROR 槽位编号无效"; return 1; }
    mv -f "$tmp" "$SLOTS_FILE" 2>/dev/null || { rm -f "$tmp"; echo "ERROR 保存失败"; return 1; }
    log "target slots: $(slots_target)"
    echo "OK slots=$(slots_target)"
    return 0
  fi
  # 列出槽位：编号 偏移 分辨率 色深 长度 是否选中
  # 注意用空格做集合边界：slots_target 输出的是「1 2 」这种空格分隔串，
  # 用 | 当边界只有第一个编号能匹配上，第 2 个以后会被误判成未选中
  tg=" $(slots_target)"
  parse_slots 2>/dev/null | while IFS='	' read -r i o w h b bl; do
    sel=no
    case "$tg" in *" $i "*) sel=yes ;; esac
    printf '%s\t%s\t%sx%s\t%sbpp\t%s\t%s\n' "$i" "$o" "$w" "$h" "$b" "$bl" "$sel"
  done
}

# ---------- 备份 / 恢复 ----------
# 动分区前必须有完整备份；没有就先拷一份出来。备份失败 → 一律拒绝写分区。
ensure_backup() {
  lp=$(logo_part) || return 1
  mkdir -p "$BACKUP_DIR" 2>/dev/null
  # 兼容旧版：早期备份放在素材库的 backup/ 下，换了目录后把它搬过来，
  # 否则老用户的备份成了孤儿，reset 会直接报「没有备份」
  if [ ! -s "$BACKUP_IMG" ] && [ -s "$LIB_DIR/backup/original-partition.img" ]; then
    cp -f "$LIB_DIR/backup/original-partition.img" "$BACKUP_IMG" 2>/dev/null && log "migrated old backup -> $BACKUP_IMG"
  fi
  if [ -s "$BACKUP_IMG" ]; then
    psz=$(part_size "$lp"); bsz=$(file_size "$BACKUP_IMG")
    [ -n "$psz" ] && [ "$psz" = "$bsz" ] && return 0
    # 已有备份但大小对不上：绝不重拷覆盖它 —— 万一当前分区已经被改过，
    # 重拷会把「改过的样子」当成原厂存下来，就再也回不去了。报错交给用户处理。
    log "backup exists but size mismatch ($bsz vs $psz) - refuse to overwrite"
    return 1
  fi
  # 备份不存在、但模块已经应用过（有选择或写入记录）→ 说明备份是被删掉的，
  # 此刻分区很可能已不是原厂。这时再「备份当前内容」就把改过的样子当原厂存了，
  # 所以直接拒绝写入，让人自己处理（真实踩过：这样造出过一份假的"原厂"备份）。
  if [ -s "$STAMP_FILE" ] || [ -s "$SELECTED_FILE" ]; then
    log "backup missing but module already used - refuse to fabricate a new 'original'"
    return 1
  fi
  tmp="$BACKUP_DIR/.orig.$$.tmp"
  if dd if="$lp" of="$tmp" bs=1M 2>/dev/null && [ -s "$tmp" ]; then
    sz=$(file_size "$tmp")
    psz=$(part_size "$lp")
    if [ -n "$psz" ] && [ "$sz" = "$psz" ]; then
      mv -f "$tmp" "$BACKUP_IMG" 2>/dev/null || { rm -f "$tmp"; return 1; }
      md5_of "$BACKUP_IMG" >"$BACKUP_DIR/original.md5" 2>/dev/null
      log "backup created: $BACKUP_IMG ($sz bytes)"
      return 0
    fi
    log "backup size mismatch after dump: $sz vs $psz"
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

cmd_backup() {
  if ensure_backup; then
    echo "OK backup=$(file_size "$BACKUP_IMG") bytes"
  else
    echo "ERROR 备份失败"
    return 1
  fi
}

# 把备份写回分区（整分区、字节还原）
restore_logo() {
  lp=$(logo_part) || { echo "ERROR 找不到 logo 分区"; return 1; }
  [ -s "$BACKUP_IMG" ] || { echo "ERROR 没有备份，恢复不了"; return 1; }
  psz=$(part_size "$lp"); bsz=$(file_size "$BACKUP_IMG")
  [ -n "$psz" ] && [ "$psz" = "$bsz" ] || { echo "ERROR 备份大小与分区不符，拒绝写入"; return 1; }
  echo "- 正在还原原厂 logo 分区（$(echo "$bsz" | awk '{printf "%.1f", $1/1048576}') MB）…"
  if dd if="$BACKUP_IMG" of="$lp" bs=1M 2>/dev/null; then
    rm -f "$STAMP_FILE" 2>/dev/null
    log "restored original logo partition ($bsz bytes)"
    echo "OK restored=original"
  else
    echo "ERROR 还原失败"
    return 1
  fi
}

# ---------- 把某个第一屏写进分区 ----------
apply_logo() {
  n="$1"
  [ -n "$n" ] || { echo "ERROR 未指定第一屏"; return 1; }
  [ "$n" = "$RESTORE_NAME" ] && { restore_logo; return $?; }

  src="$LIB_DIR/$n.bmp"
  [ -f "$src" ] || { echo "ERROR 找不到该第一屏"; return 1; }
  lp=$(logo_part) || { echo "ERROR 找不到 logo 分区"; return 1; }
  ensure_backup || { echo "ERROR 备份失败，拒绝写分区"; return 1; }

  # 先确认是张真的 BMP（库里的文件也可能是用户自己 cp 进来的，别只信长度）
  [ "$(rd2 "$src" 0)" = "BM" ] || { echo "ERROR 不是 BMP 文件"; return 1; }
  sdib=$(rd_u32 "$src" 14)
  case "$sdib" in 40|108|124) ;; *) echo "ERROR BMP 头不认识"; return 1 ;; esac

  tg=$(slots_target)
  [ -n "$tg" ] || { echo "ERROR 没有选中任何槽位"; return 1; }
  ssz=$(file_size "$src")

  # 先全量校验，再动分区：任一槽位对不上就整体不写
  for i in $tg; do
    row=$(slot_at "$i")
    [ -n "$row" ] || { echo "ERROR 槽位 $i 不存在"; return 1; }
    so=$(echo "$row" | cut -f2); sw=$(echo "$row" | cut -f3)
    sh_=$(echo "$row" | cut -f4); sb=$(echo "$row" | cut -f5); sbl=$(echo "$row" | cut -f6)
    if [ "$ssz" != "$sbl" ]; then
      echo "ERROR 图不匹配：需要 ${sw}x${sh_} ${sb}bpp 的 BMP（${sbl} 字节），这张是 ${ssz} 字节"
      return 1
    fi
    # 再核一遍尺寸字段，防止长度碰巧相同但内容不是 BMP
    fw=$(rd_u32 "$src" 18); fh=$(rd_u32 "$src" 22); fb=$(rd_w "$src" 28)
    if [ "$fw" != "$sw" ] || [ "$fh" != "$sh_" ] || [ "$fb" != "$sb" ]; then
      echo "ERROR 图不匹配：需要 ${sw}x${sh_} ${sb}bpp，这张是 ${fw}x${fh} ${fb}bpp"
      return 1
    fi
  done

  # 先把「可能被改到的槽位」记进守卫信息，再开始写 —— 万一写到一半失败，
  # 守卫仍然知道这些槽位需要还原
  write_guard_info

  # 逐个槽位原地覆盖（槽位偏移都是 4K 对齐）
  for i in $tg; do
    row=$(slot_at "$i")
    so=$(echo "$row" | cut -f2)
    [ -n "$so" ] || { echo "ERROR 槽位 $i 读取失败"; return 1; }
    if ! dd if="$src" of="$lp" bs="$SECT" seek=$((so / SECT)) conv=notrunc 2>/dev/null; then
      echo "ERROR 写入槽位 $i 失败"
      log "write slot $i at $so FAILED"
      return 1
    fi
    log "wrote slot $i at $so <- $src"
  done

  smd5=$(md5_of "$src")
  # 只存 md5：名字里万一带冒号会把「名字:md5」的解析弄坏，而校验只需要 md5
  printf '%s\n' "$smd5" >"$STAMP_FILE" 2>/dev/null
  echo "OK applied=$n slots=$(slots_target)"
  echo "next_boot=1"
}

# ---------- 校验分区里现在是不是该有的样子 ----------
# 逐个目标槽位都比：只查第一个的话，多槽位替换里有一个没写成功会被漏掉。
# 选了「恢复原厂」时，对比基准是备份里的原图（而不是某张素材）——
# 这样恢复完成才是一个可验证的终态，bootcheck 也不会每次开机重写一遍。
verify_applied() {
  lp=$(logo_part) || return 1
  tg=$(slots_target)
  [ -n "$tg" ] || return 1

  src=""; want=""
  if [ "$(active_name)" = "$RESTORE_NAME" ]; then
    [ -s "$BACKUP_IMG" ] || return 1
    src="$BACKUP_IMG"
  else
    [ -s "$STAMP_FILE" ] || return 1
    want=$(head -n1 "$STAMP_FILE" 2>/dev/null | tr -d '\r\n')
    [ -n "$want" ] || return 1
  fi

  for i in $tg; do
    row=$(slot_at "$i"); [ -n "$row" ] || return 1
    so=$(echo "$row" | cut -f2); sbl=$(echo "$row" | cut -f6)
    # 裁剪长度必须用 head -c：dd bs=1 count=N 会退化成 N 次单字节读（7.7MB 实测 55 秒）
    got=$(dd if="$lp" bs="$SECT" skip=$((so / SECT)) count=$(( (sbl + SECT - 1) / SECT )) 2>/dev/null | head -c "$sbl" | md5sum 2>/dev/null | awk '{print $1}')
    [ -n "$got" ] || return 1
    if [ -n "$src" ]; then
      exp=$(dd if="$src" bs="$SECT" skip=$((so / SECT)) count=$(( (sbl + SECT - 1) / SECT )) 2>/dev/null | head -c "$sbl" | md5sum 2>/dev/null | awk '{print $1}')
      [ -n "$exp" ] && [ "$got" = "$exp" ] || return 1
    else
      [ "$got" = "$want" ] || return 1
    fi
  done
  return 0
}

# service.sh 调：分区被 ROM 重置过就补写一次
cmd_bootcheck() {
  n=$(active_name)
  [ -n "$n" ] || { log "bootcheck: no selection"; return 0; }
  # 原厂状态不需要维护：分区本来就是原厂。不早退的话 verify 会一直失败，
  # 每次开机都拿备份整分区重写一遍（64MB），还会把 ROM 更新后的新 logo 顶掉。
  [ "$n" = "$RESTORE_NAME" ] && { log "bootcheck: factory state, nothing to do"; return 0; }
  if verify_applied; then
    log "bootcheck: partition matches '$n'"
    return 0
  fi
  log "bootcheck: partition does not match '$n', re-apply"
  apply_logo "$n" >/dev/null 2>&1
}

# ---------- 守卫脚本 ----------
# 模块被关闭(disable)时模块自己的脚本一行都不会跑，所以「还原原厂第一屏」这件事
# 必须交给模块外、始终会运行的脚本。/data/adb/post-fs-data.d 正合适。
GUARD_NAME="xuzhang-guard.sh"
GUARD_DIRS="/data/adb/post-fs-data.d /data/adb/service.d"

write_guard_info() {
  lp=$(logo_part) || return 0
  mkdir -p "$LIB_DIR" 2>/dev/null
  # 守卫要还原的是「所有曾经被改过的槽位」——目标槽位可能变过
  # （比如先只换第 1 个，后来又加上第 3 个），所以这里是并集，只增不减。
  old=""
  [ -f "$GUARD_INFO" ] && old=$(sed -n 's/^SLOTS="\(.*\)"$/\1/p' "$GUARD_INFO" 2>/dev/null)
  tg=$(slots_target)
  sl="$old"
  for i in $tg; do
    row=$(slot_at "$i") || continue
    [ -n "$row" ] || continue
    o=$(echo "$row" | cut -f2); l=$(echo "$row" | cut -f6)
    ent="$o:$l"
    case " $sl " in *" $ent "*) ;; *) sl="$sl $ent" ;; esac
  done
  [ -n "$sl" ] || return 0
  cat >"$GUARD_INFO" <<EOF
PART=$lp
BACKUP=$BACKUP_IMG
SLOTS="$sl"
EOF
  chmod 0644 "$GUARD_INFO" 2>/dev/null
}

install_guard() {
  [ -d "$MODDIR" ] || return 0
  write_guard_info
  for d in $GUARD_DIRS; do
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || continue
    g="$d/$GUARD_NAME"
    cat >"$g" <<'GUARD_EOF'
#!/system/bin/sh
# 序章 XuZhang 守卫脚本 —— 由「开机第一屏管理器」模块安装，请勿手动修改
# 作用：模块被关闭(disable)或移除时，把 logo 分区的目标槽位恢复成备份里的原厂图。
#       模块启用中则什么都不做。
MOD=/data/adb/modules/custom_bootlogo
INFO=/data/adb/bootlogo-safety/guard.info
[ -f "$INFO" ] || exit 0
if [ -d "$MOD" ] && [ ! -e "$MOD/disable" ] && [ ! -e "$MOD/remove" ]; then
  exit 0
fi
. "$INFO"
[ -n "$PART" ] && [ -f "$BACKUP" ] || exit 0
# 分区尺寸和备份对不上说明分区布局变了（比如 ROM 更新换了几何），按旧偏移写会写坏，宁可不写
[ "$(wc -c <"$PART" 2>/dev/null | tr -d ' ')" = "$(wc -c <"$BACKUP" 2>/dev/null | tr -d ' ')" ] || exit 0
for s in $SLOTS; do
  o=${s%:*}; l=${s#*:}
  [ -n "$o" ] && [ -n "$l" ] || continue
  dd if="$BACKUP" of="$PART" bs=4096 skip=$((o / 4096)) count=$(( (l + 4095) / 4096 )) conv=notrunc 2>/dev/null
done
exit 0
GUARD_EOF
    chmod 0755 "$g" 2>/dev/null
    log "guard installed: $g"
  done
  return 0
}

remove_guard() {
  for d in $GUARD_DIRS; do rm -f "$d/$GUARD_NAME" 2>/dev/null; done
}

# ---------- 动画库列表 ----------
ENTRIES_INIT=""
ENTRIES=""
load_entries() {
  [ -n "$ENTRIES_INIT" ] && return 0
  ENTRIES_INIT=1
  ENTRIES=$(ls -1 "$LIB_DIR"/*.bmp 2>/dev/null | sort)
}

entry_paths() {
  load_entries
  seen="|"
  if [ -s "$ORDER_FILE" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      seen="$seen$n|"
      [ -f "$LIB_DIR/$n.bmp" ] && printf '%s\n' "$LIB_DIR/$n.bmp"
    done <"$ORDER_FILE"
  fi
  [ -n "$ENTRIES" ] || return 0
  printf '%s\n' "$ENTRIES" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=${p##*/}; n=${n%.bmp}
    case "$seen" in *"|$n|"*) continue ;; esac
    printf '%s\n' "$p"
  done
}

entry_count() {
  load_entries
  [ -n "$ENTRIES" ] || { echo 0; return 0; }
  printf '%s\n' "$ENTRIES" | grep -c . 2>/dev/null || echo 0
}

entry_at() {
  want="$1"
  i=0
  entry_paths | while IFS= read -r p; do
    i=$((i + 1))
    if [ "$i" = "$want" ]; then printf '%s\n' "$p"; break; fi
  done
}

active_name() { [ -s "$SELECTED_FILE" ] && tr -d '\r\n' <"$SELECTED_FILE" 2>/dev/null; }
active_path() {
  an=$(active_name)
  [ -n "$an" ] && [ "$an" != "$RESTORE_NAME" ] && [ -f "$LIB_DIR/$an.bmp" ] && echo "$LIB_DIR/$an.bmp"
}

# 每张图显示：宽x高 · 大小（BMP 头里读，不依赖别的工具）
logo_info() {
  f="$1"
  w=$(rd_u32 "$f" 18); h=$(rd_u32 "$f" 22); b=$(rd_w "$f" 28)
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  case "$h" in ''|*[!0-9]*) h=0 ;; esac
  printf '%sx%s · %sbpp' "$w" "$h" "$b"
}

# ---------- 命令 ----------
cmd_list() {
  i=0
  an=$(active_name)
  entry_paths | while IFS= read -r p; do
    i=$((i + 1))
    n=${p##*/}; n=${n%.bmp}
    act=no
    [ "$n" = "$an" ] && act=yes
    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$n" "$(file_size "$p")" "$act" "$(logo_info "$p")"
  done
}

cmd_status() {
  an=$(active_name)
  echo "active=${an:-无}"
  echo "count=$(entry_count)"
  echo "library=$LIB_DIR"
  lp=$(logo_part)
  if [ -n "$lp" ]; then
    echo "part=$lp"
    echo "part_size=$(part_size "$lp")"
  else
    echo "part="
    echo "part_size=0"
  fi
  if [ -s "$BACKUP_IMG" ]; then
    echo "backup=$(file_size "$BACKUP_IMG")"
  else
    echo "backup=0"
  fi
  if verify_applied; then echo "applied=yes"; else echo "applied=no"; fi
  echo "slots_target=$(slots_target)"
  echo "slot_count=$(parse_slots 2>/dev/null | grep -c .)"
}

cmd_info() {
  cmd_status
  printf '%s\n' "##LIST"
  cmd_list
}

cmd_select() {
  idx="$1"
  case "$idx" in ''|*[!0-9]*) echo "ERROR 编号无效"; return 1;; esac
  p=$(entry_at "$idx")
  if [ -z "$p" ] || [ ! -f "$p" ]; then echo "ERROR 找不到该第一屏"; return 1; fi
  n=$(name_of "$p")
  printf '%s\n' "$n" >"$SELECTED_FILE" 2>/dev/null || { echo "ERROR 保存选择失败"; return 1; }
  if apply_logo "$n"; then
    return 0
  fi
  echo "ERROR 已选择，但写入分区失败"
  return 1
}

cmd_reset() {
  if restore_logo; then
    printf '%s\n' "$RESTORE_NAME" >"$SELECTED_FILE" 2>/dev/null
    echo "OK selected=$RESTORE_NAME"
  else
    echo "ERROR 恢复原厂失败"
    return 1
  fi
}

cmd_import() {
  src="$1"
  [ -n "$src" ] || { echo "ERROR 未指定文件"; return 1; }
  [ -f "$src" ] || { echo "ERROR 找不到文件: $src"; return 1; }

  base=$(sanitize_name "$(name_of "$src")")
  [ -n "$base" ] || base="imported"

  # 校验：必须是 BMP
  [ "$(rd2 "$src" 0)" = "BM" ] || { echo "ERROR 不是 BMP 文件"; return 1; }
  dib=$(rd_u32 "$src" 14)
  case "$dib" in 40|108|124) ;; *) echo "ERROR BMP 头不认识"; return 1 ;; esac

  # 按「选中列表里第一个槽位」的尺寸校验 —— apply 时就是拿它比的
  # （不是写死第 1 个：目标槽位未必是第 1 个，各槽位几何也可能不同）
  tgi=$(slots_target | awk '{print $1}')
  row=""
  [ -n "$tgi" ] && row=$(slot_at "$tgi")
  if [ -n "$row" ]; then
    sw=$(echo "$row" | cut -f3); sh_=$(echo "$row" | cut -f4)
    sb=$(echo "$row" | cut -f5); sbl=$(echo "$row" | cut -f6)
    fw=$(rd_u32 "$src" 18); fh=$(rd_u32 "$src" 22); fb=$(rd_w "$src" 28)
    ssz=$(file_size "$src")
    if [ "$fw" != "$sw" ] || [ "$fh" != "$sh_" ] || [ "$fb" != "$sb" ]; then
      echo "ERROR 尺寸不符：本机需要 ${sw}x${sh_} ${sb}bpp，这张是 ${fw}x${fh} ${fb}bpp"
      return 1
    fi
    [ "$ssz" = "$sbl" ] || { echo "ERROR 文件长度不符：需要 ${sbl} 字节，这张 ${ssz} 字节"; return 1; }
  fi

  target="$LIB_DIR/$base.bmp"
  n=2
  while [ -e "$target" ]; do target="$LIB_DIR/$base-$n.bmp"; n=$((n + 1)); done
  tmp="$LIB_DIR/.import.$$.tmp"
  if cp -f "$src" "$tmp" 2>/dev/null && mv -f "$tmp" "$target" 2>/dev/null; then
    chmod 0644 "$target" 2>/dev/null
    log "imported: $target"
    echo "OK stored=${target##*/}"
  else
    rm -f "$tmp" 2>/dev/null
    echo "ERROR 复制文件失败"
    return 1
  fi
}

cmd_delete() {
  idx="$1"
  case "$idx" in ''|*[!0-9]*) echo "ERROR 编号无效"; return 1;; esac
  p=$(entry_at "$idx")
  [ -n "$p" ] && [ -f "$p" ] || { echo "ERROR 找不到该第一屏"; return 1; }
  n=$(name_of "$p")
  if [ "$n" = "$(active_name)" ]; then
    echo "ERROR 这张正在用，请先切到别的（或选「$RESTORE_NAME」）"
    return 1
  fi
  rm -f "$p" 2>/dev/null || { echo "ERROR 删除失败"; return 1; }
  log "deleted: $p"
  echo "OK deleted=$n"
}

cmd_order() {
  [ "$#" -gt 0 ] || { echo "ERROR 参数为空"; return 1; }
  mkdir -p "$STATE_DIR" 2>/dev/null
  tmp="$STATE_DIR/.order.$$.tmp"
  : >"$tmp" 2>/dev/null || { echo "ERROR 无法写入排序"; return 1; }
  for n in "$@"; do
    [ -n "$n" ] || continue
    [ -f "$LIB_DIR/$n.bmp" ] && printf '%s\n' "$n" >>"$tmp"
  done
  if mv -f "$tmp" "$ORDER_FILE" 2>/dev/null; then
    log "order updated: $(tr '\n' ' ' <"$ORDER_FILE" 2>/dev/null)"
    echo "OK order=updated"
  else
    rm -f "$tmp" 2>/dev/null
    echo "ERROR 保存排序失败"
    return 1
  fi
}

# 扫描目录里的候选 BMP，按能否用于本机标注 yes/no
cmd_scan() {
  tgi=$(slots_target | awk '{print $1}')
  row=""
  [ -n "$tgi" ] && row=$(slot_at "$tgi")
  sw=$(echo "$row" | cut -f3); sh_=$(echo "$row" | cut -f4)
  sb=$(echo "$row" | cut -f5); sbl=$(echo "$row" | cut -f6)
  for d in $SCAN_DIRS; do
    [ -d "$d" ] || continue
    ls -1 "$d"/*.bmp "$d"/*.BMP 2>/dev/null | while IFS= read -r p; do
      [ -f "$p" ] || continue
      case "${p##*/}" in .*) continue ;; esac
      ok=no
      if [ "$(rd2 "$p" 0)" = "BM" ]; then
        fw=$(rd_u32 "$p" 18); fh=$(rd_u32 "$p" 22); fb=$(rd_w "$p" 28)
        if [ -n "$sw" ]; then
          [ "$fw" = "$sw" ] && [ "$fh" = "$sh_" ] && [ "$fb" = "$sb" ] && [ "$(file_size "$p")" = "$sbl" ] && ok=yes
        else
          ok=yes
        fi
      fi
      printf '%s\t%s\t%s\n' "$p" "$(file_size "$p")" "$ok"
    done
  done
}

cmd_ls() {
  d="$1"
  [ -n "$d" ] || d="/sdcard"
  case "$d" in /*) ;; *) d="/sdcard/$d" ;; esac
  [ -d "$d" ] || { echo "ERROR 目录不存在: $d"; return 1; }
  ls -1 "$d" 2>/dev/null | while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in .*) continue ;; esac
    p="$d/$n"
    if [ -d "$p" ]; then
      printf 'D\t%s\t%s\n' "$n" "$p"
    else
      case "$n" in *.bmp|*.BMP) printf 'F\t%s\t%s\t%s\n' "$n" "$(file_size "$p")" "$p" ;; esac
    fi
  done
}

case "$1" in
  list) cmd_list ;;
  status) cmd_status ;;
  info) cmd_info ;;
  slots) shift; cmd_slots "$@" ;;
  select) cmd_select "$2" ;;
  import) cmd_import "$2" ;;
  delete) cmd_delete "$2" ;;
  scan) cmd_scan ;;
  ls) cmd_ls "$2" ;;
  reset) cmd_reset ;;
  order) shift; cmd_order "$@" ;;
  backup) cmd_backup ;;
  restore) restore_logo ;;
  guard) install_guard && echo "OK guard installed" ;;
  unguard) remove_guard && echo "OK guard removed" ;;
  deploy) apply_logo "$(active_name)" ;;
  bootcheck) cmd_bootcheck && echo "OK bootcheck" ;;
  *) echo "用法: $0 {list|status|info|slots [set N...]|select N|import PATH|delete N|scan|ls DIR|reset|order NAME...|backup|restore|guard|unguard|deploy|bootcheck}"; exit 64 ;;
esac