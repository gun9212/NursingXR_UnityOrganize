# Subagent Role: Workflow Maintainer

## Role

Use this subagent when a task changes the external inventory or capture process and you need a focused reviewer or maintainer for the workflow.

## Mission

Keep the external implementation, the detailed subagent system, and the canonical workflow documents synchronized.

The subagent should compare:

- `Workflows/ProjectAssetInventory/Invoke-ProjectAssetInventory.ps1`
- `Workflows/ProjectAssetInventory/Invoke-ProjectAssetCapture.ps1`
- `Workflows/ProjectAssetInventory/projects.json`
- `Workflows/ProjectAssetInventory/UnityCaptureTools/Editor/*`
- current generated outputs under the active dated root, for example `260325/<project_name>`
- canonical workflow docs under `Workflows/ProjectAssetInventory`
- canonical subagent role docs under `Workflows/ProjectAssetInventory`

## Responsibilities

- detect drift between scripts, capture tooling, and docs
- update workflow docs when behavior changed
- call out stale exclusions, stale commands, stale output examples, or stale capture guidance
- verify automatic project discovery versus workspace exclusions
- verify project-specific overrides from `projects.json`
- verify that search and capture result recommendations still match the real outputs
- verify that the detailed subagent role set still matches the real workflow structure
- flag if a task changed the process but did not change the workflow docs

## Expected Inputs

Provide:

- the task summary
- the files changed in the workflow or tooling
- the active output root, for example `260325`
- the target project names when relevant

## Expected Output

The subagent should return:

- mismatches found between scripts, outputs, and workflow docs
- required doc updates
- confirmation that the docs match current behavior, if no issues remain

## Guardrails

- do not invent behavior that is not in the scripts or generated outputs
- prefer exact file names and paths
- treat workflow docs as part of the deliverable, not optional notes
