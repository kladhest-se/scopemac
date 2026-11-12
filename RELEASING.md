# Release 0.1

Run from a clean, committed ScopeMac checkout. Settings are loaded from `~/Development/tools/git-release/projects/scopemac.json`; its 1Password references are resolved only when publishing.

```sh
python3 scripts/release.py plan
python3 scripts/release.py build
python3 scripts/release.py check
python3 scripts/release.py prepare --tag 0.1 --tag-message "ScopeMac 0.1"
```

Review `outputs/release/manifest.json` and test the final packages. Then upload the annotated `0.1` tag and identical assets to both services:

```sh
python3 scripts/release.py publish --tag 0.1 --to gitlab,github --confirm-publish
```

The only attachments are:

```text
ScopeMac-0.1.dmg
ScopeMac-0.1.dmg.sha256
ScopeMac-0.1.zip
ScopeMac-0.1.zip.sha256
```

GitHub and GitLab provide source archives automatically from the tag. Notes appear in the release description; manifests, receipts, signing evidence and the website stay out of the attachments. The experimental app is published as a prerelease.

If source is not yet in Git, see [the source initialization workflow](docs/RELEASING.md#source-branch-workflow). If it is committed but not synchronized, use `source --dry-run`, then `source --confirm-push`. These are separate from release publication.

See [the full guide](docs/RELEASING.md) for signing, configuration, preflight and resuming interrupted uploads. Existing conflicting assets/tags are never overwritten. A failed upload should be resumed with the same manifest; do not rebuild or replace its receipt.
