# Windows port — phase 2 results

Companion to [`windows-port.md`](windows-port.md),
[`windows-port-phase0.md`](windows-port-phase0.md), and
[`windows-port-phase1.md`](windows-port-phase1.md).

Phase 2 covers execution and process semantics. Most of it is delivered; the
part that cannot be proven without a Windows host is named as such below, and
the `background_processes` capability stays off because of it.

## The "never executed" gap is closed

Phase 1 ended with a binary nobody had run. That is no longer true: `wine64`
installs in this environment and runs the Windows build.

```
./scripts/wine-smoke.sh
ok   --version          6 bytes stdout, empty stderr
ok   help               3393 bytes stdout, empty stderr
ok   status --json      574 bytes stdout, empty stderr
```

Those are the same assertions the native jobs make in
`.github/workflows/full-ci.yml` — populated stdout, completely silent stderr.
`status --json` reports `"workspace":"Z:\\home\\user\\fx"`, which means path
canonicalization is producing correctly shaped Windows paths at runtime,
exercising the `windowsHandlePathAlloc` code two reviewers flagged in phase 1.

**Wine is not Windows.** It is a reimplementation, and its fidelity is weakest
in precisely the areas this port cares about most: Job Objects, ACLs, and
console behavior. A failure under wine is always real; a pass is suggestive.
`scripts/wine-smoke.sh` says so in its own header so nobody reads a green run
as a substitute for the `windows-latest` job.

## Job Objects

`src/core/execution/windows_job.zig` is the Windows counterpart of the
process-group teardown this codebase uses on POSIX. Windows has neither
process groups nor signals, so `kill(-pgid, …)` has no translation; a Job
Object is the equivalent containment primitive, because descendants inherit
membership and terminating the job takes the whole tree.

The job is created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, which turns out
to simplify the wiring considerably: closing the last handle kills whatever is
still inside. The execution path therefore gets tree teardown from ordinary
scope exit rather than by threading a handle through every signature between
the spawn site and the termination logic.

Two things worth knowing for anyone extending this:

- The Job Object API is **not** declared in `std.os.windows` as of Zig 0.16.0,
  so it is bound here, as `GetFinalPathNameByHandleW` was in phase 1.
- `windows.BOOL` is a **non-exhaustive enum, not an integer**. Comparing it
  against `0` does not compile, and comparing against `1` would be wrong
  because every nonzero value is truthy. Use `.toBool()`.

### The race this does not close

`std.process.spawn` does not expose `CREATE_SUSPENDED`, so a child is assigned
to its job a moment *after* it starts running. A process that forks a
descendant inside that window and exits leaves that descendant outside the
job. The POSIX path has no equivalent gap, because `pgid` is applied by the
spawn itself. Closing this needs suspended-start support in the spawn layer,
and it is a real correctness difference rather than a cosmetic one.

## Execution path

`executeRawInvocation` no longer refuses on Windows, so foreground commands
reach the process layer. The architecture already split isolated (POSIX
`setsid`) from unisolated execution and routed Windows to the latter, which
made this far less invasive than the phase 0 audit predicted — the unisolated
path now creates a job, assigns the child, and closes the job on the way out.

`command_effect.plan` still routes every Windows command to the approval path,
which remains the intended v1 behavior.

## PowerShell

`shell_resolver` understood only `bash` and `zsh` at absolute POSIX paths. It
now recognizes `powershell` and `pwsh`, with or without the `.exe` suffix and
case-insensitively, since Windows filenames are case-insensitive and
configuration may omit the extension. Path classification splits on either
separator so a Windows shell path can be classified — and tested — from POSIX.

The invocation is `-NoLogo`, then `-NoProfile` only for a clean start, then
`-NonInteractive -Command` with the command text last. **`-Command` must come
last**: PowerShell treats everything after it as part of the command.

Windows has no passwd database to read a login shell from, so the system
PowerShell 5.1 path stands in as the default. PowerShell 7 (`pwsh.exe`) is
recognized but never chosen, because it is not preinstalled on Windows — that
settles one of the open questions from the original plan.

## Verification

Baseline and branch were measured **in the same environment at the same time**,
which matters more than it sounds: see the note below.

| | total | pass | skip | fail |
| --- | --- | --- | --- | --- |
| `main` 9d184f9 | 8606 | 8555 | 21 | 30 |
| phase 2 | 8617 | 8566 | 21 | 30 |

The failing sets are **identical** — both `comm` directions are empty. `+11`
total and `+11` pass are exactly the new tests: six for shell resolution, five
for the Job Object ABI.

Also green: `zig fmt --check src/`, the native ReleaseSafe build, the native
smoke test, and the Windows build.

### On the baseline number

Phase 1 recorded 30 pre-existing failures as 29. That number was measured at
`ef6eb04` several hours earlier; the container drifted in between, and one
additional environment-sensitive test began failing. The clearest example of
that whole class is a planner test that compares a login shell's output
against direct execution and now sees `nvm\nx` instead of `x`, because
`/etc/profile.d/nvm.sh` prints on login-shell startup. It is image
configuration, not product behavior.

The lesson is procedural: compare failing **sets** against a baseline run in
the same environment at the same time. A count carried over from an earlier
run is not a baseline, and quoting one invites chasing a regression that does
not exist.

## What is not done

- **`background_processes` stays off.** The provider on Windows is still the
  unavailable one. Flipping it requires proving tree termination, which needs
  a Windows host.
- **Timeout-driven tree termination is unproven.** The code is written and the
  containment primitive is correct by construction, but wine cannot arbitrate
  Job Object semantics, so nothing here demonstrates that a timed-out command
  actually takes its descendants down.
- **The spawn-to-assignment race is open**, as described above.
- **End-to-end command execution on Windows is untested.** It needs both a real
  PowerShell and a configured gateway key; wine's PowerShell is a stub that
  accepts the flag sequence without implementing the cmdlets.
- **`verifies_confidentiality` is still false.** See below.

## On the Windows DACL check

This remains the open security item from phase 1, and it is deliberately still
open. The two failure directions are not symmetric. A check that is too
permissive is a silent hole — no worse than the current `return true`. A check
that is too restrictive makes every private-state read fail, which breaks
config and auth outright on Windows.

Wine cannot arbitrate: its security model is a stub that would return a
confident answer meaning nothing. Writing roughly a hundred and fifty lines of
SID-comparison logic that has never executed would look like closing the gap
while making it harder to see.

The recommendation is to land it against phase 5's `windows-latest` runner,
where both directions can be proven on the first attempt. The seam is already
shaped for it: one constant and three predicates in
`src/core/shared/file_permissions.zig`, with a test pinning the constant per
platform so the gap cannot quietly become an assumption.
