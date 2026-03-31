# Final Test Workflow

## Goal

Run the workflow in a clean new output root and confirm that the shared portable setup still works.

## Preconditions

- `<WorkspaceRoot>` contains the Unity projects to test.
- `Workflows\ProjectAssetInventory\projects.json` contains only portable shared defaults.
- `Workflows\ProjectAssetInventory\projects.local.json` contains any local editor search roots or machine-specific overrides.

## Subagent View

Treat the run as a role-based operating model even when one developer executes everything alone.

- `workspace-orchestrator`
  - chooses the target output label, target projects, and overall run order
- `scanner-runner` / `capture-runner`
  - executes the actual scripts
- `output-validator` / `capture-validator`
  - checks whether the result is acceptable before any rerun
- `tooling-maintainer` / `capture-tooling-maintainer`
  - fixes script, config, or workflow mismatches

This means "use subagent roles" does not require literally spawning multiple agents every time.
It means the workflow should always be reasoned about in this order:

1. orchestrate
2. run
3. validate
4. fix if needed
5. validate again
6. rerun only after signoff

## Commands

From `<WorkspaceRoot>`:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetInventory.ps1" -OutputLabel "<FinalTestLabel>"
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCapture.ps1" -OutputLabel "<FinalTestLabel>"
powershell -ExecutionPolicy Bypass -File ".\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCaptureAudit.ps1" -OutputLabel "<FinalTestLabel>"
```

## What To Check

- `<FinalTestLabel>\project_inventory.csv` exists
- `<FinalTestLabel>\project_inventory_paths.txt` exists
- `<FinalTestLabel>\capture_manual_review_paths.txt` exists or can be produced after audit/review
- captured images are stored under `<FinalTestLabel>\<ProjectName>\Assets\...`
- the default framing is upper-right diagonal
- obvious tiny/composition issues can be rerun through targeted recapture
- stubborn exceptions can be moved to manual user capture without blocking the run
- the final report includes a percentage-based error summary across all inventory rows
  - capture failure rate = failed capture rows / total inventory rows * 100
  - remaining review issue rate = remaining audit issue rows / total inventory rows * 100

## Handoff Files

Keep these visible for the next developer or AI:

```text
<WorkspaceRoot>\Workflows\ProjectAssetInventory\Invoke-ProjectAssetInventory.ps1
<WorkspaceRoot>\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCapture.ps1
<WorkspaceRoot>\Workflows\ProjectAssetInventory\Invoke-ProjectAssetCaptureAudit.ps1
<WorkspaceRoot>\Workflows\ProjectAssetInventory\projects.json
<WorkspaceRoot>\Workflows\ProjectAssetInventory\projects.local.json
<WorkspaceRoot>\<FinalTestLabel>\project_inventory.csv
<WorkspaceRoot>\<FinalTestLabel>\project_inventory_paths.txt
<WorkspaceRoot>\<FinalTestLabel>\capture_manual_review_paths.txt
```