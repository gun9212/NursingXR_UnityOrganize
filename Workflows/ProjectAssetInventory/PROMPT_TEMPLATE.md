# Prompt Template

## Purpose

Use this template when another developer, another AI session, or another machine needs to run the shared `ProjectAssetInventory` workflow with only a few user-specific values changed.

## How The AI Should Start

1. Read these files first:
   - `<WORKFLOW_ROOT>\README.md`
   - `<WORKFLOW_ROOT>\SETUP_GUIDE.md`
   - `<WORKFLOW_ROOT>\MAINTENANCE.md`
   - `<WORKFLOW_ROOT>\FINAL_TEST_WORKFLOW.md`
   - `<WORKFLOW_ROOT>\projects.json`
   - `<WORKFLOW_ROOT>\projects.local.json`
   - `<WORKFLOW_ROOT>\SUBAGENT_SYSTEM.md`
2. Infer `WORKSPACE_ROOT` from `WORKFLOW_ROOT` when possible.
3. If required values are missing, ask the user only for the fields listed in `Fields To Customize`.
4. Follow the validator-first error rule: stop on error, diagnose, fix, verify, then rerun.

## Shared Prompt Template

```text
Run the shared Unity asset inventory and capture workflow.

User-supplied fields:
WORKSPACE_ROOT: <optional; example: D:\Workspace\UnityWorkflow>
WORKFLOW_ROOT: <optional; default: WORKSPACE_ROOT\Workflows\ProjectAssetInventory>
OUTPUT_LABEL: <example: 20260331_final_test>
TARGET_PROJECTS: <optional; blank means auto-discover; example: ProjectA;ProjectB>
RUN_SCOPE: <full | inventory_only | capture_only | audit_only | targeted_rerun>
QUALITY_ISSUE_TYPES: <optional; only for targeted_rerun; example: blank_or_tiny_subject,composition_retry>
QUALITY_ISSUE_CSV_PATH: <optional; only for targeted_rerun>

Path rules:
1. If WORKSPACE_ROOT is blank, infer it as the parent of WORKFLOW_ROOT.
2. If WORKFLOW_ROOT is blank, use WORKSPACE_ROOT\Workflows\ProjectAssetInventory.
3. If both are blank, infer them from the currently opened workflow files.
4. If TARGET_PROJECTS is blank, auto-discover Unity projects under WORKSPACE_ROOT.
5. Treat a folder as a Unity project only when it contains Assets, Packages, and ProjectSettings.

Required reading order:
- <WORKFLOW_ROOT>\README.md
- <WORKFLOW_ROOT>\SETUP_GUIDE.md
- <WORKFLOW_ROOT>\MAINTENANCE.md
- <WORKFLOW_ROOT>\FINAL_TEST_WORKFLOW.md
- <WORKFLOW_ROOT>\projects.json
- <WORKFLOW_ROOT>\projects.local.json
- <WORKFLOW_ROOT>\SUBAGENT_SYSTEM.md

Operating rules:
- Use the subagent-role model even if one agent performs all steps.
- Role order:
  - workspace-orchestrator: decide scope and order
  - scanner-runner / capture-runner: execute
  - output-validator / capture-validator: validate
  - tooling-maintainer / capture-tooling-maintainer: fix issues
- If any command errors, stop immediately.
- Diagnose the real cause, fix it, verify the fix, then rerun.
- Do not blindly retry the same error.
- Report local files as plain Windows paths, not browser-style links.

Execution rules:
- If RUN_SCOPE is full:
  1. inventory
  2. capture
  3. audit
  4. targeted rerun if needed
  5. audit again
- If RUN_SCOPE is inventory_only, run inventory only.
- If RUN_SCOPE is capture_only, run capture only.
- If RUN_SCOPE is audit_only, run audit only.
- If RUN_SCOPE is targeted_rerun, use QUALITY_ISSUE_CSV_PATH and QUALITY_ISSUE_TYPES to rerun only the matching files.

Capture rules:
- Scan only .fbx, .obj, and .prefab under each Unity project's Assets folder.
- Use upper-right diagonal framing by default.
- Try to show the overall shape in one glance.
- Keep mirrored output paths.
- Keep output suffixes: _fbx, _obj, _prefab.
- Leave stubborn exceptions in manual review or manual capture rather than blocking the whole run.

Final output checks:
- <WORKSPACE_ROOT>\<OUTPUT_LABEL>\project_inventory.csv
- <WORKSPACE_ROOT>\<OUTPUT_LABEL>\project_inventory_paths.txt
- <WORKSPACE_ROOT>\<OUTPUT_LABEL>\capture_manual_review_paths.txt
- Captured images under <WORKSPACE_ROOT>\<OUTPUT_LABEL>\<ProjectName>\Assets\...

Final report format:
1. Actual WORKSPACE_ROOT and WORKFLOW_ROOT used
2. Auto-discovered or user-specified TARGET_PROJECTS
3. Steps executed
4. Inventory counts
5. Capture success and failure counts
6. Final error rate across all inventory files as a percentage
   - capture failure rate = failed capture rows / total inventory rows * 100
   - remaining review issue rate = remaining audit issue rows / total inventory rows * 100
7. Remaining audit issue counts by type
8. Manual review or manual capture file paths
9. Final judgment on whether the workflow behaved correctly
```

## Fields To Customize

Only these values should normally change per user or per run:

- `WORKSPACE_ROOT`
- `WORKFLOW_ROOT`
- `OUTPUT_LABEL`
- `TARGET_PROJECTS`
- `RUN_SCOPE`
- `QUALITY_ISSUE_TYPES`
- `QUALITY_ISSUE_CSV_PATH`

## What The AI Should Ask The User

If the AI can already infer the workspace and workflow roots from the opened files, it should usually ask only these items:

- desired `OUTPUT_LABEL`
- optional `TARGET_PROJECTS`
- desired `RUN_SCOPE`
- optional rerun inputs: `QUALITY_ISSUE_TYPES`, `QUALITY_ISSUE_CSV_PATH`

If the workflow files are opened from an unknown location, the AI should ask for:

- `WORKSPACE_ROOT`
- and only ask for `WORKFLOW_ROOT` when it cannot safely assume `WORKSPACE_ROOT\Workflows\ProjectAssetInventory`

## Common Examples

### Full Run

```text
WORKSPACE_ROOT: D:\Workspace\UnityWorkflow
WORKFLOW_ROOT:
OUTPUT_LABEL: 20260331_final_test
TARGET_PROJECTS:
RUN_SCOPE: full
QUALITY_ISSUE_TYPES:
QUALITY_ISSUE_CSV_PATH:
```

### Single Project Run

```text
WORKSPACE_ROOT: D:\Workspace\UnityWorkflow
WORKFLOW_ROOT:
OUTPUT_LABEL: 20260331_projecta_only
TARGET_PROJECTS: ProjectA
RUN_SCOPE: full
QUALITY_ISSUE_TYPES:
QUALITY_ISSUE_CSV_PATH:
```

### Targeted Rerun

```text
WORKSPACE_ROOT: D:\Workspace\UnityWorkflow
WORKFLOW_ROOT:
OUTPUT_LABEL: 20260331_final_test
TARGET_PROJECTS:
RUN_SCOPE: targeted_rerun
QUALITY_ISSUE_TYPES: blank_or_tiny_subject,composition_retry
QUALITY_ISSUE_CSV_PATH: D:\Workspace\UnityWorkflow\20260331_final_test\capture_quality_issues.csv
```