# Workflows

This folder contains reusable workflows that can travel between developers and workspaces.

## AI Start Here

If another developer or AI receives only this `Workflows` directory, start with the prompt below before doing anything else.

```text
Workflows\ProjectAssetInventory 를 먼저 꼼꼼히 읽고, 어떤 워크플로우인지 파악해줘.
특히 README.md, SETUP_GUIDE.md, MAINTENANCE.md, PROMPT_TEMPLATE.md, projects.json, projects.local.json 을 우선 확인해줘.
그 다음 현재 작업 환경에 맞게 내가 바로 사용할 프롬프트를 작성해줘.
필요하면 workspace root, workflow root, output label, target projects 중 꼭 필요한 값만 나에게 물어봐줘.
```

After that, continue with the workflow-specific entry README:

```text
Workflows\ProjectAssetInventory\README.md
```

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

```text
Workflows\ProjectAssetInventory\SETUP_GUIDE.md
```

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