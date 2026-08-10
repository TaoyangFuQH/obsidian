---
description: Append a timestamped entry to today's Obsidian daily note
allowed-tools: Bash(date:*), Read, Write, Edit
---
Append a log entry to my Obsidian daily note.

Entry: $ARGUMENTS

Steps:
1. Get today's date (`date +%Y-%m-%d`) and current time (`date +%H:%M`).
2. Target file: `~/workspace/obsidian/Daily/<today>.md`.
3. If it does not exist, create it from `~/workspace/obsidian/Templates/daily.md`,
   replacing every `{{date}}` with today's date.
4. Append `- <HH:MM> — $ARGUMENTS` as the last bullet under the `## Log` heading.
   Do not modify or reorder any existing entries.
5. If the entry references a project or person, wrap it as a `[[wikilink]]`.
6. Confirm with the one line you appended — do not print the whole file.
