# Obsidian vault — daily log

This vault is written to by Claude Code and read/edited by me in Obsidian.

## Conventions (the contract for Claude)

- **Daily notes** live in `Daily/YYYY-MM-DD.md` (ISO date). One file per day.
- When logging, **append a timestamped bullet** under the `## Log` heading of
  today's note: `- HH:MM — <entry>` (24h local time).
- If today's file does not exist, create it from `Templates/daily.md`,
  substituting the date for `{{date}}`.
- Use `[[wikilinks]]` for projects, people, and other notes
  (e.g. `[[qh-platform]]`).
- Durable per-project notes go in `Projects/<name>.md`.
- Never rewrite or reorder existing log entries; only append.

## Obsidian setup

- Enable **Daily Notes** core plugin → folder `Daily/`, template
  `Templates/daily.md`, format `YYYY-MM-DD`.
- Backlinks show up automatically on `[[...]]` targets.

## Logging with Claude

Use the `/log` slash command in any Claude Code session:

```
/log fixed the MDM derivation bug in clinical coding v1
```
