# Kubernetes Scripts

Kubectl wrappers and automation utilities for Kubernetes cluster management.

## Scripts

### cluster-cleanup.sh

Comprehensive cleanup utility for removing stale resources from Kubernetes clusters.

**Features:**
- 🧹 Evicted pods cleanup (disk pressure, memory pressure, etc.)
- ❌ Failed pods removal (OOMKilled, Error states)
- ✅ Completed/Succeeded pods pruning
- 📦 Orphaned completed Jobs deletion
- 🔒 Stuck terminating namespace resolution (finalizer removal)

**Usage:**

```bash
# Dry-run to see what would be deleted
./cluster-cleanup.sh --dry-run all

# Clean evicted pods only
./cluster-cleanup.sh evicted

# Clean failed pods in specific namespace
./cluster-cleanup.sh -n production failed

# Full cleanup with verbose output
./cluster-cleanup.sh -v all

# Multiple targeted actions
./cluster-cleanup.sh evicted failed jobs
```

**Options:**

| Flag | Description |
|------|-------------|
| `-n, --namespace` | Target specific namespace (default: all) |
| `-d, --dry-run` | Show what would be deleted |
| `-v, --verbose` | Verbose output |
| `-h, --help` | Show help |

**Actions:**

| Action | Description |
|--------|-------------|
| `evicted` | Pods evicted by kubelet (resource pressure) |
| `failed` | Pods in Failed phase (Error, OOMKilled) |
| `completed` | Pods in Succeeded phase |
| `jobs` | Completed Jobs without ownerReferences |
| `stuck-ns` | Namespaces stuck in Terminating |
| `all` | Run all cleanup actions |

**Safety:**
- Requires confirmation before making changes (bypass with `--dry-run`)
- Jobs with ownerReferences are preserved (managed by CronJob, etc.)
- Stuck namespace cleanup shows warning about finalizer removal

**Requirements:**
- `kubectl` configured with cluster access
- `jq` for Jobs cleanup action

## Best Practices

1. **Always dry-run first** - Preview changes before applying
2. **Use namespace scoping** - Target specific namespaces in production
3. **Schedule regular cleanups** - Evicted pods accumulate and waste etcd storage
4. **Investigate stuck namespaces** - Understand why they're stuck before forcing deletion
