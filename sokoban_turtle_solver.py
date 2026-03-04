#!/usr/bin/env python3
"""Solve Sokoban levels from XSB input and print a move solution.
(please note this code is severly inefficient im just lazy to change anything)

  python3 sokoban_turtle_solver.py level.xsb
  cat level.xsb | python3 sokoban_turtle_solver.py

Output:
  - If solved: a move string using `udlr` for walking and `UDLR` for pushes.
  - If the program remains unsolved: `No solution found`.
"""
from __future__ import annotations

import argparse
import sys
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, Iterable, List, Optional, Sequence, Set, Tuple

Coord = Tuple[int, int]
Push = Tuple[Coord, Coord]  # (box_position_before_push, direction)

DIRS: Sequence[Tuple[str, Coord]] = [
    ("u", (-1, 0)),
    ("d", (1, 0)),
    ("l", (0, -1)),
    ("r", (0, 1)),
]


@dataclass(frozen=True)
class Board:
    walls: Set[Coord]
    goals: Set[Coord]
    floor: Set[Coord]
    start_player: Coord
    start_boxes: frozenset[Coord]


@dataclass(frozen=True)
class State:
    player: Coord
    boxes: frozenset[Coord]


@dataclass
class Solution:
    moves: str
    pushes: int


def add(a: Coord, b: Coord) -> Coord:
    return (a[0] + b[0], a[1] + b[1])


def parse_xsb(level_text: str) -> Board:
    """Parse XSB text into board data.

    Supported characters:
      # wall, @ player, + player on goal, $ box, * box on goal, . goal, ' ' empty.
    """
    raw_lines = [line.rstrip("\n") for line in level_text.splitlines()]
    lines = [line for line in raw_lines if line.strip() != ""]
    if not lines:
        raise ValueError("Empty XSB input")

    width = max(len(line) for line in lines)
    walls: Set[Coord] = set()
    goals: Set[Coord] = set()
    floor: Set[Coord] = set()
    boxes: Set[Coord] = set()
    player: Optional[Coord] = None

    for r, line in enumerate(lines):
        for c in range(width):
            ch = line[c] if c < len(line) else " "
            pos = (r, c)

            if ch == "#":
                walls.add(pos)
                continue
            if ch == " ":
                continue

            floor.add(pos)
            if ch in ".+*":
                goals.add(pos)
            if ch in "$*":
                boxes.add(pos)
            if ch in "@+":
                if player is not None:
                    raise ValueError("XSB has multiple player positions")
                player = pos

    if player is None:
        raise ValueError("XSB missing player (@ or +)")
    if len(goals) != len(boxes):
        raise ValueError(f"Invalid level: goals ({len(goals)}) != boxes ({len(boxes)})")

    return Board(
        walls=walls,
        goals=goals,
        floor=floor,
        start_player=player,
        start_boxes=frozenset(boxes),
    )


def reachable_with_predecessor(
    board: Board,
    player: Coord,
    boxes: frozenset[Coord],
) -> Dict[Coord, Tuple[Optional[Coord], str]]:
    """Map each reachable tile to (predecessor, move_char)."""
    pred: Dict[Coord, Tuple[Optional[Coord], str]] = {player: (None, "")}
    blocked = set(board.walls) | set(boxes)
    q: Deque[Coord] = deque([player])

    while q:
        cur = q.popleft()
        for move_char, d in DIRS:
            nxt = add(cur, d)
            if nxt in pred or nxt in blocked or nxt not in board.floor:
                continue
            pred[nxt] = (cur, move_char)
            q.append(nxt)

    return pred


def reconstruct_walk_moves(pred: Dict[Coord, Tuple[Optional[Coord], str]], target: Coord) -> str:
    """Reconstruct walking move sequence to target using predecessor map."""
    moves: List[str] = []
    cur = target
    while pred[cur][0] is not None:
        prev, move_char = pred[cur]
        assert prev is not None
        moves.append(move_char)
        cur = prev
    moves.reverse()
    return "".join(moves)


def push_char_for_direction(d: Coord) -> str:
    for move_char, vec in DIRS:
        if vec == d:
            return move_char.upper()
    raise ValueError(f"Unknown direction {d}")


def legal_pushes(board: Board, state: State) -> Iterable[Tuple[Push, str, str]]:
    """Yield legal pushes as (push, walk_moves, push_char)."""
    pred = reachable_with_predecessor(board, state.player, state.boxes)

    for box in state.boxes:
        for _, d in DIRS:
            push_from = add(box, (-d[0], -d[1]))
            push_to = add(box, d)
            if push_from not in pred:
                continue
            if push_to not in board.floor or push_to in board.walls or push_to in state.boxes:
                continue

            walk_moves = reconstruct_walk_moves(pred, push_from)
            yield (box, d), walk_moves, push_char_for_direction(d)


def apply_push(state: State, push: Push) -> State:
    box_from, d = push
    box_to = add(box_from, d)
    new_boxes = set(state.boxes)
    new_boxes.remove(box_from)
    new_boxes.add(box_to)
    return State(player=box_from, boxes=frozenset(new_boxes))


def deadlock_simple(board: Board, moved_box: Coord, boxes: frozenset[Coord]) -> bool:
    """Simple corner deadlock check for a just-pushed box not on a goal."""
    if moved_box in board.goals:
        return False

    blocked = set(board.walls) | set(boxes)

    def is_blocked(pos: Coord) -> bool:
        return pos in blocked or pos not in board.floor

    up = is_blocked(add(moved_box, (-1, 0)))
    down = is_blocked(add(moved_box, (1, 0)))
    left = is_blocked(add(moved_box, (0, -1)))
    right = is_blocked(add(moved_box, (0, 1)))
    return (up or down) and (left or right)


def is_solved(board: Board, boxes: frozenset[Coord]) -> bool:
    return boxes == board.goals


def solve_bfs(board: Board) -> Optional[Solution]:
    start = State(player=board.start_player, boxes=board.start_boxes)
    if is_solved(board, start.boxes):
        return Solution(moves="", pushes=0)

    parent: Dict[State, Optional[State]] = {start: None}
    parent_move_segment: Dict[State, str] = {start: ""}

    q: Deque[State] = deque([start])

    while q:
        cur = q.popleft()

        for push, walk_moves, push_char in legal_pushes(board, cur):
            nxt = apply_push(cur, push)
            moved_box = add(push[0], push[1])
            if deadlock_simple(board, moved_box, nxt.boxes):
                continue
            if nxt in parent:
                continue

            parent[nxt] = cur
            parent_move_segment[nxt] = walk_moves + push_char

            if is_solved(board, nxt.boxes):
                moves = reconstruct_solution_moves(nxt, parent, parent_move_segment)
                pushes = sum(1 for ch in moves if ch.isupper())
                return Solution(moves=moves, pushes=pushes)

            q.append(nxt)

    return None


def reconstruct_solution_moves(
    end_state: State,
    parent: Dict[State, Optional[State]],
    parent_move_segment: Dict[State, str],
) -> str:
    segments: List[str] = []
    cur = end_state
    while parent[cur] is not None:
        segments.append(parent_move_segment[cur])
        prev = parent[cur]
        assert prev is not None
        cur = prev
    segments.reverse()
    return "".join(segments)


def read_level(path: Optional[str]) -> str:
    if path:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    return sys.stdin.read()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Solve a Sokoban XSB level with BFS.")
    parser.add_argument("xsb", nargs="?", help="Path to XSB file. If omitted, read from stdin.")
    parser.add_argument(
        "--stats",
        action="store_true",
        help="Print push count to stderr when a solution is found.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        level_text = read_level(args.xsb)
        board = parse_xsb(level_text)
        solution = solve_bfs(board)
    except ValueError as e:
        print(f"Input error: {e}", file=sys.stderr)
        return 2

    if solution is None:
        print("No solution found")
        return 1

    print(solution.moves)
    if args.stats:
        print(f"pushes={solution.pushes} moves={len(solution.moves)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
