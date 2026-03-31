# Maintenance

## Update Rule

Whenever commands, outputs, capture rules, exclusions, review policy, or subagent responsibilities change, update the matching workflow documents in the same task.

At minimum, keep these files in sync:

- `Workflows\README.md`
- `Workflows\ProjectAssetInventory\README.md`
- `Workflows\ProjectAssetInventory\MAINTENANCE.md`
- any changed subagent role docs
- `Workflows\ProjectAssetInventory\projects.json` when shared config examples change

## Shared Config Policy

Treat `projects.json` as the portable shared baseline, including shared project exclude rules.

Treat `projects.local.json` as the developer- or machine-specific override. Commit the initial empty file, then keep later personal edits local unless the team explicitly decides to share a new baseline.

If a value is needed by everyone working in the same workspace, put it in `projects.json`. If it is only for one PC or one developer, put it in `projects.local.json`.

## Portable Documentation Rule

Do not hardcode one developer's absolute paths in the canonical README files.

Prefer placeholders such as:

- `<WorkspaceRoot>`
- `<OutputLabel>`
- `<ProjectName>`

## Final Deliverable Policy

For the main final output root, keep only:

```text
<OutputLabel>\project_inventory.csv
<OutputLabel>\project_inventory_paths.txt
<OutputLabel>\capture_manual_review_paths.txt
```

Generated working files such as `capture_inventory.csv`, per-project `_docs`, recovery CSVs, triage CSVs, and temporary review files may exist during execution and may be deleted afterward.

## Error Handling Policy

- Stop when a command errors.
- Diagnose the real cause before rerunning.
- Fix the workflow or script mismatch first.
- Validate the fix.
- Rerun only after validation.

## Shareability Check

Before calling the workflow "shared", verify these are true:

- the scripts run without a hardcoded workspace root
- the scripts do not rely on one developer's Unity install path
- `projects.json` is generic and safe to share
- `projects.local.json` contains only local overrides
- README examples use placeholders or relative commands