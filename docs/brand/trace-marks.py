#!/usr/bin/env python3
"""Traces the three drawings in docs/brand/source into vector paths, without redrawing anything.

    python3 docs/brand/trace-marks.py            writes Sources/HalfLidCore/Identity/LidMarks.swift and prints the fidelity
    python3 docs/brand/trace-marks.py --overlay  also writes /tmp/halflid-trace-<state>.png (the drawing in grey, the trace in red)

The drawings are the maintainer's: chiuso (closed), aperto (open) and aperto con pallino (open, with a dot). Each is turned
into a black-and-white field, its outline is found at the half-grey level with sub-pixel accuracy (marching squares), and the
outline is fitted with cubic Beziers (Schneider's algorithm) within half a pixel of the original, keeping the corners. A run
of outline that stays within that distance of a straight line is written as a straight segment: the JPEG noise would otherwise
make a straight edge wobble by a fraction of a pixel.
Nothing is smoothed beyond that, simplified or redrawn: the shapes in the app are the shapes in the drawings.

Coordinates are those of the 1024 x 1024 drawing, y pointing down. For every state the script also records the rectangle of
the base (the lower, longer piece), so the app can give all three states the same base length and position without touching
the shapes.

Needs numpy, scipy, scikit-image and Pillow. They are only needed to run this script, never to build or run the app.
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from skimage import measure

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "docs/brand/source"
OUTPUT = ROOT / "Sources/HalfLidCore/Identity/LidMarks.swift"
DRAWINGS = [("idle", "chiuso.jpeg"), ("active", "aperto.jpeg"), ("warning", "aperto con pallino.jpeg")]

TOLERANCE = 0.45        # pixels: how far the fitted curves may stray from the outline
BLUR = 0.7              # pixels: removes JPEG noise only; the thinnest feature in the drawings is 6 pixels wide
MIN_AREA = 40.0         # square pixels: smaller islands are JPEG specks
CORNER_WINDOW = 4       # outline points either side used to measure a turn
CORNER_ANGLE = 0.9      # radians: a turn sharper than this is kept as a corner


# MARK: tracing

def ink_field(path):
    grey = np.asarray(Image.open(path).convert("L"), dtype=np.float64) / 255.0
    return 1.0 - grey


def signed_area(points):
    x, y = points[:, 0], points[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def resample_closed(points, step=1.0):
    """Evenly spaced points along a closed outline."""
    closed = np.vstack([points, points[:1]])
    lengths = np.hypot(*np.diff(closed, axis=0).T)
    along = np.concatenate([[0.0], np.cumsum(lengths)])
    count = max(8, int(round(along[-1] / step)))
    targets = np.linspace(0.0, along[-1], count, endpoint=False)
    return np.column_stack([np.interp(targets, along, closed[:, 0]), np.interp(targets, along, closed[:, 1])])


def find_corners(points):
    count = len(points)
    k = CORNER_WINDOW
    angles = np.zeros(count)
    for i in range(count):
        a = points[i] - points[(i - k) % count]
        b = points[(i + k) % count] - points[i]
        denominator = np.linalg.norm(a) * np.linalg.norm(b)
        angles[i] = 0.0 if denominator == 0 else math.acos(max(-1.0, min(1.0, float(np.dot(a, b)) / denominator)))
    corners = []
    for i in range(count):
        if angles[i] < CORNER_ANGLE:
            continue
        window = [angles[(i + d) % count] for d in range(-k, k + 1)]
        if angles[i] >= max(window) and (not corners or i - corners[-1] > k):
            corners.append(i)
    if len(corners) > 1 and corners[0] + count - corners[-1] <= k:
        corners.pop()
    return corners


# Schneider, "An Algorithm for Automatically Fitting Digitized Curves" (Graphics Gems, 1990).

def bezier_point(c, t):
    s = 1.0 - t
    return s ** 3 * c[0] + 3 * s * s * t * c[1] + 3 * s * t * t * c[2] + t ** 3 * c[3]


def bezier_derivative(c, t, order):
    if order == 1:
        d = [3 * (c[i + 1] - c[i]) for i in range(3)]
        s = 1.0 - t
        return s * s * d[0] + 2 * s * t * d[1] + t * t * d[2]
    d = [6 * (c[i + 2] - 2 * c[i + 1] + c[i]) for i in range(2)]
    return (1.0 - t) * d[0] + t * d[1]


def unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def chord_parameters(points):
    d = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(points, axis=0).T))])
    return d / d[-1] if d[-1] > 0 else np.linspace(0, 1, len(points))


def generate_bezier(points, u, left, right):
    first, last = points[0], points[-1]
    b0 = (1 - u) ** 3
    b1 = 3 * u * (1 - u) ** 2
    b2 = 3 * u * u * (1 - u)
    b3 = u ** 3
    a1 = left[None, :] * b1[:, None]
    a2 = right[None, :] * b2[:, None]
    c = np.zeros((2, 2))
    x = np.zeros(2)
    for i in range(len(points)):
        c[0, 0] += a1[i] @ a1[i]
        c[0, 1] += a1[i] @ a2[i]
        c[1, 1] += a2[i] @ a2[i]
        tmp = points[i] - (first * (b0[i] + b1[i]) + last * (b2[i] + b3[i]))
        x[0] += a1[i] @ tmp
        x[1] += a2[i] @ tmp
    c[1, 0] = c[0, 1]
    det = c[0, 0] * c[1, 1] - c[1, 0] * c[0, 1]
    chord = np.linalg.norm(last - first)
    alpha_left = alpha_right = 0.0
    if abs(det) > 1e-12:
        alpha_left = (x[0] * c[1, 1] - x[1] * c[0, 1]) / det
        alpha_right = (c[0, 0] * x[1] - c[1, 0] * x[0]) / det
    epsilon = 1e-6 * chord
    if alpha_left < epsilon or alpha_right < epsilon:
        alpha_left = alpha_right = chord / 3.0
    return np.array([first, first + left * alpha_left, last + right * alpha_right, last])


def reparameterize(curve, points, u):
    new = np.empty_like(u)
    for i, (p, t) in enumerate(zip(points, u)):
        d = bezier_point(curve, t) - p
        d1 = bezier_derivative(curve, t, 1)
        d2 = bezier_derivative(curve, t, 2)
        numerator = d @ d1
        denominator = d1 @ d1 + d @ d2
        new[i] = t if abs(denominator) < 1e-12 else min(1.0, max(0.0, t - numerator / denominator))
    return new


def max_error(points, curve, u):
    worst, split = 0.0, len(points) // 2
    for i in range(1, len(points) - 1):
        d = float(np.sum((bezier_point(curve, u[i]) - points[i]) ** 2))
        if d >= worst:
            worst, split = d, i
    return worst, split


def fit_cubic(points, left, right, error):
    if len(points) == 2:
        distance = np.linalg.norm(points[1] - points[0]) / 3.0
        return [np.array([points[0], points[0] + left * distance, points[1] + right * distance, points[1]])]
    u = chord_parameters(points)
    curve = generate_bezier(points, u, left, right)
    worst, split = max_error(points, curve, u)
    if worst < error:
        return [curve]
    if worst < error * 4:
        for _ in range(6):
            u = reparameterize(curve, points, u)
            curve = generate_bezier(points, u, left, right)
            worst, split = max_error(points, curve, u)
            if worst < error:
                return [curve]
    split = min(max(split, 1), len(points) - 2)
    centre = unit(points[split - 1] - points[split + 1])
    return fit_cubic(points[: split + 1], left, centre, error) + fit_cubic(points[split:], -centre, right, error)


def straight_section(points, tolerance):
    """A run of outline points that lies within `tolerance` of the line between its ends is one straight segment."""
    chord = points[-1] - points[0]
    length = np.linalg.norm(chord)
    if length < 8.0:
        return None
    normal = np.array([-chord[1], chord[0]]) / length
    if np.max(np.abs((points - points[0]) @ normal)) > tolerance:
        return None
    return [np.array([points[0], points[0] + chord / 3.0, points[0] + 2.0 * chord / 3.0, points[-1]])]


def fit_section(points, tolerance):
    if len(points) < 2:
        return []
    line = straight_section(points, tolerance)
    if line is not None:
        return line
    reach = min(4, len(points) - 1)
    left = unit(points[reach] - points[0])
    right = unit(points[-1 - reach] - points[-1])
    return fit_cubic(points, left, right, tolerance ** 2)


def fit_outline(points, tolerance):
    """Closed outline -> list of cubic segments, split at corners."""
    corners = find_corners(points)
    count = len(points)
    if not corners:
        corners = [0, count // 2]
    sections = []
    for n, start in enumerate(corners):
        end = corners[(n + 1) % len(corners)]
        indices = list(range(start, end + 1)) if end > start else list(range(start, count)) + list(range(0, end + 1))
        sections.append(points[[i % count for i in indices]])
    curves = []
    for section in sections:
        curves.extend(fit_section(section, tolerance))
    return curves


def is_straight(curve, slack=0.06):
    chord = curve[3] - curve[0]
    length = np.linalg.norm(chord)
    if length < 1e-9:
        return False
    normal = np.array([-chord[1], chord[0]]) / length
    return all(abs((curve[i] - curve[0]) @ normal) < slack for i in (1, 2))


def path_data(curves):
    def n(v):
        text = f"{v:.2f}".rstrip("0").rstrip(".")
        return "0" if text in ("-0", "") else text

    parts = [f"M{n(curves[0][0][0])} {n(curves[0][0][1])}"]
    for c in curves:
        if is_straight(c):
            parts.append(f"L{n(c[3][0])} {n(c[3][1])}")
        else:
            parts.append(f"C{n(c[1][0])} {n(c[1][1])} {n(c[2][0])} {n(c[2][1])} {n(c[3][0])} {n(c[3][1])}")
    parts.append("Z")
    return "".join(parts)


def sample(curves, per_curve=24):
    points = []
    for c in curves:
        for t in np.linspace(0, 1, per_curve, endpoint=False):
            points.append(bezier_point(c, t))
    return np.array(points)


# MARK: one drawing

class Traced:
    def __init__(self, name, ink):
        self.name = name
        self.ink = ink
        blurred = ndimage.gaussian_filter(ink, BLUR)
        raw = measure.find_contours(blurred, 0.5)
        outlines = []
        for contour in raw:
            if not np.allclose(contour[0], contour[-1]):
                continue
            xy = np.column_stack([contour[:-1, 1], contour[:-1, 0]]) + 0.5   # (x, y), y down, pixel centres to pixel corners
            if abs(signed_area(xy)) < MIN_AREA:
                continue
            outlines.append(xy)
        # Outer outlines wind one way, holes the other (marching squares keeps ink on one side), so the sign of the largest
        # outline tells which is which.
        outlines.sort(key=lambda p: -abs(signed_area(p)))
        outer_sign = math.copysign(1, signed_area(outlines[0]))
        self.curves = [fit_outline(resample_closed(p), TOLERANCE) for p in outlines]
        self.outer = [math.copysign(1, signed_area(p)) == outer_sign for p in outlines]
        self.areas = [abs(signed_area(p)) for p in outlines]
        self.outlines = outlines
        self.base = self.find_base()
        self.dot_index = self.find_dot()

    def find_base(self):
        labels, count = ndimage.label(self.ink > 0.5)
        best = None
        for index, box in enumerate(ndimage.find_objects(labels), start=1):
            rows, cols = box
            area = int((labels[box] == index).sum())
            if area < 400:
                continue
            bottom = rows.stop
            if best is None or bottom > best[0]:
                best = (bottom, cols.start, rows.start, cols.stop - cols.start, rows.stop - rows.start)
        _, x, y, w, h = best
        return (float(x), float(y), float(w), float(h))

    def find_dot(self):
        """The dot is the one outer outline that is a circle (area close to pi r^2 for its own box) and small."""
        candidates = []
        for i, outline in enumerate(self.outlines):
            if not self.outer[i]:
                continue
            width = outline[:, 0].max() - outline[:, 0].min()
            height = outline[:, 1].max() - outline[:, 1].min()
            if 0.9 < width / height < 1.1 and self.areas[i] > 0.7 * math.pi * (width / 2) * (height / 2) and width < 120:
                candidates.append(i)
        return candidates[0] if len(candidates) == 1 and self.name == "warning" else None

    def body_data(self):
        pieces = [path_data(c) for i, c in enumerate(self.curves) if i != self.dot_index]
        return "".join(pieces)

    def dot_data(self):
        return None if self.dot_index is None else path_data(self.curves[self.dot_index])

    # MARK: fidelity

    def coverage(self, scale=4):
        """The fitted paths filled at `scale` times the size, then averaged down to the drawing's own pixels."""
        size = self.ink.shape[0] * scale
        image = Image.new("L", (size, size), 0)
        draw = ImageDraw.Draw(image)
        order = [i for i in range(len(self.curves)) if self.outer[i]] + [i for i in range(len(self.curves)) if not self.outer[i]]
        for i in order:
            polygon = [(float(x) * scale, float(y) * scale) for x, y in sample(self.curves[i])]
            draw.polygon(polygon, fill=255 if self.outer[i] else 0)
        small = np.asarray(image, dtype=np.float64).reshape(self.ink.shape[0], scale, self.ink.shape[1], scale).mean(axis=(1, 3)) / 255.0
        return small

    def fidelity(self):
        traced = self.coverage()
        a = np.clip(self.ink, 0, 1)
        overlap = float(np.minimum(a, traced).sum() / np.maximum(a, traced).sum())
        worst = float(np.abs(a - traced).max())
        return overlap, worst

    def overlay(self, path):
        grey = (255 * (1 - self.ink)).astype("uint8")
        rgb = np.stack([grey, grey, grey], axis=-1)
        image = Image.fromarray(rgb).resize((2048, 2048), Image.NEAREST)
        draw = ImageDraw.Draw(image)
        for i, curves in enumerate(self.curves):
            polygon = [(float(x) * 2, float(y) * 2) for x, y in sample(curves)]
            draw.line(polygon + [polygon[0]], fill=(220, 30, 30) if self.outer[i] else (30, 90, 220), width=1)
        image.save(path)


# MARK: Swift file

def swift_source(marks):
    lines = [
        "import CoreGraphics",
        "",
        "// Generated by docs/brand/trace-marks.py from the three drawings in docs/brand/source. Do not edit by hand: change a",
        "// drawing and run the script again.",
        "//",
        "// Each mark is the outline of one drawing fitted with cubic Beziers, in the coordinates of the 1024 x 1024 drawing (y",
        "// pointing down). `base` is the rectangle of the lower, longer piece of the laptop in the same coordinates; `LidGlyph`",
        "// uses it to give every state the same base length and position.",
        "",
        "/// The traced drawings. Internal: the rest of the app asks `LidGlyph` for them.",
        "enum LidMarks {",
        "    struct Mark {",
        "        let body: String",
        "        let dot: String?",
        "        let base: CGRect",
        "    }",
        "",
    ]
    for name, mark in marks:
        x, y, w, h = mark.base
        dot = '"' + mark.dot + '"' if mark.dot else "nil"
        lines.append(f"    static let {name} = Mark(")
        lines.append(f"        body: \"{mark.body}\",")
        lines.append(f"        dot: {dot},")
        lines.append(f"        base: CGRect(x: {x:g}, y: {y:g}, width: {w:g}, height: {h:g})")
        lines.append("    )")
        lines.append("")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


class Result:
    def __init__(self, traced):
        self.body = traced.body_data()
        self.dot = traced.dot_data()
        self.base = traced.base


def main():
    overlay = "--overlay" in sys.argv
    results = []
    for name, file in DRAWINGS:
        traced = Traced(name, ink_field(SOURCE / file))
        score, worst = traced.fidelity()
        pieces = sum(1 for i in range(len(traced.curves)) if traced.outer[i])
        holes = sum(1 for i in range(len(traced.curves)) if not traced.outer[i])
        segments = sum(len(c) for c in traced.curves)
        x, y, w, h = traced.base
        print(f"{name:8} {file:26} outlines {pieces}+{holes} holes, {segments} curves, base x={x:g} y={y:g} w={w:g} h={h:g}, "
              f"overlap {score:.4f}, worst pixel difference {worst:.2f}, dot {'yes' if traced.dot_index is not None else 'no'}")
        if overlay:
            traced.overlay(f"/tmp/halflid-trace-{name}.png")
        results.append((name, Result(traced)))
    OUTPUT.write_text(swift_source(results), encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
