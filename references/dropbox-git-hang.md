# Dropbox Git Hang — Diagnostic Playbook

## Symptoms
- cmux terminal shows no shell prompt; Claude Code appears "stuck running"
- `ps` shows git subprocesses under cmux with long `ELAPSED` times (minutes)
- `timeout 5 git status` on the repo returns exit 124

## Root Cause Chain
macOS Dropbox uses File Provider API → files marked `dataless` (online-only, no local content) → reading a file triggers download → I/O blocks until download completes → git I/O hangs on even tiny files.

**Definitive diagnostic** — check if a file is cloud-only:
```bash
# File flags: compressed,dataless = online-only (content not on disk)
ls -lO /path/to/file
# Extended attributes show Dropbox File Provider metadata
xattr -l /path/to/file  # look for com.dropbox.attrs
```
If `ls -lO` shows **`dataless`**, the file content is NOT local. Any read() call blocks until Dropbox downloads it. This applies to ALL `.git` files including tiny ones like `.git/HEAD` (21 bytes).

Three compounding factors in the `RecomAlgorithm` repo (archetypal):

1. **18 GB git pack file**: `.git/objects/pack/pack-*.pack` — all object-database reads block when Dropbox syncs it
2. **Tracked large data files**: 13.6 GB `yt_metadata_en.jsonl.gz`, 2.4 GB `youtube_ideology.tar.gz`, 2.1 GB `new_yt_score_all_subrs.csv.bz2` — `git status` reads them to check for changes
3. **Deep file trees**: `data/raw/youtube_ideology/data/included/` subdirectory with more tracked files

## Step 1: Confirm Git Is the Blocker

```bash
# Find cmux daemon PID
CMUX_PID=$(pgrep -f '/Applications/cmux.app/Contents/MacOS/cmux')

# See git subprocesses and their elapsed time
ps -eo pid,ppid,stat,etime,command | awk -v p=$CMUX_PID '$2==p && /git/'
```

Processes stuck >30s for `git status` or `git branch --show-current` confirm the hang.

## Step 2: Find Which File Git Is Stuck On

```bash
# For each stuck git PID, check open file descriptors
GIT_PID=<pid>
lsof -p $GIT_PID 2>/dev/null | grep 'REG.*CloudStorage'
```

Look for FD `3r` on a large file — that's git reading it. The file path tells you what to fix.

## Step 3: Immediate Relief — Kill + Exclude

```bash
# Kill stuck git processes (use -9; SIGTERM is often ignored during I/O wait)
kill -9 <pid1> <pid2> ...

# Mark large tracked files as assume-unchanged so git status skips them
git -C /path/to/repo update-index --assume-unchanged \
  data/raw/youtube_ideology.tar.gz \
  data/raw/yt_metadata_en.jsonl.gz

# Verify git status no longer hangs
timeout 10 git -C /path/to/repo status --porcelain
```

**Caveat**: `--assume-unchanged` only helps if the hang is on working-tree file reads. If the 18 GB pack file is locked by Dropbox, even `git cat-file -t HEAD` will hang — `--assume-unchanged` won't help. In that case, pause Dropbox sync or wait.

**Caveat**: `git commit` may appear to time out (exit 124) but actually succeed — the commit object is written to disk before the timeout fires. Check `git log --oneline -1` to confirm instead of trusting the exit code.

## Step 4: Permanent Fix — Bare-Repo Architecture

The root problem: Dropbox File Provider marks files `dataless` (online-only), and git needs to read `.git` files constantly. The two don't mix.

**Do NOT put a working git repo in Dropbox.** The correct architecture:

```
~/working/RecomAlgorithm/          ← working tree (local disk, NOT Dropbox)
~/Dropbox/repos/RecomAlgorithm.git ← bare repo (Dropbox-synced remote)
~/Dropbox/data/RecomAlgorithm/     ← large data files (Dropbox-synced)
```

Working tree links to Dropbox data via symlink:
```bash
ln -s ~/Dropbox/data/RecomAlgorithm ~/working/RecomAlgorithm/data
```

Git remote points to the bare repo in Dropbox:
```bash
git remote add origin ~/Dropbox/repos/RecomAlgorithm.git
git push origin main
```

**Why bare repo in Dropbox works:**
- No working tree → no `git status` scanning
- Only `.git/objects` and `.git/refs` — pack files, simple read/write pattern
- Dropbox syncs pack files without the churn of thousands of small file locks
- Other machines: `git clone ~/Dropbox/repos/RecomAlgorithm.git`

**Migration steps** (after user makes files "available offline" in Finder):

```bash
# 1. Create bare repo in Dropbox
git init --bare ~/Library/CloudStorage/Dropbox/repos/RecomAlgorithm.git

# 2. Move working tree out of Dropbox
mkdir -p ~/working
mv ~/Library/CloudStorage/Dropbox/working/RecomAlgorithm ~/working/RecomAlgorithm

# 3. Add remote and push
cd ~/working/RecomAlgorithm
git remote add origin ~/Library/CloudStorage/Dropbox/repos/RecomAlgorithm.git
git push origin main

# 4. Symlink data back to Dropbox
rm -rf data
ln -s ~/Library/CloudStorage/Dropbox/working/RecomAlgorithm/data ~/working/RecomAlgorithm/data

# 5. On another machine
git clone ~/Library/CloudStorage/Dropbox/repos/RecomAlgorithm.git
ln -s ~/Library/CloudStorage/Dropbox/working/RecomAlgorithm/data data
```

**Caveat: `mv` from Dropbox hangs on `dataless` files.** If files are `compressed,dataless`, `mv` (which copies+deletes across filesystem boundaries) will block on every unreadable file. The user MUST first make the folder "available offline" in Finder (right-click → "Make available offline"). There is no CLI for this — `fileproviderctl`, `brctl`, `cp -c`, `ditto` all hang on dataless files.

**Quick fix before full migration** — if you just need git to work NOW:
```bash
# Add data/ to .gitignore
echo 'data/' >> .gitignore

# Remove large files from git tracking (keeps them on disk)
# Note: git rm --cached may itself hang if pack file is locked
git rm --cached data/raw/youtube_ideology.tar.gz
git rm --cached data/raw/yt_metadata_en.jsonl.gz

# Commit the removal
git commit -m "Untrack large data files (Dropbox I/O issues)"
```

## Testing Git Health

```bash
# Quick check: can git read its object database?
timeout 5 git cat-file -t HEAD  # should return "commit" near-instantly

# Quick check: can git stat the working tree?
timeout 10 git status --porcelain  # should complete with no or few lines
```

If `cat-file` hangs → pack file is locked → pause Dropbox or wait.
If only `status` hangs → working-tree files are the issue → `--assume-unchanged` or `git rm --cached`.

## CLI Dead Ends

These do NOT work to force-download dataless files from Dropbox File Provider:

| Attempt | Result |
|---|---|
| `fileproviderctl materialize` | Command doesn't exist |
| `brctl download` | Command doesn't exist |
| `cp -c` (APFS clone) | Hangs on `compressed,dataless` files |
| `ditto` | Hangs on dataless files |
| `mv` across filesystems | Hangs (reads every file to copy) |
| `cat` on a dataless file | Hangs until Dropbox downloads it |
| `touch` on a dataless file | Succeeds but does NOT trigger download |

**Only Fix**: Finder → right-click folder → "Make available offline" → wait for Dropbox to finish downloading. There is no programmatic workaround.
