# SDD ledger — plan: docs/superpowers/plans/2026-09-09-pms-open-source-distribution.md

## Pre-flight scan

| Task | Shared file/interface | Finding | Ruling |
| --- | --- | --- | --- |
| Task 2 → Task 3 | `compose.yaml`, `ENV_FILE`, `COMPOSE_FILE`, `PMS_VERSION` | Task 3 must use the same Compose project and named volumes created by Task 2. | Keep all operation scripts on the existing `docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE"` contract; discover the actual Compose project volume by labels rather than guessing a prefix. |
| Task 3 → Task 5 | `scripts/test-operations-safety.sh` | Task 5 invokes this test in release CI. | Make the test deterministic without requiring a healthy full stack; it must exercise refusal boundaries and syntax/help paths. |
| Task 3 → Task 6 | `scripts/backup.sh`, `scripts/restore.sh`, `scripts/upgrade.sh`, operation docs | Task 6 depends on the scripts being safe enough for clean-machine drills. | Require explicit restore confirmation, validate archives before mutation, and fail before any Docker mutation when prerequisites are missing. |
| Task 3 → existing docs | `docs/operations/backup-restore.md`, `upgrade.md`, `troubleshooting.md` already exist from earlier release work | The plan says Create, but the repository already contains initial versions. | Modify the existing documents in place and keep the resource-preflight guidance; do not duplicate files. |

## Rulings

- Ruling: use the version-matched `schema-init` image as the fixed MySQL/OceanBase client for logical database dumps and restores — the image is already based on `mysql:8.4`, so this avoids adding another unpinned tool dependency to the distribution package.
- Ruling: restore into a newly created database and upload volume by default rather than overwriting the live `brad_pms` database or `pms-uploads` volume — this makes the public script fail-safe; switching production traffic to a restored target remains an explicit deployment decision.

## Task 3

Task 3: complete — backup, isolated restore, upgrade rollback, documentation, and safety contract tests reviewed and pushed as `ad685d1`.

## Task 4 pre-flight

| Concern | Finding | Ruling |
| --- | --- | --- |
| Existing source workflows | `pms-backend` already has `publish-images.yml`; `pms-front` already has `publish-image.yml`. Both publish version tags, but neither currently publishes commit-SHA tags or has a local workflow contract test. | Extend the existing workflows in place rather than creating duplicate workflows. Keep tag/manual-dispatch behavior and add immutable version + SHA tags for every published image. |
| Backend image set | The backend workflow already builds `Dockerfile` and `Dockerfile.migrator` as separate GHCR images. | Preserve both images and apply the same version/SHA tagging contract to each. |
| Frontend image set | The frontend workflow already builds the existing `Dockerfile` for multi-arch output. | Preserve the existing build and add the same immutable tagging contract. |
| Distribution release docs | `docs/operations/release-images.md` is missing. | Add the release ordering, visibility checks, tag conventions, and distribution update procedure without embedding credentials. |

## Task 4

Task 4: complete — release workflows serialize publication, enforce immutable version/SHA tags, and have local Ruby YAML contract coverage.
