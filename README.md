# skills

Personal catalog of Agent Skills (`SKILL.md` folders) for Claude Code, Codex, Cursor, GitHub Copilot, Grok, and anything else that reads the Agent Skills spec.

Author each skill once under `skills/<name>/`. The install script links that folder into the two discovery roots that actually get auto-loaded:

- `.agents/skills/` — Codex, Cursor, Copilot, Grok, Gemini
- `.claude/skills/` — Claude Code (Cursor, Copilot, and Grok also read this)

There is no single folder all of those agents scan. Two links beat five copies.

## Install

**Windows (PowerShell):**

```powershell
pwsh -File scripts/install.ps1
```

**macOS / Linux:**

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

That does both this repo and your user home (`~/.agents/skills`, `~/.claude/skills`). Scope it if you want:

```text
--project / -Project     this repo only
--global  / -Global      user home only
--uninstall              remove this catalog's links
--dry-run / -DryRun      print actions, change nothing
--status  / -Status      show what is linked
```

On Windows, `install.sh` runs `install.ps1` and creates directory junctions (no Developer Mode). On macOS and Linux it creates symlinks.

Re-run after you add, rename, or delete a skill. Stale links from this catalog are pruned. Links that point at some other catalog are left alone. A real directory in the way is left alone.

## Tests

```powershell
pwsh -File scripts/test-install.ps1
```

```bash
./scripts/test-install.sh
```

## Add a skill

1. Create `skills/<name>/SKILL.md` with `name` and `description` frontmatter.
2. Run the install script.
3. In an agent session, invoke `/<name>` or let the description trigger it.

Keep frontmatter to the portable spec fields (`name`, `description`, plus optional `license`, `compatibility`, `metadata`, `allowed-tools`) if the same file has to load in every host.

## Using these skills in other repos

A global install is enough for local agents. Grok can also point at the catalog without links:

```toml
# ~/.grok/config.toml
[skills]
paths = ["/absolute/path/to/this-repo/skills"]
```

Claude Code has no extra-path setting. Global `~/.claude/skills` links, `claude --add-dir` this repo, or a plugin are the options.
