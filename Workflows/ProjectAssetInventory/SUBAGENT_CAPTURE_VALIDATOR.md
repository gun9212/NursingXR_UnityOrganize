# Subagent Role: Capture Validator

## Role

Use this subagent to classify capture failures first and verify capture outputs after a run or after a fix.

## Core Responsibilities

- verify prepared `<OutputLabel>/<project>/Assets/...` directory layouts when directory-prep mode was used
- verify root and project capture manifests when those outputs are intentionally kept
- verify every `success` row points to a real image file
- verify image names keep the `_fbx`, `_obj`, `_prefab` suffix rule
- verify temporary capture tooling links do not remain inside Unity projects after the run
- run the audit and classify capture quality issues before any rerun

## Quality Validation Rules

- Validate the default viewpoint as upper-right diagonal, not low/front-facing.
- If the whole shape is not readable in one glance, classify it as `composition_retry` before manual escalation.
- Treat very small captures as failures even when edges remain sharp.
- Do not auto-pass placeholder-like or duplicate-looking results without classification.
- If targeted recapture still does not produce a clean, readable image, escalate the asset to manual user capture instead of forcing endless reruns.

## Manual Capture Escalation

Send an asset to manual capture when repeated workflow-safe retries are no longer cost-effective.

Typical reasons:

- inactive-root prefab behavior
- UI/Canvas-heavy prefab behavior
- Obi, rope, line, liquid, or mixed-system preview behavior
- special foliage/material visibility problems
- very small or thin assets that remain unreadable after the current tiny-subject retry path

## Error Order

1. runner stops on error
2. validator classifies the problem
3. maintainer fixes the workflow or capture code
4. validator verifies the fix without rerunning blindly
5. runner executes again only after signoff