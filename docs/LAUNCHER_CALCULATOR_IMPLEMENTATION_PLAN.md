# Issue #2: launcher calculator

Status: implemented locally, 2026-09-25. The evaluator, launcher integration,
clipboard copy, continuation, advanced functions, and native test target are in
place. See [validation evidence](../artifacts/launcher-calculator/README.md) and
[user documentation](DESKTOP.md#calculator).

Issue: [Add calculator for launcher](https://github.com/Seafoam-Labs/pearl/issues/2).
The issue links to [Alfred's calculator](https://www.alfredapp.com/help/features/calculator/).
It requests a calculator inside the existing launcher. The behavior below defines Pearl's implementation; the issue does not specify
detailed requirements.

## Outcome and scope

Type `12 * (3 + 4)` into Pearl's launcher, see `84` as the first result, and
press Enter to copy it. Typing a trailing `=` replaces the expression with its
answer so calculation can continue. A leading `=` explicitly selects calculator
mode, including named functions such as `=sqrt(81)`.

Alfred provides calculation results in its search field, clipboard copying,
trailing-equals continuation, an explicit advanced mode, and configurable number
formats. These interactions inform this plan. Pearl uses its existing GTK
launcher and native clipboard service, with a bounded Zig evaluator.

Deliver basic arithmetic, copying, continuation, and a documented advanced
subset. Locale-dependent numbers, currency-symbol stripping, unit/currency
conversion, stored variables/history, and full Alfred function compatibility
remain follow-ups. File search, workflows, and a general launcher redesign are
outside issue #2. No Aqueous changes, subprocess calculator, external math
library, new control protocol, or preference migration are expected.

## Initial integration points

| Component | Integration |
| --- | --- |
| `src/desktop/launcher.zig` | Owns app/window results, immutable search jobs, keyboard handling, activation, and virtualized GTK rows. Add a calculator result and calculator status here. |
| `src/desktop/apps.zig` | Shares the GIO catalog and limits admitted search jobs to two across the process. Preserve these limits and app discovery behavior. |
| `src/desktop/policy.zig` | Ranks application/window matches. Keep their relative order; place a valid calculation before those matches. |
| `src/services/clipboard.zig` | Owns bounded clipboard history and native selection publication. Extend with a small text-copy operation using the existing ownership path. |
| `src/ui/surfaces/manager.zig` | Creates launchers and owns clipboard privacy synchronization. Supply the launcher with a copy callback that synchronizes privacy immediately before copying. |
| `src/tests.zig`, `build.zig` | Pure test imports and private Aqueous integration targets. Register calculator tests and a focused integration target. |
| `tests/integration/test_desktop.py`, `test_clipboard_capture.py` | Existing discovery/activation, private input, clipboard interoperability, and lifecycle fixtures to reuse. |

The launcher currently bounds queries to 512 UTF-8 bytes and shows at most 200
results. Jobs retain their catalog and copied window state. Generation/session
checks reject stale activation, and Enter can wait for a pending search. Extend
these contracts to calculation and continuation rather than adding an independent
result path with different freshness rules.

## Interaction contract

| Input/action | Behavior |
| --- | --- |
| `12 * (3 + 4)` | First selectable row: `84`; subtitle identifies a calculation and says Enter copies. Matching applications/windows may follow. |
| `42`, `Firefox`, `1password`, `org.app`, `/tmp/file` | Ordinary search; a bare number is not an implicit calculation. |
| `=42`, `=sqrt(81)` | Explicit calculator mode, yielding `42` and `9`. Do not show app/window matches. |
| `2 +`, `=sqrt(` | Incomplete expression; no actionable calculator result. Explicit mode shows a quiet completion hint. |
| `=1 / 0`, `=sqrt(-1)` | Nonselectable, translated error explaining division by zero or the function domain. |
| `=unknown(2)`, `=2(3)` | Unsupported syntax; never partially evaluate or execute text. |
| Enter/click on a calculator row | Copy only the displayed number to the regular clipboard; dismiss after the service accepts publication. |
| Copy unavailable or privacy gate closed | Keep the launcher open with a specific message; never report success or launch another result as fallback. |
| `12 * 7=` | Replace with `84`, keep focus and caret at the end, and do not copy or dismiss. |
| `=sqrt(81)=` | Replace with `=9`, preserving explicit calculator mode. |
| Up/Down, Escape, Ctrl+C | Preserve existing navigation/dismissal and native entry selection/copy behavior. Enter is the calculator copy action. |

For implicit detection, require a numeric start (optionally signed or parenthesized),
at least one binary operator, and tokens drawn entirely from the basic arithmetic
grammar. A leading slash is ordinary search. A leading `=` always opts in. Named
functions/constants require explicit mode so application names remain searchable.
Numeric expressions such as `2026-09-25` are arithmetic; matching search results
remain available below. Arbitrary mixed text never produces a partial result.

Implicit incomplete/invalid calculations keep normal search results and do not
replace the footer with a loud error. Remove the old calculator row immediately
on edits; if older app/window rows remain visible while searching, activation
must still reject their generation. Explicit errors cannot leave an old answer
selected or copyable.

Recognize trailing `=` from the edited text, including paste and keypad input,
only at the end of a complete valid expression. It must not interfere with IME
composition or insertion inside text. Consume it exactly once after successful
evaluation. An invalid expression keeps its text and cannot reuse an old answer.
Do not replace the query if the user edits or moves the caret before completion.

The result uses existing launcher row typography, a bundled symbolic calculator
icon, and a localized accessible description identifying the expression, answer,
and copy action. Update placeholder/footer text to include calculation. Preserve
Material/native GTK themes, text scaling, density, and English/German labels.

## Evaluation contract

Add `src/desktop/calculator.zig` as a GTK-independent lexer, parser, evaluator,
and formatter. Return typed outcomes: not applicable, incomplete, value, or
diagnostic. Diagnostics carry an error kind and byte position; localize them at
the UI boundary. Require full input consumption.

Initial grammar:

- Decimal literals (`12`, `.5`, `1.25`) and scientific notation (`1e3`, `2e-3`).
- Parentheses, unary `+`/`-`, binary `+`, `-`, `*`, `/`, and exponentiation `^`.
- Usual precedence, right-associative powers: `2^3^2 = 512`, `-2^2 = -4`,
  and `2^-2 = 0.25`.
- ASCII whitespace is accepted between tokens. Decimal separator is always `.`,
  with no grouping separators. Reject commas and currency symbols with guidance
  in explicit mode; never silently reinterpret `1,234`.

Advanced subset, in explicit mode:

- Constants `pi` and `e`; case-insensitive ASCII identifiers.
- Single-argument `abs`, `sqrt`, `exp`, `ln`, `log` (base 10), `log2`, `sin`,
  `cos`, `tan`, `asin`, `acos`, `atan`, `ceil`, `floor`, `round`, and `trunc`.
- Trigonometric angles are radians. Define `round` as ties away from zero.
- `mod(a,b)` provides remainder with the sign of the dividend; a zero divisor
  fails. Neither infix `%` nor a percentage suffix is accepted initially,
  avoiding an ambiguous percent/modulo interpretation.

Use `f64` with explicit finite/domain checks. Division by zero, invalid real
powers, invalid function domains, literal overflow, and nonfinite results are
diagnostics. Underflow follows `f64` behavior. This is approximate arithmetic,
not arbitrary-precision or financial decimal arithmetic; document this in user
help. Test large integers and precision boundaries so approximation is deliberate.

Format finite results with up to 15 significant decimal digits, trimming trailing
fractional zeros and normalizing negative zero. Use scientific notation outside
the readable fixed-point range (nonzero magnitude below `1e-6` or at
least `1e15`). Display, copy, and continuation use the same string, so continued
calculation starts from the visible rounded value. Ensure every formatted value
is valid parser input, including negative values and exponent notation. At the
largest finite `f64` boundary, round downward when rounding upward would overflow
on reparse.

Bound the evaluator independently of UI validation: 512 input bytes, 256 tokens,
32 nested parser calls, 256 evaluation operations, and a 128-byte result buffer.
Count unary/power recursion as well as parentheses toward the depth limit.
Reject excess deterministically. Use a small Pratt or recursive-descent parser
with bounded storage; never call a shell, eval engine, network, or filesystem.

## Search, activation, and clipboard integration

1. Evaluate the original copied query in the existing worker, before Unicode
   folding used for application search. Store the typed outcome and formatted
   text in the job's arena. Explicit mode skips app/window ranking but uses the
   same admitted-task, cancellation, completion, and teardown machinery.
2. Extend `Hit` with an explicit calculator payload/kind. Update sorting,
   binding, selection identity, accessibility, and activation exhaustively.
   Calculator results never index into the application catalog or update recent
   applications. A missing/loading app catalog must not prevent evaluation.
3. Retain the pending action's query generation and action kind (copy or
   continue). Only a completion matching that query and current session may
   satisfy it. Edits clear the action; background refresh of the same query can
   rebind it to the latest generation. Repeated Enter must not double-copy.
   Preserve deferred app/window activation behavior and test it as a regression.
4. Revalidate current query, generation, session, and lock state immediately
   before copy/continuation. Closing, output removal, session loss, or teardown
   cancels the action; late callbacks only release owned resources.
5. Pass a typed copy callback through `Launcher.create`. Its manager-side
   implementation calls `syncClipboardPrivacy()` before invoking the service.
   Do not use `GdkClipboard` as a second selection owner or spawn `wl-copy`.
6. Add a service operation such as `copyText(bytes)` that checks availability,
   validates text, handles deduplication, and publishes through the same native
   source path as `select`. Today `add` returns no ID and a duplicate is not
   moved to the front: never assume `entries[0]` is the newly requested value.
   Refactor a private helper to return the exact retained ID if appropriate.
7. Prepare resources before replacing the old owned selection. On failure,
   preserve the previous selection and leave the calculator available to retry.
   Once copied, retain payload ownership independently of the popup/job arena
   so closing the launcher cannot invalidate a later paste. Copy acceptance is
   a selection request, not proof that another application pasted the result.

Successful copies use ordinary bounded, memory-only history. Expressions are
not stored as history or logged; retain existing status/log payload boundaries.
Lock/authentication/inactive-session cleanup continues through the clipboard
service. Do not queue a copy for replay after unlock.

## Implementation sequence and acceptance

### P1 — pure calculator core

Implement classification, arithmetic parser, formatter, and resource limits in
`src/desktop/calculator.zig`; import its tests from `src/tests.zig`.

Exit: table-driven tests cover precedence/associativity, signed exponents,
scientific notation, incomplete vs invalid input, divide-by-zero, overflow,
underflow, negative zero, formatting and continuation round trips, every limit,
and ordinary application queries. Seeded malformed-input tests prove bounded
completion without panics. A 512-byte expression must not trigger unbounded work.

### P2 — launcher result and native copy

Wire calculator results into `launcher.zig`, copy through `manager.zig` and
`clipboard.zig`, and add the icon to `resources/pearl.gresource.xml`. Update row
labels, placeholder, footer, and translations through the existing `tr` path.

Exit: `12*(3+4)` displays `84`; Enter and pointer activation both publish exactly
`84`, then dismiss. An independent clipboard client can paste after dismissal.
Duplicate history entries copy the intended number. Clipboard failure preserves
the popup and prior selection. App/window ranking and activation still pass.

### P3 — continuation and advanced functions

Add explicit mode's function table and trailing-equals handling, including
query-bound pending actions and caret/composition checks. No settings UI is
required for the documented fixed grammar.

Exit: `12*7=` becomes `84`, then `+6` yields `90`; `=sqrt(81)=` becomes `=9`.
Every documented function has value/domain tests. Invalid or stale expressions
cannot copy, replace the entry, or activate an unrelated application. Native
keyboard and pasted trailing-equals paths agree.

### P4 — regression, accessibility, and documentation

Add `tests/integration/test_launcher_calculator.py` and a
`test-launcher-calculator` build target using private Aqueous/input/clipboard
fixtures. Add only test-build instrumentation where deterministic worker delays
or private diagnostics are necessary; do not expose expression content through
the production CLI.

Cover rapid edits followed by Enter/equal, canceled jobs, two-output job pressure,
popup close/reopen, app catalog refresh/failure, output removal, lock, session
disconnect, polkit inhibition, copy failure, and clipboard publication lifetime.
Verify a query becoming invalid never reuses its earlier successful result.

Capture calculator success, incomplete, and error states in Material dark/light
and native GTK modes, with larger text and English/German labels. Check keyboard
focus and accessible result/action descriptions; report any real screen-reader
checks still pending separately. Retain evidence under
`artifacts/launcher-calculator/` once implementation is tested.

Preserve existing launcher targets: search p95 below 50 ms over the 2,000-app
fixture and warm opening below 100 ms on the documented test setup. Measure
calculator query-to-paint on the same setup; acceptance uses the same 50 ms
search budget and requires no new worker or subprocess per keystroke.

Update `docs/DESKTOP.md` with syntax, copy/continuation, decimal-format limits,
and approximate numeric behavior. Update clipboard documentation for the new
producer, and the README entry when implementation status changes.

Validation commands:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test -Doptimize=ReleaseSafe
PEARL_TEST_AQUEOUS_PREFIX="$PWD/.cache/aqueous-activity-production" ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-launcher-calculator -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-desktop -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-clipboard-capture -Doptimize=ReleaseSafe
```

Issue #2 is ready to close when P1–P4 pass and evidence demonstrates actual
paste interoperability, freshness under rapid input, and preserved launcher
behavior. Full Alfred numeric-format and function parity is not a closure gate.


## Delivery notes

P1–P4 are implemented. Pure tests include each documented function, parser
limits, 10,000 seeded malformed inputs, and 10,000 finite-number formatting
round trips. Native tests use real keyboard/pointer input and independent
clipboard consumers; deterministic delayed jobs exercise input, caret, output,
and authentication races. Copy errors persist across background refresh until
editing or a successful retry.

The calculator suite uses the current pinned Aqueous build. Its output-loss
check uses the output-power protocol: the pinned compositor's output-management
configuration path has an unrelated assertion. The existing desktop and
clipboard/capture regression suites use their default legacy private fixture.
The feature requires no compositor changes. Detailed results and remaining
physical screen-reader/IME qualification are recorded with the evidence.
