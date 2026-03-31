# Setup Guide

## Goal

Set up the shared `ProjectAssetInventory` workflow on a new PC or in a new workspace so any developer can run inventory, capture, and audit with minimal local changes.

## How To Read The Subagent Docs

The workflow documents several `SUBAGENT_*.md` files.
That does not mean the operator must always spawn multiple agents.
It means the workflow is organized by responsibility so any developer or AI can follow the same order of work.

Use the role names as an operating checklist:

- `workspace-orchestrator`
  - decides scope, output label, and handoff order
- `scanner-runner` / `capture-runner`
  - performs the real script execution
- `output-validator` / `capture-validator`
  - judges whether the output is acceptable
- `tooling-maintainer` / `capture-tooling-maintainer`
  - fixes errors in scripts, config, or capture logic

When an error happens, think in that same role order:

1. runner stops
2. validator classifies the problem
3. maintainer fixes the root cause
4. validator verifies the fix
5. runner executes again

## 1. Prepare The Workspace

Create a workspace root and place the workflow plus one or more Unity projects under it.

```text
<WorkspaceRoot>
  Workflows
    ProjectAssetInventory
  <UnityProjectA>
  <UnityProjectB>
```

Each Unity project must contain:

```text
Assets
Packages
ProjectSettings
```

## 2. Keep Shared And Local Config Separate

Shared defaults live here:

```text
<WorkspaceRoot>\Workflows\ProjectAssetInventory\projects.json
```

Local machine overrides live here:

```text
<WorkspaceRoot>\Workflows\ProjectAssetInventory\projects.local.json
```

Recommended policy:
- commit `projects.json` with shared project rules
- commit the initial empty `projects.local.json` in the shared workflow
- after that, let each developer add only their own machine-specific values locally and do not push those personal edits back

## 3. Fill In Local Config

Use `projects.local.json` only for values that should not be shared with the whole team:
- local Unity editor installation roots
- private per-machine overrides
- temporary local experiments

Keep shared project exclude rules in `projects.json`.

Example local template:

```json
{
  "editor_search_roots": [
    "D:\\UnityEditors"
  ],
  "projects": {
    "Nested/ProjectB": {
      "unity_editor_path": "C:\\Program Files\\Unity\\Hub\\Editor\\2022.3.22f1\\Editor\\Unity.exe"
    }
  }
}
```

Notes:
- keys under `projects` are paths relative to `<WorkspaceRoot>` when you really need a local-only per-project override
- use `/` separators in config keys and exclude paths
- `unity_editor_path` may point either to `Unity.exe` or to the editor folder that contains `Editor\Unity.exe`

## 4. Check Unity Editor Discovery

The capture script searches for editors in this order:
1. project-specific `unity_editor_path`
2. `editor_search_roots` from `projects.json` and `projects.local.json`
3. environment variables:
   - `UNITY_EDITOR_SEARCH_ROOTS`
   - `UNITY_EDITOR_ROOT`
4. fallback:

```text
C:\Program Files\Unity\Hub\Editor
```

If your machine uses a nonstandard Unity install location, add it to `projects.local.json`.

## 5. Run Inventory

From `<WorkspaceRoot>`:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetInventory.ps1" -OutputLabel "<OutputLabel>"
```

If `-OutputLabel` is omitted, the scripts default to today's date in `yyyyMMdd` format.

## 6. Run Capture

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCapture.ps1" -OutputLabel "<OutputLabel>"
```

Current defaults:
- upper-right diagonal view
- mirrored output path under `<OutputLabel>\<ProjectName>\Assets\...`
- output file names keep `_fbx`, `_obj`, `_prefab`

## 7. Run Audit

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCaptureAudit.ps1" -OutputLabel "<OutputLabel>"
```

Current audit buckets:
- `blank_or_tiny_subject`
- `composition_retry`
- `placeholder_duplicate`

## 8. Rerun Only Problem Files

Example targeted rerun:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCapture.ps1" -OutputLabel "<OutputLabel>" -QualityIssueCsvPath ".\<OutputLabel>\capture_quality_issues.csv" -QualityIssueTypes "blank_or_tiny_subject"
```

Use targeted reruns instead of rerunning everything when only a small set of files has framing or quality problems.

## 9. Final Files To Keep

Keep these root-level docs in the final lean output:

```text
<OutputLabel>\project_inventory.csv
<OutputLabel>\project_inventory_paths.txt
<OutputLabel>\capture_manual_review_paths.txt
```

Captured images remain under:

```text
<OutputLabel>\<ProjectName>\Assets\...
```

## 10. Error Rule

If a command errors:
1. stop
2. diagnose the real cause
3. fix the script or config mismatch
4. verify the fix
5. rerun only after validation

Do not blindly rerun on the same error.

## 11. Manual Capture Rule

If a small number of assets still cannot be captured cleanly after targeted reruns, move them to manual user capture instead of blocking the whole workflow.

Typical cases:
- inactive-root prefabs
- UI or Canvas-heavy prefabs
- rope, line, liquid, or mixed-system prefabs
- special foliage/material visibility cases
- tiny props that still stay unreadable after the retry flow

## 12. Shared Prompt Template

If another developer or AI needs to run the workflow without re-reading the whole repository first, start from:

```text
<WorkspaceRoot>\Workflows\ProjectAssetInventory\PROMPT_TEMPLATE.md
```

That prompt is designed so each operator changes only the user-specific fields such as workspace root, output label, target projects, and rerun scope.
