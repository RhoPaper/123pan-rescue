# 123pan-rescue

Rescue **all files from a 123pan (123云盘) cloud drive to a local disk** — resumable, checkpointed, and verifiable.

[中文说明](README.md) · English

123pan ships an official WebDAV endpoint (*Tools → Third-party mount*), but the vendor itself warns against
using it for file migration: **it supports neither instant-upload nor resume**, and it lags on large directories.
Copying hundreds of GB through a mounted drive usually means losing track of where you stopped, re-downloading
everything after a hiccup, and having no idea whether the copy is actually complete.

This wrapper fixes those three problems with **per-top-level-directory batching + file-level skip +
interrupt checkpoints + full reconciliation**.

## Features

- 🧭 **Interactive menu** — run it with no arguments and pick from a menu; a config wizard handles first-time setup.
- 🔐 **Config wizard** — server / account / app password / destination, stored in `~/.config/123pan-rescue/config` (mode 600).
- ♻️ **Real resume** — files already present with a matching size are skipped; re-running only fetches what is missing.
- 📌 **Checkpoints** — on Ctrl-C the script records the *in-flight* file (and its byte offset) **before** terminating rclone,
  because rclone deletes its `*.partial` temp file on graceful exit.
- 🧮 **Verification** — file count, total bytes, and per-file size are reconciled against a cloud manifest.
- 🧱 **Manifest shrink guard** — a truncated (index-lagged) listing is refused instead of silently reported as "all good".
- 🛡 **Never deletes** — only `copy / copyto / lsjson / lsd` are used; `sync` and `delete` are never called.
- 🔒 **Single-instance lock** — `flock` prevents accidentally running two transfers against the same destination.
- 🧪 **47-case self-test** — spins up a local fake WebDAV server, including a "kill mid-download and resume" case.

## Requirements

`bash 4.4+`, `rclone 1.60+` (latest recommended), `python3`, `curl`, `flock`.

```bash
# Arch
sudo pacman -S rclone python curl util-linux
# Debian / Ubuntu
sudo apt install -y python3 curl util-linux
curl -fsSL https://rclone.org/install.sh | sudo bash
```

## Quick start

Prerequisite: a 123pan membership (third-party mount is a paid feature). Create an app under
*Tools → Third-party mount → Add app*, **authorize the `我的文件` root folder**, prefer **read-only** permission,
and copy the generated **app password**.

```bash
git clone git@github.com:RhoPaper/123pan-rescue.git
cd 123pan-rescue

./123pan-rescue.sh            # interactive menu (recommended for the first run)

# or step by step
./123pan-rescue.sh init       # configure server / account / app password / destination
./123pan-rescue.sh preflight  # connectivity, auth, free space — downloads nothing
./123pan-rescue.sh manifest   # fetch the full cloud manifest (path + size)
./123pan-rescue.sh run        # download; Ctrl-C any time, re-run to resume
./123pan-rescue.sh verify     # reconcile: count, bytes, no missing files
```

## Commands

| Command | Purpose |
|---|---|
| `init` | Configuration wizard |
| `menu` | Interactive menu |
| `preflight` | Health check: reachability, vendor probing, auth, listing, free space |
| `manifest` | Fetch the cloud manifest, one remote directory at a time |
| `run` | Download by top-level directory; per-item checkpoints and retries |
| `status` | Progress summary (`status deep` also verifies locally) |
| `verify` | Full reconciliation (local only — costs no cloud traffic) |
| `crosscheck <txt>` | Cross-check against a directory-tree text dump |
| `settings` | Adjust concurrency / rate limit / priority / skip list |
| `reset` | Clear checkpoint state (never touches downloaded files) |

## Flags

```
-d DIR   destination        -t N   concurrent transfers      -P A,B  download priority
-u URL   WebDAV endpoint    -c N   concurrent directory scans -s A,B  skip these folders
-a USER  account            -l R   rate limit (e.g. 10M)     -y      assume yes
-n       dry run            -q     quiet                     --no-color / --menu / --allow-shrink
```

Precedence: **CLI flags > environment variables > config file > built-in defaults**.

## How verification works

`verify` requires all three to be green: matching file count, matching total bytes, and zero missing /
size-mismatched files. WebDAV exposes no file hashes, so finish with a spot check: pick a few dozen files
(including the largest ones) and compare a locally computed `md5sum` against a freshly downloaded copy.

## Notes and limitations

- The state directory is named `.from123-state` (inside the destination) for backward compatibility.
- The manifest is TAB-separated; file names containing a literal TAB are not supported.
- A destination on `tmpfs` is rejected on purpose.
- The 123pan "backup" area (PC/phone backups) is not part of the `我的文件` tree and is usually invisible over WebDAV —
  use the official client to restore those.
- The tool targets generic WebDAV but the defaults assume 123pan; other servers work via `--url` but are untested.

## Testing locally (no cloud account needed)

```bash
./test/make-testdata.sh   # build a fake cloud drive with awkward names, deep nesting, a 200MB file...
./test/selftest.sh        # start a local WebDAV server and run all 47 cases
```

## License

[MIT](LICENSE)
