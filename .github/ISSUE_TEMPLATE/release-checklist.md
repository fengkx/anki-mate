---
name: Release Checklist
about: Track a macOS release from verification through GitHub publication
title: "Release: vX.Y.Z"
labels:
  - release
assignees: []
---

## Preflight

- [ ] `master` is green on CI
- [ ] Release notes labels are applied to merged PRs
- [ ] `release` environment secrets are present and current
- [ ] Local smoke check completed with `just build-release`

## Create Release

- [ ] Create and push semantic tag `vX.Y.Z`
- [ ] Wait for `Release macOS App` workflow to finish `verify`
- [ ] Approve the protected `release` environment
- [ ] Review workflow summary and attached artifacts
- [ ] Review draft GitHub release title and auto-generated notes

## Validate Artifacts

- [ ] Download release zip from GitHub Releases
- [ ] Verify checksum with `shasum -a 256 -c`
- [ ] Verify Gatekeeper with `spctl -a -t exec -vv`
- [ ] Verify provenance with `gh attestation verify`
- [ ] Review notarization log if the workflow produced one

## Publish

- [ ] Publish the GitHub release
- [ ] Announce release
