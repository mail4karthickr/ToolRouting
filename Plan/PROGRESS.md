# Progress Log

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
