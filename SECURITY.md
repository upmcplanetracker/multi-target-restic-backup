# Security Policy

## Supported Versions

This is a single-branch personal/homelab project -- there are no
maintained release lines or LTS versions. Security fixes land on `main`;
always run the latest version of `restic-backup.sh`.

## Reporting a Vulnerability

There's no dedicated security contact or private disclosure process for
this project. If you find a security issue (e.g. a way the script's
config/credential-file handling, locking, or privilege model could be
abused), please just open a
[GitHub issue](../../issues) describing it, or submit a
[pull request](../../pulls) with a fix if you have one.

Since this project doesn't handle sensitive data beyond what's in your
own local config (repository passwords, cloud credentials -- all of
which stay on your machine and are never transmitted anywhere by the
script itself), public disclosure via a normal issue is fine for
essentially any finding. If you're ever unsure whether something is
sensitive enough to warrant more caution before posting publicly, use
your judgment -- a heads-up in the issue that you're being deliberately
vague about exploit details is welcome, but a formal embargo process
isn't necessary for a project of this scope.

## Scope

Relevant: `restic-backup.sh`'s handling of config files, credential
files, locking, and privilege (it runs as root). Also relevant: the
example `logrotate.conf` and systemd unit files in `examples/`.

Out of scope: vulnerabilities in `restic` itself (report those
[upstream](https://github.com/restic/restic/security)), your MTA/mail
setup, or your cloud storage provider -- this script only consumes
those, it doesn't implement them.
