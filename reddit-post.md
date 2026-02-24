# Reddit Post for r/ClaudeAI

---

**Title:** Cowork sessions don't sync between Macs — so I built a tool to fix that

---

**Body:**

I use Claude Desktop's Cowork mode on a Mac Studio at home and a MacBook Pro when I travel. The problem: my Cowork sessions don't follow me between machines. Session titles show up (metadata syncs via your Claude account), but the actual conversation history, output files, and uploads are stored locally and stay behind.

So I built a shell script that exports sessions from one Mac and installs them on the other, with a few things I learned the hard way baked in:

- If your macOS username differs between machines (mine does), all internal file paths get rewritten automatically
- Some sessions sync as empty shells — the title appears but there's no conversation data. `--force` overwrites these with the real data
- Includes a verification script that checks every session for integrity after sync
- Supports `--dry-run` to preview before committing, and `backup` to snapshot before changing anything

**Typical workflow when switching machines:**

1. `./migrate.sh export` on the machine you just worked on
2. Transfer `~/cowork-migration` to the other Mac (AirDrop, SCP, NAS, whatever)
3. `./migrate.sh install --force` on the target Mac
4. Restart Claude Desktop

That's it. All your sessions, conversation logs, output files, and uploads are now on both machines.

**What I learned about how Cowork stores data:**

Sessions live at `~/Library/Application Support/Claude/local-agent-mode-sessions/` in a nested UUID directory structure. The UUIDs are tied to your Claude account, not the machine, so they're identical across all your Macs. Each session has a JSON metadata file plus a directory containing the full conversation log (`audit.jsonl`), files Cowork created, and files you uploaded.

The discovery that made this possible: session metadata syncs via your account (all 51 sessions from my desktop were already listed on my laptop), but the conversation data and files don't always come along. That's the gap this tool fills.

**This is meant as a community workaround until Anthropic (hopefully) ships native cloud sync for Cowork sessions.** If you use Cowork across multiple Macs, you know the pain.

**GitHub:** [github.com/DRVBSS/cowork-migrate](https://github.com/DRVBSS/cowork-migrate)

No dependencies beyond macOS and Python 3 (pre-installed). Just clone and run. MIT licensed.

Happy to take PRs if Claude changes the storage format down the line.
