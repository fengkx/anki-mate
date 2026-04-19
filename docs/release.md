# Release Guide

## Overview

This repository ships the macOS app through GitHub Releases using a Developer ID-signed, notarized `.app` zipped for direct download.

The release workflow is designed around current Apple and GitHub guidance:

- sign with a Developer ID Application certificate
- notarize with `notarytool`
- staple the notarization ticket back onto the `.app`
- create the GitHub release as a draft first, upload assets, then publish
- generate a provenance attestation for the shipped artifacts

## Trigger

- Push a semantic version tag like `v0.1.0`
- Or run `.github/workflows/release-macos.yml` manually for an existing tag
  - set `create_release=false` for a packaging-only dry run
  - set `publish=false` to keep the GitHub release as a draft for manual review

## Required GitHub Environment

Create a protected GitHub Actions environment named `release`.

Recommended protection:

- restrict deployments to tags
- require manual approval
- store signing and notarization secrets only in this environment

## Required Secrets

Store these as environment secrets under `release`:

- `APPLE_DEVELOPER_ID_CERT_BASE64`
  Base64-encoded `.p12` containing the Developer ID Application certificate
- `APPLE_DEVELOPER_ID_CERT_PASSWORD`
  Password for that `.p12`
- `APPLE_DEVELOPER_IDENTITY`
  Optional explicit identity name, for example `Developer ID Application: Your Name (TEAMID)`
- `APPLE_NOTARY_API_KEY_BASE64`
  Base64-encoded App Store Connect API key `.p8`
- `APPLE_NOTARY_KEY_ID`
  App Store Connect API key ID
- `APPLE_NOTARY_ISSUER_ID`
  App Store Connect issuer ID

## Local Dry Run

Unsigned local packaging:

```bash
APP_VERSION=0.1.0 ./scripts/package-macos-release.sh
```

Or via `just`:

```bash
just package-release 0.1.0
```

If signing and notarization environment variables are present, the same script will sign and notarize locally.

## Release Checklist

Before creating the tag:

- confirm `just ci` is green on `master`
- confirm the app launches locally from a fresh `just build-release`
- confirm signing materials in the `release` environment are current
- confirm release notes labels are applied on merged PRs so auto-generated notes group correctly

Publish flow:

1. Create and push a semantic tag such as `v0.1.0`
2. Wait for `.github/workflows/release-macos.yml` to finish the `verify` job
3. Approve the protected `release` environment if GitHub asks for manual approval
4. Review the draft GitHub release, attached assets, generated notes, and workflow summary
5. Publish the release

Post-publish verification:

- download the shipped zip from GitHub Releases
- verify checksum with `shasum -a 256 -c`
- verify Gatekeeper acceptance on a clean Mac with `spctl -a -t exec -vv`
- verify provenance with GitHub CLI:

```bash
gh attestation verify path/to/Anki-Mate-<version>-macos-arm64.zip -R <owner>/<repo>
```

## Release Artifacts

The workflow currently publishes:

- `Anki-Mate-<version>-macos-arm64.zip`
- `Anki-Mate-<version>-macos-arm64.sha256`
- `Anki-Mate-<version>-macos-arm64.manifest.json`
- notarization JSON logs for traceability

## Notes

- The workflow intentionally signs nested binaries explicitly and avoids `codesign --deep` for release signing.
- The shipped archive is created only after stapling, so users download an offline-verifiable notarized app bundle.
- Artifact provenance is generated with GitHub's official attestation action.
- GitHub artifact attestations for private repositories require GitHub Enterprise Cloud. Public repositories can use them on current GitHub plans.
