# AWS Scripts

AWS CLI helper scripts for common operations.

## assume-role.sh

Production-ready role assumption with MFA support and session caching.

### Features

- **MFA Support**: Prompts for TOTP code, auto-detects MFA device
- **Session Caching**: Avoids re-authentication within session duration
- **Cross-Account**: Supports external-id for cross-account roles
- **Profile-Aware**: Works with AWS CLI named profiles
- **Eval-Friendly**: Output designed for `eval` or `source`

### Usage

```bash
# Basic - source to set env vars in current shell
source assume-role.sh arn:aws:iam::123456789012:role/AdminRole

# Eval alternative
eval "$(./assume-role.sh arn:aws:iam::123456789012:role/AdminRole)"

# With MFA (will prompt for code)
source assume-role.sh arn:aws:iam::123456789012:role/AdminRole \
  --mfa-serial arn:aws:iam::123456789012:mfa/myuser

# Cross-account with external-id
source assume-role.sh arn:aws:iam::987654321098:role/CrossAccountRole \
  --external-id MyExternalId123

# Extended session (up to 12 hours)
source assume-role.sh arn:aws:iam::123456789012:role/AdminRole \
  --duration 43200

# With specific profile and region
source assume-role.sh arn:aws:iam::123456789012:role/AdminRole \
  --profile production \
  --region us-west-2
```

### Options

| Option | Description |
|--------|-------------|
| `-m, --mfa-serial` | MFA device ARN (auto-detected if not specified) |
| `-e, --external-id` | External ID for cross-account trust |
| `-d, --duration` | Session duration in seconds (default: 3600) |
| `-s, --session-name` | Session name identifier |
| `-p, --profile` | AWS CLI profile for source credentials |
| `-r, --region` | AWS region |
| `-c, --no-cache` | Disable session caching |
| `-v, --verbose` | Verbose output |

### Session Caching

Credentials are cached in `~/.aws/cli/cache/` and reused if more than 5 minutes remain before expiration. Use `--no-cache` to force fresh credentials.

### Requirements

- AWS CLI v2
- jq
- Valid AWS credentials (profile or environment)

### Environment Variables Set

After sourcing, these variables are exported:

```bash
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
AWS_CREDENTIAL_EXPIRATION
```

`AWS_PROFILE` is unset to prevent conflicts with temporary credentials.
