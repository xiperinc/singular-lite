# TASK-4242: Proof field contract

Status: ready
Area: widget
Target branch: `target`
Worker branch: `worker/TASK-4242`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Verify the widget with declared proof tests.

## Scope

Owned files:

- `src/widget.py`
- `tests/proof/`
- `tests/single.py`

Forbidden files:

- `private/`
- Any file outside the owned scope.

## Acceptance Criteria

- The widget satisfies its contract.
  Keep this continuation and `literal text` intact.
- Existing tasks still dispatch.
