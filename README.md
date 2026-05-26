# cowork-migrate

Sync [Claude Desktop](https://claude.ai) Cowork sessions between Macs.

Claude Desktop's Cowork mode stores session data locally — conversation history, output files, and uploads don't fully sync across machines. If you work on a desktop at home and a laptop on the road, your sessions won't follow you. This tool bridges the gap until Anthropic ships native cloud sync.

**Use cases:**

- Keep the same Cowork sessions on your desktop and laptop
- Migrate sessions when upgrading to a new Mac
- Back up your Cowork session data locally

## What It Syncs

Each Cowork session consists of:

- **Session metadata** (`local_<uuid>.json`) — title, creation date, model used, selected folders, initial message
- **Conversation log** (`audit.jsonl`) — the complete chat history
- **Output files** (`outputs/`) — files Cowork created during the session
- **Uploaded files** (`uploads/`) — files you uploaded into the session
- **Internal state** (`.claude/`) — Cowork's working state for the session

## Requirements

- macOS (tested on macOS 13+)
- Python 3 (pre-installed on macOS)
- Claude Desktop with Cowork mode used at least once on both Macs
- Both Macs logged into the same Claude account

## Quick Start

### Step 1: Export from the source Mac

```bash
git clone https://github.com/DRVBSS/cowork-migrate.git
cd cowork-migrate
./migrate.sh export
```

This creates `~/cowork-migration/` containing your sessions.

If you have more than one Claude account logged in (or Claude has created more than one workspace) the tool will list the available `(account-uuid / sub-uuid)` pairs and let you pick which one to export. Pick `A` to export them all in one go, or pass `--all` to skip the prompt. For scripted runs, use `--account=<uuid> --sub=<uuid>` to target a specific pair.

### Step 2: Transfer to the other Mac

Use any method to copy the `~/cowork-migration` folder:

```bash
# AirDrop — right-click the folder in Finder, Share > AirDrop

# SCP over network
scp -r ~/cowork-migration user@other-mac.local:~/

# USB/Thunderbolt drive
cp -R ~/cowork-migration /Volumes/MyDrive/

# Synology/NAS — copy to a shared folder
cp -R ~/cowork-migration /Volumes/NAS-Share/
```

### Step 3: Install on the target Mac

```bash
cd ~/cowork-migration
./migrate.sh install
```

New sessions are added. Existing sessions are skipped (use `--force` to overwrite).

### Step 4: Restart Claude Desktop

Quit Claude Desktop (Cmd+Q) and reopen it. Your sessions should appear in the Cowork sidebar.

### Step 5: Verify

```bash
./migrate.sh verify
```

Or use the standalone verification script for a more detailed check:

```bash
./verify.sh --verbose
```

## Ongoing Sync Between Two Macs

To keep sessions in sync as you work across machines, run the export/transfer/install cycle whenever you switch. A typical workflow:

1. Finish working on Mac A
2. Run `./migrate.sh export` on Mac A
3. Transfer `~/cowork-migration` to Mac B (AirDrop, SCP, NAS, etc.)
4. Run `./migrate.sh install --force` on Mac B
5. Restart Claude Desktop on Mac B

The `--force` flag ensures that sessions updated on Mac A overwrite the older versions on Mac B. Without it, existing sessions are skipped.

**Tip:** If both machines are on the same network, you can do it in one shot from Mac B:

```bash
scp -r user@mac-a.local:~/cowork-migration ~/
cd ~/cowork-migration && ./migrate.sh install --force
```

## Commands

| Command | Description |
|---------|-------------|
| `./migrate.sh export` | Export all sessions to `~/cowork-migration/` |
| `./migrate.sh install` | Import sessions from `~/cowork-migration/` |
| `./migrate.sh install --force` | Import and overwrite existing sessions |
| `./migrate.sh verify` | Verify all sessions are healthy after sync |
| `./migrate.sh list` | List all Cowork sessions on this Mac |
| `./migrate.sh backup` | Create a timestamped backup of all sessions |

### Standalone Verification Script

For a more detailed health check, use the standalone `verify.sh`:

```bash
./verify.sh               # Check all sessions
./verify.sh --verbose     # Detailed per-file checks
./verify.sh --fix         # Auto-fix stale username paths
```

Checks performed:

- JSON metadata is valid and parseable
- Session directories exist with conversation data
- `audit.jsonl` (conversation log) exists and is non-empty
- All file paths reference the correct macOS username
- Referenced folders (selected workspace directories) exist on disk
- Output and upload files are present

### Options

| Flag | Description |
|------|-------------|
| `--force` | Overwrite sessions that already exist on the target Mac |
| `--dry-run` | Preview what would happen without making changes |
| `--account=<uuid>` | Pre-select an account-uuid (skip the interactive prompt) |
| `--sub=<uuid>` | Pre-select a sub-uuid (skip the interactive prompt) |
| `--all` | Select every `(account/sub)` pair found on this Mac (export only) |
| `--target-account=<uuid>` | Install into a different account-uuid; UUIDs inside session files are rewritten to match (install only) |
| `--target-sub=<uuid>` | Install into a different sub-uuid; UUIDs inside session files are rewritten to match (install only) |
| `--help` | Show usage information |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COWORK_STAGING_DIR` | `~/cowork-migration` | Override the staging directory location |

## How It Works

Claude Desktop stores Cowork sessions locally at:

```
~/Library/Application Support/Claude/local-agent-mode-sessions/<account-uuid>/<sub-uuid>/
```

A Mac can have several of these `(account-uuid / sub-uuid)` pairs — typically one per Claude account you've logged into, sometimes more if Claude has created additional workspaces. Each pair is independent and contains its own set of sessions:

```
local_<session-uuid>.json          # Metadata (title, date, model, etc.)
local_<session-uuid>/              # Session data directory
  audit.jsonl                      # Full conversation log
  outputs/                         # Files created by Cowork
  uploads/                         # Files you uploaded
  .claude/                         # Internal working state
```

The tool:

1. **Export** — enumerates every `(account/sub)` pair on this Mac; if there's more than one, prompts you to pick which one (or `A` for all). Copies the selected pair(s) into the staging folder, preserving the hierarchy: `~/cowork-migration/sessions/<account-uuid>/<sub-uuid>/`
2. **Install** — finds every pair inside the staging folder and copies each into the target Mac's matching `<account-uuid>/<sub-uuid>/` location (creating those directories if Claude Desktop hasn't yet). Sessions that already exist are skipped unless `--force` is used.
3. **Path rewriting** — if the macOS username differs between machines (e.g., `john` on the desktop, `johnsmith` on the laptop), all file paths inside JSON and JSONL files are automatically rewritten.

`list`, `verify`, and `backup` all iterate across every pair found on this Mac and group their output per pair. You can scope any command to a single pair with `--account=<uuid> --sub=<uuid>`.

## Common Scenarios

### Sessions show up but are empty

Some sessions may sync their metadata via your Claude account but not the actual conversation data. Use `--force` to overwrite:

```bash
./migrate.sh install --force
```

### Different usernames on each Mac

Handled automatically. The tool detects the source username from paths inside the session files and rewrites them to match the current user. No manual configuration needed.

### Migrating sessions from one Claude account into another

Use `--target-account` and/or `--target-sub` on `install` to move sessions across accounts (or across workspaces within the same account). The tool writes the session into the target `<account-uuid>/<sub-uuid>/` directory and rewrites every reference to the source UUIDs inside the session metadata, `audit.jsonl`, and the internal `.claude/` files. Files you uploaded or that Cowork generated under `outputs/` and `uploads/` are left untouched.

```bash
# 1) On the source Mac, export the pair you want to migrate
./migrate.sh export --account=AAA-... --sub=BBB-...

# 2) Transfer ~/cowork-migration to the target Mac, then list the
#    pairs that already exist for the destination account:
./migrate.sh list

# 3) Install the source pair into the destination pair
./migrate.sh install \
    --account=AAA-... --sub=BBB-... \
    --target-account=CCC-... --target-sub=DDD-...
```

Either `--target-account` or `--target-sub` can be set on its own — the unset side preserves the source UUID. Because the rewrite is destructive on the installed copy, the staging folder is left unchanged and you can re-run with `--force` if anything goes wrong.

Remapping is only allowed when staging contains exactly one source pair — use `--account` / `--sub` to pick one if you exported several at once.

### Multiple Claude accounts on one Mac

If you've logged into more than one Claude account, `~/Library/Application Support/Claude/local-agent-mode-sessions/` will contain multiple `<account-uuid>/` directories. Each command lists them and lets you choose:

```bash
./migrate.sh export
# Multiple (account-uuid / sub-uuid) pairs found
# ============================================================
#
#   1) account: 84ffcfc5-8f16-4701-89c1-7dd74a5334ba
#      sub:     13181e23-288a-4768-912b-646e119ecc3b
#      sessions: 21
#
#   2) account: 9a2b...
#      sub:     7c4d...
#      sessions: 8
#
#   A) All pairs
#
#   Select [1-2 or A]:
```

Pick a number to export just that account, or `A` to export everything. To pre-select non-interactively, pass `--account=<uuid>` and/or `--sub=<uuid>`, or `--all`.

`list`, `verify`, and `backup` always operate across every pair (and group their output per pair). Scope any of them to a single account with the same `--account` / `--sub` flags.

### Checking what's on your Mac before syncing

```bash
./migrate.sh list
```

Shows all sessions with their titles, dates, and archived status.

### Creating a backup before making changes

```bash
./migrate.sh backup
```

Creates a timestamped copy at `~/cowork-backup-YYYYMMDD-HHMMSS/`.

## Troubleshooting

### "No Cowork sessions found"

Make sure Claude Desktop has been opened in Cowork mode at least once. The session directory is only created after your first Cowork session.

### "Operation not permitted" errors

If running from a location with restricted permissions (like an external drive), copy the script to your home directory first:

```bash
cp /Volumes/MyDrive/cowork-migration/migrate.sh ~/
cd ~
./migrate.sh install
```

### Sessions don't appear after install

1. Make sure Claude Desktop is completely quit (Cmd+Q, not just closed)
2. Reopen Claude Desktop
3. Check the Cowork sidebar — migrated sessions should appear with their original titles
4. If a session shows but has no content, re-run with `--force`

### "Permission denied" on the script

```bash
chmod +x migrate.sh
```

## Data Safety

- The tool never modifies files on the source Mac during export
- During install, existing sessions are skipped by default (no overwrites)
- Use `--dry-run` to preview any operation before committing
- The `backup` command creates a safety copy you can restore from

## Limitations

- Migrated sessions may not be resumable (Cowork might treat them as read-only history)
- The conversation log and all files are preserved for reference
- This is a community workaround until Anthropic adds native cloud sync for Cowork sessions
- This tool works with the local session storage format as of Claude Desktop v1.x (February 2025). Future versions may change the storage format.

## Contributing

Issues and pull requests are welcome. If Claude Desktop changes its session storage format, please open an issue.

## License

MIT License. See [LICENSE](LICENSE) for details.
