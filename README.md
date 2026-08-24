# Quarks

Quarks is a source-based package manager for Linux. It is for people who want to build packages from reviewed recipes, choose build options, and install them under their own user account. It can also stage packages for a managed system or a Linux distribution.

Quarks is not a replacement for a full distribution package manager yet. The catalog is small, and packages still need the compilers and other build tools they use. Expect gaps.

## How it works

A package is described by a `.nuclei` recipe. Quarks resolves its dependencies, downloads the listed source archives, checks their SHA-256 or SHA-512 checksums, and builds them in a Bubblewrap sandbox. Builds run as a regular user, without access to your home directory or the network by default.

The finished files are merged into the install root as one transaction. If the merge fails, Quarks rolls it back. A system-wide install may use `sudo` for the final copy, but the build itself does not run as root.

Remote package repositories are GPG signed and are rejected by default if the signature is missing or invalid. Source downloads use HTTPS and exact checksums. Unsafe overrides exist for unusual environments, but they are not the default.

## Requirements

- Linux
- Ruby 3.2 through 4.0
- Bubblewrap (`bwrap`)
- `gpg` and `gpgv`
- GNU `cp`, `tar`, `unzip`, and `patch`
- The compiler and build tools required by each package

## Install Quarks

For the guided installer, clone the repository and run `install.rb`:

```sh
git clone https://github.com/RobertFlexx/Quarks.git
cd Quarks
ruby install.rb
```

The installer has three modes:

- `personal` installs a rootless copy for one user.
- `managed` creates or uses a dedicated `quarks` Linux account and adds a system-wide launcher.
- `distribution` stages a package tree for a distribution or LFS build. Its dependencies remain managed by the distribution.

The installer uses only the Ruby standard library. It can run unattended:

```sh
ruby install.rb --mode personal --yes
ruby install.rb --mode managed --user quarks --yes
ruby install.rb --mode distribution --destdir "$PWD/pkg" --yes
```

Run `ruby install.rb --help` for prefix, dependency, color, and dry-run options.

Running the same install command again creates a clean staged replacement and keeps atomic rollback backups. Add `--uninstall` to remove Quarks, its package data, state, configuration, PATH snippets, and installer backups. Add `--remove-program-only` if you need to keep package data.

You can also install the gem:

```sh
gem install quarks-package-manager
quarks version
```

Or run Quarks from a checkout:

```sh
git clone https://github.com/RobertFlexx/Quarks.git
cd Quarks
bundle install
./quarks version
```

The default install root is `~/.local/quarks`. State is stored in `~/.local/state/quarks`.

## Updates and trust

A copy installed from the repository can check its tracked HTTPS upstream during `quarks sync`. Other commands do not wait for this check.

```sh
quarks self-update --check   # check now
quarks self-update           # verify, confirm, and install an update
```

Self-update is enabled only if the installed commit has a valid Git signature. The installer records that signature's fingerprint. Every later update must match the pinned fingerprint, and installation is transactional.

## First commands

```sh
quarks setup-path        # add Quarks-installed commands to PATH
quarks search hello      # search the catalog
quarks info hello        # inspect a package
quarks install hello     # build and install it
```

Quarks shows the planned build and asks before starting. Use `--yes` to skip the prompt.

```sh
quarks upgrade               # upgrade packages in the world file
quarks remove hello
quarks world                 # list explicitly installed packages
quarks owner usr/bin/hello   # find the package that owns a file
quarks doctor                # check the local setup
```

Run `quarks help` for all commands.

## Configuration

Quarks looks for configuration in `/etc/quarks/quarks.conf`, `~/.quarks.conf`, and the user config path (`$XDG_CONFIG_HOME/quarks/quarks.conf`, normally `~/.config/quarks/quarks.conf`). `QUARKS_CONFIG` can name an additional file. Later files win, but an environment variable that is already set takes precedence. Unknown keys are errors.

```conf
jobs = 12
sandbox = true
use = "ssl unicode -static-libs"
```

Settings can also be supplied as environment variables. These are common examples:

| Variable | Meaning |
| --- | --- |
| `QUARKS_ROOT` | Package install root |
| `QUARKS_STATE_ROOT` | Database, cache, log, and operation state root |
| `QUARKS_TMPDIR` | Build workspace |
| `QUARKS_JOBS` | Number of parallel build jobs |
| `QUARKS_SIZE_PROBE_MS` | Download-size lookup budget in milliseconds; `0` disables it |
| `QUARKS_USE` | Global USE flags |
| `QUARKS_NUCLEI_PATHS` | Additional local recipe directories, separated by `:` |
| `QUARKS_REPO_URLS` | Additional remote repository manifests |
| `QUARKS_NO_SANDBOX=1` | Disable Bubblewrap isolation; unsafe |

Run `quarks environment` for the full formatted variable reference. It groups variables by purpose, shows defaults or current values, marks unsafe settings, and includes examples.

`quarks env` does something different: it prints shell exports for the paths provided by installed packages. `quarks setup-path` writes the required setup to your shell configuration.

## USE flags

USE flags select optional package features. Global flags are stored in `~/.config/quarks/use.conf`. Per-package rules are stored in `~/.config/quarks/package.use`. Prefix a flag with `-` to disable it.

```sh
quarks use set ssl unicode -gtk
quarks use package app-editors/vim gui -python
quarks use explain app-editors/vim
```

The last command shows where each effective flag came from.

## Package recipes

Recipes use the `.nuclei` format. The syntax looks like Ruby, but Quarks parses recipes as data and does not execute them while loading. Sources must use HTTPS and include an exact checksum by default.

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

Set `QUARKS_NUCLEI_PATHS`, or `nuclei_paths` in `quarks.conf`, to load recipes from another directory. They appear alongside the packaged recipes.

Local recipes are useful for personal packages. To add one to the shared catalog, open a pull request with the `.nuclei` file. Reviewed and verified recipes are included in a later catalog update.

## Remote repositories

Remote repository manifests must be GPG signed by default:

```sh
quarks add-repo main https://packages.example/index.json \
  --gpg-key-id 0123456789ABCDEF0123456789ABCDEF01234567 \
  --gpg-key-url https://packages.example/signing-key.asc
quarks sync
quarks list-repos
```

Manifests expire after no more than 30 days. Their sequence numbers must increase, which prevents a repository from serving older metadata as current.

## Safety limits

- Recipe files are parsed as data before any build command runs.
- Sandboxed builds have no network or home-directory access by default.
- Download redirects are checked again and cannot point to private-network addresses by default.
- Quarks refuses root builds by default.
- Quarks does not overwrite files it does not own unless you pass `--force`.
- Quarks stops if its database appears damaged instead of silently rebuilding it.

## Project status

The install, build, upgrade, remove, and rollback workflow is available. The catalog currently contains about 115 recipes, so it will not cover every package. More recipes are being verified over time.

## Contributing

Bug reports, fixes, and package recipes are welcome. New recipes are especially useful; see [Package recipes](#package-recipes) for the format.

To work on Quarks itself:

```sh
git clone https://github.com/RobertFlexx/Quarks.git
cd Quarks
bundle install
./quarks version
```

Test and release tooling is kept outside the public repository. Open an issue if the public code or documentation is unclear.

## License

Quarks uses the BSD 3-Clause license. See [LICENSE](LICENSE).
