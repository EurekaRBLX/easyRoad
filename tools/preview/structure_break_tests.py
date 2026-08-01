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

    if failures:
        for failure in failures:
            print("FAILED:", failure)
        return 1
    print("structure break-tests passed: missing tail and floating pier both detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
