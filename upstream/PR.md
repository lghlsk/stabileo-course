# PR 제출용 자료

아래 **제목**과 **본문**을 GitHub PR 작성 화면에 그대로 붙여넣으시면 됩니다.

---

## 제목

```
fix(dsm): nodal loads reach the load vector as NaN in the step-by-step solver
```

---

## 본문

```markdown
### What happens

In Advanced → step-by-step (DSM) wizard, every result from step 7 onwards
is `NaN` whenever the model has a nodal load. Steps 1–6 look fine on
screen, so the problem appears to start at the solution step.

Reproduced on a three-node frame with a single horizontal nodal load:

| step | | 
|---|---|
| 2 — local stiffness | clean |
| 3 — transformation | clean |
| 4 — global assembly | clean |
| **5 — load vector** | **2 NaN** |
| 6 — partition | 2 NaN |
| **7 — displacements** | **all NaN** |
| 8 — reactions | all NaN |

The load vector was `[0, 0, 0, 10, NaN, NaN, 0, 0, 0]` — `fx` arrived,
the other two components did not.

### Why

`solveDetailed` destructures nodal loads as `{ fx, fy, mz }`:

```ts
const { nodeId, fx, fy, mz } = load.data;
```

`SolverNodalLoad` is `{ fx, fz, my }` — the names adopted when the 2D
solver moved from (x, y) to (x, z). `fy` and `mz` are `undefined`.

Three guards should have stopped it and none did, all for the same
reason — comparisons against `NaN` are false:

1. `if (Math.abs(val) < 1e-15) return;` in `addLC`. `Math.abs(undefined)`
   is `NaN`, so the term was not skipped as a zero. It was added to the
   vector, making it `NaN`.
2. `if (maxVal < singularityTol) throw` in `solveLU`. A matrix carrying
   `NaN` passed the pivot check and returned `NaN` instead of raising
   `detailed.singularMatrix`.
3. The final pivot check, same shape.

`svelte-check` does flag the two property accesses, but they sit among
pre-existing errors in the same file, so they were easy to miss.

This is the same class of defect as the one recorded in the comment at
the top of `solver-detailed.ts` — `nodeDistance` reading `b.y - a.y`
after the rename. That call site was fixed; this one was not.

### Changes

- Destructure `{ fx, fz, my }` and pass them through.
- `Number.isFinite(val)` in `addLC`, before the magnitude test, so a
  missing term can never reach the vector.
- Both singularity checks written as `!(a >= b)`, true for `NaN` as well
  as for genuinely small pivots. A poisoned matrix now raises instead of
  returning `NaN`.

### Test

There was no test on the nodal-load path — only
`solver-detailed-load-vector.test.ts`, which covers distributed loads.
That gap is why this survived, so the PR adds the missing pair.

`solver-detailed-nodal-load.test.ts` uses a cantilever with a tip load:

- no `NaN` in `F`, `Ff`, `FfMod`, `uFree`, `uAll`, `reactionsRaw`
- the vertical component appears exactly once in the load vector
- tip deflection matches `PL³/3EI` to 8 decimal places
- reactions are finite

Verified on the reproducing model as well: the load vector becomes
`[0, 0, 0, 10, 0, 0, 0, 0, 0]` and the reactions `-10, -10, +10`, which
is equilibrium — the 10 kN horizontal load returns as a horizontal
reaction, and the 100 kN·m it produces at 10 m height is resisted by a
±10 kN couple over the 10 m span.

The Rust solver is unaffected; this is the TypeScript teaching path only.

`npm run test` needs `npm run wasm` first in a fresh checkout, so I ran
the two `solver-detailed` suites in isolation: 7 tests, all green.
```

---

## 참고

- 변경 규모: 소스 16줄, 테스트 70줄 (2개 파일)
- 브랜치명 제안: `fix/dsm-nodal-load-nan`
- 이 저장소에는 `CONTRIBUTING.md`나 PR 템플릿, CLA가 없습니다.
- CI는 `web` 디렉터리에서 `npm run test`를 돌립니다. 전체 실행에는
  WASM 빌드가 선행되어야 하므로, 로컬에서는 `npm run wasm`을 먼저
  하시거나 해당 테스트만 격리해 확인하시면 됩니다.
