#!/usr/bin/env python3
"""Regression contract for road-deletion junction ownership.

Roblox Studio owns the actual DescendantRemoving and ChangeHistoryService
events, so this check combines source wiring assertions with an executable
model of the lifecycle decision that failed live: deleting a T's branch leaves
two visibly trimmed pieces, but their preserved source endpoints still meet and
must collapse back to standalone road ends.
"""

from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


@dataclass(frozen=True)
class Approach:
    source_endpoint: tuple[float, float]
    outward: tuple[float, float]
    profile: str = "same-road"


def dot(a: tuple[float, float], b: tuple[float, float]) -> float:
    return a[0] * b[0] + a[1] * b[1]


def smooth_source_pass_through(
    approaches: list[Approach], controller: tuple[float, float]
) -> bool:
    if len(approaches) != 2:
        return False
    a, b = approaches
    dx = a.source_endpoint[0] - b.source_endpoint[0]
    dz = a.source_endpoint[1] - b.source_endpoint[1]
    midpoint = (
        (a.source_endpoint[0] + b.source_endpoint[0]) * 0.5,
        (a.source_endpoint[1] + b.source_endpoint[1]) * 0.5,
    )
    center_dx = midpoint[0] - controller[0]
    center_dz = midpoint[1] - controller[1]
    return (
        dx * dx + dz * dz <= 0.25 * 0.25
        and center_dx * center_dx + center_dz * center_dz <= 0.25 * 0.25
        and a.profile == b.profile
        and dot(a.outward, b.outward) < -0.85
    )


def action(
    kind: str,
    approaches: list[Approach],
    controller: tuple[float, float] = (10.0, 5.0),
) -> str:
    if kind == "Roundabout":
        return "roundabout-owner"
    if len(approaches) <= 1 or smooth_source_pass_through(approaches, controller):
        return "restore-detach-delete"
    return "rebuild"


def main() -> int:
    junction = source("src/Mesh/JunctionBuilder.lua")
    main_source = source("src/main.lua")
    roundabout = source("src/Mesh/RoundaboutBuilder.lua")
    problems: list[str] = []

    required = {
        "public deletion lifecycle": "function JunctionBuilder.CleanupAfterRoadRemoval(",
        "durable endpoint lookup": "local source = RoadSource.ReadSegment(road)",
        "source endpoint parity": "sourceEndpoints[1].X - sourceEndpoints[2].X",
        "controller-centre parity": "sourceMidpoint.X - junctionData.Position.X",
        "orphan/smooth collapse decision": "#roads <= 1 or isSmoothPassThrough(roads, junctionId)",
        "topology detach before restore": "RoadInstance.StampJunctions(\n\t\t\t\troad,",
        "forced source restore": "trimApproach(road, style, settings, true)",
        "controller deletion": "JunctionInstance.Delete(junctionModel)",
        "removed road identity exclusion": "if road ~= removedRoad then",
        "rebuild exclusion forwarding": "JunctionBuilder.Rebuild(junctionId, style, settings, removedRoad)",
    }
    for label, needle in required.items():
        if needle not in junction:
            problems.append(f"missing {label}")

    if (
        "instance:SetAttribute(\"RW_StartJunctionId\", nil)" in main_source
        or "instance:SetAttribute(\"RW_EndJunctionId\", nil)" in main_source
    ):
        problems.append(
            "DescendantRemoving mutates the deleting road's topology, so Undo can restore it detached"
        )
    if "connectedRoadsExcept(junctionId, instance :: Model)" not in main_source:
        problems.append("remaining-road scan does not exclude the deleting Model")
    if (
        "JunctionBuilder.CleanupAfterRoadRemoval(junctionId, getStyle(), settings, instance :: Model)"
        not in main_source
    ):
        problems.append("Studio deletion listener does not invoke lifecycle cleanup")
    if "RoundaboutBuilder.Rebuild(ring, getStyle(), settings, instance :: Model)" not in main_source:
        problems.append("roundabout deletion rebuild does not exclude the deleting Model")
    if "if road == excludedRoad then" not in roundabout:
        problems.append("roundabout preflight still includes the deleting approach")
    if (
        "RoundaboutBuilder.PrepareForRingRemoval(instance :: Model, getStyle(), settings)"
        not in main_source
    ):
        problems.append("intentional direct ring deletion no longer restores its live road")
    if "roadsFolderRemoving" not in main_source:
        problems.append("bulk Roads-folder deletion has no conservative lifecycle guard")
    if "ringRemovalFromRoadCleanup[instance]" not in main_source:
        problems.append("nested ring removal can reinterpret the still-queryable deleting road")
    if (
        "ringRemovalFromRoadCleanup[ring] = true" not in main_source
        or "ringRemovalFromRoadCleanup[ring] = nil" not in main_source
    ):
        problems.append("final-road cleanup does not scope suppression around ring destruction")

    # DescendantRemoving is synchronous. Without the scoped guard, destroying
    # the last road-owned ring re-enters the ring branch while the departing
    # road still appears connected and restores/detaches exactly that road.
    nested_final_road_result = (
        "delete-controller"
        if "ringRemovalFromRoadCleanup[instance]" in main_source
        else "restore-deleting-road"
    )
    if nested_final_road_result != "delete-controller":
        problems.append("final roundabout road deletion corrupts Undo through nested owner cleanup")

    through = [
        Approach((10.0, 5.0), (-1.0, 0.0)),
        Approach((10.0, 5.0), (1.0, 0.0)),
    ]
    offset = [
        Approach((10.0, 5.0), (-1.0, 0.0)),
        Approach((10.0, 7.0), (1.0, 0.0)),
    ]
    corner = [
        Approach((10.0, 5.0), (-1.0, 0.0)),
        Approach((10.0, 5.0), (0.0, 1.0)),
    ]
    remote = [
        Approach((20.0, 5.0), (-1.0, 0.0)),
        Approach((20.0, 5.0), (1.0, 0.0)),
    ]
    branch = Approach((10.0, 5.0), (0.0, -1.0))

    cases = {
        "last surviving road": ("Intersection", through[:1], "restore-detach-delete"),
        "deleted T branch": ("Intersection", through, "restore-detach-delete"),
        "live T junction": ("Intersection", [*through, branch], "rebuild"),
        "offset cross-section ends": ("Intersection", offset, "rebuild"),
        "coincident sources at remote controller": ("Intersection", remote, "rebuild"),
        "real two-road corner": ("Intersection", corner, "rebuild"),
        "roundabout retains owner flow": ("Roundabout", through, "roundabout-owner"),
    }
    for label, (kind, approaches, expected) in cases.items():
        actual = action(kind, approaches)
        if actual != expected:
            problems.append(f"{label}: expected {expected}, got {actual}")

    if problems:
        for problem in problems:
            print(f"FAIL: {problem}")
        return 1
    print("junction lifecycle contract passed: orphan, T-collapse, offset, corner, and roundabout cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
