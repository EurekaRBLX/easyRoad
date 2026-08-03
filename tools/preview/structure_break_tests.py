#!/usr/bin/env python3
"""Prove the structure validators reject gaps and hovering piers."""
import sys

import structure_preview as preview


def main():
    curve, ranges, piers = preview.validate_geometry()
    failures = []

    missing_tail = ranges[:-1]
    errors = preview.module_errors(curve, missing_tail, 30.0)
    if not any("does not reach" in error for error in errors):
        failures.append("missing final module was not detected")

    floating = list(piers)
    station, top, ground = floating[0]
    floating[0] = (station, top, ground+3.0)
    errors = preview.pier_errors(floating)
    if not any("does not terminate" in error for error in errors):
        failures.append("floating pier was not detected")

    # Recreate the shipped defect: interface overlap consumed effectively the
    # whole deck, leaving no structural slab visible below the road body.
    real_viaduct_section = preview.viaduct_section

    def buried_viaduct(*args, **kwargs):
        section = real_viaduct_section(*args, **kwargs)
        section["slab_bottom"] = -1.0 + 0.01
        return section

    preview.viaduct_section = buried_viaduct
    try:
        errors = preview.procedural_errors()
    finally:
        preview.viaduct_section = real_viaduct_section
    if not any("buried inside" in error for error in errors):
        failures.append("buried viaduct deck was not detected")

    def oversized_viaduct(*args, **kwargs):
        section = real_viaduct_section(*args, **kwargs)
        section["deck_width"] = section["barrier_outer"] * 2
        return section

    preview.viaduct_section = oversized_viaduct
    try:
        errors = preview.procedural_errors()
    finally:
        preview.viaduct_section = real_viaduct_section
    if not any("overshoots" in error for error in errors):
        failures.append("sidewall-blocking viaduct deck was not detected")

    errors = preview.curved_viaduct_errors(clearance=-0.5)
    if not any("clips the curved road envelope" in error for error in errors):
        failures.append("inward viaduct parapet was not detected")

    errors = preview.banked_structure_errors(structure_roll_deg=0)
    if not any("bank diverges" in error for error in errors):
        failures.append("unbanked structure under a superelevated road was not detected")

    if failures:
        for failure in failures:
            print("FAILED:", failure)
        return 1
    print(
        "structure break-tests passed: missing tail, floating pier, buried deck, "
        "sidewall-blocking deck, inward parapet, and unbanked shell all detected"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
