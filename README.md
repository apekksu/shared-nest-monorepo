# shared-nest-monorepo

Shared CI/CD workflow for NestJS **monorepos** with multi-secret support.

> For single-app repos, use [shared-nest-ci-cd](https://github.com/apekksu/shared-nest-ci-cd) instead.

## Usage

In your monorepo's `.github/workflows/deploy.yml`:

```yaml
name: Deploy NestJS Monorepo

on:
  push:
    branches:
      - main

jobs:
  deploy:
    uses: apekksu/shared-nest-monorepo/.github/workflows/ci.yml@main
    with:
      s3-bucket-name: your-s3-bucket
      application-name: ${{ github.event.repository.name }}
      application-port: 3000
      aws-region: us-west-2
      secrets: |
        [
          {"secret": "shared-secret", "path": "."},
          {"secret": "shared-secret", "path": "apps/api"},
          {"secret": "intel-secret", "path": "apps/intel"}
        ]
      ec2-app-tag: your-ec2-tag
    secrets:
      aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
      aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

## Secrets Format

The `secrets` input is a JSON array of objects:

| Field | Description |
|-------|-------------|
| `secret` | AWS Secrets Manager secret name |
| `path` | Where to create `.env` file (use `.` for root) |

### Examples

```json
// Root only
[{"secret": "my-secret", "path": "."}]

// Multiple apps, same secret
[
  {"secret": "shared", "path": "apps/api"},
  {"secret": "shared", "path": "apps/web"}
]

// Different secrets per app
[
  {"secret": "api-secret", "path": "apps/api"},
  {"secret": "cms-secret", "path": "apps/cms"}
]
```

## How it works

1. Fetches each secret from AWS Secrets Manager
2. Creates `.env` file at each specified path **before build**
3. `.env` files are bundled into the artifact
4. Deploys to EC2 via SSM with PM2
