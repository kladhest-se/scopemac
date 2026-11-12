# Unified releases

The release entry point is `python3 scripts/release.py`. It coordinates the existing macOS scripts, creates DMG/ZIP distributions and publishes the same prepared bytes to GitLab and GitHub. It never creates remote repositories, deploys the PHP website, moves existing tags, overwrites assets or rolls back another service's successful release. Source branch uploads are a separate, explicitly confirmed command.

## Target and prerequisites

| Target | Status | Build validation | Runtime validation |
| --- | --- | --- | --- |
| macOS 14+, Apple Silicon | Experimental | Native build, app tests, mock USB sanitizer tests, signing, notarization, stapling and Gatekeeper | Manually test the final ZIP with a real DSO2D15 and on a second Mac/account |

Use Python 3.9+, Git, PHP 8+, Xcode/Command Line Tools on an Apple Silicon Mac, a Developer ID Application certificate with its private key, and a configured `notarytool` keychain profile. No `gh`, `glab` or Python packages are required. Both repositories must already exist and contain the source commit being released. Use the separate `source` command to synchronize committed branches when needed.

The single version source is `Sources/Version.swift`. `package.sh` reads its marketing version and build number, and the coordinator derives `<version>` (default tag `0.1`). Releases remain prereleases while the target is experimental.

## Local configuration

Configuration lookup order is:

1. Explicit `--config /path/to/settings.json`.
2. `SCOPEMAC_RELEASE_CONFIG` from the process environment.
3. `~/Development/tools/git-release/projects/scopemac.json`, when present.
4. Ignored `work/release-config.json`, when present.
5. Built-in defaults, sufficient for an unconfigured plan.

Store real machine settings in the shared project profile. `examples/release-config.json` documents the schema with placeholders; it contains no credentials. Copy it to either configuration location, replace paths and repository URLs, and keep it outside source control. An explicitly selected missing file fails instead of silently falling back.

The default GitHub project is `https://github.com/kladhest-se/scopemac`. GitLab has no default project. A configured repository requires both its HTTPS web URL and its matching Git transport URL. Nested GitLab groups are supported. Web URLs cannot contain credentials, query strings, fragments, ports or traversal. Git transport is restricted to the exact matching SSH or credential-free HTTPS repository.

Configuration accepts `github`, `github_git`, `gitlab`, `gitlab_git`, `notary_profile`, `env`, `credentials`, and `source_branch`. The only allowed `env` keys are `SCOPEMAC_SIGN_IDENTITY`, `SCOPEMAC_RELEASE_PYTHON` and `PHP`. The dedicated Python path must be absolute; it is used by the offline tests and native packaging/notarization helpers. If omitted, the coordinator uses its current interpreter for tests and native scripts retain their standalone `python3` fallback. Signing identity and notarization profile names are non-secret configuration. Private keys remain in Keychain. Unified builds use the tracked bundled dependency; `SCOPEMAC_DEPENDENCIES` overrides are refused.

`SCOPEMAC_SIGN_IDENTITY` and `SCOPEMAC_NOTARY_PROFILE` can also be supplied through the process environment. `notary_profile` in configuration overrides the environment profile. Run the existing interactive `xcrun notarytool store-credentials ScopeMac-notary` command separately if the profile does not exist.

## API credentials

Token providers are configured per service. The default is the `GITHUB_TOKEN` or `GITLAB_TOKEN` environment variable; a descriptor can select another variable:

```json
{"credentials": {"github": {"provider": "env", "variable": "GITHUB_TOKEN"}}}
```

Shared machine profiles can use 1Password CLI without copying secrets into the environment or a file:

```json
{
  "credentials": {
    "github": {"provider": "1password", "vault": "Private", "item": "github.com", "field": "your-org/scopemac-rw"},
    "gitlab": {"provider": "1password", "reference": "op://Private/your-gitlab-item/your-token-field"}
  }
}
```

For 1Password, configure either a copied `op://` reference or `vault`, `item`, `field`; `account` is optional. A selected provider is authoritative: it does not silently fall back to another credential source. `op` lookup runs only during explicitly confirmed publication. Planning, building, checking, preparing and source pushing do not read API tokens. Failed/cancelled lookups, duplicate fields and unresolved references fail without printing secret output. The tool never creates or refreshes tokens or changes 1Password items.

GitHub needs Contents write permission. GitLab needs API access and at least Developer project/group access with its package registry enabled. API credentials do not replace Git SSH keys or the Git credential helper used by source/tag pushes. Configure a separate environment-provider profile for CI if the local shared profile uses 1Password.

For interactive Bash with the default environment provider:

```bash
read -r -s -p 'GitHub token: ' GITHUB_TOKEN; printf '\n'
export GITHUB_TOKEN
read -r -s -p 'GitLab token: ' GITLAB_TOKEN; printf '\n'
export GITLAB_TOKEN
```

Keep literal tokens out of commands, notes, JSON configuration, logs and source. Do not enable shell tracing. Repository tokens, including custom configured environment variables, are removed from build subprocess environments. Token values and credential descriptors are not written to manifests/provenance or packaged from local settings.

## Source branch workflow

Source synchronization never compiles, signs, tags or uploads release assets:

```sh
python3 scripts/release.py source --to gitlab,github --dry-run
python3 scripts/release.py source --to gitlab,github --confirm-push
```

The checkout must be clean and committed. All selected destinations pass `git push --dry-run` before the first actual push. Only the current branch is pushed to `source_branch` (or its own name if unset), with `--no-follow-tags`, no force and no mirror. Each pushed branch is read back and checked against the local commit. Independent services can still fail partway through synchronization; inspect remote branches before retrying. Review all committed source/history before a first public push.

For an extracted source directory with no commit, initialization is opt-in:

```sh
python3 scripts/release.py source --init --confirm-push --to gitlab,github
```

Every selected remote must already exist and have no refs. Existing remote history is refused; clone it and import source instead. Git identity must be configured. The initial branch is `source_branch` or `main`. The tool stages only the explicit public source inventory, respecting ignore rules; other staged/untracked files block the first commit. `--commit-message` can override the initial commit annotation. No extra commit is made in an existing committed checkout. `--init` cannot be combined with `--dry-run` because initialization changes local metadata. Never pass `--init` simply to bypass a history conflict.

## Build, check and prepare

Finish edits, commit them and synchronize the source commit to the intended repositories before building. Every source input must be tracked for publication, including files that might otherwise be ignored. Extra untracked files also block publication. Generated output, local configuration and Python caches are ignored.

```sh
python3 scripts/release.py plan
python3 scripts/release.py build
python3 scripts/release.py check
python3 scripts/release.py prepare
```

- `plan` only prints the ordered commands and target policy.
- `build` runs the release automation's offline tests, PHP syntax check, and `release.sh`. The native script builds/packages, runs app and mock USB tests, signs and notarizes the app, staples it, creates the ZIP and DMG, then signs/notarizes/staples the DMG and writes individual checksums. Only then is provenance recorded. Apple submission uses the network; repository publication does not happen.
- `check` revalidates source, the exact app bundle/ZIP, signing, notarization, hashes and, when present, the prepared manifest and package contents.
- `prepare` copies only the verified DMG, ZIP and individual checksum files into the exact upload inventory and writes a local manifest with release notes. It does not upload or deploy anything.

Options follow the command:

```sh
python3 scripts/release.py plan --config /path/to/non-secret-config.json
python3 scripts/release.py prepare --notes docs/RELEASE-NOTES.md
```

Custom notes must be a fingerprint-covered source file inside the checkout. Add/commit them before building. Without `--notes`, the current version's section of `CHANGELOG.md` supplies notes. Both forms receive an experimental-target heading before review.

Preparation from an extracted source directory is allowed after a verified build, with a null commit in the manifest. Publication always requires a clean Git checkout and the current exact commit; an extracted archive cannot publish. A source fingerprint includes application code, scripts, tests, docs, website and dependencies. Editing a website caption or changing the source commit after building therefore requires a rebuild. Do not edit provenance records to bypass this check.

## Exact publication inventory

For version 0.1, `outputs/artifacts/` contains exactly these four attachments:

```text
ScopeMac-0.1.dmg
ScopeMac-0.1.dmg.sha256
ScopeMac-0.1.zip
ScopeMac-0.1.zip.sha256
```

Both packages contain the same signed, notarized and stapled `ScopeMac.app`. The DMG includes a drag-to-Applications shortcut and is independently signed, notarized and stapled. Each `.sha256` file contains one SHA-256 digest and the matching package basename; verify with `shasum -a 256 -c ScopeMac-0.1.dmg.sha256` and the ZIP equivalent.

No source archive, website bundle, notes file, manifest, aggregate checksum list or Apple submission evidence is attached. GitHub and GitLab automatically provide source archives from the published tag. Release notes appear in the release description. All source, license files and PHP website files must be committed so they are included in those automatically generated archives. Website deployment remains separate.

`outputs/release/manifest.json` stays local and binds the source fingerprint, commit, target status, reviewed tag/annotation/notes, destinations and the exact four asset hashes. `outputs/release/receipt.json` stays local for resumable publication. Missing, extra, duplicated, symlinked or modified release assets are refused.

`build/provenance/macos.json` records source/toolchain information, bundle file hashes, final ZIP/DMG hashes and both Apple notarization evidence hashes. Native validation checks the DMG signature and stapling, mounts it read-only and verifies its app matches the ZIP/app bundle, then detaches it. All Apple results and verification records stay under ignored `build/`; they are not uploaded. These checks do not claim bit-for-bit reproducibility or physical runtime validation.

The inventory/provenance schema is now version 2. Rebuild and prepare again after this change; old manifests or existing releases with different assets are not overwritten or silently migrated. Preserve any earlier publication receipt and resolve conflicting tags/releases deliberately.

Review the manifest, all output files, target repositories and notes before publication. Run the manual runtime checks on the final ZIP.

## Explicit publication

```sh
python3 scripts/release.py publish --to gitlab,github --confirm-publish
```

GitLab and GitHub are the defaults; a configured single destination can be selected with `--to github` or `--to gitlab`. Names must be distinct. `release --confirm-publish` is a convenience that prepares if no manifest exists and otherwise reuses the exact existing manifest/receipt; it does not build or replace a reviewed manifest. The separate prepare/review/publish sequence is recommended. Without `--confirm-publish`, publication is refused. Selecting an unconfigured destination or failing to resolve its configured token provider fails before tag pushes/uploads.

Every selected destination receives read-only preflight before any publication: local source/artifacts/records are rechecked, repository identity and access are validated, existing annotated tags are resolved, and remote release notes, hashes and links are checked. Configure both repositories with the same source commit before starting. Write authorization may still fail when the service enforces protected-tag, token or organization policies; no preflight can eliminate all later network/policy failures.

An annotated local tag is created at the manifest commit if needed. The default is `0.1`; `prepare --tag 0.1 --tag-message "ScopeMac 0.1"` records the exact requested annotation. An optional `v` prefix remains supported for future operator choice. The tag must still match the marketing version. Publishing uses the prepared tag/message; explicit overrides must agree, and an existing local tag annotation must match. Only that tag is pushed, without force. Existing lightweight tags or tags pointing elsewhere are refused. A remote tag is verified after push. Existing tags are never moved.

### GitHub

The tool finds existing drafts as well as published releases. A new release starts as a draft. Every uploaded asset must return the matching SHA-256 digest. Matching assets are reused; unknown or conflicting digests, duplicate/unexpected assets or different notes fail. Only a complete, verified draft is made public as a prerelease. The release has the four explicit attachments plus GitHub’s automatic source links. Missing assets are not appended to an already public release.

### GitLab

Artifacts use versioned generic package URLs under `scopemac/<version>/`. Existing bytes are streamed and hashed before reuse. Uploaded bytes are downloaded and verified before a tagged release advertises their links. Different bytes, notes, commit IDs or link destinations fail instead of overwriting an existing release. Downloads can follow HTTPS object-storage redirects; API credentials are dropped on an origin change.

## Receipts and interrupted runs

`outputs/release/receipt.json` binds the prepared manifest hash, current destination and completed destinations. It is saved before mutations and after each successful destination. The same reviewed manifest can resume an interrupted repository publication and reuse matching uploads. Completed destinations are checked again before being skipped. Partial publication is possible across independent services; there is no cross-service transaction or automatic rollback.

Retain receipts and inspect service state after failures. Do not delete or modify a receipt to recover. A receipt from another manifest is refused. `build` and `prepare` refuse to replace a release with an existing receipt. For a new release, use a new version and fresh checkout, preserving the previous output directory as release evidence. One operator per checkout is enforced by a local file lock; operators on separate machines must coordinate to avoid remote races.

Do not remove published assets or tags as an automatic cleanup step. Resolve conflicts deliberately with a new version when appropriate.

## Offline validation

```sh
python3 -m unittest discover -s tests -v
```

Tests use temporary repositories and mocked APIs. They exercise planning, source drift, modified bundles, dirty/untracked/ignored inputs, archive inventories, configuration, missing credentials, tag conflicts, draft sequencing, upload digests, GitLab downloads, interrupted runs and receipt binding. They do not contact publication services. Exercise the adapters with dedicated test repositories before using production tags.

The shared profile, 1Password and source workflow are adapted from BitSkim; its MIT notice is preserved under `ThirdParty/BitSkim/`. ScopeMac retains its own native build and stricter manifest/upload validation.

API references: [GitHub releases](https://docs.github.com/en/rest/releases/releases), [GitHub assets](https://docs.github.com/en/rest/releases/assets), [GitLab generic packages](https://docs.gitlab.com/user/packages/generic_packages/), [GitLab releases](https://docs.gitlab.com/api/releases/).
