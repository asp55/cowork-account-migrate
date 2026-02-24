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

This creates `~/cowork-migration/` containing all your sessions.

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

The two UUID directories are tied to your Claude account (not the machine), so they're identical across all Macs logged into the same account. Each session has:

```
local_<session-uuid>.json          # Metadata (title, date, model, etc.)
local_<session-uuid>/              # Session data directory
  audit.jsonl                      # Full conversation log
  outputs/                         # Files created by Cowork
  uploads/                         # Files you uploaded
  .claude/                         # Internal working state
```

The tool:

1. **Export** — copies all session JSON files and their directories into a portable staging folder
2. **Install** — copies sessions into the target Mac's Claude session directory, skipping any that already exist (unless `--force` is used)
3. **Path rewriting** — if the macOS username differs between machines (e.g., `john` on the desktop, `johnsmith` on the laptop), all file paths inside JSON and JSONL files are automatically rewritten

## Common Scenarios

### Sessions show up but are empty

Some sessions may sync their metadata via your Claude account but not the actual conversation data. Use `--force` to overwrite:

```bash
./migrate.sh install --force
```

### Different usernames on each Mac

Handled automatically. The tool detects the source username from paths inside the session files and rewrites them to match the current user. No manual configuration needed.

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
