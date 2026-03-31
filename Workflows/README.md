# Workflows

This folder contains reusable workflows that can travel between developers and workspaces.

## Portable Layout

Treat the folder that contains `Workflows` as the workspace root:

```text
<WorkspaceRoot>
  Workflows
    ProjectAssetInventory
  <UnityProjectA>
  <UnityProjectB>
  <OutputLabel>
```

## Setup Guide

For first-time setup on another machine or workspace, use:

`	ext
Workflows\\ProjectAssetInventory\\SETUP_GUIDE.md
` 

## Current Workflow

- `ProjectAssetInventory`
  - auto-discovers Unity projects under `<WorkspaceRoot>`
  - scans only `.fbx`, `.obj`, `.prefab` under each project's `Assets`
  - mirrors capture outputs under `<OutputLabel>/<ProjectName>/Assets/...`
  - uses an upper-right diagonal capture view as the default framing rule
  - stops on error, validates, fixes, and then reruns
  - allows a small number of stubborn assets to move to manual user capture

## Shared vs Local Config

Shared workflow defaults live in:

```text
Workflows\ProjectAssetInventory\projects.json
```

Developer- or machine-specific overrides live in:

```text
Workflows\ProjectAssetInventory\projects.local.json
```

Recommended rule:
- share `projects.json`
- let each developer maintain their own `projects.local.json`

## Final Deliverable Policy

For the main dated output root, keep only these root-level docs:

```text
<OutputLabel>\project_inventory.csv
<OutputLabel>\project_inventory_paths.txt
<OutputLabel>\capture_manual_review_paths.txt
```

Keep actual captured images under:

```text
<OutputLabel>\<ProjectName>\Assets\...
```

## Error Handling Rule

- Stop on error.
- Diagnose before rerun.
- Fix the script or workflow mismatch first.
- Verify the fix.
- Rerun only after validator signoff.

## Workflow Sync Rule

Whenever commands, outputs, capture rules, exclusions, review policy, or subagent responsibilities change, update the matching workflow documents in the same task.