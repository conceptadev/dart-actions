# Dart Actions

A collection of reusable GitHub Actions workflows for Dart and Flutter projects. These workflows are designed to streamline CI/CD processes, enforce code quality standards, and automate publishing to pub.dev.

## 📋 Table of Contents

- [Available Workflows](#available-workflows)
  - [CI Workflow](#ci-workflow)
  - [PR Title Check Workflow](#pr-title-check-workflow)
  - [Publish Workflow](#publish-workflow)
- [Quick Start](#quick-start)
- [Detailed Usage](#detailed-usage)

---

## Available Workflows

### CI Workflow

**File:** `.github/workflows/ci.yml`

A comprehensive continuous integration workflow for Dart/Flutter projects using Melos for monorepo management.

#### Features

- ✅ Multi-package testing with Melos
- 🔍 Static code analysis with Dart Analyzer
- 🎯 Optional DCM (Dart Code Metrics) integration
- 🚀 Customizable Melos commands
- ⚡ Concurrent execution with auto-cancellation
- 📦 FVM (Flutter Version Management) support

#### Usage

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

jobs:
  ci:
    uses: conceptadev/dart-actions/.github/workflows/ci.yml@main
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
    with:
      flutter-version: "stable"
      run-dcm: true
      melos-commands: |
        melos run format:check
        melos run build_runner
```

#### Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `flutter-version` | Flutter version to use (e.g., "stable", "3.19.0") | No | `"stable"` |
| `run-dcm` | Whether to run DCM analysis | No | `true` |
| `melos-commands` | Custom Melos commands to run (one per line) | No | `""` |

#### Secrets

| Secret | Description | Required |
|--------|-------------|----------|
| `token` | GitHub token for authentication (used for DCM) | Yes |

#### What It Does

1. **Checkout** - Clones your repository
2. **Setup Flutter** - Installs specified Flutter version using FVM
3. **Setup Melos** - Installs and configures Melos
4. **Bootstrap** - Runs `melos bootstrap` to install dependencies
5. **Custom Commands** - Executes any custom Melos commands you specify
6. **Analysis** - Runs Dart analyzer on all packages
7. **DCM** - Runs Dart Code Metrics (if enabled)
8. **Testing** - Runs all Flutter and Dart tests

---

### PR Title Check Workflow

**File:** `.github/workflows/pr-title-check.yml`

Validates pull request titles against [Conventional Commits](https://www.conventionalcommits.org/) specification.

#### Features

- 📝 Enforces Conventional Commits format
- 💬 Automatic PR comments with helpful error messages
- 🔄 Auto-removes comments when title is fixed
- 🎨 Customizable messages

#### Usage

```yaml
name: PR Title Check

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

jobs:
  pr-title-check:
    uses: conceptadev/dart-actions/.github/workflows/pr-title-check.yml@main
```

#### Advanced Usage

```yaml
jobs:
  pr-title-check:
    uses: conceptadev/dart-actions/.github/workflows/pr-title-check.yml@main
    with:
      comment_header: "custom-pr-title-lint"
      comment_message: |
        ⚠️ Your PR title doesn't follow our guidelines!
        
        Please use: `type(scope): description`
        
        Examples:
        - feat(auth): add login functionality
        - fix(ui): resolve button alignment issue
        - docs: update README
```

#### Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `comment_header` | Header used for the sticky PR comment | No | `"pr-title-lint-error"` |
| `comment_message` | Custom message shown when PR title is invalid | No | Default error message |

#### Valid PR Title Examples

```
feat: add new feature
fix: resolve critical bug
docs: update documentation
style: format code
refactor: restructure component
test: add missing tests
chore: update dependencies
feat(auth)!: breaking change in authentication
```

---

### Publish Workflow

**File:** `.github/workflows/publish.yml`

Automates publishing of Dart/Flutter packages to pub.dev using OIDC authentication.

#### Features

- 🚀 Automated publishing to pub.dev
- 🔐 Secure OIDC authentication (no API tokens needed)
- 📦 Multi-package support with parallel execution
- ✅ Pre-publish validation (analyze, test, dry-run)
- 🎯 Fail-safe mode (continues on individual package failures)

#### Usage

```yaml
name: Publish Packages

on:
  release:
    types: [published]

jobs:
  publish:
    uses: conceptadev/dart-actions/.github/workflows/publish.yml@main
    with:
      packages_folder_path: "packages"
      packages: |
        my_package
        another_package
        third_package
```

#### Inputs

| Input | Description | Required | Example |
|-------|-------------|----------|---------|
| `packages_folder_path` | Path to the folder containing packages | Yes | `"packages"` |
| `packages` | List of package names to publish (one per line) | Yes | See example above |
| `flutter_version_file` | Repository-relative path to an exact Flutter version in `.fvmrc`, `.fvm/fvm_config.json`, or `pubspec.yaml` | No | `".fvmrc"` |

Set `flutter_version_file: ".fvmrc"` to publish with the same SDK pinned by
your project. When omitted, the workflow continues to use the latest stable
Flutter release. A `pubspec.yaml` version file must declare an exact Flutter
version, not a range.

#### What It Does

For each package:

1. **Checkout** - Clones the repository
2. **Setup** - Installs Dart and Flutter
3. **Dependencies** - Runs `flutter pub get`
4. **Analysis** - Runs `flutter analyze`
5. **Testing** - Runs `flutter test`
6. **Dry Run** - Tests publishing with `dart pub publish --dry-run`
7. **Publish** - Publishes to pub.dev using OIDC authentication

#### Requirements

- Your repository must be set up for [OIDC publishing](https://dart.dev/tools/pub/automated-publishing)
- The workflow requires `id-token: write` permission (already configured)
- A "Production" environment should be configured in your repository settings

---

## Quick Start

### 1. Add Workflows to Your Repository

Create a `.github/workflows` directory in your repository and add your workflow files:

```yaml
# .github/workflows/ci.yml
name: CI

on:
  pull_request:
  push:
    branches: [main]

jobs:
  ci:
    uses: conceptadev/dart-actions/.github/workflows/ci.yml@main
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
```

```yaml
# .github/workflows/pr-check.yml
name: PR Checks

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

jobs:
  title-check:
    uses: conceptadev/dart-actions/.github/workflows/pr-title-check.yml@main
```

```yaml
# .github/workflows/publish.yml
name: Publish

on:
  workflow_dispatch:
    inputs:
      packages:
        description: 'Package names (comma-separated)'
        required: true

jobs:
  publish:
    uses: conceptadev/dart-actions/.github/workflows/publish.yml@main
    with:
      packages_folder_path: "packages"
      packages: ${{ inputs.packages }}
```

### 2. Required Permissions

Ensure your workflows have the necessary permissions:

```yaml
permissions:
  contents: read        # For checkout
  pull-requests: write  # For PR comments
  id-token: write      # For OIDC publishing
```

### 3. Repository Setup

For publishing to pub.dev:
1. Enable OIDC publishing in your pub.dev account
2. Configure a "Production" environment in your repository settings
3. Ensure your packages have proper version numbers and changelogs

---

## Detailed Usage

### CI Workflow Examples

#### Basic Monorepo Setup

```yaml
jobs:
  ci:
    uses: conceptadev/dart-actions/.github/workflows/ci.yml@main
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
```

#### With Custom Flutter Version

```yaml
jobs:
  ci:
    uses: conceptadev/dart-actions/.github/workflows/ci.yml@main
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
    with:
      flutter-version: "3.19.0"
```

#### With Build Runner and Code Generation

```yaml
jobs:
  ci:
    uses: conceptadev/dart-actions/.github/workflows/ci.yml@main
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
    with:
      melos-commands: |
        melos run build_runner
        melos run format:check
```

#### Without DCM

```yaml
jobs:
  ci:
    uses: conceptadev/dart-actions/.github/workflows/ci.yml@main
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
    with:
      run-dcm: false
```

### Publish Workflow Examples

#### Manual Publishing via Workflow Dispatch

```yaml
name: Publish Packages

on:
  workflow_dispatch:
    inputs:
      packages:
        description: 'Package names to publish'
        required: true
        type: string

jobs:
  publish:
    uses: conceptadev/dart-actions/.github/workflows/publish.yml@main
    with:
      packages_folder_path: "packages"
      packages: ${{ inputs.packages }}
```

#### Automatic Publishing on Release

```yaml
name: Publish on Release

on:
  release:
    types: [published]

jobs:
  publish:
    uses: conceptadev/dart-actions/.github/workflows/publish.yml@main
    with:
      packages_folder_path: "packages"
      packages: |
        core_package
        utils_package
        ui_package
```

---

## Additional Resources

- [Coverage Comment Action](docs/COVERAGE_ACTION.md) - Automated code coverage analysis and PR comments
- [Conventional Commits](https://www.conventionalcommits.org/) - Commit message specification
- [Melos](https://melos.invertase.dev/) - Tool for managing Dart/Flutter monorepos
- [OIDC Publishing](https://dart.dev/tools/pub/automated-publishing) - Secure package publishing

---

## Contributing

When contributing to these workflows:

1. Ensure PR titles follow Conventional Commits
2. Test workflow changes thoroughly
3. Update documentation for any new features
4. Maintain backward compatibility when possible

---

## License

See [LICENSE](LICENSE) file for details.
