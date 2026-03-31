# Project Asset Inventory Subagent System

## Purpose

This workflow uses a detailed subagent system so larger runs can split inventory generation, capture execution, validation, and workflow maintenance cleanly.

Use this system when:

- multiple Unity projects exist under the workspace root
- output format or config rules changed
- capture tooling or Unity version mapping changed
- validation needs to be separated from execution

## Core Roles

- `workspace-orchestrator`
  - overall owner of one inventory-plus-capture run
  - picks the output label, target projects, and handoff order
- `tooling-maintainer`
  - owns `Invoke-ProjectAssetInventory.ps1`
  - owns inventory script behavior changes and compatibility fixes
- `capture-tooling-maintainer`
  - owns `Invoke-ProjectAssetCapture.ps1`
  - owns `UnityCaptureTools/Editor/*`
  - owns Unity editor resolution and temporary tooling injection behavior
- `project-discovery-reviewer`
  - verifies which folders are or are not treated as Unity projects
- `config-maintainer`
  - owns `projects.json`
  - manages per-project excludes, output name overrides, editor overrides, and capture toggles
- `scanner-runner`
  - runs the actual inventory generation for one or more projects
- `capture-runner`
  - prepares mirrored capture directories or runs the actual capture generation for one or more projects
- `output-writer`
  - owns inventory and capture output schema and human-facing text format when those change
- `output-validator`
  - verifies inventory counts, exclusions, duplicate handling, and searchability
- `capture-validator`
  - verifies prepared directory layouts, capture row counts, file existence for success rows, cleanup of temporary tooling, and failure reporting
- `workflow-maintainer`
  - keeps canonical docs synchronized with the real workflow behavior
- `capture-planner`
  - designs later capture phases without destabilizing the implemented v1 flow

## Recommended Handoff Order

1. `workspace-orchestrator`
2. `project-discovery-reviewer`
3. `config-maintainer`
4. `tooling-maintainer`
5. `scanner-runner`
6. `output-validator`
7. `capture-tooling-maintainer` when capture behavior changed
8. `capture-runner` in directory-prep mode when output structure approval is needed first
9. `capture-validator` for directory-prep validation when directory-prep mode ran
10. `capture-runner` for real rendering after the directory layout is approved
11. `capture-validator`
12. `workflow-maintainer`
13. `capture-planner` when designing a future capture phase

## Parallelization Guidance

- Run one `scanner-runner` per target project when the projects are independent.
- Run one `capture-runner` per target project only if separate Unity instances are acceptable for that workspace; otherwise keep capture serialized.
- Validate root inventory outputs against the sum of per-project inventory outputs when the shared inventory contract changes.
- Validate root capture outputs against the sum of per-project capture outputs when the shared capture contract changes.
- Keep `capture-tooling-maintainer` and `workflow-maintainer` coordinated whenever the capture script or Unity batch tooling changes.

## Current Canonical Docs

- `Workflows/ProjectAssetInventory/SUBAGENT_SYSTEM.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_WORKSPACE_ORCHESTRATOR.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_TOOLING_MAINTAINER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_CAPTURE_TOOLING_MAINTAINER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_PROJECT_DISCOVERY_REVIEWER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_CONFIG_MAINTAINER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_SCANNER_RUNNER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_CAPTURE_RUNNER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_OUTPUT_WRITER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_OUTPUT_VALIDATOR.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_CAPTURE_VALIDATOR.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_WORKFLOW_MAINTAINER.md`
- `Workflows/ProjectAssetInventory/SUBAGENT_CAPTURE_PLANNER.md`

## Error Handling Order

Use the same validator-first pattern for both inventory and capture failures.

Generic role mapping:

- error-validator = output-validator for inventory, capture-validator for capture
- fix-worker = tooling-maintainer for inventory, capture-tooling-maintainer for capture
- verification-worker = the same validator role that classified the failure
- execution-runner = scanner-runner for inventory, capture-runner for capture

Mandatory error order:

1. runner stops on error and returns logs, exit code, and affected scope
2. validator classifies the error and identifies the responsible fixer
3. maintainer applies the fix without triggering a rerun
4. validator verifies the fix and confirms the branch is ready to rerun
5. runner executes again only after that signoff

Stop rules:

- runners do not auto-retry after runtime or compiler failures
- maintainers do not self-approve reruns
- validators are responsible for both first-pass triage and post-fix verification
- orchestrator must enforce the stop rule before any rerun is scheduled

