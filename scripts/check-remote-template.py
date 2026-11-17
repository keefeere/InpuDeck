#!/usr/bin/env python3
# Contract checks for the shipped TV remote template, for the pre-commit hook.
#
# Swift tests assert the same rules, but they only run where a Swift compiler
# exists. This mirrors the decoder's structural rules so a template edit can be
# checked on any machine: the shipped file is the only template in v1, so a bad
# cell here means a dead button on the maintainer's sofa, not a CI failure.
#
# Usage: check-remote-template.py [FILE]
import json
import sys

USAGE = {
    "power": 0x0030, "sleep": 0x0032, "brightnessUp": 0x006F, "brightnessDown": 0x0070,
    "fastForward": 0x00B3, "rewind": 0x00B4, "next": 0x00B5, "previous": 0x00B6,
    "shuffle": 0x00B9, "repeat": 0x00BC, "playPause": 0x00CD, "mute": 0x00E2,
    "volumeUp": 0x00E9, "volumeDown": 0x00EA, "menu": 0x0040, "menuPick": 0x0041,
    "menuEscape": 0x0046, "info": 0x0060, "closedCaption": 0x0061, "tv": 0x0089,
    "guide": 0x008D, "exit": 0x0094, "help": 0x0095, "channelUp": 0x009C,
    "channelDown": 0x009D, "home": 0x0223, "back": 0x0224, "backLg": 0x01CD, "forward": 0x0225,
    "stop": 0x0226, "refresh": 0x0227,
}
KEYS = {
    "up": 0x52, "down": 0x51, "left": 0x50, "right": 0x4F, "return": 0x28,
    "escape": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C, "delete": 0x4C,
    "home": 0x4A, "end": 0x4D, "pageUp": 0x4B, "pageDown": 0x4E,
}
MODIFIERS = {"shift": 0x02, "ctrl": 0x01, "alt": 0x04, "gui": 0x08}
CONTROLS = {"button", "dpad", "rocker", "spacer"}
DPAD_ROLES = {"up", "down", "left", "right", "center"}
ROCKER_ROLES = {"primary", "secondary"}


def action_problems(action: dict, cell_id: str) -> list[str]:
    kind = action.get("kind")
    if kind not in {"key", "consumer", "none"}:
        return [f'cell "{cell_id}": action kind {kind!r} is not in v1']
    if kind == "key":
        key = action.get("key")
        problems = [] if key in KEYS else [f'cell "{cell_id}": unknown key name {key!r}']
        modifiers = action.get("modifiers", [])
        if not isinstance(modifiers, list) or any(m not in MODIFIERS for m in modifiers):
            problems.append(f'cell "{cell_id}": unknown modifier name')
        return problems
    if kind == "consumer":
        usage = action.get("usage")
        if not isinstance(usage, str):
            return [f'cell "{cell_id}": usage must be a name, not a number ({usage!r})']
        if usage not in USAGE:
            return [f'cell "{cell_id}": unknown consumer usage {usage!r}']
        if not 0x0000 <= USAGE[usage] <= 0x03FF:
            return [f'cell "{cell_id}": usage {usage} is outside the declared range']
    return []


def check(path: str) -> list[str]:
    raw = json.load(open(path, encoding="utf-8"))
    problems: list[str] = []

    if raw.get("formatVersion") != 1:
        problems.append(f"formatVersion must be 1, got {raw.get('formatVersion')!r}")
    if not raw.get("id"):
        problems.append("id is missing")
    if not raw.get("name"):
        problems.append("name is missing")
    columns, rows = raw.get("columns"), raw.get("rows")
    if not isinstance(columns, int) or not 3 <= columns <= 6:
        problems.append("columns must be an integer in 3..6")
        return problems
    if not isinstance(rows, int) or not 3 <= rows <= 10:
        problems.append("rows must be an integer in 3..10")
        return problems

    seen: set[str] = set()
    occupied: dict[tuple[int, int], str] = {}
    for cell in raw.get("cells") or []:
        cell_id = cell.get("id")
        if not cell_id:
            problems.append("a cell has no id")
            continue
        if cell_id in seen:
            problems.append(f'duplicate cell id "{cell_id}"')
        seen.add(cell_id)

        row, col = cell.get("row"), cell.get("col")
        row_span, col_span = cell.get("rowSpan", 1), cell.get("colSpan", 1)
        if not isinstance(row, int) or not isinstance(col, int):
            problems.append(f'cell "{cell_id}": row and col must be integers')
            continue
        if row_span < 1 or col_span < 1:
            problems.append(f'cell "{cell_id}": spans must be >= 1')
            continue
        if row < 1 or col < 1 or row + row_span - 1 > rows or col + col_span - 1 > columns:
            problems.append(f'cell "{cell_id}": outside the {columns}x{rows} grid')
            continue

        covered = {(r, c) for r in range(row, row + row_span) for c in range(col, col + col_span)}
        clash = covered & occupied.keys()
        if clash:
            problems.append(f'cell "{cell_id}": overlaps "{occupied[next(iter(clash))]}"')
            continue
        occupied.update({spot: cell_id for spot in covered})

        control = cell.get("control")
        if control not in CONTROLS:
            problems.append(f'cell "{cell_id}": unknown control {control!r}')
            continue

        if control in {"button", "spacer"}:
            if "actions" in cell:
                problems.append(f'cell "{cell_id}": a {control} must not list role actions')
            if "action" in cell:
                problems += action_problems(cell["action"], cell_id)
            if control == "button" and not cell.get("label"):
                problems.append(f'cell "{cell_id}": a button needs a label')
        elif control == "dpad":
            if "action" in cell:
                problems.append(f'cell "{cell_id}": a dpad must not list a single action')
            roles = cell.get("actions") or {}
            for role in ("up", "down", "left", "right"):
                if role not in roles:
                    problems.append(f'cell "{cell_id}": dpad is missing "{role}"')
            if "center" not in roles:
                problems.append(f'cell "{cell_id}": dpad has no center (kept, but say so in docs)')
            if set(roles) - DPAD_ROLES:
                problems.append(f'cell "{cell_id}": dpad has unknown roles {sorted(set(roles) - DPAD_ROLES)}')
            for role, slot in roles.items():
                # Role slots are flat actions with an optional label, matching RawAction.
                problems += action_problems(slot, f'{cell_id}.{role}')
        else:
            if "action" in cell:
                problems.append(f'cell "{cell_id}": a rocker must not list a single action')
            roles = cell.get("actions") or {}
            for role in ("primary", "secondary"):
                if role not in roles:
                    problems.append(f'cell "{cell_id}": rocker is missing "{role}"')
            if set(roles) - ROCKER_ROLES:
                problems.append(f'cell "{cell_id}": rocker has unknown roles {sorted(set(roles) - ROCKER_ROLES)}')
            for role, slot in roles.items():
                if not slot.get("label") and not cell.get("label"):
                    problems.append(f'cell "{cell_id}.{role}": a rocker half with no label is an anonymous button')
                problems += action_problems(slot, f'{cell_id}.{role}')

    gaps = [(r, c) for r in range(1, rows + 1) for c in range(1, columns + 1) if (r, c) not in occupied]
    if gaps:
        problems.append(f"grid is not fully covered, empty cells: {gaps}")
    return problems


def main() -> int:
    paths = sys.argv[1:] or ["InpuDeck/RemoteTemplate.tv-default.json"]
    problems = [problem for path in paths for problem in check(path)]
    for problem in problems:
        print(problem)
    if not problems:
        print("Remote template covers its grid and every named action resolves.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
