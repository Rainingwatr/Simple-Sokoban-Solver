# My Simple Sokoban Solver (Python 3 + XSB)

This repository provides a Python 3 script that:

- accepts Sokoban levels in **XSB format** (from file or stdin)
- solves using a push-based BFS search (all credits go towards [https://timallanwheeler.com/blog/] (Timallan wheeler))
- outputs the solution as move strings

## Usage

```bash
python3 sokoban_turtle_solver.py level.xsb
```

or:

```bash
cat level.xsb | python3 sokoban_turtle_solver.py
```

## Output format

- `u d l r` = walking moves
- `U D L R` = push moves

If no solution is found, the script prints:

```text
No solution found
```

## Optional stats

```bash
python3 sokoban_turtle_solver.py level.xsb --stats
```

Prints `pushes` and total `moves` to stderr.
