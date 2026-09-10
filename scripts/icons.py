#!/usr/bin/env python3
"""Builds and verifies every piece of Overnight's branding from one master image.

    resources/branding/OvernightIconMaster.png
        |
        +-- resources/Overnight.icns ................ the app bundle's icon
        +-- resources/branding/OvernightIcon-256.png . the one the README shows
        +-- resources/VolumeIcon.icns ............... the mounted DMG's icon in the sidebar
        +-- resources/branding/OvernightVolumeIcon-256.png ... the one the docs show
        +-- resources/branding/OvernightDMGBackground.png ...  the installer window, 1x
        +-- resources/branding/OvernightDMGBackground@2x.png . and at 2x

The whole pipeline is standard library only, on purpose. `sips` and `iconutil` exist only on
macOS, and pulling in Pillow or ImageMagick would make the artwork rebuildable on some machines
and not others. Everything here runs the same way on any host with python3, which is what lets
CI check that the checked-in assets still match the master pixel for pixel.

The installer window's geometry is not in this file. It lives in
resources/branding/dmg-layout.env, which scripts/make-dmg.sh also reads, so the arrow painted
into the background and the icons Finder puts on either side of it cannot drift apart.

Commands:

    python3 scripts/icons.py build      rewrite the generated assets
    python3 scripts/icons.py verify     check the generated assets against the master
    python3 scripts/icons.py palette    print the colours read off the master

`verify` compares decoded pixels, not compressed bytes. zlib's output is allowed to differ
between versions, so byte equality would be a false alarm waiting to happen; pixel equality is
the property that actually matters.

The one thing that is not guaranteed identical everywhere is `math.sin`, which the Lanczos
kernel calls: a libm that rounds differently could move a resampled channel by one unit, in the
vanishingly rare case where it lands within a rounding step of a byte boundary. Everything
drawn from scratch rather than resampled avoids the problem entirely by sticking to the five
operations IEEE 754 pins exactly — see the note above the drawing section. `verify` runs on the
Linux CI runner, so that is the platform the committed assets have to agree with.
"""

import array
import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, "resources", "branding", "OvernightIconMaster.png")
ICNS = os.path.join(ROOT, "resources", "Overnight.icns")
README_ICON = os.path.join(ROOT, "resources", "branding", "OvernightIcon-256.png")
VOLUME_ICNS = os.path.join(ROOT, "resources", "VolumeIcon.icns")
VOLUME_PREVIEW = os.path.join(
    ROOT, "resources", "branding", "OvernightVolumeIcon-256.png"
)

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


# --- The brand's own colours ----------------------------------------------------------------


def brand_palette(image):
    """Pulls the three colours everything else is painted with out of the icon itself.

    Nothing here invents a colour. The DMG background and the volume icon have to look like
    they came out of the same tin of paint as the app icon, and the cheapest way to guarantee
    that is to read the paint off the icon rather than to write hex codes down twice.

    Takes the 256pt representation rather than the master because it is already rendered by
    the time this is called and because a Lanczos reduction has averaged away the master's
    per-pixel grain, which is what makes the answer stable rather than a lottery between
    neighbouring speckles.
    """
    samples = []
    pixels = image.pixels
    for i in range(image.width * image.height):
        o = i * 4
        if pixels[o + 3] < 250:
            continue
        # Rec. 601 weights, kept as integers so the ordering is exact.
        samples.append((2 * pixels[o] + 5 * pixels[o + 1] + pixels[o + 2], o))
    if not samples:
        raise ValueError("the icon has no opaque pixels to take a palette from")
    samples.sort()

    def mean(subset):
        if not subset:
            raise ValueError("empty palette band")
        red = green = blue = 0
        for _, o in subset:
            red += pixels[o]
            green += pixels[o + 1]
            blue += pixels[o + 2]
        count = len(subset)
        return (red // count, green // count, blue // count)

    count = len(samples)
    return {
        # The band's hot centre: the top half percent of the icon by luminance.
        "core": mean(samples[int(count * 0.995):] or samples[-1:]),
        # The blue haze the band fades into, taken from the shoulder of the distribution.
        "halo": mean(samples[int(count * 0.82):int(count * 0.90)]),
        # The night the whole thing sits on: the darkest quarter.
        "deep": mean(samples[:max(1, int(count * 0.25))]),
    }


def _mix(a, b, t):
    """Straight linear blend between two RGB triples, t = 0 gives a."""
    return tuple(int(a[i] + (b[i] - a[i]) * t + 0.5) for i in range(3))


# --- Drawing --------------------------------------------------------------------------------
#
# Everything below paints with +, -, *, / and sqrt only. No exp, no sin, no cos, no pow. That is
# not stylistic: IEEE 754 pins those five operations to a single correctly rounded answer on
# every platform and pins nothing about the transcendentals, so this is the difference between
# artwork that is bit-identical everywhere and artwork that is bit-identical on whatever libm
# happened to build it. Since `verify` fails a build over a single differing byte, the second
# kind would be unusable.
#
# So the falloff curves are polynomials rather than Gaussians, "how much does this face the
# light" is a dot product rather than a cosine, and a curve's arms are tilted by a fraction of
# its own slope rather than by an angle in degrees. The resampler above is the one part of the
# pipeline this does not cover — Lanczos needs a sine — and the module docstring says so.


class _Noise:
    """A 64-bit linear congruential generator, for star fields and nothing else.

    `random` would do, but its stream is a documented implementation detail rather than a
    guarantee, and these bytes get committed. Sixteen lines of integer arithmetic is a cheaper
    promise to keep than "no future Python changes the Mersenne Twister".
    """

    __slots__ = ("state",)

    _MASK = (1 << 64) - 1

    def __init__(self, seed):
        self.state = seed & self._MASK

    def _step(self):
        # Knuth's multiplier and increment, as used by Numerical Recipes.
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) & self._MASK
        return self.state >> 33

    def unit(self):
        """The next value in [0, 1)."""
        return self._step() / 2147483648.0

    def between(self, low, high):
        return low + (high - low) * self.unit()


def _glow(u):
    """A bell that is 1 at the centre, 0 at and beyond u = 1, and flat at both ends."""
    if u >= 1.0:
        return 0.0
    if u <= 0.0:
        return 1.0
    v = 1.0 - u * u
    return v * v * v


def _ramp(u):
    """Smoothstep: 0 below u = 0, 1 above u = 1, with zero slope at both."""
    if u <= 0.0:
        return 0.0
    if u >= 1.0:
        return 1.0
    return u * u * (3.0 - 2.0 * u)


def _s_curve(start, end, arm_tilt, arm_reach, samples):
    """Samples the same S the menu bar glyph is built from, in whatever space you hand it.

    Both control points come from one arm vector reflected through the chord's midpoint, so the
    curve is symmetric under a half turn about that point and inflects exactly halfway along.
    `Sources/OvernightCore/MenuBarBand.swift` builds the menu bar glyph from that same
    construction; this is the shape at background scale, which is why the two read as one mark.

    `arm_tilt` is how much of the chord's own slope the arms take, from 0 for arms that run flat
    along the chord's x axis to 1 for arms parallel to the chord. It has to stay under 1: at 1
    the curve is a straight line, and past it the S inverts. MenuBarBand states the same knob as
    an angle in degrees, which reads better in a design constant but needs a tangent to use;
    here it is a ratio, so that nothing in this file has to call a transcendental.

    `arm_reach` is how far along that direction each control point sits, as a fraction of the
    chord, and is what sets how pronounced the S is.
    """
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    span = math.sqrt(dx * dx + dy * dy)
    tilted = math.sqrt(dx * dx + dy * dy * arm_tilt * arm_tilt)
    reach = arm_reach * span / tilted
    arm = (reach * dx, reach * dy * arm_tilt)
    p0 = start
    p1 = (start[0] + arm[0], start[1] + arm[1])
    p2 = (end[0] - arm[0], end[1] - arm[1])
    p3 = end
    points = []
    for i in range(samples + 1):
        t = i / samples
        u = 1.0 - t
        a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
        points.append((
            a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
            a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1],
        ))
    return points


def _distance_to_polyline(px, py, points):
    best = None
    for i in range(len(points) - 1):
        ax, ay = points[i]
        bx, by = points[i + 1]
        vx, vy = bx - ax, by - ay
        span = vx * vx + vy * vy
        if span == 0.0:
            t = 0.0
        else:
            t = ((px - ax) * vx + (py - ay) * vy) / span
            if t < 0.0:
                t = 0.0
            elif t > 1.0:
                t = 1.0
        dx = px - (ax + vx * t)
        dy = py - (ay + vy * t)
        d = dx * dx + dy * dy
        if best is None or d < best:
            best = d
    return math.sqrt(best)


def _distance_to_segments(px, py, segments):
    best = None
    for ax, ay, bx, by in segments:
        vx, vy = bx - ax, by - ay
        span = vx * vx + vy * vy
        if span == 0.0:
            t = 0.0
        else:
            t = ((px - ax) * vx + (py - ay) * vy) / span
            if t < 0.0:
                t = 0.0
            elif t > 1.0:
                t = 1.0
        dx = px - (ax + vx * t)
        dy = py - (ay + vy * t)
        d = dx * dx + dy * dy
        if best is None or d < best:
            best = d
    return math.sqrt(best)


class Painting:
    """A float RGB canvas with no alpha, because a window background is never see-through.

    Channels are kept as floats in 0..255 rather than bytes so that a hundred faint additions
    accumulate instead of each rounding to nothing.
    """

    __slots__ = ("width", "height", "red", "green", "blue")

    def __init__(self, width, height):
        self.width = width
        self.height = height
        size = width * height
        self.red = array.array("d", bytes(8 * size))
        self.green = array.array("d", bytes(8 * size))
        self.blue = array.array("d", bytes(8 * size))

    def add(self, index, colour, amount):
        if amount <= 0.0:
            return
        self.red[index] += colour[0] * amount
        self.green[index] += colour[1] * amount
        self.blue[index] += colour[2] * amount

    def blend(self, index, colour, alpha):
        if alpha <= 0.0:
            return
        keep = 1.0 - alpha
        self.red[index] = self.red[index] * keep + colour[0] * alpha
        self.green[index] = self.green[index] * keep + colour[1] * alpha
        self.blue[index] = self.blue[index] * keep + colour[2] * alpha

    def to_image(self):
        """Rounds to bytes through an ordered dither.

        The installer window's sky falls through about twenty values per channel over 400
        points. Rounded straight to bytes that is twenty visible bands; Finder does not
        dither it for you. A signed half-unit Bayer offset breaks the bands into a texture
        that is invisible at any normal viewing distance and, unlike random dither, still
        compresses.
        """
        pixels = bytearray(self.width * self.height * 4)
        for y in range(self.height):
            row = y * self.width
            for x in range(self.width):
                i = row + x
                bias = _BAYER[(y & 7) * 8 + (x & 7)]
                o = i * 4
                pixels[o] = _clamp8(self.red[i] + bias)
                pixels[o + 1] = _clamp8(self.green[i] + bias)
                pixels[o + 2] = _clamp8(self.blue[i] + bias)
                pixels[o + 3] = 255
        return Image(self.width, self.height, pixels)


def _bayer_8():
    """The classic 8x8 ordered-dither matrix, recursed from [[0, 2], [3, 1]]."""
    matrix = [[0]]
    while len(matrix) < 8:
        size = len(matrix)
        grown = [[0] * (size * 2) for _ in range(size * 2)]
        for y in range(size):
            for x in range(size):
                value = matrix[y][x] * 4
                grown[y][x] = value
                grown[y][x + size] = value + 2
                grown[y + size][x] = value + 3
                grown[y + size][x + size] = value + 1
        matrix = grown
    # Centred on zero and scaled to a little under half a byte step.
    return [(matrix[y][x] + 0.5) / 64.0 - 0.5 for y in range(8) for x in range(8)]


_BAYER = _bayer_8()


# --- The mounted volume's icon --------------------------------------------------------------
#
# A DMG that reuses the app icon for its volume tells you nothing: the thing in the sidebar is
# not the app, it is a disk with the app on it. So this is a disk — a platter, seen face on,
# with a spindle and a lit rim — surfaced with the app icon's own artwork. It reads as
# "Overnight, on a disk" at 512pt and as a dark disc with a band of light at 16pt.

VOLUME_CANVAS = 1024

# The platter's diameter on that canvas. Smaller than the app icon's 824pt squircle grid on
# purpose: a circle of the same width reads as larger than a rounded rectangle, and macOS
# draws volume icons without the app-icon grid's margins anyway.
VOLUME_DISC = 880

# How much bigger the master's squircle is blown up before the platter is cut out of it.
# Masking the master at its own size would intersect a circle with a rounded square and leave
# an octagon; enlarging first means the disc is cut from the middle of the artwork, well inside
# the squircle's corners, and comes out actually round.
VOLUME_FILL = 1.34

# Where the light comes from, as a unit vector in image coordinates with y downward. Up and to
# the left, which is where macOS lights everything else.
VOLUME_LIGHT = (-0.7071067811865476, -0.7071067811865476)

# The lit edge of the platter, as fractions of its radius.
VOLUME_RIM_INSET = 0.012
VOLUME_RIM_WIDTH = 0.030
VOLUME_BEVEL_WIDTH = 0.115
VOLUME_BEVEL_DEPTH = 0.42

# The spindle. Small and hard-edged: a large soft one reads as a planet sitting on the artwork
# rather than as a hole through a disk. The radius is a fraction of the canvas; the other two
# are fractions of that radius, for the width of its edge and the size of the hole inside it.
VOLUME_HUB_RADIUS = 0.070
VOLUME_HUB_EDGE = 0.12
VOLUME_HUB_HOLE = 0.42

VOLUME_SHADOW_OFFSET = 8
VOLUME_SHADOW_RADIUS = 12
VOLUME_SHADOW_OPACITY = 0.30

VOLUME_PREVIEW_SIZE = 256


def centered_square(image, size):
    """Crops or pads `image` to a centred square of `size`, whichever it needs."""
    result = bytearray(size * size * 4)
    left = (image.width - size) // 2
    top = (image.height - size) // 2
    for y in range(size):
        src_y = top + y
        if src_y < 0 or src_y >= image.height:
            continue
        for x in range(size):
            src_x = left + x
            if src_x < 0 or src_x >= image.width:
                continue
            src = (src_y * image.width + src_x) * 4
            dst = (y * size + x) * 4
            result[dst:dst + 4] = image.pixels[src:src + 4]
    return Image(size, size, result)


def render_volume_sizes(master, palette):
    """Master -> a branded platter -> every size the volume .icns needs.

    Returns {pixel size: Image}, on the same halving ladder as the app icon.
    """
    min_x, min_y, max_x, max_y = opaque_bounds(master)
    shape = max(max_x - min_x + 1, max_y - min_y + 1)
    # Blow the master up until the disc can be cut from the middle of its squircle rather than
    # from the squircle's outline, then take the square the disc is inscribed in.
    enlarged = round(master.width * (VOLUME_DISC * VOLUME_FILL) / shape)
    art = centered_square(resize(master, enlarged, enlarged), VOLUME_DISC)
    art = centered_on_canvas(art, VOLUME_CANVAS)

    pixels = bytearray(art.pixels)
    canvas = VOLUME_CANVAS
    centre = canvas / 2.0
    radius = VOLUME_DISC / 2.0

    rim_colour = _mix(palette["core"], (255, 255, 255), 0.35)
    hub_colour = _mix(palette["deep"], palette["halo"], 0.45)

    rim_centre = radius * (1.0 - VOLUME_RIM_INSET)
    rim_width = radius * VOLUME_RIM_WIDTH
    bevel_width = radius * VOLUME_BEVEL_WIDTH
    hub_radius = canvas * VOLUME_HUB_RADIUS
    hub_edge = hub_radius * VOLUME_HUB_EDGE
    hub_hole = hub_radius * VOLUME_HUB_HOLE

    for y in range(canvas):
        dy = y + 0.5 - centre
        row = y * canvas
        for x in range(canvas):
            dx = x + 0.5 - centre
            d = math.sqrt(dx * dx + dy * dy)
            o = (row + x) * 4

            # Cut the platter out of the artwork, one pixel of antialiasing at the edge. Inside
            # it the alpha is forced opaque: the crop came from well within the master's own
            # shape, so anything less than solid there would be a resampling artefact.
            coverage = radius + 0.5 - d
            if coverage <= 0.0:
                pixels[o + 3] = 0
                continue
            pixels[o + 3] = 255 if coverage >= 1.0 else _clamp8(255.0 * coverage)

            # Which way this pixel faces, for the lighting. The exact centre faces nowhere.
            facing = (dx * VOLUME_LIGHT[0] + dy * VOLUME_LIGHT[1]) / d if d > 0.0 else 0.0

            # Bevel: the platter's edge turns away from the viewer, so it darkens, and it
            # darkens hardest where it also turns away from the light.
            bevel = _glow((radius - d) / bevel_width) if d <= radius else 1.0
            if bevel > 0.0:
                shade = 1.0 - VOLUME_BEVEL_DEPTH * bevel * (0.55 - 0.45 * facing)
                pixels[o] = _clamp8(pixels[o] * shade)
                pixels[o + 1] = _clamp8(pixels[o + 1] * shade)
                pixels[o + 2] = _clamp8(pixels[o + 2] * shade)

            # Rim: a machined edge catching the light, brightest where it faces it.
            rim = _glow(abs(d - rim_centre) / rim_width)
            if rim > 0.0:
                lit = rim * (0.15 + 0.85 * _ramp((facing + 0.35) / 1.1))
                for c in range(3):
                    pixels[o + c] = _clamp8(
                        pixels[o + c] + (rim_colour[c] - pixels[o + c]) * lit
                    )

            # Spindle: a punched hole with a lit lip. This is the one detail that stops the
            # whole thing reading as a round app icon.
            if d < hub_radius + hub_edge:
                inside = _ramp((hub_radius - d) / hub_edge)
                if inside > 0.0:
                    for c in range(3):
                        pixels[o + c] = _clamp8(pixels[o + c] * (1.0 - 0.86 * inside))
                    core = _ramp((hub_hole - d) / hub_edge)
                    if core > 0.0:
                        for c in range(3):
                            pixels[o + c] = _clamp8(
                                pixels[o + c] + (hub_colour[c] - pixels[o + c]) * core * 0.55
                            )
                lip = _glow(abs(d - hub_radius) / hub_edge)
                if lip > 0.0:
                    # Lit from the far side of the light, the way a recess is.
                    lit = lip * (0.15 + 0.85 * _ramp((0.35 - facing) / 1.1)) * 0.70
                    for c in range(3):
                        pixels[o + c] = _clamp8(
                            pixels[o + c] + (rim_colour[c] - pixels[o + c]) * lit
                        )

    platter = with_shadow(
        Image(canvas, canvas, pixels),
        VOLUME_SHADOW_OFFSET,
        VOLUME_SHADOW_RADIUS,
        VOLUME_SHADOW_OPACITY,
    )

    sizes = {canvas: platter}
    size = canvas
    while size > 16:
        size //= 2
        sizes[size] = resize(sizes[size * 2], size, size)
    return sizes


# --- The installer window's background ------------------------------------------------------
#
# Deep space with the galactic band across the bottom, a well under each icon so a near-black
# app icon does not vanish into a near-black background, and an arrow between them. There is no
# lettering: Finder already writes "Overnight" and "Applications" under the two icons, and a
# hand-rolled stroke font underneath its real one would look like exactly what it is.

DMG_LAYOUT = os.path.join(ROOT, "resources", "branding", "dmg-layout.env")
DMG_BACKGROUND = os.path.join(ROOT, "resources", "branding", "OvernightDMGBackground.png")
DMG_BACKGROUND_2X = os.path.join(
    ROOT, "resources", "branding", "OvernightDMGBackground@2x.png"
)

# The @2x asset is what gets painted; the 1x is a reduction of it, so the two cannot drift.
DMG_SCALE = 2

# The starlight is drawn at a fraction of the final resolution and enlarged once. Nothing in it
# has detail finer than tens of points, so this costs nothing visible and saves most of the
# work — and because every layer is additive, adding them before the enlargement rather than
# after gives the same answer for one resample instead of four.
DMG_GLOW_DIVISOR = 4

DMG_STAR_COUNT = 420
DMG_STAR_SEED = 0x0BE12A17


def read_dmg_layout(path=DMG_LAYOUT):
    """Reads resources/branding/dmg-layout.env, the file make-dmg.sh sources.

    Deliberately dumb: KEY=value, one per line, `#` starts a comment. Anything that would make
    the shell and this disagree — quoting, substitution, continuations — is rejected rather
    than half-supported, because "the shell read it one way and Python the other" is the exact
    failure this file exists to prevent.
    """
    values = {}
    with open(path, "r") as handle:
        for number, line in enumerate(handle, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if "=" not in line:
                raise ValueError("%s:%d: expected KEY=value" % (os.path.basename(path), number))
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if not key or not value or any(c in value for c in "\"'$`\\ "):
                raise ValueError(
                    "%s:%d: %s must be an unquoted bare word with no substitutions"
                    % (os.path.basename(path), number, key)
                )
            values[key] = int(value) if value.lstrip("-").isdigit() else value
    required = [
        "DMG_VOLUME_NAME", "DMG_WINDOW_WIDTH", "DMG_WINDOW_HEIGHT",
        "DMG_WINDOW_X", "DMG_WINDOW_Y", "DMG_ICON_SIZE", "DMG_TEXT_SIZE",
        "DMG_APP_X", "DMG_APP_Y", "DMG_APPLICATIONS_X", "DMG_APPLICATIONS_Y",
    ]
    missing = [key for key in required if key not in values]
    if missing:
        raise ValueError("%s is missing %s" % (os.path.basename(path), ", ".join(missing)))
    return values


def _starlight(width, height, layers):
    """Every glow in the window, painted small, added together, and enlarged once.

    `layers` is a list of (points, radius, peak, inner, outer). Each contributes a band of
    light along its polyline, `inner` at the core fading through `outer` at the edge. The
    distance to each polyline is computed once and reused by every layer that shares it, which
    is what makes a narrow bright streak inside a wide dim haze affordable.

    Returns a full-size RGBA image with the light in the alpha channel.
    """
    low_w = max(8, width // DMG_GLOW_DIVISOR)
    low_h = max(8, height // DMG_GLOW_DIVISOR)
    step_x = width / low_w
    step_y = height / low_h
    count = low_w * low_h

    # Keyed by identity, so two layers that were handed the same list of points share one
    # distance field and two that were not simply do not. Passing the same curve twice is how a
    # narrow bright streak inside a wide dim haze is paid for once.
    fields = {}
    for points, _, _, _, _ in layers:
        key = id(points)
        if key in fields:
            continue
        field = array.array("d", bytes(8 * count))
        for y in range(low_h):
            py = (y + 0.5) * step_y
            row = y * low_w
            for x in range(low_w):
                field[row + x] = _distance_to_polyline((x + 0.5) * step_x, py, points)
        fields[key] = field

    # Premultiplied, so overlapping layers add as light does rather than as paint.
    red = array.array("d", bytes(8 * count))
    green = array.array("d", bytes(8 * count))
    blue = array.array("d", bytes(8 * count))
    alpha = array.array("d", bytes(8 * count))
    for points, radius, peak, inner, outer in layers:
        field = fields[id(points)]
        for i in range(count):
            intensity = _glow(field[i] / radius)
            if intensity <= 0.0:
                continue
            weight = peak * intensity
            colour = _mix(outer, inner, intensity * intensity)
            red[i] += colour[0] * weight
            green[i] += colour[1] * weight
            blue[i] += colour[2] * weight
            alpha[i] += weight

    pixels = bytearray(count * 4)
    for i in range(count):
        a = alpha[i]
        if a <= 0.0:
            continue
        o = i * 4
        if a > 1.0:
            a = 1.0
        # Back to straight alpha, dividing out the weight the colours were accumulated with.
        scale = 1.0 / alpha[i]
        pixels[o] = _clamp8(red[i] * scale)
        pixels[o + 1] = _clamp8(green[i] * scale)
        pixels[o + 2] = _clamp8(blue[i] * scale)
        pixels[o + 3] = _clamp8(255.0 * a)
    return resize(Image(low_w, low_h, pixels), width, height)


def render_dmg_background(layout, palette):
    """Returns {1: Image, 2: Image} for the installer window's background."""
    scale = DMG_SCALE
    width = layout["DMG_WINDOW_WIDTH"] * scale
    height = layout["DMG_WINDOW_HEIGHT"] * scale
    painting = Painting(width, height)

    deep = palette["deep"]
    halo = palette["halo"]
    core = palette["core"]
    sky = _mix(deep, halo, 0.16)
    floor = _mix(deep, (0, 0, 0), 0.55)
    dust = _mix(deep, halo, 0.55)

    # 1. Night, darkening downward, with the corners falling away.
    for y in range(height):
        f = y / (height - 1.0)
        base = _mix(sky, floor, f * (2.0 - f))
        ny = (y + 0.5 - height / 2.0) / (height / 2.0)
        row = y * width
        for x in range(width):
            nx = (x + 0.5 - width / 2.0) / (width / 2.0)
            fade = nx * nx * 0.55 + ny * ny * 0.80
            if fade > 1.0:
                fade = 1.0
            keep = 1.0 - 0.45 * fade * fade
            i = row + x
            painting.red[i] = base[0] * keep
            painting.green[i] = base[1] * keep
            painting.blue[i] = base[2] * keep

    # 2. The galactic band: a wide dim haze with a narrow bright streak down the middle of it,
    #    which is how it is built in the app icon too, and a far fainter one near the top for
    #    depth. Both follow the menu bar glyph's S at another scale.
    near = _s_curve((-90 * scale, 438 * scale), (690 * scale, 350 * scale), 0.47, 0.50, 64)
    far = _s_curve((-90 * scale, 60 * scale), (690 * scale, 16 * scale), 0.39, 0.50, 64)
    light = _starlight(width, height, [
        (near, 100.0 * scale, 0.26, halo, dust),
        (near, 18.0 * scale, 0.34, core, halo),
        (far, 54.0 * scale, 0.07, halo, dust),
        (far, 9.0 * scale, 0.06, core, halo),
    ])
    lit = light.pixels
    red, green, blue = painting.red, painting.green, painting.blue
    for i in range(width * height):
        o = i * 4
        a = lit[o + 3]
        if a:
            a /= 255.0
            red[i] += lit[o] * a
            green[i] += lit[o + 1] * a
            blue[i] += lit[o + 2] * a

    # 3. Stars. Sparse, dim, and never inside the wells, where they would read as dirt on the
    #    artwork rather than as sky.
    noise = _Noise(DMG_STAR_SEED)
    wells = [
        (layout["DMG_APP_X"] * scale, layout["DMG_APP_Y"] * scale),
        (layout["DMG_APPLICATIONS_X"] * scale, layout["DMG_APPLICATIONS_Y"] * scale),
    ]
    well_radius = 104.0 * scale
    star_tint = _mix(halo, (255, 255, 255), 0.72)
    for _ in range(DMG_STAR_COUNT):
        sx = noise.between(0, width)
        sy = noise.between(0, height)
        size = noise.between(0.5, 1.5) * scale
        brightness = noise.between(0.06, 0.42)
        near_well = False
        for wx, wy in wells:
            dx, dy = sx - wx, sy - wy
            if math.sqrt(dx * dx + dy * dy) < well_radius:
                near_well = True
                break
        if near_well:
            continue
        span = int(size) + 2
        for y in range(max(0, int(sy) - span), min(height, int(sy) + span + 1)):
            dy = y + 0.5 - sy
            row = y * width
            for x in range(max(0, int(sx) - span), min(width, int(sx) + span + 1)):
                dx = x + 0.5 - sx
                painting.add(
                    row + x, star_tint,
                    brightness * _glow(math.sqrt(dx * dx + dy * dy) / size),
                )

    # 4. A well under each icon: a lit plate with a soft edge and a rim. Without one, a
    #    near-black app icon on a near-black background is a rectangle of nothing with a label
    #    under it. A plain blurred blob would do the job too and look like a smudge, so this
    #    holds a flat centre out to 78% of its radius and only then falls away.
    #
    #    It is also wide enough to reach under the label Finder writes below each icon. Finder
    #    picks that label's colour from the system appearance rather than from the background
    #    it is drawn over, so a dark installer window is a light-mode legibility risk; the
    #    plate is the local contrast that hedges it. MANUAL-CHECKS M9 is where that gets an
    #    actual pair of eyes on it, in both appearances.
    well_tint = _mix(halo, core, 0.25)
    well_rim = _mix(halo, core, 0.55)
    for wx, wy in wells:
        span = int(well_radius) + 2
        for y in range(max(0, int(wy) - span), min(height, int(wy) + span + 1)):
            dy = y + 0.5 - wy
            row = y * width
            for x in range(max(0, int(wx) - span), min(width, int(wx) + span + 1)):
                dx = x + 0.5 - wx
                d = math.sqrt(dx * dx + dy * dy)
                plate = 1.0 - _ramp((d - well_radius * 0.78) / (well_radius * 0.22))
                painting.add(row + x, well_tint, 0.13 * plate)
                painting.add(
                    row + x, well_rim,
                    0.06 * _glow(abs(d - well_radius * 0.88) / (well_radius * 0.12)),
                )

    # 5. The arrow, which is the whole instruction the window gives, so it is drawn at the
    #    weight of the icons it sits between rather than as a hint.
    arrow_y = (layout["DMG_APP_Y"] + layout["DMG_APPLICATIONS_Y"]) / 2.0 * scale
    arrow_x = (layout["DMG_APP_X"] + layout["DMG_APPLICATIONS_X"]) / 2.0 * scale
    stroke = 9.0 * scale
    reach = 40.0 * scale
    head = 18.0 * scale
    segments = [
        (arrow_x - reach, arrow_y, arrow_x + reach - stroke * 0.5, arrow_y),
        (arrow_x + reach - head, arrow_y - head, arrow_x + reach - stroke * 0.5, arrow_y),
        (arrow_x + reach - head, arrow_y + head, arrow_x + reach - stroke * 0.5, arrow_y),
    ]
    arrow_tint = _mix(halo, core, 0.80)
    bloom = stroke * 2.6
    x0 = max(0, int(arrow_x - reach - bloom))
    x1 = min(width - 1, int(arrow_x + reach + bloom))
    y0 = max(0, int(arrow_y - head - bloom))
    y1 = min(height - 1, int(arrow_y + head + bloom))
    for y in range(y0, y1 + 1):
        row = y * width
        for x in range(x0, x1 + 1):
            d = _distance_to_segments(x + 0.5, y + 0.5, segments)
            painting.add(row + x, halo, 0.15 * _glow(d / bloom))
            edge = stroke / 2.0 + 0.5 - d
            if edge > 0.0:
                painting.blend(row + x, arrow_tint, 0.9 * (1.0 if edge >= 1.0 else edge))

    full = painting.to_image()
    return {scale: full, 1: resize(full, width // scale, height // scale)}


# --- Pipeline -------------------------------------------------------------------------------


def load_master():
    """The branding master, decoded once. Everything generated here comes out of this file."""
    with open(MASTER, "rb") as handle:
        master = decode_png(handle.read())
    if master.width != master.height:
        raise ValueError("the master must be square, got %dx%d" % (master.width, master.height))
    return master


def render_sizes(master=None):
    """Master -> Apple's 824-in-1024 grid -> every size the .icns needs.

    Returns {pixel size: Image}. Sizes below 1024 are exact halvings of the canvas, which keeps
    each step a clean 2:1 resample instead of seven independent rescales of the master.
    """
    master = load_master() if master is None else master

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


def render_everything():
    """Every generated asset, from the one master, in one pass.

    The app icon is rendered first because its 256pt representation is what the palette is
    read off, so the volume icon's rim and the installer background's sky are literally the
    app icon's own colours rather than a second set of hex codes to keep in step.
    """
    master = load_master()
    icon = render_sizes(master)
    palette = brand_palette(icon[README_SIZE])
    layout = read_dmg_layout()
    return {
        "icon": icon,
        "volume": render_volume_sizes(master, palette),
        "background": render_dmg_background(layout, palette),
        "layout": layout,
        "palette": palette,
    }


def _write(path, payload):
    with open(path, "wb") as handle:
        handle.write(payload)
    print("wrote %s (%d bytes)" % (os.path.relpath(path, ROOT), os.path.getsize(path)))


def command_build():
    rendered = render_everything()

    icon = {size: encode_png(image) for size, image in rendered["icon"].items()}
    volume = {size: encode_png(image) for size, image in rendered["volume"].items()}

    _write(ICNS, build_icns(icon))
    _write(README_ICON, icon[README_SIZE])
    _write(VOLUME_ICNS, build_icns(volume))
    _write(VOLUME_PREVIEW, volume[VOLUME_PREVIEW_SIZE])
    _write(DMG_BACKGROUND, encode_png(rendered["background"][1]))
    _write(DMG_BACKGROUND_2X, encode_png(rendered["background"][DMG_SCALE]))
    return 0


def _check_icns(path, sizes, failures):
    """Every representation in a committed .icns, against what the master says it should be."""
    name = os.path.relpath(path, ROOT)
    with open(path, "rb") as handle:
        entries = parse_icns(handle.read())

    expected = ["TOC "] + [kind for kind, _ in ICNS_ENTRIES]
    if [kind for kind, _ in entries] != expected:
        failures.append(
            "%s entries are %s, expected %s" % (name, [k for k, _ in entries], expected)
        )
        return

    images = entries[1:]
    for (kind, size), (_, payload) in zip(ICNS_ENTRIES, images):
        image = decode_png(payload)
        if (image.width, image.height) != (size, size):
            failures.append(
                "%s entry %s is %dx%d, expected %dx%d"
                % (name, kind, image.width, image.height, size, size)
            )
        elif image.pixels != sizes[size].pixels:
            failures.append("%s entry %s does not match the branding master" % (name, kind))

    toc = b"".join(
        kind.encode("ascii") + struct.pack(">I", len(payload) + 8)
        for kind, payload in images
    )
    if entries[0][1] != toc:
        failures.append("%s: the table of contents does not describe the entries after it" % name)


def _check_png(path, expected, failures):
    name = os.path.relpath(path, ROOT)
    with open(path, "rb") as handle:
        actual = decode_png(handle.read())
    if (actual.width, actual.height) != (expected.width, expected.height):
        failures.append(
            "%s is %dx%d, expected %dx%d"
            % (name, actual.width, actual.height, expected.width, expected.height)
        )
    elif actual.pixels != expected.pixels:
        failures.append("%s does not match the branding master" % name)


def command_verify():
    rendered = render_everything()
    failures = []

    _check_icns(ICNS, rendered["icon"], failures)
    _check_png(README_ICON, rendered["icon"][README_SIZE], failures)
    _check_icns(VOLUME_ICNS, rendered["volume"], failures)
    _check_png(VOLUME_PREVIEW, rendered["volume"][VOLUME_PREVIEW_SIZE], failures)
    _check_png(DMG_BACKGROUND, rendered["background"][1], failures)
    _check_png(DMG_BACKGROUND_2X, rendered["background"][DMG_SCALE], failures)

    # tiffutil -cathidpicheck, which make-dmg.sh pairs these two with, refuses anything that is
    # not exactly double in both directions. Catching that here means the packaging step on
    # macOS cannot be the first thing to discover it.
    one = rendered["background"][1]
    two = rendered["background"][DMG_SCALE]
    if (two.width, two.height) != (one.width * DMG_SCALE, one.height * DMG_SCALE):
        failures.append(
            "the @2x background is %dx%d, which is not %dx the 1x %dx%d"
            % (two.width, two.height, DMG_SCALE, one.width, one.height)
        )

    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print("run 'python3 scripts/icons.py build' to regenerate", file=sys.stderr)
        return 1

    print("branding assets match %s" % os.path.relpath(MASTER, ROOT))
    return 0


def command_palette():
    """Prints the colours the generated assets are painted with. For eyes, not for CI."""
    palette = brand_palette(render_sizes()[README_SIZE])
    for name in ("deep", "halo", "core"):
        red, green, blue = palette[name]
        print("%-5s #%02X%02X%02X  rgb(%d, %d, %d)" % (name, red, green, blue, red, green, blue))
    return 0


def main(argv):
    commands = {
        "build": command_build,
        "verify": command_verify,
        "palette": command_palette,
    }
    if len(argv) != 2 or argv[1] not in commands:
        print("usage: icons.py {build|verify|palette}", file=sys.stderr)
        return 2
    try:
        return commands[argv[1]]()
    except (ValueError, zlib.error, OSError) as error:
        # A corrupt or truncated asset is a normal failure for this script to report, not a
        # reason to print a stack trace at whoever is reading the CI log.
        print("%s" % error, file=sys.stderr)
        print("run 'python3 scripts/icons.py build' to regenerate", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
