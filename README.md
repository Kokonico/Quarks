# Quarks

Quarks is a source-based package manager for Linux. You ask for a package, it works out the dependencies, builds everything in a sandbox under your own user, and installs it. If an install fails partway through, your system stays as it was.

Some things worth knowing up front:

- Builds run in a Bubblewrap sandbox as a regular user. No network, no access to your home directory.
- Downloads are checked against exact SHA-256 or SHA-512 checksums over HTTPS.
- Installs are transactional. A failed merge rolls back cleanly.
- Package repositories are GPG signed. Unsigned ones are rejected by default.
- Packages support per-package USE flags if you want that level of control.

## Requirements

- Linux with Ruby 3.2 through 4.0
- Bubblewrap (`bwrap`) for sandboxed builds
- `gpg` and `gpgv` for signed repositories
- GNU `cp`, `tar`, `unzip`, and `patch`, plus whatever toolchain a package needs

## Installing

For a guided Linux installation from a checkout, run:

```sh
git clone https://github.com/RobertFlexx/Quarks.git
cd Quarks
ruby install.rb
```

The installer offers three profiles: a rootless personal install, a managed
installation owned by a dedicated `quarks` Linux account, and a staged
distribution/LFS package tree. It uses only the Ruby standard library and can
also run unattended:

```sh
# Personal installation
ruby install.rb --mode personal --yes

# Dedicated account plus a system-wide launcher
ruby install.rb --mode managed --user quarks --yes

# Distribution package staging (dependencies remain distro-managed)
ruby install.rb --mode distribution --destdir "$PWD/pkg" --yes
```

Use `ruby install.rb --help` for custom prefixes, dependency handling, color,
and dry-run options.

Re-running the same install command performs a clean staged replacement and
keeps atomic rollback backups. Run the same command with `--uninstall` to fully
remove Quarks, package data, state, configuration, PATH snippets, and installer
backups. Use `--remove-program-only` when package data must be preserved.

Repository-installed copies can check their tracked HTTPS upstream during an
ordinary `quarks sync` without slowing down other commands. Use
`quarks self-update --check` to force a check or `quarks self-update` to verify,
confirm, and transactionally install an available update. Self-update is
enabled only when the installed commit has a valid Git signature; every update
must match the pinned signing fingerprint recorded at installation.

RubyGems remains the shortest installation method:

```sh
gem install quarks-package-manager
quarks version
```

Or run it straight from a checkout:

```sh
git clone https://github.com/RobertFlexx/Quarks.git
cd Quarks
bundle install
./quarks version
```

Everything lives under `~/.local/quarks` by default, with state in `~/.local/state/quarks`. Builds never run as root. If you point Quarks at a system-wide install root, only the final copy step uses `sudo`.

## First steps

```sh
quarks setup-path        # put quarks-installed apps on your PATH
quarks search hello      # find packages
quarks info hello        # see details
quarks install hello     # build and install
```

Builds ask before doing anything. Add `--yes` to skip the prompt. Other commands you will probably want at some point:

```sh
quarks upgrade               # update everything in your world file
quarks remove hello
quarks world                 # what you have explicitly installed
quarks owner usr/bin/hello   # which package owns a file
quarks doctor                # check that your setup is healthy
```

Run `quarks help` for the full list.

## Configuration

Quarks reads `/etc/quarks/quarks.conf`, then `~/.config/quarks/quarks.conf`, then the `QUARKS_CONFIG` environment variable. Later files win. Unknown keys are errors, not warnings.

A small example:

```conf
jobs = 12
sandbox = true
use = "ssl unicode -static-libs"
```

Most settings can also come from environment variables:

| Variable | Purpose |
|---|---|
| `QUARKS_ROOT` | Installation root |
| `QUARKS_JOBS` | Build parallelism |
| `QUARKS_SIZE_PROBE_MS` | Download-size lookup budget in milliseconds; `0` disables probing |
| `QUARKS_USE` | Global USE flags |
| `QUARKS_TMPDIR` | Where builds happen |
| `QUARKS_NO_SANDBOX=1` | Disable Bubblewrap (unsafe) |

Run `quarks env` to print shell exports for everything Quarks installs. `quarks setup-path` adds them to your shell config for you.

## USE flags

Global flags live in `~/.config/quarks/use.conf`, and per-package rules go in `package.use` next to it. Prefix a flag with `-` to turn it off.

```sh
quarks use set ssl unicode -gtk
quarks use package app-editors/vim gui -python
quarks use explain app-editors/vim    # show where each flag came from
```

## Writing your own recipes

Packages are described by `.nuclei` files. These are data files with Ruby-like syntax, and nothing in them gets executed while loading. Sources must be HTTPS with an exact checksum.

```ruby
nuclei "hello", "2.12.1" do
  description "GNU Hello"
  homepage "https://www.gnu.org/software/hello/"
  license "GPL-3.0-or-later"
  category "app-misc"

  depends "sys-libs/ncurses"
  build_depends "sys-devel/make"

  source "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz",
         checksum: "<64 hex characters>",
         algorithm: "sha256",
         size: 1_234_567

  build_system :autotools

  build do
    run "./configure --prefix=%{prefix}"
    run "make -j%{jobs}"
    install "make DESTDIR=%{destdir} install"
  end
end
```

Point `QUARKS_NUCLEI_PATHS` (or `nuclei_paths` in your config) at a directory and your recipes show up alongside the packaged ones.

If you package something new, consider sending it upstream. Recipes are meant to be shared the same way Gentoo handles ebuilds: open a pull request against this repository with your `.nuclei` file, and once it is reviewed and verified it ships to everyone in the next catalog update. Local recipes are fine for quick personal use, but the catalog only grows because people contribute theirs.

## Signed repositories

You can also add remote repositories. They must be GPG signed:

```sh
quarks add-repo main https://packages.example/index.json \
  --gpg-key-id 0123456789ABCDEF0123456789ABCDEF01234567 \
  --gpg-key-url https://packages.example/signing-key.asc
quarks sync
quarks list-repos
```

Repository manifests expire after at most 30 days and carry a sequence number that only ever goes up, so a repository cannot hand you stale or rolled-back metadata.

## Safety basics

- Recipe files are parsed as data. Nothing runs while loading them.
- Build commands stay inside a sandbox with no network and no view of your home directory.
- Downloads cannot be redirected to private-network addresses, and redirects get checked again.
- Root builds are refused, and installs will not overwrite files Quarks does not own unless you pass `--force`.
- If the database looks damaged, Quarks stops and tells you instead of quietly rebuilding it.

## Status

The core workflow works well, but the package catalog is still small. About 115 recipes ship today and more are being verified over time. Expect gaps.

## Contributing

Bug reports and pull requests are welcome. New package recipes are the most useful contribution of all; see "Writing your own recipes" above for the format. To work on Quarks itself:

```sh
git clone https://github.com/RobertFlexx/Quarks.git
cd Quarks
bundle install
./quarks version
```

Test and release tooling is kept outside the public tree. If something here does not make sense, open an issue.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
