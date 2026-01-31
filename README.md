# DevOps Scripts

![Bash](https://img.shields.io/badge/Bash-5.0+-4EAA25?style=flat&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.11+-3776AB?style=flat&logo=python&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue)

Collection of battle-tested automation scripts for DevOps workflows.

## Categories

```
├── bash/           # Shell scripts
├── python/         # Python automation
├── aws/            # AWS CLI helpers
├── kubernetes/     # kubectl wrappers
├── docker/         # Docker utilities
└── git/            # Git automation
```

## Highlights

- 🔧 `aws/assume-role.sh` - Easy role assumption with MFA
- 🐳 `docker/cleanup.sh` - Prune unused images/volumes
- ☸️ `kubernetes/pod-logs.sh` - Aggregate logs from multiple pods
- 🔄 `git/sync-forks.sh` - Keep forks up to date

## Installation

```bash
git clone https://github.com/ghndrx/devops-scripts.git
export PATH="$PATH:$(pwd)/devops-scripts/bash"
```

## License

MIT
