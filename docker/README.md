# Docker Scripts

Utilities for Docker container and image management.

## Scripts

### cleanup.sh

Comprehensive Docker resource cleanup with safety features.

#### Features

- **Multi-resource cleanup**: Containers, images, volumes, networks, build cache
- **Age-based filtering**: Only remove resources older than specified duration
- **Dry-run mode**: Preview what would be removed without deleting
- **Buildx support**: Optionally clear multi-platform builder cache
- **Space reporting**: Shows disk usage before and after cleanup

#### Usage

```bash
# Preview what would be cleaned up
./cleanup.sh --dry-run

# Basic cleanup (stopped containers, dangling images, networks, build cache)
./cleanup.sh --force

# Full cleanup including ALL unused images and volumes
./cleanup.sh --all --volumes --force

# Remove only resources older than 7 days
./cleanup.sh --older-than 7d --force

# Full cleanup with buildx cache
./cleanup.sh -a -v -b -f
```

#### Options

| Option | Description |
|--------|-------------|
| `-a, --all` | Remove ALL unused images, not just dangling |
| `-v, --volumes` | Also prune unused volumes (⚠️ destructive) |
| `-b, --buildx` | Also prune buildx cache |
| `-o, --older-than` | Only remove resources older than duration (e.g., `24h`, `7d`) |
| `-d, --dry-run` | Preview what would be removed |
| `-f, --force` | Skip confirmation prompts |
| `-h, --help` | Show help message |

#### Safety

- Volumes are **not** removed by default (data loss risk)
- Always use `--dry-run` first to preview changes
- Age-based filtering helps preserve recent resources
- Colored output clearly indicates what will be removed

#### Automation

Add to crontab for automatic cleanup:

```bash
# Weekly cleanup of resources older than 7 days
0 3 * * 0 /path/to/cleanup.sh --all --older-than 7d --force >> /var/log/docker-cleanup.log 2>&1
```

## Contributing

Scripts should follow these conventions:
- Use `set -euo pipefail` for safety
- Include `--help` output
- Support `--dry-run` where applicable
- Use colored output for clarity
