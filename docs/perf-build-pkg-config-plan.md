# perf-build pkg-config dep — Plan

Branch: `fix/perf-build-pkg-config`
Start date: 2026-09-25

---

## Situation

`make perf-build` fails on fresh Debian/Ubuntu cloud images (e.g. hetzner-staging) with:

```
Makefile.config:191: *** Error: pkg-config needed by babeltrace2 is missing
```

`tools/perf/Makefile.config` hard-errors when `pkg-config` is absent, even when
`libbabeltrace2-dev` itself is not installed. The detection step requires `pkg-config`
to probe for babeltrace2; without it the build stops unconditionally.

---

## Problems to Solve

1. **`pkg-config` absent from bootstrap apt list** — `make bootstrap` on Debian/Ubuntu does
   not install `pkg-config`, so fresh cloud images miss it; `make perf-build` fails hard.

---

## Goals

1. `make perf-build` succeeds on a fresh Debian/Ubuntu install after `make bootstrap`.

---

## Scope

Files/components changed:
- `lib/bootstrap.sh` — add `pkg-config` to the apt-get install list
- `Makefile` — update the `perf-build` comment to mention `pkg-config`

No changes to: the perf build invocation itself, `NO_PERF_BUILD` logic, Arch bootstrap
(Arch's `pkgconf` is a transitive dep of `libelf` and already present).

---

## Non-goals

- Installing `libbabeltrace2-dev` (CTF trace format not needed for our perf tests)
- Passing `NO_BABELTRACE2=1` to suppress the check (would hide other pkg-config failures)

---

## Design decisions

### Install pkg-config, don't suppress the check

`NO_BABELTRACE2=1` would bypass the hard-error without installing the tool. But
`pkg-config` is a standard build-time dependency used by many other libraries perf
probes for (libunwind, libdw, etc.). Installing it is the right fix; suppressing the
check would mask future missing-tool failures.

---

## Testing strategy

- **Manual** — `make perf-build` on a fresh Debian VM after `make bootstrap` (can't
  replicate in CI without a Docker/VM environment)
- **Existing CI** — `test-programs-build.sh` + `make dev-test` verify bootstrap doesn't
  break the existing build pipeline

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths

make perf-build
# Expected: PASS (on this host, pkg-config already present)
```
