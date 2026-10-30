# Synthetic acceptance certificate

`audit.json`, `ledger.json`, `evidence-manifest.json`, `task.md` and
`policy.json` describe one candidate. `@HEAD@` is replaced by an anonymous
synthetic Git commit. The test creates a passing host log and uses the public
`gate-report.py` commands to create and bind its request and result; it hashes
the final audit and report into the manifest. No provider runs; a driver decision block is exercised with side-effect stand-ins.

`cases.json` contains language-neutral mutations and expected answers. Each
case starts from the valid certificate. `changes` names a record, a JSON key
path and a replacement value (or `delete`). `rebindArtifacts` refreshes the
manifest after changing a record, so a refusal tests the named part rather
than an incidental stale hash. `args` and `env` describe explicit arguments
and ambient environment probes. The same inputs run from two directories.
`attempts.json` pins the driver's existing audit attempt dispositions as separate
branch and failure-class fields. The shell block check covers the legacy `infra`
verdict without voiding a counted round, alongside genuine infrastructure outcomes.
`reviews.json` pins classification against the explicit host outcome.

The program accepts explicit candidate identity, `--run-dir`, `--state-dir`,
`--audit`, `--task-contract`, `--config`, and `--schema-dir`. Run records use the
classic names: `audit-verification.json`, `verification-request-N.json`,
`verification-task-contract-N.md`, `verification-policy-N.json` and
`evidence-manifest.json`; the state directory holds `review-policy/ledger.json`
and its optional lock. An audit's adjacent `.pre-normalize.json` is also
checked when present. Policy environment overrides must be supplied using
`--policy-env-json`; ambient configuration is ignored. `--trusted-shell`,
`--legacy-schema-mode` and `--require-audit` carry the remaining driver inputs.
All five policy inputs (`--config`, `--policy-env-json`, `--trusted-shell`,
`--legacy-schema-mode`, `--require-audit`) are required, including explicit empty
values where appropriate. Omitting any is a usage error.
Standalone checks write nothing. Only `--driver-records` requests the existing
`acceptance-check.json` and `.err` files, after the same structural prechecks
or on a usage error. Tests cover both diagnostic paths.

The test generates a compact manifest above 1 MiB: valid content passes structure
and certificate checks; an invalid digest is refused for its content. File input
avoids the former command-line size limit, as ruled in I-10.

The schema checker deliberately retains the classic keyword subset. Adding
validation for unsupported schema keywords would change acceptance behavior.
