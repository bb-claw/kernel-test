# LLD + OBJCOPY — Plan

Branch: `fix/lld-objcopy`
Start date: 2026-09-26

---

## Situation

`feat/lld-linker` (PR #80) added `LD=ld.lld` to all kernel builds when LLD ≥ 17.0.1 is
present. On Hetzner staging with LLD 18.1.8 just installed, x86_64 and i386 build correctly,
but arm64 and riscv fail at the final `OBJCOPY vmlinux` step:

```
aarch64-linux-gnu-objcopy: vmlinux: file format not recognized
```

Confirmed LLD-specific: `USE_LLD=0 make build ARCHS=arm64` passes in 12s; with LLD it fails.

**Root cause:** LLD 18 emits arm64 ELF with section types (e.g. `SHT_LLVM_ADDRSIG`,
new relocation entries) that `aarch64-linux-gnu-objcopy` from Debian bookworm binutils 2.40
does not recognise. x86_64/i386 native ELF is unaffected. The kernel handles this
automatically when `LLVM=1` (full Clang toolchain) by substituting `OBJCOPY=llvm-objcopy`;
with only `LD=ld.lld` the substitution does not happen.

A second independent failure: `ccache: error: Could not find compiler "riscv64-linux-gnu-gcc"
in PATH` on Hetzner. The Ansible `kernel-test` role never installed the riscv cross-compiler.

---

## Problems to Solve

1. **LLD + arm64/riscv build failure** — `OBJCOPY=llvm-objcopy` must accompany `LD=ld.lld`
   for cross-compiled arches; missing on Hetzner.
2. **Missing riscv cross-compiler on Hetzner** — `gcc-riscv64-linux-gnu` not installed by
   the Ansible role.

---

## Goals

1. When `llvm-objcopy` is available and LLD is active: pass `OBJCOPY=llvm-objcopy` to all
   `kmake()` calls so all four arches link correctly with LLD.
2. When `llvm-objcopy` is absent and LLD is active: use LLD for x86_64/i386 (native ELF
   works with GNU objcopy); fall back to BFD for arm64/riscv; warn in preflight.
3. Add `llvm-18` (provides `llvm-objcopy-18`) and `gcc-riscv64-linux-gnu` /
   `binutils-riscv64-linux-gnu` to the Ansible `kernel-test` role.
4. CI tests cover: objcopy present/absent × preflight output + kmake-args logic.

---

## Scope

Files changed:
- `lib/build.sh` — detect `llvm-objcopy` after `detect_lld()`; set `LINKER_OBJCOPY`;
  update `kmake()` to conditionally add `OBJCOPY=` and gate cross-arch LLD
- `lib/preflight.sh` — add second warning line when `llvm-objcopy` absent
- `tests/ci/test-lld.sh` — 5 new test cases
- `docs/lld-objcopy-plan.md` — this file

Ansible (homelab repo — not tracked here, documented for reference):
- `ansible/roles/kernel-test/tasks/main.yml` — add `llvm-18`, `gcc-riscv64-linux-gnu`,
  `binutils-riscv64-linux-gnu` to the existing apt task; add `update-alternatives` task
  for `llvm-objcopy → llvm-objcopy-18`

No changes to: `lib/common.sh`, `lib/report.sh`, `Makefile`, CI infrastructure.

---

## Non-goals

- Full LLVM toolchain (`LLVM=1`, `COMPILER=clang`) — already separate, unaffected.
- Checking `llvm-objcopy` version — any version that exists is adequate; the ELF
  format mismatch is with GNU objcopy, not a version floor issue.
- Fixing the ccache PATH issue for riscv — the failure is a missing package, not PATH.

---

## Design decisions

### LINKER_OBJCOPY variable in build.sh

A single `LINKER_OBJCOPY` variable (empty or `"llvm-objcopy"`) set once after `detect_lld()`
keeps the per-call kmake logic minimal. The alternative (checking `command -v llvm-objcopy`
inside kmake on every invocation) is equivalent but runs the check ~18 times per build.

### Scope: all arches, not cross-arch only

When `LINKER_OBJCOPY` is set, `OBJCOPY=llvm-objcopy` is applied to all arches including
x86_64/i386. This matches what `LLVM=1` does and avoids per-arch branching in the happy
path. `llvm-objcopy` handles all ELF targets and is a drop-in replacement for GNU objcopy.

### Gate arm64/riscv out of LLD when llvm-objcopy absent

Rather than letting the build run and fail at the OBJCOPY step (as before), the harness
skips `LD=ld.lld` for non-x86 arches when `LINKER_OBJCOPY` is empty. The decision uses
`$ARCH` which is already in scope inside `kmake()`. This preserves the x86 speedup on
hosts that have lld but not llvm-18.

### Second preflight line, not inline suffix

A separate `Preflight: llvm-objcopy not found — arm64/riscv will use BFD` line is easier
to grep in CI and matches the existing pattern where each condition gets its own
`Preflight:` line. The inline suffix form would require changing the LLD detection line.

### Ansible: llvm-18 rather than llvm

`llvm-18` is pinned to the same major as `lld-18` (already installed from apt.llvm.org).
The unversioned `llvm` package on bookworm resolves to llvm-14 (provides `llvm-objcopy`
at 14.x — too old to handle LLD 18 ELF output reliably). Pinning to -18 keeps the toolchain
version coherent.

---

## Implementation

### lib/build.sh

After the `detect_lld()` block (line 53–57), add:

```bash
LINKER_OBJCOPY=""
if [[ "$LINKER" == lld ]]; then
    command -v llvm-objcopy >/dev/null 2>&1 && LINKER_OBJCOPY="llvm-objcopy"
fi
```

Replace line 128 in `kmake()`:

```bash
# Before:
[[ ${LINKER:-bfd} == lld ]] && make_args+=( LD=ld.lld )

# After:
if [[ ${LINKER:-bfd} == lld ]]; then
    if [[ -n "${LINKER_OBJCOPY:-}" ]]; then
        make_args+=( LD=ld.lld OBJCOPY="$LINKER_OBJCOPY" )
    elif [[ "$ARCH" == x86_64 || "$ARCH" == i386 ]]; then
        make_args+=( LD=ld.lld )
    fi
fi
```

### lib/preflight.sh

After `printf 'Preflight: LLD %s ≥ %s — using ld.lld\n'`, add:

```bash
if ! command -v llvm-objcopy >/dev/null 2>&1; then
    printf 'Preflight: llvm-objcopy not found — arm64/riscv will use BFD\n'
fi
```

### Ansible tasks/main.yml (homelab repo)

```yaml
- name: Install kernel build dependencies not covered by make bootstrap
  apt:
    name:
      - libssl-dev
      - dwarves
      - llvm-18               # provides llvm-objcopy-18 for LLD arm64/riscv builds
      - gcc-riscv64-linux-gnu  # riscv cross-compiler
      - binutils-riscv64-linux-gnu
    state: present
    update_cache: false

- name: Register llvm-objcopy-18 as llvm-objcopy alternative
  alternatives:
    name: llvm-objcopy
    path: /usr/bin/llvm-objcopy-18
    link: /usr/bin/llvm-objcopy
    priority: 100
```

---

## Testing strategy

### New CI tests (tests/ci/test-lld.sh, 5 additions)

- **preflight: llvm-objcopy present → no objcopy warning line** — run preflight with
  stubbed `ld.lld` (22.1.8) and a stub `llvm-objcopy`; check output does NOT contain
  "llvm-objcopy not found".
- **preflight: llvm-objcopy absent → warning line printed** — run preflight without
  `llvm-objcopy` in stub PATH; check output contains "llvm-objcopy not found".
- **kmake-args: LLD + objcopy present → OBJCOPY=llvm-objcopy in args** — inline
  replication of the kmake conditional; verify both LD and OBJCOPY are set.
- **kmake-args: LLD + no objcopy, ARCH=x86_64 → LD set, no OBJCOPY** — inline
  replication; verify LD=ld.lld present, OBJCOPY absent.
- **kmake-args: LLD + no objcopy, ARCH=arm64 → neither LD nor OBJCOPY** — inline
  replication; verify make_args is empty (BFD path).

---

## Testing commands

```sh
# Verify preflight on a host with llvm-objcopy
make preflight
# Expected: "Preflight: LLD X.Y.Z ≥ 17.0.1 — using ld.lld"
# Expected: no "llvm-objcopy not found" line

# Verify degraded mode (simulate absent llvm-objcopy)
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v llvm | tr '\n' ':') make preflight
# Expected: "Preflight: LLD X.Y.Z ≥ 17.0.1 — using ld.lld"
# Expected: "Preflight: llvm-objcopy not found — arm64/riscv will use BFD"

# Verify arm64 builds after Ansible deploys llvm-18
make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=arm64
# Expected: Build OK: tinyconfig / arm64

# Full CI gate
make lint
make ci-test
```
