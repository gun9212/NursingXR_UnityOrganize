# Project Asset Inventory And Capture Workflow

## Purpose

This workflow manages reusable inventory and capture work for any Unity projects placed under the same workspace root.

It is designed so another developer, another session, or another AI can continue the same process without hidden chat-only context.

## How To Interpret The Subagent System

This workflow includes detailed `SUBAGENT_*.md` files.
Those role docs define responsibility and execution order even if a single developer runs the whole workflow manually.

In practice, read them like this:

- `workspace-orchestrator`
  - decides scope and run order
- `scanner-runner` / `capture-runner`
  - executes inventory or capture
- `output-validator` / `capture-validator`
  - checks whether the run is good enough
- `tooling-maintainer` / `capture-tooling-maintainer`
  - fixes workflow or script issues before a rerun

So "use the subagent system" means "follow the role-based order of responsibility," not "you must always spin up many separate agents."

## Portable Workspace Layout

The scripts derive `<WorkspaceRoot>` from their own location when `-WorkspaceRoot` is omitted.

Keep this layout:

```text
<WorkspaceRoot>
  Workflows
    ProjectAssetInventory
      Invoke-ProjectAssetInventory.ps1
      Invoke-ProjectAssetCapture.ps1
      Invoke-ProjectAssetCaptureAudit.ps1
      projects.json
      projects.local.json
      UnityCaptureTools
  <Unity projects...>
  <dated output roots...>
```

## What It Scans

Only these asset kinds are scanned, and only under each discovered project's `Assets` folder:

- `.fbx`
- `.obj`
- `.prefab`

`Packages`, `ProjectSettings`, `Library`, and other non-`Assets` folders are not part of the inventory.

## Shared And Local Config

Shared defaults:

```text
Workflows\ProjectAssetInventory\projects.json
```

Local per-developer overrides:

```text
Workflows\ProjectAssetInventory\projects.local.json
```

Suggested usage:
- keep `projects.json` for shared workspace-level defaults and shared project overrides
- keep machine-specific editor search roots, private overrides, and developer-only experiments in `projects.local.json`
- `projects.local.json` is intentionally empty by default; commit the initial empty file, then let each developer change it locally without pushing those personal edits

## Setup Guide

Start here on a new PC or workspace:

```text
Workflows\ProjectAssetInventory\SETUP_GUIDE.md
```

## Prompt Template

Use this shared prompt when another developer or AI needs to run the workflow with only a few per-user values changed:

```text
Workflows\ProjectAssetInventory\PROMPT_TEMPLATE.md
```

## AI Entry Behavior

If another AI receives only the `Workflows` directory on a different PC, it should use this README as the entrypoint.

Expected startup behavior:
- infer `WORKSPACE_ROOT` and `WORKFLOW_ROOT` from the opened README location when possible
- read the setup, maintenance, final-test, config, and subagent docs before running anything
- ask the user only for the minimum missing fields such as `OUTPUT_LABEL`, optional `TARGET_PROJECTS`, and the desired `RUN_SCOPE`
- use `PROMPT_TEMPLATE.md` as the canonical reusable prompt shape when it needs a shared prompt

## Main Scripts

From `<WorkspaceRoot>`:

Inventory:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetInventory.ps1" -OutputLabel "<OutputLabel>"
```

Capture:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCapture.ps1" -OutputLabel "<OutputLabel>"
```

Audit:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCaptureAudit.ps1" -OutputLabel "<OutputLabel>"
```

If `-OutputLabel` is omitted, the scripts default to the current date in `yyyyMMdd` format.

## Standard Run Order

1. Place one or more Unity projects under `<WorkspaceRoot>`.
2. Update `projects.local.json` if the current machine needs editor search roots or project overrides.
3. Run inventory.
4. Review the inventory if needed.
5. Run capture.
6. Run audit.
7. Rerun only the affected files when quality or framing issues are found.
8. If a small number of files still cannot be captured cleanly, move them to manual user capture.

## Capture Rules

Current default capture behavior:

- upper-right diagonal view
- try to show the overall shape in one glance
- keep the real asset path structure under the dated output root
- keep the original extension suffix in the output file name

Example:

```text
Assets\ART\Prefabs\Office.prefab
-> <OutputLabel>\<ProjectName>\Assets\ART\Prefabs\Office_prefab.png
```

## Final Deliverable Shape

Root-level files to keep in the final lean deliverable:

```text
<OutputLabel>\project_inventory.csv
<OutputLabel>\project_inventory_paths.txt
<OutputLabel>\capture_manual_review_paths.txt
```

Inventory output expectations:

- `project_inventory.csv` includes both project-relative fields and an `absolute_path` column so rows can be copied directly into Windows Explorer.
- `project_inventory_paths.txt` stores absolute filesystem paths, one per line, for fast `Ctrl+F` search and copy/paste into Windows Explorer.

Actual images remain under:

```text
<OutputLabel>\<ProjectName>\Assets\...
```

Working files such as `capture_inventory.csv`, per-project `_docs`, triage CSVs, recovery CSVs, and temporary review outputs may be generated during execution and removed later.

Final report expectations:

- total inventory rows
- capture success and failure counts
- remaining audit issue counts by type
- capture failure rate as a percentage of total inventory rows
- remaining review issue rate as a percentage of total inventory rows

## Review And Targeted Recapture PolicyUse audit results to classify problems before rerunning.

Current issue categories:

- `blank_or_tiny_subject`
- `composition_retry`
- `placeholder_duplicate`

Expected handling:

- `blank_or_tiny_subject`
  - try targeted recapture with tighter framing
- `composition_retry`
  - rerun with alternate composition
- `placeholder_duplicate`
  - inspect whether it is a real problem or an accepted reference-only asset

## Manual Capture Escalation Policy

Do not block the whole workflow on a small number of stubborn assets.

If a file still fails after targeted recapture and review, it may move to manual user capture.

Typical manual-capture exceptions:

- inactive-root prefabs that collapse into empty preview results
- UI or Canvas-heavy prefabs that do not behave like normal 3D props
- Obi, line, rope, liquid, or mixed-system prefabs that do not render reliably in the batch preview path
- special foliage or material cases where preview visibility remains unreliable
- very small or thin props that still do not become readable after the current tiny-subject retry flow

## Unity Editor Discovery

The capture script looks for editors in this order:

1. per-project `unity_editor_path` override from config
2. `editor_search_roots` from `projects.json` and `projects.local.json`
3. environment variables:
   - `UNITY_EDITOR_SEARCH_ROOTS`
   - `UNITY_EDITOR_ROOT`
4. standard fallback:

```text
C:\Program Files\Unity\Hub\Editor
```

## Cross-Session / Cross-AI Reuse

Another session or another AI can use the same workflow if these conditions are true:

- the workflow folder remains under `<WorkspaceRoot>\Workflows\ProjectAssetInventory`
- Unity projects remain under the same workspace root
- shared defaults stay in `projects.json`
- local overrides stay in `projects.local.json`
- a compatible Unity editor is installed for each target project

This workflow does not rely on hidden chat memory for core execution because:

- the scripts derive `WorkspaceRoot` from their own location
- project-specific config is stored in config files on disk
- the main inventory source is persisted in `project_inventory.csv`
- final manual review state is persisted in `capture_manual_review_paths.txt`

## Main Handoff Files

A later developer or AI should start from:

```text
<WorkspaceRoot>\Workflows\ProjectAssetInventory\Invoke-ProjectAssetInventory.ps1
<WorkspaceRoot>\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCapture.ps1
<WorkspaceRoot>\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCaptureAudit.ps1
<WorkspaceRoot>\Workflows\ProjectAssetInventory\projects.json
<WorkspaceRoot>\Workflows\ProjectAssetInventory\projects.local.json
<WorkspaceRoot>\<OutputLabel>\project_inventory.csv
<WorkspaceRoot>\<OutputLabel>\project_inventory_paths.txt
<WorkspaceRoot>\<OutputLabel>\capture_manual_review_paths.txt
```
