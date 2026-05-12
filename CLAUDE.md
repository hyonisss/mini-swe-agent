# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**mini-swe-agent** is a minimalist AI software engineering agent that solves GitHub issues and programming challenges. The core design philosophy is simplicity: the agent is ~100 lines of Python, uses only bash as its tool, and maintains a completely linear message history.

## Commands

```bash
# Install for development
pip install -e .

# Run the agent
mini -t "your task"
mini -m "claude-sonnet-4-5" -t "task" -y   # specify model, auto-confirm all actions

# Tests
pytest -n auto                          # all tests in parallel
pytest tests/test_fire.py --run-fire    # real API tests (costs money, requires API keys)
pytest tests/test_foo.py::test_bar      # single test

# Lint & format
ruff check --fix .
ruff format .
pre-commit run --all-files
```

## Architecture

Three pluggable components interact via duck-typed protocols (defined in `src/minisweagent/__init__.py`):

```
minisweagent/
  __init__.py       # Model, Environment, Agent protocols
  agents/           # Control flow (DefaultAgent, InteractiveAgent)
  models/           # LLM interfaces (litellm, text-based, response API variants)
  environments/     # Action execution (local, docker, singularity, swerex)
  config/           # YAML loading, Jinja2 templating, Pydantic validation
  run/              # Entry point scripts (mini.py, benchmarks/, utilities/)
```

**Data flow:** `DefaultAgent.run(task)` loops: call LLM → parse bash tool call → `Environment.execute()` → append observation to messages → repeat until `Submitted` or limits exceeded.

**Message structure:** Each message dict has `role`, `content`, and `extra` (parsed actions, cost, timestamp, response metadata).

**Exit/control via exceptions:** `InterruptAgentFlow` hierarchy — `Submitted` (task done), `LimitsExceeded` (step/cost limit), `UserInterruption`, `FormatError`.

### Key design decisions

- **Only bash**: No specialized tools. All agent actions are shell commands.
- **Stateless execution**: Each bash action runs in a fresh subprocess — no persistent shell state between steps.
- **Linear history**: Messages are appended sequentially; no branching, filtering, or editing.
- **Template-based prompting**: Jinja2 templates for system and instance messages, with access to env vars and platform info.
- **Configuration**: YAML files (e.g. `configs/mini.yaml`) select which agent/model/environment class to instantiate; CLI key-value overrides supported (e.g. `model.model_kwargs.temperature=0`).

## Style Guide

- Python 3.10+, type annotations using built-in generics (`list` not `List`)
- Use `pathlib` over `os.path`; prefer `Path.read_text()` over `open()`
- Minimal code — avoid intermediate variables when you can pass expressions directly
- No exception catching unless explicitly required; let exceptions surface to users
- Comments only for genuinely non-obvious logic
- Config objects use `dataclass` (Pydantic BaseModel in practice)
- Templates use `jinja2`

### Test style

- `pytest` only (not `unittest`)
- **Do not mock/patch anything unless explicitly asked to**
- No trivial tests — each test should cover multiple failure points
- Inline assertions: `assert func() == expected` not `result = func(); assert result == expected`
- `parametrize` first arg: tuple; second arg: list

## Commit Message Format

```
feat(component): description     # new features
fix(component): description      # bug fixes
enh(component): description      # enhancements
ref(component): description      # refactoring
ci: description                  # CI/test infrastructure
dev: description                 # dev tooling (cursor/claude rules, etc.)
docs: description                # documentation
chore: description               # maintenance
```

Components: `models`, `agents`, `env`, `config`, `run`, `benchmarks`, `cli`, `deps`

Focus commit messages on intent, not implementation details. Do **not** add "Co-authored-by" lines.
