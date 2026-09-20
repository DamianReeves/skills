# Skills

Each skill is one folder with a `SKILL.md` file:

```text
skills/my-skill/
  SKILL.md
  scripts/       optional executables
  references/    optional extra docs
  assets/        optional templates
```

This is the only copy you edit. After you add or rename a skill, run `scripts/install.sh` or `scripts/install.ps1` so `.agents/skills` and `.claude/skills` point here.

`name` in the frontmatter should match the folder name: lowercase letters, digits, hyphens.
