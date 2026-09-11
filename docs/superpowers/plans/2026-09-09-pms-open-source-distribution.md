# PMS Open-Source Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a public-facing `pms-distribution` repository that lets users run PMS from versioned container images through one documented Docker Compose workflow, while keeping `pms-backend` and `pms-front` as the source repositories.

**Architecture:** The distribution repository contains only deployment manifests, configuration examples, operational scripts, documentation, and release automation. The frontend and backend source repositories build and publish versioned images; the distribution Compose file consumes those images and keeps database data and uploads in named volumes. MySQL remains the first supported production database; MySQL becomes a separate supported profile only after migration verification.

**Tech Stack:** Docker Compose v2, MySQL 8 MySQL-compatible mode, Spring Boot backend image, Nginx frontend image, Bash scripts, GitHub Actions, GHCR.

**Spec:** `docs/superpowers/specs/2026-09-09-pms-open-source-distribution-design.md`

## Global Constraints

- Keep `pms-backend` and `pms-front` as independent source repositories; do not delete or copy their source into the distribution repository.
- Do not commit `.env`, passwords, JWT secrets, SMTP credentials, object-storage credentials, backups, or real business data.
- Do not use `latest` image tags in release Compose files.
- The default Compose path must publish only the frontend entry point to the host.
- MySQL is the first production-supported database; MySQL is not called supported until migration and recovery checks pass.
- Every phase must end with a fresh verification run and a review checkpoint before the next phase.

---

### Task 1: Establish the distribution repository contract

**Files:**
- Create: `README.md`
- Create: `NOTICE`
- Create: `.env.example`
- Create: `CODE_OF_CONDUCT.md`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Modify: `docs/superpowers/specs/2026-09-09-pms-open-source-distribution-design.md`
- Test: repository file and secret-denylist checks

**Interfaces:**
- Produces the public repository layout, the supported-version policy, image variables, and user-facing command contract consumed by Tasks 2–6.

- [x] **Step 1: Write the failing repository contract check**

Create `scripts/test-distribution-contract.sh` that fails when the required root files, `.env.example` keys, image tags, or prohibited secret patterns are missing.

- [x] **Step 2: Run the contract check to verify it fails**

Run: `bash scripts/test-distribution-contract.sh`

Expected: FAIL because the README, environment contract, and operational scripts are not present yet.

- [x] **Step 3: Add the repository documents and configuration contract**

The README must lead with the three-command quick start, link to upgrade/backup/troubleshooting guides, state the supported database profiles, and explain that the existing backend/frontend repositories remain source repositories. `.env.example` must use placeholders and include `PMS_VERSION`, image names, ports, database credentials, JWT secret, bootstrap admin settings, and deployment mode.

- [x] **Step 4: Run the contract check to verify it passes**

Run: `bash scripts/test-distribution-contract.sh`

Expected: PASS with no secret-pattern violations.

- [x] **Step 5: Commit the repository contract**

```bash
git add README.md NOTICE .env.example CODE_OF_CONDUCT.md CONTRIBUTING.md SECURITY.md scripts/test-distribution-contract.sh docs/superpowers/specs/2026-09-09-pms-open-source-distribution-design.md
git commit -m "docs: establish open source distribution contract"
```

### Task 2: Add versioned MySQL Compose deployment

**Files:**
- Create: `compose.yaml`
- Create: `compose.yaml`
- Create: `docker/healthcheck-backend.sh`
- Create: `docker/healthcheck-frontend.sh`
- Create: `scripts/bootstrap.sh`
- Create: `scripts/status.sh`
- Create: `scripts/logs.sh`
- Create: `../pms-backend/Dockerfile`
- Modify: `../pms-backend/.dockerignore`
- Test: `scripts/test-compose-config.sh`

**Interfaces:**
- Consumes `.env.example` keys from Task 1.
- Produces a fixed-version Compose deployment with `frontend`, `backend`, `mysql`, and `uploads-init` services.
- `bootstrap.sh` exits nonzero for missing Docker, missing `.env`, invalid required secrets, or occupied entry port; otherwise it runs `docker compose pull` and `docker compose up -d`.

- [ ] **Step 1: Write the failing Compose validation**

Validate with `docker compose --env-file .env.example -f compose.yaml config` and assert that the rendered services include the frontend, backend, database, migration, and upload initialization services.

- [ ] **Step 2: Run the validation to verify it fails**

Run: `bash scripts/test-compose-config.sh`

Expected: FAIL because no release Compose file exists.

- [ ] **Step 3: Build the version-matched migration image**

Use the existing `pms-backend/Dockerfile`. Flyway runs from the backend image on startup and must not contain application credentials.

- [x] **Step 4: Add the release Compose files and runtime health checks**

Use fixed image references derived from `PMS_VERSION`; let MySQL initialize the `pms` database and let backend Flyway apply migrations; keep database and backend ports internal by default; expose `${PMS_PORT:-5173}:8080` only for the frontend; keep named volumes for database data and uploads; use service health dependencies; preserve non-root and read-only runtime constraints from the backend/frontend source Compose definitions.

- [x] **Step 5: Add bootstrap/status/log helpers**

`bootstrap.sh` must create a local `.env` from `.env.example` only when absent, generate `PMS_JWT_SECRET` with `openssl rand -hex 32` when the value is still a placeholder, refuse weak bootstrap passwords, and print the frontend URL after readiness. `status.sh` and `logs.sh` must accept an optional service name and use the same Compose file and env file.

- [x] **Step 6: Run config and shell verification**

Run: `bash scripts/test-compose-config.sh && bash -n scripts/*.sh docker/*.sh && docker compose --env-file .env.example -f compose.yaml config >/tmp/pms-compose-config.yml`

Expected: exit 0; rendered config contains no literal production secret and no `latest` tag.

- [x] **Step 7: Commit the Compose deployment and migrator image source**

```bash
git add compose.yaml compose.yaml docker scripts
git commit -m "feat: add versioned mysql distribution compose"
```

### Task 3: Add upgrade, backup, restore, and troubleshooting workflows

**Files:**
- Create: `scripts/upgrade.sh`
- Create: `scripts/backup.sh`
- Create: `scripts/restore.sh`
- Create: `docs/operations/upgrade.md`
- Create: `docs/operations/backup-restore.md`
- Create: `docs/operations/troubleshooting.md`
- Test: `scripts/test-operations-safety.sh`

**Interfaces:**
- All scripts consume the same `COMPOSE_FILE`, `ENV_FILE`, and `PMS_VERSION` variables.
- `backup.sh` produces a timestamped archive containing the database dump and uploads archive.
- `restore.sh <archive>` requires an explicit `RESTORE_CONFIRM=YES` environment variable and refuses a missing or malformed archive.
- `upgrade.sh <version>` creates a backup, updates `PMS_VERSION`, pulls images, recreates services, and verifies backend readiness.

- [ ] **Step 1: Write safety tests for destructive operations**

Test that restore refuses missing confirmation, backup refuses a missing running stack, and upgrade refuses an empty or invalid version.

- [ ] **Step 2: Run safety tests to verify they fail**

Run: `bash scripts/test-operations-safety.sh`

Expected: FAIL because the operation scripts do not exist.

- [ ] **Step 3: Implement guarded backup and restore**

Use explicit named volumes and temporary directories; never use broad recursive deletion; require the archive to contain the expected database and uploads members before restoring.

- [ ] **Step 4: Implement upgrade and readiness verification**

Record the previous version, run backup before changing containers, wait for `/api/health/ready`, and print logs if readiness fails.

- [ ] **Step 5: Add operational documentation and pass safety tests**

Run: `bash scripts/test-operations-safety.sh`

Expected: PASS with destructive commands requiring explicit confirmation.

- [ ] **Step 6: Commit operations support**

```bash
git add scripts docs/operations
git commit -m "feat: add distribution upgrade and backup workflows"
```

### Task 4: Publish versioned images from the source repositories

**Files:**
- Modify: `../pms-backend/.github/workflows/ci.yml`
- Create: `../pms-backend/.github/workflows/publish-image.yml`
- Modify: `../pms-front/.github/workflows/ci.yml`
- Create: `../pms-front/.github/workflows/publish-image.yml`
- Create: `docs/operations/release-images.md`

**Interfaces:**
- A Git tag such as `v1.0.0` in each source repository publishes the corresponding frontend/backend images to GHCR with immutable version and commit-SHA tags.
- The distribution repository consumes those image names through `.env.example` and `PMS_VERSION`.

- [ ] **Step 1: Add workflow validation cases**

Validate that publish workflows trigger only on version tags, have `packages: write`, log in to GHCR using `GITHUB_TOKEN`, build the frontend and backend Dockerfiles, and publish both the version and SHA tags.

- [ ] **Step 2: Run workflow syntax and existing CI checks**

Run in each source repository: `git diff --check`, existing CI test commands, and a YAML parse check using the repository's available tooling.

- [ ] **Step 3: Implement image publishing workflows**

Use least-privilege permissions, never print secrets, and fail if the Docker build cannot reproduce from the repository checkout.

- [ ] **Step 4: Document release ordering**

Document: test source repositories → tag backend/frontend → verify GHCR manifests → update distribution `PMS_VERSION` → run clean-machine Compose smoke test → publish distribution release.

- [ ] **Step 5: Commit source-repository release automation separately**

Use one commit in each source repository:

```bash
git add .github/workflows
git commit -m "ci: publish versioned container image"
```

### Task 5: Add release CI and community automation

**Files:**
- Create: `.github/workflows/validate.yml`
- Create: `.github/workflows/release.yml`
- Create: `.github/ISSUE_TEMPLATE/install-problem.yml`
- Create: `.github/ISSUE_TEMPLATE/feature-request.yml`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`
- Create: `CHANGELOG.md`
- Create: `docs/operations/support-matrix.md`

**Interfaces:**
- Pull requests validate shell scripts, Compose rendering, documentation links, secret denylist, and image tag rules.
- Version tags create a GitHub Release only after validation succeeds.

- [ ] **Step 1: Add a failing release contract assertion**

Require that the release workflow references the distribution Compose file, runs the contract and shell tests, and refuses to release with placeholder secrets.

- [ ] **Step 2: Implement validation and release workflows**

Use a matrix for shell/Compose/docs checks and make release creation depend on the validation job.

- [ ] **Step 3: Add issue and support templates**

Installation issues must request OS, Docker version, Compose output, logs, and redaction instructions; feature requests must request problem, user impact, and acceptance criteria.

- [ ] **Step 4: Run repository checks**

Run: `bash scripts/test-distribution-contract.sh && bash scripts/test-compose-config.sh && bash scripts/test-operations-safety.sh && git diff --check`

- [ ] **Step 5: Commit release automation**

```bash
git add .github CHANGELOG.md docs/operations/support-matrix.md
git commit -m "ci: validate and release distribution package"
```

### Task 6: Clean-machine smoke test and phase review

**Files:**
- Create: `docs/operations/clean-machine-smoke-test.md`
- Modify: `README.md`
- Test: full distribution validation and Docker smoke test

**Interfaces:**
- Produces the evidence required before calling the distribution package ready for public preview.

- [ ] **Step 1: Validate repository state**

Run: `git status --short`, `git log --oneline -5`, and verify no `.env`, backup, credential, or generated data files are tracked.

- [ ] **Step 2: Run static verification**

Run: `bash scripts/test-distribution-contract.sh && bash scripts/test-compose-config.sh && bash scripts/test-operations-safety.sh && git diff --check`

- [ ] **Step 3: Run the clean-machine Docker smoke test**

From a clean Docker environment, execute the documented bootstrap path, verify `/api/health/ready`, sign in with the configured bootstrap account, create a test project, restart the stack, and verify the project remains.

- [ ] **Step 4: Run backup and restore acceptance**

Create a backup, restore it into a fresh named volume, and verify the same project and attachment metadata are visible.

- [ ] **Step 5: Review the phase before continuing**

Record actual commands, timings, supported platforms, known limitations, and any failed checks in `docs/operations/clean-machine-smoke-test.md`. Stop here for user review before adding the MySQL profile or broader ecosystem work.
