# Multi-Target Restic Backup Script with Failure Emails

A single-file, config-driven [restic](https://restic.net/) backup
orchestrator for Linux. Backs up a directory to a local repository, then
copies snapshots out to any number of additional targets such as another
mounted path (NAS, a second disk, another machine over NFS/CIFS) and/or
S3-compatible object storage (Backblaze B2, AWS S3, MinIO, ...).

## Why this exists

Most simple restic wrapper scripts either only handle one destination,
or abort entirely the moment any single step fails meaning a NAS
outage or a temporary credential glitch silently kills your *entire*
backup run, including targets that had nothing to do with the failure.

This script treats every backup target as an independent unit:

- **One target failing doesn't stop the others.** If your NAS is offline
  the local backup, your S3 copy, and anything else you've
  configured still run.
- **You get told when something breaks.** A single summary email lists
  exactly which step(s) failed, with the relevant log output attached,
  not just a generic "backup failed" cron notification.
- **Adding a target is config, not code.** New destinations are declared
  in the `.env` file; the script doesn't need editing.

## Requirements

- Linux with bash (developed/tested on Ubuntu; should work on any modern
  distro with the tools below)
- [restic](https://restic.net/) (`sudo apt install restic` or see restic's
  own install docs for other distros/methods)
- `flock` (part of `util-linux`, present by default on virtually all
  Linux systems)
- Root privileges to run the script (needed to preserve file ownership,
  ACLs, and extended attributes on the backup source)
- *Optional, for failure emails:* a `mail`-providing package (e.g.
  `mailutils` on Debian/Ubuntu) and a working local mail transport agent
  such as `postfix` configured to relay outbound mail. Setting up mail
  delivery itself is outside the scope of this script. There are
  plenty of good guides for configuring postfix as a relay-only MTA.
  Search for "postfix satellite system" or your distro's mail-server
  documentation. This script just calls `mail` if `MAIL_TO` is set and
  the binary exists. If mail isn't configured, it logs a warning and
  continues normally.
- *Optional, for S3-compatible targets:* an account and bucket with your
  provider of choice (Backblaze B2, AWS S3, MinIO, etc.) and an access
  key/secret pair. See restic's own
  [S3 backend documentation](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#amazon-s3)
  and your provider's key-management docs for the specifics.
  This script only consumes the resulting credentials, it doesn't walk you
  through creating them.

## Quick start

```bash
# 1. Install the script
sudo cp restic-backup.sh /usr/local/sbin/restic-backup.sh
sudo chmod 750 /usr/local/sbin/restic-backup.sh

# 2. Create your config
sudo cp .env.example /etc/restic-backup.env
sudo chmod 600 /etc/restic-backup.env
sudo nano /etc/restic-backup.env   # edit paths, targets, mail settings

# 3. Create a restic repo password (do this for each repo you'll use --
#    local, and one per target)
openssl rand -base64 32 | sudo tee /etc/restic/local.pass
sudo chmod 600 /etc/restic/local.pass

# 4. Create an exclude file (can start empty)
sudo touch /etc/restic/excludes.txt

# 5. Dry-run it
sudo /usr/local/sbin/restic-backup.sh

# 6. Check the log
sudo tail -f /var/log/restic-backup.log
```

Start with `ENABLED_TARGETS=""` (local-only) in your `.env` to confirm
the basics work before adding remote targets one at a time.

## Configuration reference

All configuration lives in a single sourced `.env`-style file. See
[`.env.example`](.env.example) for a fully commented template. Summary:

| Variable | Required | Description |
|---|---|---|
| `BACKUP_SOURCE` | yes | Directory to back up |
| `LOCAL_REPO` | yes | Path to the local restic repository |
| `LOCAL_TMP` | yes | Scratch directory for restic |
| `LOCAL_PASSWORD_FILE` | yes | File containing the local repo's password |
| `EXCLUDE_FILE` | yes | Restic exclude-patterns file |
| `LOCK_FILE` | no (default `/var/run/restic-backup.lock`) | Prevents overlapping runs |
| `LOG_FILE` | no (default `/var/log/restic-backup.log`) | Log output path |
| `KEEP_DAILY` | no (default `7`) | Daily snapshots to retain, per repo |
| `RESTIC_TAG` | no (default `daily`) | Tag applied to snapshots |
| `RESTIC_HOST` | no (default: machine hostname) | `--host` value passed to restic |
| `ENABLED_TARGETS` | no | Space-separated target names to run |
| `MAIL_TO` | no | Failure-email recipient; leave unset to disable email entirely |
| `MAIL_SUBJECT_TAG` | no (default `[restic-backup]`) | Email subject prefix |

### Targets

Each name in `ENABLED_TARGETS` needs a matching `TARGET_<NAME>_*` block
(name uppercased). Two types are supported:

**`path`** - another restic repo reachable via a local filesystem path:
a NAS share, a second local disk, another machine's disk exposed over
NFS/CIFS, etc.

| Variable | Required | Description |
|---|---|---|
| `TARGET_<NAME>_TYPE` | yes | `path` |
| `TARGET_<NAME>_REPO` | yes | Filesystem path to the target repo |
| `TARGET_<NAME>_PASSWORD_FILE` | yes | Password file for this repo |
| `TARGET_<NAME>_MOUNTPOINT` | no | If set, verified mounted (`mountpoint -q`) before use |

**`s3`** - an S3-compatible object store (Backblaze B2, AWS S3, MinIO,
Wasabi, ...).

| Variable | Required | Description |
|---|---|---|
| `TARGET_<NAME>_TYPE` | yes | `s3` |
| `TARGET_<NAME>_REPO` | yes | Restic `s3:...` repository URL |
| `TARGET_<NAME>_PASSWORD_FILE` | yes | Password file for this repo |
| `TARGET_<NAME>_ENV_FILE` | yes | File exporting `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |

Target names may only contain letters, digits, and underscores (they're
used to build variable names internally).

### Setting up a mount for a `path` target

This script checks that a mount is present (if you set
`TARGET_<NAME>_MOUNTPOINT`); it doesn't create the mount for you. In
brief: add an entry to `/etc/fstab` (or a `systemd.mount` unit) for your
NAS share or second disk, mount it, and point `TARGET_<NAME>_REPO` at a
directory inside it. See `man fstab`, `man mount`, or your NAS vendor's
NFS/CIFS export documentation for the specifics of your setup.

## Running on a schedule

Two examples are provided in [`examples/`](examples/):

- **cron**: add a line like the following to root's crontab
  (`sudo crontab -e`):
  ```
  0 3 * * * /usr/local/sbin/restic-backup.sh >/dev/null 2>&1
  ```
- **systemd timer**: see
  [`examples/systemd/restic-backup.service`](examples/systemd/restic-backup.service)
  and
  [`examples/systemd/restic-backup.timer`](examples/systemd/restic-backup.timer).
  Install both under `/etc/systemd/system/`, then:
  ```bash
  sudo systemctl daemon-reload
  sudo systemctl enable --now restic-backup.timer
  ```

## Log rotation

The script appends to `LOG_FILE` indefinitely; it doesn't rotate its own
logs. Use `logrotate` -- see
[`examples/logrotate.conf`](examples/logrotate.conf) for a starting
point. Install it at `/etc/logrotate.d/restic-backup` and test with:

```bash
sudo logrotate -d /etc/logrotate.d/restic-backup   # dry run
sudo logrotate -f /etc/logrotate.d/restic-backup   # force a rotation
```

If you see an "insecure permissions" error, the example config already
includes the `su root root` fix -- see the comments in that file for
why.

## How failure reporting works

- If nothing can start at all (missing backup source, restic not
  installed, config file missing, etc.), you get an email immediately
  and the script exits.
- If the local backup or any individual target fails partway through,
  the script logs it, **skips retention for that step**, and moves on to
  the next step regardless.
- At the end of the run, if anything failed, you get **one** email
  listing every failed step by name, a full OK/FAILED summary of every
  step that ran, and the last 60 lines of the log.
- A fully clean run sends no email at all.

Only the local repository gets an integrity check (`restic check`) by
default; remote targets (NAS/S3/etc.) are not independently verified,
since doing so for an S3 target means real egress cost and for any
target means real added runtime. If you want that, `restic check
--read-data-subset=<N>/<M>` against a target repo (via `restic -r
<repo> --password-file <file> check --read-data-subset=1/20`, for
example) is a reasonable periodic addition -- left out of this script
by default so you can opt in deliberately rather than have it silently
add cost/time to every run.

## Troubleshooting

- **"insecure permissions" from logrotate** - see the Log rotation
  section above.
- **B2/S3 target fails with an obscure credential error** - the script
  validates that `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are actually
  set after sourcing `TARGET_<NAME>_ENV_FILE`; if you're still stuck,
  confirm the file has no stray quoting issues and that each line starts
  with `export`.
- **Nothing happens / "another backup run is already in progress"** -
  check `LOCK_FILE`; a crashed prior run can occasionally leave a stale
  lock. `flock` releases automatically when the holding process exits,
  so this is rare, but if you're certain no run is active, the lock file
  can be safely removed.
- **No email arrives on failure** - confirm `mail -s test you@example.com`
  works standalone first; if it doesn't, the issue is in your MTA setup,
  not this script.
## License

[MIT](LICENSE)
