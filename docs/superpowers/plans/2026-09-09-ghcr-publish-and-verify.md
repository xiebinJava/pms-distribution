# GHCR Image Publishing and Distribution Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the versioned frontend and backend images required by `pms-distribution` to GHCR and verify a clean installation from the public distribution repository.

**Architecture:** The `pms-front` repository publishes `ghcr.io/xiebinjava/pms-front:<version>`. The `pms-backend` repository publishes `ghcr.io/xiebinjava/pms-backend:<version>`. Each image is published for `linux/amd64` and `linux/arm64`. Workflows support manual dispatch for the current `1.0.0` validation and tag-based releases for future versions; the distribution repository remains the version-pinned consumer.

**Tech Stack:** GitHub Actions, Docker Buildx, GHCR, Docker Compose v2, MySQL 8.

**Spec:** Existing `pms-distribution` release contract in `scripts/test-distribution-contract.sh`, `scripts/test-compose-config.sh`, `.env.example`, and `compose.yaml`.

## Global Constraints

- Use explicit image versions; never use `latest` in the distribution release path.
- Keep frontend and backend source repositories separate from the distribution repository.
- Do not commit credentials, generated `.env` files, or bootstrap secret files.
- The clean-install verification must use an isolated Compose project and a non-conflicting host port.
- Published release images must include both `linux/amd64` and `linux/arm64` manifests.
- Do not report the installation as passing unless anonymous GHCR pulls and the full bootstrap flow succeed.

---

### Task 1: Publish backend images

**Files:**
- Create: `../pms-backend/.github/workflows/publish-images.yml`
- Test: workflow YAML structure, shell syntax, and GitHub Actions run status

**Interfaces:**
- Consumes: `Dockerfile`, repository `GITHUB_TOKEN` with `packages: write`.
- Produces: `ghcr.io/xiebinjava/pms-backend:<version>`.

- [ ] **Step 1: Add a workflow with manual and tag triggers**

  The workflow must accept a required `version` input defaulting to `1.0.0`, derive the version from `v*` tags when tag-triggered, configure QEMU and Buildx, build the backend Dockerfile for `linux/amd64,linux/arm64` with cache, and push immutable version tags. It must grant only `contents: read` and `packages: write` permissions.

- [ ] **Step 2: Validate the workflow locally**

  Run `bash -n` against any inline shell extracted or manually reviewed, parse the YAML with Ruby's standard YAML parser, and confirm the backend image coordinate and Dockerfile path are present.

- [ ] **Step 3: Commit and push the backend workflow**

  Commit only the workflow and push the configured branch so GitHub Actions can run the workflow.

### Task 2: Publish the frontend image

**Files:**
- Create: `../pms-front/.github/workflows/publish-image.yml`
- Test: workflow YAML structure, shell syntax, and GitHub Actions run status

**Interfaces:**
- Consumes: `Dockerfile`, repository `GITHUB_TOKEN` with `packages: write`.
- Produces: `ghcr.io/xiebinjava/pms-front:<version>`.

- [ ] **Step 1: Add a workflow with manual and tag triggers**

  The workflow must accept a required `version` input defaulting to `1.0.0`, derive the version from `v*` tags when tag-triggered, configure QEMU and Buildx, build the existing frontend Dockerfile for `linux/amd64,linux/arm64` with cache, and push the explicit version tag.

- [ ] **Step 2: Validate the workflow locally**

  Parse the YAML with Ruby's standard YAML parser and confirm the frontend image coordinate and Dockerfile path are present.

- [ ] **Step 3: Commit and push the frontend workflow**

  Commit only the workflow and push the configured branch so GitHub Actions can run the workflow.

### Task 3: Publish and verify the current release images

**Files:**
- Modify: none unless package visibility or release metadata requires a narrowly scoped correction
- Test: GitHub Actions workflow runs, GHCR anonymous manifest inspection

**Interfaces:**
- Consumes: the two published workflows from Tasks 1 and 2.
- Produces: anonymously readable `1.0.0` manifests for all three distribution image references.

- [ ] **Step 1: Dispatch both workflows for version `1.0.0`**

  Use `gh workflow run` against each workflow and record the run IDs.

- [ ] **Step 2: Wait for completion and inspect logs**

  Use `gh run watch --exit-status` for both run IDs. If a run fails, inspect the failed step before changing code.

- [ ] **Step 3: Verify anonymous GHCR access**

  Run `docker manifest inspect` for `ghcr.io/xiebinjava/pms-front:1.0.0` and `ghcr.io/xiebinjava/pms-backend:1.0.0`. If any manifest returns `denied`, report package visibility as the blocker and do not claim installation success.

### Task 4: Run a clean distribution installation

**Files:**
- Test: a fresh clone of public `pms-distribution`, `scripts/bootstrap.sh`, Docker Compose health checks, HTTP smoke checks

**Interfaces:**
- Consumes: public `pms-distribution` and anonymous `1.0.0` GHCR images.
- Produces: healthy frontend/backend/MySQL stack reachable on an isolated host port.

- [ ] **Step 1: Clone the public distribution into a temporary directory**

  Use `mktemp -d` and `git clone --depth 1 https://github.com/xiebinJava/pms-distribution`. Do not use the existing working tree or existing Compose project.

- [ ] **Step 2: Run the bootstrap on a free port**

  Change only the temporary clone's `PMS_PORT` to `5174`, run `COMPOSE_PROJECT_NAME=pms-distribution-verify ./scripts/bootstrap.sh`, and capture the generated bootstrap secret file path without printing secrets.

- [ ] **Step 3: Verify service health and HTTP behavior**

  Confirm Compose reports healthy `mysql`, `backend`, and `frontend` services, then check `http://127.0.0.1:5174` and the frontend health endpoint. Confirm the migration init services completed successfully.

- [ ] **Step 4: Stop only the isolated verification project**

  Run `docker compose --project-name pms-distribution-verify down` from the temporary clone, preserving the user's existing project and data volumes.

### Review checklist

- [ ] Both workflow files are limited to image publishing and do not expose secrets.
- [ ] Workflow runs succeeded with fresh GitHub Actions evidence.
- [ ] All three image manifests are anonymously readable at `1.0.0`.
- [ ] All three image manifests include both `linux/amd64` and `linux/arm64`.
- [ ] Fresh-clone bootstrap completed and service health checks passed.
- [ ] Existing local services and repositories remain unchanged except for the intended workflow commits.
