# state.json schema (schema_version: 1)

> SSOT for the per-session state file written to `docs/refinement/mangchi/<slug>/state.json`.
> Initialised by `scripts/preflight.sh`; every round appends to `rounds[]` and `issues[].history[]`.

```json
{
  "schema_version": 1,
  "mangchi_version": "0.4.0",
  "slug": "src-routes-auth-py",
  "target_basename": "auth.py",
  "started_at": "2026-04-16T10:00:00Z",
  "self_review_mode": false,
  "no_verify_mode": false,
  "axes_opt_in": [],
  "start_axis": "correctness",
  "gate_cmd": null,
  "rounds": [
    {
      "n": 1,
      "axis": "correctness",
      "verdict": "REVISE",
      "no_changes_suggested": false,
      "diff_loc": 18,
      "codex_tokens": {"review": 15234, "verify": 4821, "estimate_only": false},
      "ended_at": "..."
    }
  ],
  "issues": [
    {
      "id": 1,
      "first_seen_round": 1,
      "axis": "correctness",
      "title": "null check missing",
      "locus": "auth.py:42-45",
      "severity": "HIGH",
      "confidence": "HIGH",
      "history": [
        {
          "round": 1,
          "action": "ACCEPT | REJECT | FORCED_ACCEPT",
          "reason": "... (REJECT는 file:line citation 포함)",
          "diff_verified": true,
          "verification": {"verdict": "AGREE | DISAGREE", "reason": "..."}
        }
      ],
      "status": "RESOLVED | PENDING | FORCED_ACCEPT"
    }
  ],
  "codex_tokens_total": 20055,
  "forced_accept_count": 0,
  "force_accept_threshold": 2,
  "last_invalid_codex_output": null,
  "status": "active | converged | aborted",
  "termination_reason": null
}
```

## Field notes

- `axes_opt_in`: values of `--include-axes` (`necessity`, `robustness`).
- `mangchi_version`: written by `scripts/preflight.sh` since 0.4.0. `codex-run.sh` refuses a session whose state.json lacks it (a 0.3.x session) and prints the migration steps: write `round-(N-1).carryover.md` from this file, move aside any `round-N.codex.txt` that has no `.json`, then add the field.
- `target_basename`: the original file name. The working copy is always `updated.<ext>`, so `codex-run.sh` re-checks this name against the credential-file list on every call.
- `rounds[].codex_tokens`: copied from the result JSON `scripts/codex-run.sh` writes next to each answer (`round-N.codex.txt.json` / `round-N.verify.txt.json`), field `tokens.call_total`. That total includes every earlier attempt of the same call (`tokens.prior_total`: the schema retry's first attempt, a re-run after a timeout), so the 500K guard sees them. `estimate_only` is true when Codex CLI reported no usage (the `tokens used` footer after the echoed prompt) and the `char/4*1.3` estimate of the assembled prompt was used.
- `issues[].status`: `RESOLVED` (closed) / `PENDING` (carried over, incl. no-op ACCEPT) / `FORCED_ACCEPT` (2 consecutive DISAGREE).
- `issues[].history[].diff_verified`: result of the Phase 5 `git diff -w --numstat` ±5-line locus check.
- `termination_reason`: one of `verified_rounds` / `two_pass` / `r5_cap` / `gate_pass` / `user_stop` / `aborted_token_budget` / `aborted_forced_accept` / `aborted_codex_schema` / `aborted_context_window` / `aborted_gate_failed` / `aborted_no_termination_path`.
- Legacy (pre-0.2.0) sessions have no `schema_version`; `--continue` prints a warning and maps `verdict: BLOCK` → `REVISE + severity: HIGH`. 0.2.x-0.3.x sessions have `schema_version` 1 but no `mangchi_version`: see `mangchi_version` above.
