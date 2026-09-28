#!/usr/bin/env python3
"""CPU audit of the GLSL Cook-Torrance implementation used by VkNRC.

This intentionally mirrors shader/src/CookTorranceBRDF.glsl rather than a
reference implementation.  It reports counterexamples to invariants expected
from a usable BRDF sampling implementation without requiring a GPU.
"""

from __future__ import annotations

import argparse
import json
import math
import random
from dataclasses import asdict, dataclass
from pathlib import Path


PI = math.pi


def ieee_div(a: float, b: float) -> float:
    if b != 0.0:
        return a / b
    if a == 0.0 or math.isnan(a):
        return math.nan
    return math.copysign(math.inf, a * (b if b != 0.0 else 1.0))


def dot(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def normalize(v: tuple[float, float, float]) -> tuple[float, float, float]:
    length = math.sqrt(dot(v, v))
    if length == 0.0:
        return (math.nan, math.nan, math.nan)
    return tuple(x / length for x in v)  # type: ignore[return-value]


def luminance(c: tuple[float, float, float]) -> float:
    return 0.212671 * c[0] + 0.715160 * c[1] + 0.072169 * c[2]


def specular_probability(diffuse: tuple[float, float, float], specular: tuple[float, float, float]) -> float:
    dl = luminance(diffuse)
    sl = luminance(specular)
    return ieee_div(sl, dl + sl)


def walter_g1(v_dot_h: float, v_dot_n: float, roughness2: float) -> float:
    vn2 = v_dot_n * v_dot_n
    a2 = ieee_div(1.0, roughness2 * ieee_div(1.0 - vn2, vn2))
    a = math.sqrt(a2) if a2 >= 0.0 else math.nan
    approximation = 1.0 if a >= 1.6 else ieee_div(3.535 * a + 2.181 * a2, 1.0 + 2.276 * a + 2.577 * a2)
    return max(ieee_div(v_dot_h, v_dot_n), 0.0) * approximation


def beckmann_d(n_dot_h: float, roughness2: float) -> float:
    nh2 = n_dot_h * n_dot_h
    nh4 = nh2 * nh2
    exponent = ieee_div(nh2 - 1.0, roughness2 * nh2)
    numerator = math.exp(exponent) if exponent < 710.0 else math.inf
    return ieee_div(numerator, PI * roughness2 * nh4)


def cook_torrance_pdf(
    diffuse: tuple[float, float, float],
    specular: tuple[float, float, float],
    roughness: float,
    light: tuple[float, float, float],
    view: tuple[float, float, float],
    normal: tuple[float, float, float] = (0.0, 0.0, 1.0),
) -> float:
    n_dot_l = dot(light, normal)
    if n_dot_l < 0.0:
        return 0.0
    half_vector = normalize(tuple(l + v for l, v in zip(light, view)))
    n_dot_h = dot(normal, half_vector)
    p_h = beckmann_d(n_dot_h, roughness * roughness) * n_dot_h
    p_ct = ieee_div(p_h, 4.0 * dot(view, half_vector))
    p_lambert = n_dot_l / PI
    probability = specular_probability(diffuse, specular)
    return p_lambert * (1.0 - probability) + p_ct * probability


def schlick_fresnel(v_dot_h: float, ior: float = 1.5) -> float:
    f0 = (ior - 1.0) / (ior + 1.0)
    f0 *= f0
    return f0 + (1.0 - f0) * (1.0 - v_dot_h) ** 5


def cook_torrance_brdf(
    diffuse: tuple[float, float, float],
    specular: tuple[float, float, float],
    roughness: float,
    light: tuple[float, float, float],
    view: tuple[float, float, float],
    normal: tuple[float, float, float] = (0.0, 0.0, 1.0),
) -> tuple[float, float, float]:
    half_vector = normalize(tuple(l + v for l, v in zip(light, view)))
    n_dot_h = max(dot(normal, half_vector), 1e-8)
    v_dot_h = max(dot(view, half_vector), 1e-8)
    n_dot_l = min(max(dot(normal, light), 1e-8), 1.0 - 1e-8)
    n_dot_v = min(max(dot(normal, view), 1e-8), 1.0 - 1e-8)
    roughness2 = roughness * roughness
    geometric = walter_g1(v_dot_h, n_dot_v, roughness2) * walter_g1(v_dot_h, n_dot_l, roughness2)
    normal_distribution = beckmann_d(n_dot_h, roughness2)
    fresnel = schlick_fresnel(v_dot_h)
    scale = ieee_div(normal_distribution * geometric * fresnel, 4.0 * n_dot_l * n_dot_v)
    return tuple(d / PI + s * scale for d, s in zip(diffuse, specular))  # type: ignore[return-value]


def sample_cook_torrance(
    diffuse: tuple[float, float, float],
    specular: tuple[float, float, float],
    roughness: float,
    view: tuple[float, float, float],
    u1: float,
    u2: float,
    u3: float,
) -> tuple[float, float, float]:
    tangent2 = -roughness * roughness * math.log(1.0 - u1)
    n_dot_h = math.sqrt(1.0 / (1.0 + tangent2))
    phi = 2.0 * PI * u2
    radius = math.sqrt(1.0 - n_dot_h * n_dot_h)
    half_vector = (radius * math.cos(phi), radius * math.sin(phi), n_dot_h)
    view_dot_half = dot(view, half_vector)
    if view_dot_half < 0.0:
        half_vector = tuple(-x for x in half_vector)  # type: ignore[assignment]
        view_dot_half = -view_dot_half
    light = tuple(-v + 2.0 * view_dot_half * h for v, h in zip(view, half_vector))
    if u3 > specular_probability(diffuse, specular):
        radius = math.sqrt(u1)
        light = (radius * math.cos(phi), radius * math.sin(phi), math.sqrt(1.0 - u1))
    return light  # type: ignore[return-value]


@dataclass
class Finding:
    invariant: str
    values: dict[str, object]


def run_audit(samples: int, seed: int) -> dict[str, object]:
    findings: list[Finding] = []

    black_probability = specular_probability((0.0, 0.0, 0.0), (0.0, 0.0, 0.0))
    if not math.isfinite(black_probability):
        findings.append(Finding("specular_probability_is_finite", {"material": "black", "value": black_probability}))

    max_g1 = (-math.inf, {})
    for roughness in (0.001, 0.01, 0.05, 0.1, 0.3, 0.7, 1.0):
        for i in range(1, 1000):
            v_dot_n = i / 1000.0
            for v_dot_h in (0.25, 0.5, 0.75, 1.0):
                value = walter_g1(v_dot_h, v_dot_n, roughness * roughness)
                if value > max_g1[0]:
                    max_g1 = (value, {"roughness": roughness, "v_dot_n": v_dot_n, "v_dot_h": v_dot_h})
    if not (0.0 <= max_g1[0] <= 1.0):
        findings.append(Finding("walter_g1_is_in_unit_interval", {**max_g1[1], "value": max_g1[0]}))

    rng = random.Random(seed)
    pdf_nonfinite = 0
    pdf_negative = 0
    pdf_zero = 0
    smallest_positive = math.inf
    largest_finite = 0.0
    first_bad: dict[str, object] | None = None
    materials = (
        ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0), 0.001),
        ((0.5, 0.5, 0.5), (0.04, 0.04, 0.04), 0.001),
        ((0.5, 0.5, 0.5), (0.04, 0.04, 0.04), 0.05),
        ((0.5, 0.5, 0.5), (0.04, 0.04, 0.04), 0.3),
        ((0.0, 0.0, 0.0), (1.0, 1.0, 1.0), 0.001),
    )
    for _ in range(samples):
        diffuse, specular, roughness = materials[rng.randrange(len(materials))]
        phi_l = 2.0 * PI * rng.random()
        phi_v = 2.0 * PI * rng.random()
        z_l = rng.uniform(-1.0, 1.0)
        z_v = rng.uniform(0.0, 1.0)
        r_l = math.sqrt(max(0.0, 1.0 - z_l * z_l))
        r_v = math.sqrt(max(0.0, 1.0 - z_v * z_v))
        light = (r_l * math.cos(phi_l), r_l * math.sin(phi_l), z_l)
        view = (r_v * math.cos(phi_v), r_v * math.sin(phi_v), z_v)
        value = cook_torrance_pdf(diffuse, specular, roughness, light, view)
        if not math.isfinite(value):
            pdf_nonfinite += 1
            if first_bad is None:
                first_bad = {"diffuse": diffuse, "specular": specular, "roughness": roughness, "light": light, "view": view, "pdf": value}
        elif value < 0.0:
            pdf_negative += 1
            if first_bad is None:
                first_bad = {"diffuse": diffuse, "specular": specular, "roughness": roughness, "light": light, "view": view, "pdf": value}
        elif value == 0.0:
            pdf_zero += 1
        else:
            smallest_positive = min(smallest_positive, value)
            largest_finite = max(largest_finite, value)

    if pdf_nonfinite:
        findings.append(Finding("pdf_is_finite", {"failures": pdf_nonfinite, "first": first_bad}))
    if pdf_negative:
        findings.append(Finding("pdf_is_nonnegative", {"failures": pdf_negative, "first": first_bad}))

    sampled_below_hemisphere = 0
    sampled_bad_pdf = 0
    sampled_nonfinite_throughput = 0
    sampled_max_throughput = 0.0
    sampled_max_case: dict[str, object] | None = None
    sampled_materials = materials[1:]
    for _ in range(samples):
        diffuse, specular, roughness = sampled_materials[rng.randrange(len(sampled_materials))]
        phi_v = 2.0 * PI * rng.random()
        z_v = max(rng.random(), 1e-8)
        r_v = math.sqrt(1.0 - z_v * z_v)
        view = (r_v * math.cos(phi_v), r_v * math.sin(phi_v), z_v)
        u1, u2, u3 = rng.random(), rng.random(), rng.random()
        light = sample_cook_torrance(diffuse, specular, roughness, view, u1, u2, u3)
        if light[2] < 0.0:
            sampled_below_hemisphere += 1
        pdf = cook_torrance_pdf(diffuse, specular, roughness, light, view)
        if not math.isfinite(pdf) or pdf <= 0.0:
            sampled_bad_pdf += 1
            continue
        brdf = cook_torrance_brdf(diffuse, specular, roughness, light, view)
        cosine = abs(light[2])  # Mirrors BRDFStep, including the abs().
        throughput = max(ieee_div(channel * cosine, pdf) for channel in brdf)
        if not math.isfinite(throughput):
            sampled_nonfinite_throughput += 1
        elif throughput > sampled_max_throughput:
            sampled_max_throughput = throughput
            sampled_max_case = {
                "diffuse": diffuse,
                "specular": specular,
                "roughness": roughness,
                "view": view,
                "light": light,
                "pdf": pdf,
                "brdf": brdf,
                "throughput": throughput,
            }

    if sampled_below_hemisphere:
        findings.append(Finding("sampled_direction_is_in_shading_hemisphere", {"failures": sampled_below_hemisphere}))
    if sampled_bad_pdf:
        findings.append(Finding("sampled_direction_has_positive_finite_pdf", {"failures": sampled_bad_pdf}))
    if sampled_nonfinite_throughput:
        findings.append(Finding("sampled_throughput_is_finite", {"failures": sampled_nonfinite_throughput}))

    return {
        "mirror_source": "shader/src/CookTorranceBRDF.glsl",
        "samples": samples,
        "seed": seed,
        "pass": not findings,
        "summary": {
            "finding_count": len(findings),
            "pdf_nonfinite": pdf_nonfinite,
            "pdf_negative": pdf_negative,
            "pdf_zero": pdf_zero,
            "pdf_smallest_positive": smallest_positive if math.isfinite(smallest_positive) else None,
            "pdf_largest_finite": largest_finite,
            "walter_g1_max": max_g1[0],
            "sampled_below_hemisphere": sampled_below_hemisphere,
            "sampled_bad_pdf": sampled_bad_pdf,
            "sampled_nonfinite_throughput": sampled_nonfinite_throughput,
            "sampled_max_finite_throughput": sampled_max_throughput,
            "sampled_max_case": sampled_max_case,
        },
        "findings": [asdict(finding) for finding in findings],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=200_000)
    parser.add_argument("--seed", type=int, default=0x564B4E52)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    result = run_audit(args.samples, args.seed)
    rendered = json.dumps(result, indent=2, allow_nan=True)
    print(rendered)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(rendered + "\n", encoding="utf-8")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
