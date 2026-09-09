#!/usr/bin/env python3
"""Builds and verifies Overnight's app icon from the branding master.

The whole pipeline is standard library only, on purpose. `sips` and `iconutil` exist only on
macOS, and pulling in Pillow or ImageMagick would make the icon rebuildable on some machines
and not others. Everything here runs the same way on any host with python3, which is what lets
CI check that the checked-in .icns still matches the master pixel for pixel.

Commands:

    python3 scripts/icons.py build     rewrite the generated assets
    python3 scripts/icons.py verify    check the generated assets against the master

`verify` compares decoded pixels, not compressed bytes. zlib's output is allowed to differ
between versions, so byte equality would be a false alarm waiting to happen; pixel equality is
the property that actually matters.

The one thing that is not guaranteed identical everywhere is `math.sin`, which the Lanczos
kernel calls: a libm that rounds differently could move a resampled channel by one unit, in the
vanishingly rare case where it lands within a rounding step of a byte boundary. `verify` runs on
the Linux CI runner, so that is the platform the committed assets have to agree with.
"""

import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, "resources", "branding", "OvernightIconMaster.png")
ICNS = os.path.join(ROOT, "resources", "Overnight.icns")
README_ICON = os.path.join(ROOT, "resources", "branding", "OvernightIcon-256.png")

# The canvas the icon is designed on. Every other size is an exact halving of it.
CANVAS = 1024

# Apple draws a macOS app icon's rounded rectangle at 824pt inside a 1024pt canvas. The master
# is a full-bleed squircle, so it gets scaled down until its opaque shape hits that proportion
# and the leftover margin becomes the canvas padding and shadow room.
SHAPE = 824

# A drop shadow is part of the macOS icon grid; iOS is the platform that omits it.
SHADOW_OFFSET = 8
SHADOW_RADIUS = 11
SHADOW_OPACITY = 0.28

# OSTypes as `iconutil` writes them for a full .iconset, in the same order. Each entry is
# (OSType, pixel size). Several sizes appear twice because macOS addresses "32x32" and
# "16x16@2x" separately even though they are the same bitmap.
ICNS_ENTRIES = [
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]

README_SIZE = 256


class Image:
    """8-bit RGBA, straight (non-premultiplied) alpha, row-major."""

    __slots__ = ("width", "height", "pixels")

    def __init__(self, width, height, pixels=None):
        self.width = width
        self.height = height
        self.pixels = pixels if pixels is not None else bytearray(width * height * 4)


# --- PNG ------------------------------------------------------------------------------------


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    depth, color, compression, filtering, interlace = data[24:29]
    if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
        raise ValueError("expected a non-interlaced 8-bit RGBA PNG")

    idat = bytearray()
    offset = 8
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        if data[offset + 4:offset + 8] == b"IDAT":
            idat += data[offset + 8:offset + 8 + length]
        offset += 12 + length

    raw = zlib.decompress(bytes(idat))
    stride = width * 4
    out = bytearray(height * stride)
    previous = bytearray(stride)
    pos = 0
    for y in range(height):
        kind = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if kind == 1:
            for x in range(4, stride):
                line[x] = (line[x] + line[x - 4]) & 255
        elif kind == 2:
            for x in range(stride):
                line[x] = (line[x] + previous[x]) & 255
        elif kind == 3:
            for x in range(4):
                line[x] = (line[x] + (previous[x] >> 1)) & 255
            for x in range(4, stride):
                line[x] = (line[x] + ((line[x - 4] + previous[x]) >> 1)) & 255
        elif kind == 4:
            for x in range(4):
                line[x] = (line[x] + previous[x]) & 255
            for x in range(4, stride):
                line[x] = (line[x] + _paeth(line[x - 4], previous[x], previous[x - 4])) & 255
        elif kind != 0:
            raise ValueError("unknown PNG filter %d" % kind)
        out[y * stride:(y + 1) * stride] = line
        previous = line
    return Image(width, height, out)


def _chunk(kind, payload):
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def encode_png(image):
    """Encodes RGBA8 with per-row adaptive filtering, the same heuristic libpng uses."""
    stride = image.width * 4
    pixels = image.pixels
    raw = bytearray()
    previous = bytearray(stride)
    for y in range(image.height):
        line = pixels[y * stride:(y + 1) * stride]
        candidates = []

        none = bytes(line)
        candidates.append((0, none))

        sub = bytearray(line)
        for x in range(stride - 1, 3, -1):
            sub[x] = (line[x] - line[x - 4]) & 255
        candidates.append((1, bytes(sub)))

        up = bytes((line[x] - previous[x]) & 255 for x in range(stride))
        candidates.append((2, up))

        average = bytearray(stride)
        for x in range(4):
            average[x] = (line[x] - (previous[x] >> 1)) & 255
        for x in range(4, stride):
            average[x] = (line[x] - ((line[x - 4] + previous[x]) >> 1)) & 255
        candidates.append((3, bytes(average)))

        paeth = bytearray(stride)
        for x in range(4):
            paeth[x] = (line[x] - previous[x]) & 255
        for x in range(4, stride):
            paeth[x] = (line[x] - _paeth(line[x - 4], previous[x], previous[x - 4])) & 255
        candidates.append((4, bytes(paeth)))

        # Minimum sum of absolute differences, reading each byte as a signed delta.
        best_kind, best = min(
            candidates,
            key=lambda c: sum(b if b < 128 else 256 - b for b in c[1]),
        )
        raw.append(best_kind)
        raw += best
        previous = line

    header = struct.pack(">IIBBBBB", image.width, image.height, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", header)
        + _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + _chunk(b"IEND", b"")
    )


# --- Resampling -----------------------------------------------------------------------------


def _lanczos(x, a):
    if x == 0.0:
        return 1.0
    if x <= -a or x >= a:
        return 0.0
    px = math.pi * x
    return a * math.sin(px) * math.sin(px / a) / (px * px)


def _taps(src_size, dst_size, a=3):
    """Per-output-pixel (index, weight) lists, with the kernel widened when downscaling."""
    scale = dst_size / src_size
    support = a / scale if scale < 1.0 else a
    step = 1.0 / scale
    rows = []
    for i in range(dst_size):
        center = (i + 0.5) * step
        first = max(0, int(center - support + 0.5))
        last = min(src_size - 1, int(center + support - 0.5) + 1)
        weights = []
        total = 0.0
        for j in range(first, last + 1):
            w = _lanczos((j + 0.5 - center) * min(scale, 1.0), a)
            if w != 0.0:
                weights.append((j, w))
                total += w
        if not weights or total == 0.0:
            j = min(src_size - 1, max(0, int(center)))
            weights, total = [(j, 1.0)], 1.0
        rows.append([(j, w / total) for j, w in weights])
    return rows


def resize(image, width, height):
    """Lanczos resample through premultiplied alpha, so transparent pixels cannot bleed in."""
    src_w, src_h, src = image.width, image.height, image.pixels

    # Horizontal pass, into premultiplied floats.
    horizontal = _taps(src_w, width)
    mid = [0.0] * (width * src_h * 4)
    for y in range(src_h):
        base = y * src_w * 4
        row = src[base:base + src_w * 4]
        pr = [0.0] * src_w
        pg = [0.0] * src_w
        pb = [0.0] * src_w
        pa = [0.0] * src_w
        for x in range(src_w):
            o = x * 4
            alpha = row[o + 3] / 255.0
            pr[x] = row[o] * alpha
            pg[x] = row[o + 1] * alpha
            pb[x] = row[o + 2] * alpha
            pa[x] = row[o + 3] * 1.0
        out = y * width * 4
        for x in range(width):
            r = g = b = alpha = 0.0
            for j, w in horizontal[x]:
                r += pr[j] * w
                g += pg[j] * w
                b += pb[j] * w
                alpha += pa[j] * w
            o = out + x * 4
            mid[o] = r
            mid[o + 1] = g
            mid[o + 2] = b
            mid[o + 3] = alpha

    # Vertical pass, back to straight alpha bytes.
    vertical = _taps(src_h, height)
    result = bytearray(width * height * 4)
    for y in range(height):
        taps = vertical[y]
        out = y * width * 4
        for x in range(width):
            r = g = b = alpha = 0.0
            for j, w in taps:
                o = (j * width + x) * 4
                r += mid[o] * w
                g += mid[o + 1] * w
                b += mid[o + 2] * w
                alpha += mid[o + 3] * w
            a8 = _clamp8(alpha)
            o = out + x * 4
            if a8 == 0:
                result[o + 3] = 0
            else:
                inv = 255.0 / a8
                result[o] = _clamp8(r * inv)
                result[o + 1] = _clamp8(g * inv)
                result[o + 2] = _clamp8(b * inv)
                result[o + 3] = a8
    return Image(width, height, result)


def _clamp8(value):
    v = int(value + 0.5)
    if v < 0:
        return 0
    if v > 255:
        return 255
    return v


# --- Composition ----------------------------------------------------------------------------


def opaque_bounds(image, threshold=250):
    """Bounding box of the fully opaque artwork, ignoring antialiased and shadow pixels."""
    min_x, min_y, max_x, max_y = image.width, image.height, -1, -1
    for y in range(image.height):
        base = y * image.width * 4
        row = image.pixels[base:base + image.width * 4]
        solid = [x for x in range(image.width) if row[x * 4 + 3] >= threshold]
        if not solid:
            continue
        min_y = min(min_y, y)
        max_y = y
        min_x = min(min_x, solid[0])
        max_x = max(max_x, solid[-1])
    if max_x < 0:
        raise ValueError("the master has no opaque pixels")
    return min_x, min_y, max_x, max_y


def _box_blur_alpha(alpha, width, height, radius):
    """Three box passes, which is the usual cheap stand-in for a Gaussian."""
    src = alpha
    for _ in range(3):
        dst = bytearray(width * height)
        span = 2 * radius + 1
        for y in range(height):
            base = y * width
            total = src[base] * (radius + 1)
            for i in range(1, radius + 1):
                total += src[base + min(i, width - 1)]
            for x in range(width):
                dst[base + x] = total // span
                total += src[base + min(x + radius + 1, width - 1)]
                total -= src[base + max(x - radius, 0)]
        src = dst
        dst = bytearray(width * height)
        for x in range(width):
            total = src[x] * (radius + 1)
            for i in range(1, radius + 1):
                total += src[min(i, height - 1) * width + x]
            for y in range(height):
                dst[y * width + x] = total // span
                total += src[min(y + radius + 1, height - 1) * width + x]
                total -= src[max(y - radius, 0) * width + x]
        src = dst
    return src


def with_shadow(image, offset, radius, opacity):
    """Composites the artwork over a blurred, offset copy of its own alpha."""
    width, height = image.width, image.height
    alpha = bytearray(image.pixels[3::4])

    shifted = bytearray(width * height)
    for y in range(offset, height):
        shifted[y * width:(y + 1) * width] = alpha[(y - offset) * width:(y - offset + 1) * width]

    blurred = _box_blur_alpha(shifted, width, height, radius)

    result = bytearray(image.pixels)
    for i in range(width * height):
        shadow = int(blurred[i] * opacity + 0.5)
        if shadow == 0:
            continue
        o = i * 4
        top = result[o + 3]
        if top == 255:
            continue
        # Source-over: opaque black shadow underneath, artwork on top.
        out_a = top + shadow * (255 - top) // 255
        if out_a == 0:
            continue
        for c in range(3):
            result[o + c] = (result[o + c] * top) // out_a
        result[o + 3] = out_a
    return Image(width, height, result)


def centered_on_canvas(image, canvas):
    """Places `image` in the middle of a transparent square canvas."""
    if image.width > canvas or image.height > canvas:
        raise ValueError(
            "artwork is %dx%d, too large for a %dpt canvas: the master's opaque shape is a "
            "smaller share of its own canvas than expected"
            % (image.width, image.height, canvas)
        )
    result = bytearray(canvas * canvas * 4)
    left = (canvas - image.width) // 2
    top = (canvas - image.height) // 2
    row_bytes = image.width * 4
    for y in range(image.height):
        dst = ((top + y) * canvas + left) * 4
        result[dst:dst + row_bytes] = image.pixels[y * row_bytes:(y + 1) * row_bytes]
    return Image(canvas, canvas, result)


# --- ICNS -----------------------------------------------------------------------------------


def _icns_entry(kind, payload):
    return kind.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload


def _icns_toc(png_by_size):
    """The `TOC ` entry: every following entry's type and total length, in order.

    Optional as far as the format goes, but Apple's own .icns files and the ones `iconutil`
    writes all carry one, and matching them is the cheapest way to stay on the path macOS's
    icon reader is best tested against.
    """
    return b"".join(
        kind.encode("ascii") + struct.pack(">I", len(png_by_size[size]) + 8)
        for kind, size in ICNS_ENTRIES
    )


def build_icns(png_by_size):
    body = _icns_entry("TOC ", _icns_toc(png_by_size))
    body += b"".join(_icns_entry(kind, png_by_size[size]) for kind, size in ICNS_ENTRIES)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def parse_icns(data):
    if data[:4] != b"icns":
        raise ValueError("not an .icns file")
    total = struct.unpack(">I", data[4:8])[0]
    if total != len(data):
        raise ValueError("icns length field is %d but the file is %d bytes" % (total, len(data)))
    entries = []
    offset = 8
    while offset < len(data):
        kind = data[offset:offset + 4].decode("ascii")
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        if length < 8 or offset + length > len(data):
            raise ValueError("icns entry %s has a bad length" % kind)
        entries.append((kind, data[offset + 8:offset + length]))
        offset += length
    return entries


# --- Pipeline -------------------------------------------------------------------------------


def render_sizes():
    """Master -> Apple's 824-in-1024 grid -> every size the .icns needs.

    Returns {pixel size: Image}. Sizes below 1024 are exact halvings of the canvas, which keeps
    each step a clean 2:1 resample instead of seven independent rescales of the master.
    """
    with open(MASTER, "rb") as handle:
        master = decode_png(handle.read())
    if master.width != master.height:
        raise ValueError("the master must be square, got %dx%d" % (master.width, master.height))

    min_x, min_y, max_x, max_y = opaque_bounds(master)
    shape = max(max_x - min_x + 1, max_y - min_y + 1)
    # Scale the whole master, margins included, until its shape lands on Apple's 824pt grid.
    scaled = round(master.width * SHAPE / shape)

    art = resize(master, scaled, scaled)
    canvas = centered_on_canvas(art, CANVAS)
    canvas = with_shadow(canvas, SHADOW_OFFSET, SHADOW_RADIUS, SHADOW_OPACITY)

    sizes = {CANVAS: canvas}
    size = CANVAS
    while size > 16:
        size //= 2
        sizes[size] = resize(sizes[size * 2], size, size)
    return sizes


def command_build():
    sizes = render_sizes()
    encoded = {size: encode_png(image) for size, image in sizes.items()}

    with open(ICNS, "wb") as handle:
        handle.write(build_icns(encoded))
    with open(README_ICON, "wb") as handle:
        handle.write(encoded[README_SIZE])

    print("wrote %s (%d bytes)" % (os.path.relpath(ICNS, ROOT), os.path.getsize(ICNS)))
    print(
        "wrote %s (%d bytes)"
        % (os.path.relpath(README_ICON, ROOT), os.path.getsize(README_ICON))
    )
    return 0


def command_verify():
    sizes = render_sizes()
    failures = []

    with open(ICNS, "rb") as handle:
        entries = parse_icns(handle.read())

    expected = ["TOC "] + [kind for kind, _ in ICNS_ENTRIES]
    if [kind for kind, _ in entries] != expected:
        failures.append(
            "icns entries are %s, expected %s" % ([k for k, _ in entries], expected)
        )
    else:
        images = entries[1:]
        for (kind, size), (_, payload) in zip(ICNS_ENTRIES, images):
            image = decode_png(payload)
            if (image.width, image.height) != (size, size):
                failures.append(
                    "icns entry %s is %dx%d, expected %dx%d"
                    % (kind, image.width, image.height, size, size)
                )
            elif image.pixels != sizes[size].pixels:
                failures.append("icns entry %s does not match the branding master" % kind)

        toc = b"".join(
            kind.encode("ascii") + struct.pack(">I", len(payload) + 8)
            for kind, payload in images
        )
        if entries[0][1] != toc:
            failures.append("the icns table of contents does not describe the entries after it")

    with open(README_ICON, "rb") as handle:
        readme = decode_png(handle.read())
    if (readme.width, readme.height) != (README_SIZE, README_SIZE):
        failures.append(
            "%s is %dx%d, expected %dx%d"
            % (os.path.basename(README_ICON), readme.width, readme.height, README_SIZE, README_SIZE)
        )
    elif readme.pixels != sizes[README_SIZE].pixels:
        failures.append(
            "%s does not match the branding master" % os.path.basename(README_ICON)
        )

    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print("run 'python3 scripts/icons.py build' to regenerate", file=sys.stderr)
        return 1

    print("icon assets match %s" % os.path.relpath(MASTER, ROOT))
    return 0


def main(argv):
    commands = {"build": command_build, "verify": command_verify}
    if len(argv) != 2 or argv[1] not in commands:
        print("usage: icons.py {build|verify}", file=sys.stderr)
        return 2
    try:
        return commands[argv[1]]()
    except (ValueError, zlib.error) as error:
        # A corrupt or truncated asset is a normal failure for this script to report, not a
        # reason to print a stack trace at whoever is reading the CI log.
        print("%s" % error, file=sys.stderr)
        print("run 'python3 scripts/icons.py build' to regenerate", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
