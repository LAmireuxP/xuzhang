#!/usr/bin/env python3
"""把任意图片转成能直接用于「序章」第一屏的 BMP。

为什么要转换：第一屏的替换图必须和 logo 分区里那个槽位的原图「同宽高、同色深」，
也就是字节长度一致，才能原地覆盖。这个脚本负责等比缩放、居中贴到黑底、补成目标
分辨率，再存成 24bpp BMP。

用法:
    pip install pillow
    python logo_convert.py 我的图.png 输出.bmp                  # 默认 1080x2400
    python logo_convert.py 我的图.png 输出.bmp --size 1440x3200
    python logo_convert.py 我的图.png 输出.bmp --scale 0.8      # 再留一圈边
    python logo_convert.py --probe 某张.bmp                     # 只校验一张现成 BMP

本机需要什么尺寸，在模块界面点「槽位」就能看到（宽x高 和 色深），按它填 --size。
"""
import argparse
import os
import struct
import sys

BMP_HEADER = 14
DIB_OK = (40, 108, 124)


def bmp_len(w, h, bpp, dib=40):
    """按 BMP 规格算出文件字节长度（行按 4 字节对齐）"""
    row = ((w * bpp + 31) // 32) * 4
    pal = (1 << bpp) * 4 if bpp <= 8 else 0
    return BMP_HEADER + dib + pal + row * abs(h)


def probe(path):
    """读一张 BMP 的头，返回 (w, h, bpp, dib, 实际长度, 规格长度)"""
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        raise SystemExit(f"{path} 不是 BMP")
    dib = struct.unpack_from("<I", d, 14)[0]
    if dib not in DIB_OK:
        raise SystemExit(f"{path} 的 BMP DIB 头是 {dib}，不认")
    w, h = struct.unpack_from("<ii", d, 18)
    bpp = struct.unpack_from("<H", d, 28)[0]
    return w, h, bpp, dib, len(d), bmp_len(w, h, bpp, dib)


def convert(src, dst, size, scale, bg):
    from PIL import Image, ImageOps

    tw, th = size
    im = Image.open(src)
    im = ImageOps.exif_transpose(im)          # 手机拍的照片带方向信息，先掰正
    im = im.convert("RGB")

    # 等比缩放到目标尺寸内（再乘 scale 留边），居中贴到黑底
    box_w, box_h = int(tw * scale), int(th * scale)
    ratio = min(box_w / im.width, box_h / im.height)
    new = im.resize((max(1, int(im.width * ratio)), max(1, int(im.height * ratio))), Image.LANCZOS)

    canvas = Image.new("RGB", (tw, th), bg)
    canvas.paste(new, ((tw - new.width) // 2, (th - new.height) // 2))

    canvas.save(dst, "BMP")
    w, h, bpp, dib, actual, expect = probe(dst)
    if actual != expect:
        raise SystemExit(f"写出来的 BMP 长度不对：{actual} != {expect}")
    return w, h, bpp, actual


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("src", nargs="?")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--size", default="1080x2400", help="目标分辨率，默认 1080x2400")
    ap.add_argument("--scale", type=float, default=1.0, help="内容占比，默认 1.0（铺满），0.8 会留一圈黑边")
    ap.add_argument("--bg", default="#000000", help="背景色，默认纯黑")
    ap.add_argument("--probe", metavar="BMP", help="只校验一张现成的 BMP，不转换")
    a = ap.parse_args()

    if a.probe:
        w, h, bpp, dib, actual, expect = probe(a.probe)
        ok = "OK" if actual == expect else "长度异常"
        print(f"{a.probe}\n  {w}x{h} {bpp}bpp DIB={dib}\n  实际 {actual} 字节 / 规格 {expect} 字节  -> {ok}")
        return 0 if actual == expect else 1

    if not a.src or not a.dst:
        ap.error("需要 输入图 和 输出.bmp（或用 --probe 校验现成的）")
    try:
        tw, th = (int(x) for x in a.size.lower().split("x"))
    except Exception:
        raise SystemExit("--size 格式应为 1080x2400")

    if a.dst.lower().endswith(".bmp") is False:
        raise SystemExit("输出文件名要以 .bmp 结尾")

    w, h, bpp, n = convert(a.src, a.dst, (tw, th), a.scale, a.bg)
    print(f"已生成 {a.dst}")
    print(f"  {w}x{h} {bpp}bpp，{n} 字节")
    print(f"  长度和本机需要的对得上就能直接导入：{n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())