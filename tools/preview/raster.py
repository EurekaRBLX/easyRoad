"""Tiny pure-stdlib rasterizer + PNG writer (no deps).

Enough to draw filled polygons and polylines so geometry can be eyeballed
without Studio or any image library.
"""
import zlib, struct, math


class Canvas:
    def __init__(self, w, h, bg=(47, 54, 64)):
        self.w, self.h = w, h
        self.px = bytearray()
        for _ in range(w * h):
            self.px += bytes(bg)

    def _set(self, x, y, rgb):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            self.px[i:i + 3] = bytes(rgb)

    def fill_poly(self, pts, rgb):
        if len(pts) < 3:
            return
        ys = [p[1] for p in pts]
        y0, y1 = max(0, int(min(ys))), min(self.h - 1, int(max(ys)) + 1)
        for y in range(y0, y1 + 1):
            sy = y + 0.5
            xs = []
            n = len(pts)
            for i in range(n):
                ax, ay = pts[i]
                bx, by = pts[(i + 1) % n]
                if (ay <= sy < by) or (by <= sy < ay):
                    t = (sy - ay) / (by - ay)
                    xs.append(ax + t * (bx - ax))
            xs.sort()
            for i in range(0, len(xs) - 1, 2):
                for x in range(int(math.floor(xs[i] + 0.5)), int(math.ceil(xs[i + 1] - 0.5)) + 1):
                    self._set(x, y, rgb)

    def disc(self, cx, cy, r, rgb):
        for y in range(int(cy - r), int(cy + r) + 1):
            for x in range(int(cx - r), int(cx + r) + 1):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    self._set(x, y, rgb)

    def ring(self, cx, cy, r_in, r_out, rgb):
        for y in range(int(cy - r_out), int(cy + r_out) + 1):
            for x in range(int(cx - r_out), int(cx + r_out) + 1):
                d2 = (x - cx) ** 2 + (y - cy) ** 2
                if r_in * r_in <= d2 <= r_out * r_out:
                    self._set(x, y, rgb)

    def line(self, a, b, rgb, width=1):
        dx, dy = b[0] - a[0], b[1] - a[1]
        steps = int(max(abs(dx), abs(dy))) + 1
        for i in range(steps + 1):
            t = i / steps
            x, y = a[0] + dx * t, a[1] + dy * t
            if width <= 1:
                self._set(int(x), int(y), rgb)
            else:
                self.disc(x, y, width / 2, rgb)

    def polyline(self, pts, rgb, width=1):
        for i in range(len(pts) - 1):
            self.line(pts[i], pts[i + 1], rgb, width)

    def save(self, path):
        raw = b""
        for y in range(self.h):
            raw += b"\x00" + bytes(self.px[y * self.w * 3:(y + 1) * self.w * 3])
        def chunk(tag, data):
            c = struct.pack(">I", len(data)) + tag + data
            return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        png = b"\x89PNG\r\n\x1a\n"
        png += chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw, 6))
        png += chunk(b"IEND", b"")
        open(path, "wb").write(png)
        return path
