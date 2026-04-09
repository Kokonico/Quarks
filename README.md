# Quarks Package Manager

> A continuation of [Photon](https://github.com/RobertFlexx/Photon) by [@RobertFlexx](https://github.com/RobertFlexx), which was discontinued due to a series of unfortunate events. Quarks will continue what Photon never got the chance to finish.

A production ready, Portage inspired source based package manager written in Ruby, designed for a Linux distribution(s).

> By yours truly, hehe

## Features

### Core Package Management
- **Source-based builds**: Compile packages from source with support for multiple build systems
- **Dependency resolution**: Recursive dependency resolution with circular dependency detection
- **Multiple build systems**: Autotools, CMake, Meson, Make, Ninja, and manual builds
- **World file**: Track user-requested packages for system upgrades
- **SLOT support**: Multiple versions of the same package can coexist
- **Blockers**: Package conflict detection and resolution

### Portage-Inspired Features
- **USE flags**: Flexible package configuration system
- **Package USE**: Per-package USE flag configuration
- **World set**: User-selected packages for system management
- **Depclean**: Remove orphaned packages
- **Preserved rebuild**: Rebuild packages affected by library updates
- **Check-world**: Verify world file integrity

### Quarks-Exclusive Features

#### Quantum States
Packages can be in different quantum states beyond just installed/uninstalled:
- **Frozen**: Package is installed but locked from updates
- **Volatile**: Package may need rebuilding or attention
- **Blocked**: Package is blocked by another
- **Broken**: Package has broken dependencies

#### Flux Control
Power management system for build behavior:
- `minimal` - Minimal resources, no verification
- `standard` - Balanced (default)
- `performance` - Higher parallelism, run tests
- `maximum` - Maximum power, full optimization

#### Beam Commands
Quick analysis tools for introspection:
- `beam deps` - Show dependencies
- `beam revdeps` - Show reverse dependencies
- `beam tree` - Draw dependency tree
- `beam graph` - Generate graphviz output
- `beam size` - Show package size
- `beam audit` - Audit installed packages
- `beam verify` - Verify package files

#### Sparks
Lightweight Ruby automation scripts stored in `~/.config/quarks/sparks/`.

#### Profiles
Preset configurations for different use cases (desktop, server, minimal).

#### Wavelength Sync
Configure repository sync behavior:
- `full` - Complete sync
- `incremental` - Smart sync using ETags (default)
- `shallow` - Only changed packages
- `mirror` - Download everything, no verification

### Repository Support
- **Local repositories**: Use nuclei recipe files from local directories
- **Web repositories**: Fetch package metadata from remote JSON manifests
- **GPG verification**: Signature verification for web repositories
- **Incremental sync**: ETag/Last-Modified based caching for efficient updates
- **Offline mode**: Graceful fallback to cached data when offline

### System Integration
- **ldconfig integration**: Automatic library cache updates
- **Desktop files**: Desktop database registration for .desktop files
- **Man pages**: Categorized man page installation
- **Info pages**: GNU info database support
- **Alternatives**: File alternative management (like update-alternatives)
- **MIME types**: Automatic MIME database updates
- **GTK icons**: Icon cache updates

### Security
- **Checksum verification**: SHA256, SHA512, SHA1, MD5 support
- **Path validation**: Symlink and directory traversal protection
- **File collisions**: Detection and prevention of file ownership conflicts
- **GPG signatures**: Repository and package signature verification
- **Secure shell escaping**: Proper command-line argument escaping
- **Config protection**: Protected system configuration files

### Build Features
- **Parallel builds**: Multi-threaded build support
- **Build caching**: Source tarball caching
- **Build logging**: Detailed build logs with timestamps
- **Resume support**: Continue interrupted builds (SIGINT safe)
- **Build state persistence**: Save state on interrupt, resume later
- **Sandbox support**: Optional build sandboxing
- **Patches**: Built-in patch application with strip level support

### Signal Handling
- **Graceful shutdown**: Handle SIGINT, SIGTERM, SIGQUIT
- **State saving**: Automatically save build state on interrupt
- **Resume capability**: `--resume` flag to continue interrupted builds

## Installation

### Requirements
- Ruby >= 3.0
- SQLite3
- Standard build tools (gcc, make, tar)
- OpenSSL (for checksum verification)

### Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/quarks.git
cd quarks

# Install a package
./quarks install hello

# Search for packages
./quarks search nginx

# Update repositories
./quarks sync

# Upgrade installed packages
./quarks upgrade
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QUARKS_ROOT` | `~/.local/quarks` | Installation root |
| `QUARKS_STATE_ROOT` | `~/.local/state/quarks` | State/cache/log root |
| `QUARKS_TMPDIR` | `$STATE_ROOT/var/tmp/quarks` | Build temp directory |
| `QUARKS_JOBS` | CPU count | Parallel build jobs |
| `QUARKS_NUCLEI_PATHS` | - | Additional local repo paths |
| `QUARKS_REPO_URLS` | - | Remote repo manifest URLs |
| `QUARKS_VERIFY_REPOS` | 0 | Verify repository signatures |
| `QUARKS_ALLOW_INSECURE` | 0 | Allow checksum: skip |
| `QUARKS_DEBUG` | 0 | Enable debug output |

### Configuration File

Create `~/.config/quarks/quarks.conf` or `/etc/quarks/quarks.conf`:

```conf
# Repository priorities (lower = higher priority)
repo_priority main 100
repo_priority testing 200

# Build options
jobs 4
```

## Usage

### Package Installation

```bash
# Install a package
quarks install hello

# Install with dependencies only (no package)
quarks install --nodeps package

# Fetch sources only
quarks install --fetchonly package

# Pretend mode (dry run)
quarks install --pretend package

# Skip dependency resolution
quarks install --nodeps package
```

### Package Removal

```bash
# Remove a package
quarks remove hello

# Remove without dependencies
quarks remove --nodeps hello
```

### System Upgrade

```bash
# Upgrade all packages in world file
quarks upgrade

# Dry run upgrade
quarks upgrade --pretend
```

### Repository Management

```bash
# Add a web repository
quarks add-repo myrepo https://example.com/repo/index.json

# Add with GPG verification
quarks add-repo myrepo https://example.com/repo/index.json --gpg-key-id ABC123

# List repositories
quarks list-repos

# Remove a repository
quarks remove-repo myrepo

# Sync repositories
quarks sync
```

### Query Commands

```bash
# Search for packages
quarks search nginx

# List installed packages
quarks list

# Show package info
quarks info nginx

# Show package files
quarks files nginx

# Find package providing command
quarks which nginx

# Find package owning file
quarks owner /usr/bin/nginx
```

### USE Flag Management

```bash
# Show current USE flags
quarks use

# Set global USE flags
quarks use set X11 video

# Remove global USE flags
quarks use del X11

# Set package-specific USE flags
quarks use package app-vim/syntax on gui
```

### World Set Management

```bash
# Show world file contents
quarks world

# Check world file integrity
quarks check-world

# Remove orphaned packages
quarks depclean

# Rebuild packages for preserved libraries
quarks preserved-rebuild
```

### Quarks-Exclusive Commands

```bash
# System status overview
quarks status

# Set power level
quarks flux minimal
quarks flux performance
quarks flux maximum

# Freeze a package (prevent updates)
quarks freeze nginx

# Unfreeze a package
quarks thaw nginx

# Beam analysis commands
quarks beam deps nginx
quarks beam revdeps openssl
quarks beam tree gcc
quarks beam size vim
quarks beam audit

# Wavelength sync modes
quarks wavelength full
quarks wavelength shallow

# Profile management
quarks profile
quarks profile create desktop
quarks profile activate desktop

# Spark scripts
quarks spark list
quarks spark create mybuild
quarks spark run mybuild
```

### System Maintenance

```bash
# Clean cache
quarks clean

# Compact database
quarks compact-db

# System health check
quarks doctor
```

## Package Recipes (Nuclei Format)

Packages are defined using the Nuclei DSL:

```ruby
nuclei "hello", "2.12.1" do
  description "GNU Hello World"
  homepage "https://www.gnu.org/software/hello/"
  license "GPL-3.0"
  category "app-misc"

  depends "sys-libs/ncurses"
  build_depends "gcc", "make"

  source "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz",
         sha256: "abc123..."

  configure "--prefix=/usr"
  build_system :autotools

  slot "0"
  blocks "app-misc/hello-old"

  iuse "X", "gtk"
  use_dep "gtk", "x11-libs/gtk+:3"

  patch "fix-warning.patch", strip: 1

  env "CFLAGS", "-O2"

  build do
    configure
    make
  end

  install do
    make "install"
  end
end
```

### Advanced Package Features

#### SLOT Support
```ruby
slot "1"           # Primary slot
subslot "1.2"      # Sub-slot for ABI compatibility
```

#### Package Blockers
```ruby
blocks "app-misc/old-package"     # This package blocks another
blocked_by "app-misc/other"      # This package is blocked by another
```

#### USE Dependencies
```ruby
iuse "X", "ssl", "gtk"

use_dep "gtk", "x11-libs/gtk+:3"           # When gtk USE is enabled
use_dep "ssl", "dev-libs/openssl", condition: :enabled
```

### Supported Build Systems

- `:autotools` - GNU Autotools (configure/make)
- `:cmake` - CMake build system
- `:meson` - Meson build system
- `:make` - Plain Makefile
- `:ninja` - Ninja build system
- `:manual` - Custom commands only
- `:auto` - Auto-detect based on files

## Web Repository Format

Web repositories use JSON manifests:

```json
{
  "repo_name": "quarks-main",
  "generated_at": "2024-01-01T00:00:00Z",
  "package_count": 100,
  "packages": [
    {
      "name": "hello",
      "version": "2.12.1",
      "description": "GNU Hello World",
      "category": "app-misc",
      "license": "GPL-3.0",
      "dependencies": ["sys-libs/ncurses"],
      "build_dependencies": ["gcc", "make"],
      "sources": [
        {
          "url": "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz",
          "hash": "abc123...",
          "algorithm": "sha256"
        }
      ],
      "build_system": "autotools"
    }
  ]
}
```

### Repository Signing

Sign your repository manifest:

```bash
# Create a GPG key
gpg --gen-key

# Sign the manifest
gpg --sign --armor -o index.json.sig index.json

# Distribute both files
```

## Systemd Service Generation

Packages can include systemd service files:

```ruby
nuclei "myservice", "1.0.0" do
  description "My awesome service"

  systemd_service do
    exec_start "/usr/bin/myservice"
    restart "on-failure"
    user "myservice"
    group "myservice"
  end
end
```

## Development

### Running Tests

```bash
# Install test dependencies
gem install minitest

# Run tests
ruby -Ilib -Ispec spec/quarks_test.rb
```

### Adding a New Package

1. Create a nuclei file in `nuclei/<category>/<name>.nuclei`
2. Define the package using the Nuclei DSL
3. Test locally with `quarks install --fetchonly <name>`
4. Submit for inclusion in the distribution

## Architecture

```
quarks/
├── src/
│   └── quarks/
│       ├── builder.rb          # Build system execution
│       ├── database.rb         # SQLite package database
│       ├── installer.rb        # File installation
│       ├── package.rb          # Nuclei DSL parser
│       ├── repository.rb       # Repository management
│       ├── resolver.rb         # Dependency resolution
│       ├── system_integration.rb # System integration
│       ├── web_repo.rb         # Web repository support
│       ├── parallel_build.rb   # Parallel build support
│       ├── conflict_resolver.rb # Conflict detection
│       └── systemd_manager.rb  # Systemd service generation
├── nuclei/                     # Package recipes
├── docs/                       # Web repo documentation
└── tools/                      # Development tools
```

## License

BSD 3-Clause License
