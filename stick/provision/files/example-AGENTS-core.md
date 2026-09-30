# Global Agent Instructions (placeholder)

The real `AGENTS-core.md` ships only on the physical stick (internal policy;
gitignored). `ENABLE_POLICY_FILES=1` installs it as `~/AGENTS.md` and
`~/.codex/AGENTS.md`, and writes `~/.claude/CLAUDE.md` containing:

```
# Global Instructions

@~/AGENTS.md
```

(the `@` import is expanded by Claude Code; Codex reads `~/.codex/AGENTS.md`
directly, so the same core file serves both).

To provide your own: create `stick/provision/files/AGENTS-core.md` with your
core agent policy. Structure convention used by the real file: markdown
section headers paired with matching lowercase XML tags, e.g.

```markdown
# Core policy

<quality>
Rules here.
</quality>

<languages>
Rules here.
</languages>
```

Refresh it from your control machine's `~/AGENTS.md` by stripping any
`@`-import lines (imports reference paths that do not exist on fresh
machines).
