# Progress Log

## 2026-08-04 — Hybrid router (Stage 1 → Stage 2) implemented and measured

### What was built
- `Services/Routing/HybridOrchestrator.swift` — owns the article's cascade
  and conforms to `ToolRouter` (the "Hybrid" strategy in the UI):
  1. Stage 1: `MiniLMRouter.retrieve(topK: 4)` shortlist; empty shortlist =
     cheap abstention (LLM never runs).
  2. Stage 2: `LLMRouter.select(query, from: shortlist)`.
  3. Policy enforced in code, not trusted to the model: backend collapse
     (any `sendToBackend` sub-call escalates the whole request),
     candidate-set validation (a pick outside the shortlist the session
     actually saw is ungrounded → escalate), verbatim-duplicate dedupe.
  4. Stage 3 (NOT built yet): hand the ordered calls to the actual agent
     for execution — routing currently stops at selection.
- `Services/Routing/LLMRouter.swift` — REWRITTEN as Stage 2 only; it no
  longer routes independently. `select(_:from:)` builds per-request
  instructions containing ONLY the k retrieved tools (+ full escalation
  policy) and returns a `RoutingPlan` via guided generation (greedy).
  Fresh session per request — the candidate set is baked into the
  instructions, so there is no reusable prefix worth a long-lived session;
  `prewarm()` warms base model weights only. Prompt is O(k), not O(N).
- LLM-only strategy REMOVED from the picker and the eval suite (the
  measurement motivating the hybrid is already recorded; the LLM is
  always Stage 2 now). Picker: MiniLM / Hybrid, default Hybrid.

### Measured (iPhone 17 Pro, iOS 27.0, same 30-sample routing eval)
| Run | Strategy | Metric | Score |
|---|---|---|---|
| 09:01 | Hybrid (MiniLM k=4 → LLM) | **Routing Accuracy** | **0.933 (28/30)** |
| ref | LLM-only (final recorded run, gate) | Routing Accuracy | ≥ 0.8 |
| ref | MiniLM embedding-only (final) | Routing Accuracy | 0.500 (15/30) |

Eval wall-clock: 166.9 s for 30 samples ≈ 5.6 s/sample end-to-end on
device (includes per-request session creation + guided decode; no
latency metric is recorded yet — add one before optimizing).

### Failure analysis (2/30, both Stage-2 call-count quirks)
- "Get my June and July statements for checking" — one `bank_statement`
  call instead of two (model merged both months into one call, or emitted
  two identical calls that the dedupe collapsed). Tool choice correct.
- "What's my credit limit?" — two `card_limits` calls instead of one
  (likely debit + credit fan-out; different args survive dedupe). Tool
  choice correct.
- Zero escalation/chain/multi-intent failures — exactly the classes the
  embedding-only router failed (13 of its 15 misses); the LLM stage
  recovered all of them, confirming the cascade design.

### Decisions
- Hybrid gate set to ≥ 0.8 (same bar the LLM-only router met); measured
  0.933 clears it with margin.
- Candidate-set validation escalates (send_to_backend) rather than drops
  the offending call: dropping breaks chains, and the backend can serve
  anything.

### Next
- Stage 3: execute the routed calls via the agent (`BankAPIClient`) and
  compose the final answer — the orchestrator's placeholder step.
- Hill-climb the two call-count misses (candidates: an instruction nudge
  on per-period repeats; eval first, keep only if ≥ 0.933 holds).
- Latency ablation: hybrid vs. the retired LLM-only configuration
  (article predicts ~25–30% of LLM-only latency; measure, don't assume).
- Threshold calibration exercise (off-topic samples + sweep) still open.

## 2026-08-04 — Embedding router (Stage 1) implemented and measured

### What was built
- `Services/Routing/Embedder.swift` — `Embedder` protocol + `MLXEmbedder` actor
  (all-MiniLM-L6-v2 via MLXEmbedders, 384-d, L2-normalized).
- `Services/Routing/ToolIndex.swift` — multi-vector index (description + example
  queries per tool, max-similarity per tool), fingerprinted and persisted to
  Application Support.
- `Services/Routing/MiniLMRouter.swift` — article-exact embedding router:
  - `retrieve(query, topK: 4)` — threshold-filtered top-k shortlist with scores
    (the hybrid's Stage-1 API; a shortlist, never an execution plan).
  - `route()` — argmax-or-none classifier (top-1 above threshold, else abstain
    as an EMPTY selection). Abstain→backend forwarding is app policy in
    `ToolRoutingViewModel`, not router logic.
- Strategy picker (LLM / MiniLM) in the chat UI.
- Package: `ml-explore/mlx-swift-lm` pinned **2.31.3** (do not float to `main`;
  it moved to a macro/multi-package loader API). Metal Toolchain component
  installed for Xcode 27 beta.

### Measured (on iPhone 17 Pro, iOS 27.0, 30-sample eval unless noted)
| Run | Strategy / stage | Metric | Score |
|---|---|---|---|
| gate | LLM router (final) | Routing Accuracy | ≥ 0.8 |
| 06:43 | MiniLM final router, fanOutGap 0.05 + backend pseudo-tool | Routing Accuracy | 0.433 (13/30) |
| 07:00 | + abstain-as-none (pseudo-tool removed) | Routing Accuracy | 0.433 (13/30) |
| 07:03 | + fanOutGap calibrated 0.05 → 0.02 | Routing Accuracy | 0.500 (15/30) |
| 07:31 | article-exact top-1-or-none (fan-out removed) | Routing Accuracy | 0.500 (15/30) |
| 08:09 | MiniLM as Stage-1 retriever, k=4 | **Recall@4** | **1.000 (25/25)** |
| 08:09 | (same run) abstention on in-domain action queries | Abstention | 0.000 (0/5) — metric since removed, see below |

### Decisions
- **Abstain = "none" via similarity threshold only** (embedding stage); the
  explicit none/`send_to_backend` option belongs to LLM-based selection.
  Source: mbrenndoerfer.com tool-selection article ("for embedding-based
  routing, abstention is implemented via the similarity threshold").
- **Abstention metric removed from the retrieval eval**: all expected-empty
  samples were in-domain actions ("freeze my card"), which embed at 0.85+
  against card/payment lookup tools — no threshold separates them, so the
  metric was structurally pinned at 0. Escalation is graded in the routing
  eval; threshold abstention will be measured in the calibration exercise
  with genuinely off-topic samples (weather/music), which the dataset
  currently lacks.
- **similarityThreshold 0.45 is provisional, NOT calibrated.** Observed
  positives ≥ 0.66; negative distribution unmeasured (no off-topic samples).
  Calibration = separate exercise: add off-topic samples, sweep 0.30–0.60,
  pick the operating point that keeps recall at 1.0 with margin.
- **k = 4 validated** by Recall@4 = 1.000 (max distinct tools any sample
  needs is 3). If future samples need more distinct tools, first option is
  adaptive k (all above threshold up to a cap), then query decomposition.

### Failure analysis of embedding-only routing (0.500)
- 5 action/escalation samples — verb reasoning; LLM's job.
- 8 chain/ordering/decomposition samples — planning; LLM's job.
- 2 fan-out tension samples — single global gap can't serve both; resolved
  by moving multi-tool selection to the LLM stage.

### Next
- **HybridRouter**: `retrieve(topK: 4)` shortlist → LLM session over only
  those tools + explicit none option → select, order, parameterize.
  Ceiling is 100% (perfect recall); article benchmark: ~90% of LLM-only
  accuracy at 25–30% of the latency.
- Calibration exercise for the similarity threshold (off-topic samples + sweep).
- Dataset hygiene: several eval prompts are verbatim catalog `exampleQueries`
  (trivial 1.00 retrieval matches); future samples should avoid reuse.
