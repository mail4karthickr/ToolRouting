# Design Doc: On‑Device Tool Selection & Routing for LLM Agents on iOS

**Stack:** Swift · Apple Foundation Models framework (~3B on‑device model) · MLX Swift (`MLXEmbedders`) · Apple Evaluations framework (Book Tracker pattern)
**Source article:** [Tool Selection for LLM Agents: Routing Strategies and Implementation](https://mbrenndoerfer.com/writing/tool-selection-llm-agents-routing-strategies) — M. Brenndoerfer, Feb 2026
**Status:** Draft v1 · **Audience:** iOS engineers new to this project (no prior agent/routing experience assumed)

---

## Table of Contents

1. [Overview, Goals & Non‑Goals](#1-overview-goals--non-goals)
2. [Background](#2-background)
3. [Requirements](#3-requirements)
4. [Architecture Overview](#4-architecture-overview)
5. [Detailed Design](#5-detailed-design)
6. [Evaluation Plan (Apple Evaluations framework)](#6-evaluation-plan)
7. [Project & Module Structure](#7-project--module-structure)
8. [Implementation Milestones](#8-implementation-milestones)
9. [Best‑Practices Checklist (Article → Implementation)](#9-best-practices-checklist)
10. [Risks & Mitigations](#10-risks--mitigations)
11. [Appendix: Glossary & References](#11-appendix)

---

## 1. Overview, Goals & Non‑Goals

### 1.1 What we are building

We are building a reusable **hybrid tool router** for an iOS assistant/agent feature. Given a user query and a registry of app capabilities ("tools" — e.g., calculator, calendar lookup, notes search, unit converter, web search), the system must decide:

1. **Which tool to call**, if any (selection / routing),
2. **With what arguments** (parameter extraction),
3. **In what order**, when multiple tools are needed (orchestration),
4. **When to abstain** — answer directly or say "I can't do that" instead of forcing a tool call.

The core insight from the source article is that this is a **two‑stage retrieval + ranking problem**, not a single LLM call:

- **Stage 1 (retrieval):** an on‑device **embedding model (via MLX / `MLXEmbedders`)** narrows N registered tools to the top‑k (3–5) semantically closest candidates in a few milliseconds.
- **Stage 2 (ranking + execution):** Apple's on‑device **Foundation Models** ~3B LLM (`LanguageModelSession`) receives *only those k tools* and performs the final fine‑grained selection, argument generation, and tool calling via the framework's native `Tool` protocol.

This hybrid cascade matters even more on‑device than on a server: the article reports flat LLM routing degrades beyond ~20 tools even for frontier models, and Apple's on‑device model is a compact ~3B‑parameter model with a small context window (~4,096 tokens shared between input and output). Every tool schema we inject consumes that budget and dilutes attention. Retrieval‑then‑rank is therefore not an optimization here — it is the load‑bearing design decision.

### 1.2 Goals

- G1: Correct tool selection ≥ 90% on our golden dataset for a registry of 10–50 tools, measured with Apple's **Evaluations framework**.
- G2: Correct **abstention** (choosing "no tool") on out‑of‑scope queries, ≥ 85% on the abstention slice of the dataset.
- G3: Stage‑1 routing latency ≤ 50 ms warm (embedding + similarity); end‑to‑end response start ≤ ~2 s on supported devices.
- G4: Fully **on‑device and offline** after first launch (no server round‑trips for routing or generation; embedding model weights cached locally).
- G5: A repeatable **evaluation‑driven development loop** (hill‑climbing), modeled on Apple's Book Tracker sample, so description changes, threshold changes, and OS/model updates are regression‑tested.
- G6: New tools can be added by writing a `ToolSpec` + a `Tool` conformance + dataset samples — no router code changes.

### 1.3 Non‑Goals (v1)

- Training a **learned router** (classifier) — the article recommends this only for large, stable ecosystems with abundant query→tool logs; we design the interfaces so one can be slotted in later, but do not build it now.
- Fine‑tuning the LLM (Foundation Models adapters) or the embedding model — noted as a future option in §5.10.
- Server‑side routing or Private Cloud Compute execution paths (PCC is used only as the **judge model** in evaluations).
- Cross‑app / App Intents integration (follow‑up project).

---

## 2. Background

> New team members: read this section fully. It compresses the source article and the three Apple/MLX building blocks you need.

### 2.1 The tool‑selection problem (article summary)

An LLM connected to tools faces a routing problem: map a natural‑language intent to one of N capabilities, or to "none." Unlike network routing there is no lookup table — the model infers everything from **tool descriptions**, which act as the *interface* between the model and your code. Key findings from the article that shape this design:

- **Descriptions are the highest‑leverage artifact.** A cited study found that improving description clarity alone raised correct selection by 15–20 percentage points, with no model changes. Vague one‑liners ("Weather tool") cause systematic routing errors no prompt tuning can fix. Descriptions must be treated as first‑class, version‑controlled, regression‑tested engineering artifacts.
- **Rich beats minimal.** The best descriptions state what the tool does, *when to use it*, *when NOT to use it* (negative examples), and include a few example queries phrased the way real users actually type (informal, abbreviated). Negative examples are the main defense against false positives (e.g., a calendar tool firing on "what day is it?").
- **Names matter statistically.** Common, domain‑conventional names (`get_current_weather`) outperform clever or overly technical ones (`atmospheric_conditions_retriever`) because the model's associations come from patterns in human‑written code.
- **Embedding‑based routing** treats selection as dense retrieval: embed each tool's text once, embed the query at runtime, take cosine‑similarity top‑k. It is fast and scales, but its **recall is a hard ceiling** — if the retriever misses the right tool, the LLM never sees it. Embedding *description + examples* ("tool_text_construction") consistently outperforms embedding the description alone, because examples inject query‑like vocabulary.
- **LLM‑based routing** (give the model all schemas, let it pick) is the most flexible — it uses conversational context and world knowledge — but costs full inference per decision, and accuracy degrades with many distractor tools (attention dilution; ~20‑tool practical ceiling without specialized training).
- **Hybrid routing** (retrieve top‑k with embeddings, then let the LLM rank/select among k) captures ~90% of LLM‑only accuracy at ~25–30% of the latency cost. k = 3–7 is the empirical sweet spot; use larger k when tools overlap semantically.
- **Thresholds & abstention.** Every router needs a confidence gate and an explicit "none" path. Per‑tool calibrated thresholds beat one global threshold; destructive tools (delete, send, purchase) deserve higher thresholds than cheap read‑only ones. Align routing investment with the *failure cost* of a wrong call.
- **Multi‑tool = planning, not classification.** Sequential chains (output of tool A feeds tool B), parallel calls (only when truly independent — watch shared rate limits and side effects), and conditional branching (ReAct‑style interleaved reason→act→observe, which adapts when a tool returns something unexpected instead of committing to a brittle upfront plan). Parallel failure policies must be explicit: all‑or‑nothing, best‑effort, or retry‑failed‑only.
- **Tool hallucination** (inventing tools, or real tools with invalid/implausible arguments) is mitigated by constrained decoding (strongest — invalid token sequences get zero probability), registry validation before execution, and downstream sanity checks on argument *values* that pass schema but fail reality.
- **Training options** if zero‑shot accuracy plateaus: SFT on balanced positive/negative/ambiguous examples with hard negatives; **synthetic data generation** (teacher generates queries per tool → verify → dedupe for diversity); rejection sampling using execution success as free feedback; RL as a last resort (sparse rewards, credit assignment, safety constraints — simulate side‑effecting tools).
- **Brittleness is ongoing.** Minor description edits shift routing decisions; *model updates shift them too*. On iOS this is acute: the OS updates the on‑device model underneath us, so routing regression tests must re‑run on every OS/model update, not just on our own changes. Monitor per‑tool selection distributions for drift.

### 2.2 Platform building block #1 — Foundation Models framework (the "3B" model)

Apple's Foundation Models framework (iOS 26+/macOS 26+, Apple Intelligence–capable devices) exposes the on‑device ~3‑billion‑parameter LLM through a Swift API. Everything runs locally: private, offline, and free per‑request. Pieces we rely on:

- `SystemLanguageModel.default.availability` — must be checked before any feature is shown; can be unavailable (ineligible device, Apple Intelligence disabled, model still downloading).
- `LanguageModelSession(tools:instructions:)` — a stateful session. **Tools are fixed at session creation**, which is exactly what our dynamic router needs: we create a short‑lived session per request containing only the top‑k retrieved tools.
- `Tool` protocol — `name`, `description`, a `@Generable Arguments` struct (with `@Guide` annotations per parameter), and an async `call(arguments:)` that returns promptable output. The framework performs **constrained (guided) generation** against the argument schema — the strongest hallucination defense from §2.1, and we get it natively.
- `@Generable` / `@Guide` — guided generation for structured outputs; also used for our router's own structured "selection" responses and for `.count(a...b)`‑style constraints.
- `GenerationOptions(sampling: .greedy)` — deterministic decoding; important for reproducible evaluations.
- Context window ≈ 4,096 tokens (prompt + output combined). Overflow surfaces as a generation error (`exceededContextWindowSize`); other notable errors include guardrail violations and unsupported languages. Sessions also expose a `transcript` (our conversation memory) and `prewarm()` to hide cold‑start latency.

Consequence for design: **tool schemas are expensive.** With 50 registered tools we could never inline them all; with top‑k = 3–5 concise specs we stay well inside budget and keep the small model's attention focused.

### 2.3 Platform building block #2 — MLX Swift + `MLXEmbedders` (the embedding model)

MLX is Apple's array/ML framework for Apple silicon. The `MLXEmbedders` library (in `ml-explore/mlx-swift-lm`, formerly part of `mlx-swift-examples`) ships ready‑made BERT‑family encoder implementations and a pooling API, loading weights from the Hugging Face Hub (with local caching). Typical use: load a `ModelContainer` for a configuration such as **`bge_small`** (BAAI/bge‑small‑en‑v1.5, ~33M params, 384‑dim) or MiniLM / Nomic / quantized Qwen3‑Embedding variants, tokenize text, run the encoder, then mean‑pool with `normalize: true` so cosine similarity reduces to a dot product.

Notes that shape the design:

- Runs on Apple‑silicon devices and Macs; **iOS Simulator support is limited** (Metal‑dependent) — plan on physical devices or a macOS target for the eval harness.
- Weights are downloaded on first use (~tens of MB for BGE‑small/MiniLM); we must decide bundle‑vs‑download (§5.3) and precompute/persist the tool index so steady‑state queries embed only the query text.
- The same embedder is reused for **dataset deduplication** in the evaluation pipeline (§6.4), mirroring the article's diversity‑filtering advice.

### 2.4 Platform building block #3 — Evaluations framework + the Book Tracker sample

Announced at WWDC26 ("Meet the Evaluations framework"), with the **Book Tracker** sample app ("Book Tracker: Using Evaluations to evaluate an intelligent feature") as the canonical reference. Generative features break the same‑input→same‑output contract unit tests rely on, so the framework provides dataset‑driven, statistical testing:

- Implement the `Evaluation` protocol: define the **subject** (code under test), a **dataset** of `ModelSample(prompt:expected:)` values (e.g., via `ArrayLoader`), one or more `Metric`s with `Evaluator` closures returning `.passing(rationale:)` / `.failing(rationale:)` (or scores), and `aggregateMetrics` (means, variance, grouped stats) via `MetricsAggregator`.
- Run through **Swift Testing** with the `.evaluates(...)` trait and assert an **optimization target**, e.g., `#expect(result.aggregateValue(.mean(of: metric)) >= 0.8)`. The report breaks down per‑sample prompts, measurements, and full model responses.
- **`SampleGenerator`** (`samples.makeSamples(_:targetCount:)`) synthesizes additional dataset samples from a seed set — the article's synthetic‑data recipe, productized.
- **`ModelJudgeEvaluator`** uses a second, at‑least‑as‑capable model (e.g., `PrivateCloudComputeLanguageModel()`) as a qualitative judge, with numeric scales (even number of levels to avoid a neutral default), `ScoreDimension`s to split vague criteria into narrow ones, and `ModelJudgePrompt` to give the judge app context.
- Apple's stated best practices, which we adopt wholesale in §6: start with 20–30 focused samples and grow; **if you can measure it in code, use a heuristic evaluator**; use model judges only for qualitative traits; start the judge simple; let per‑sample *rationales* drive the next change ("hill‑climbing" / evaluation‑driven development).

The framework ships with the newest SDKs (introduced at WWDC26; in beta at the time of writing). Evaluations live in **test targets** only — nothing from this framework ships in the app binary — so the app itself can keep a lower deployment target while evals build against the latest SDK on macOS/CI.

---

## 3. Requirements

### 3.1 Functional

| ID | Requirement |
|----|-------------|
| F1 | Route a free‑form query to exactly one of N registered tools, or abstain, in a single turn. |
| F2 | Support multi‑step requests: sequential chains with data dependencies, and parallel calls for independent sub‑requests, with explicit failure policy per plan. |
| F3 | Extract structured, schema‑valid arguments for the selected tool (guided generation). |
| F4 | Abstain gracefully: below‑threshold retrieval or an LLM "none" selection yields a direct answer or an honest "can't help with that," never a forced tool call. |
| F5 | Registry is data‑driven: adding/removing a tool updates the embedding index without code changes to the router. |
| F6 | Per‑tool similarity thresholds and a risk level (`readOnly` / `mutating` / `destructive`) that gates confirmation UX and threshold strictness. |
| F7 | Every routing decision is observable: candidates, scores, chosen tool, stage latencies (os_signpost + optional debug log). |

### 3.2 Non‑functional

| ID | Requirement |
|----|-------------|
| N1 | Offline after first launch; no query content leaves the device (evaluation judging via PCC happens only in dev/CI, never in the shipping app). |
| N2 | Warm Stage‑1 latency ≤ 50 ms for ≤ 200 tools (brute‑force dot products are fine at this scale; no vector DB needed). |
| N3 | Memory: embedder resident set ≲ 150 MB; released under memory pressure and lazily reloaded. |
| N4 | Deterministic eval mode: greedy decoding, fixed registry snapshot, pinned dataset version. |
| N5 | All components behind protocols so the embedder (MLX) and the LLM (Foundation Models) can be swapped or mocked in tests. |
| N6 | Graceful degradation: if Foundation Models is unavailable → feature hidden or reduced to deterministic shortcuts; if the embedder isn't ready → fall back to LLM‑only routing over a curated "core" tool subset. |

---

## 4. Architecture Overview

```
                        ┌──────────────────────────────────────────────┐
 User query ──────────▶ │ Stage 0 · Preconditions & deterministic router│
                        │ • SystemLanguageModel availability check      │
                        │ • Exact/regex fast paths ("/timer 5m")        │
                        │ • Input hygiene (length, language)            │
                        └──────────────┬───────────────────────────────┘
                                       ▼
                        ┌──────────────────────────────────────────────┐
                        │ Stage 1 · Semantic retrieval (MLXEmbedders)   │
                        │ • Embed query (384‑d, normalized)             │
                        │ • Cosine top‑k over precomputed ToolIndex     │
                        │ • Per‑tool + global thresholds                │
                        └───────┬──────────────────────┬───────────────┘
                     all below  │                      │ top‑k (3–5) candidates
                     threshold  ▼                      ▼
                        ┌──────────────┐   ┌──────────────────────────────────┐
                        │  ABSTAIN      │   │ Stage 2 · LLM select + execute    │
                        │  direct answer│   │ LanguageModelSession(tools: topK) │
                        │  (no tools)   │   │ • FM‑native Tool calling          │
                        └──────────────┘   │ • Guided args (@Generable/@Guide) │
                                           │ • "answer directly" = LLM none    │
                                           └──────────────┬───────────────────┘
                                                          ▼
                                           ┌──────────────────────────────────┐
                                           │ Execution & validation layer      │
                                           │ • registry check, arg sanity      │
                                           │ • risk gate → user confirmation   │
                                           │ • sequential/parallel orchestration│
                                           └──────────────┬───────────────────┘
                                                          ▼
                                                   Final response
```

Design rationale, tied to the article:

- **Stage 0** exists because not every decision deserves ML. Deterministic shortcuts are free, testable, and remove load from both models (the article's "align cost with failure cost" economics).
- **Stage 1** is the article's *embedding‑based routing*, used as a coarse filter, never as the sole decider for anything risky. Its recall is the system's ceiling, so we measure Recall@k explicitly (§6.3) and tune tool text construction before touching anything else.
- **Stage 2** is the article's *LLM‑based routing*, kept cheap by only ever seeing k schemas. Crucially, we do **not** build a bespoke "return the tool name as JSON" protocol — we hand the top‑k tools to `LanguageModelSession` and let the framework's native, constrained tool‑calling do selection + argument extraction + invocation in one pass. Fewer moving parts, and constrained decoding for free.
- **Abstention** has two doors: a cheap one after Stage 1 (nothing similar enough → answer directly with a tool‑free session) and a semantic one inside Stage 2 (instructions explicitly permit answering without tools).

---

## 5. Detailed Design

### 5.1 `ToolSpec` — the single source of truth for a capability

Everything the article says about descriptions is encoded in one value type. The FM `Tool` conformance, the embedding text, the docs, and the eval dataset all derive from it — descriptions can never drift apart across stages.

```swift
/// Declarative metadata for one capability. Treated like code:
/// versioned, reviewed, and regression-tested by RouterEvals.
struct ToolSpec: Identifiable, Codable, Sendable {
    enum Risk: String, Codable, Sendable { case readOnly, mutating, destructive }

    let id: String              // "calendar.check_availability" — namespaced (article: hierarchical structure)
    let displayName: String
    let category: String        // "calendar" — enables future two-stage category→tool routing
    let description: String     // What it does + when to use it. Consistent verbs across the registry.
    let useWhen: [String]       // Positive example queries, phrased like real users type (incl. informal)
    let avoidWhen: [String]     // Negative examples — the false-positive defense
    let scopeNote: String       // "Does not create events; use calendar.create_event for that."
    let risk: Risk
    let similarityThreshold: Float?   // per-tool override; nil → RouterConfig.defaultThreshold
    let deprecatedBy: String?   // steer the model away from legacy tools (article: deprecation notes)

    /// The exact text that gets embedded (article: tool_text_construction).
    /// Description + examples consistently beats description alone, because
    /// examples add the query-like vocabulary users will actually type.
    var embeddingText: String {
        var parts = ["\(id): \(description)", scopeNote]
        if !useWhen.isEmpty  { parts.append("Use for: " + useWhen.joined(separator: "; ")) }
        if !avoidWhen.isEmpty { parts.append("Do not use for: " + avoidWhen.joined(separator: "; ")) }
        return parts.joined(separator: " ")
    }
}
```

**Description authoring guidelines** (enforced in code review; each rule traces to the article):

1. Name = namespaced, conventional, lowercase snake/dot case; no clever names.
2. Description opens with a standard action verb from our controlled vocabulary (`look up`, `create`, `update`, `delete`, `compute`, `convert`, `search`) — consistent verbs keep embedding clusters tight.
3. State scope *and non‑scope* ("Does not handle…").
4. ≥ 3 `useWhen` examples matching the real query distribution (include informal phrasings: "whats on tmrw"), ≥ 2 `avoidWhen` examples naming the tool that *should* handle those.
5. Keep it concise — every token is context‑window budget in Stage 2.
6. Any edit to a `ToolSpec` requires the RouterEvals suite to pass (descriptions are code).

The registry is a simple observable collection with a stable content hash, used to invalidate the vector index:

```swift
actor ToolRegistry {
    private(set) var specs: [ToolSpec]
    var fingerprint: String { /* stable hash of ids + embeddingTexts + embedder model id */ }
    func specs(inCategories: Set<String>? = nil) -> [ToolSpec] { ... } // context-scoped registries
}
```

### 5.2 `Embedder` protocol + MLX implementation

```swift
protocol Embedder: Sendable {
    var modelID: String { get }          // part of the index fingerprint
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]  // L2-normalized
}
```

MLX-backed implementation (API shape per `mlx-swift-lm`'s `MLXEmbedders`; verify names against the pinned package version — this repo moves):

```swift
import MLX
import MLXEmbedders

actor MLXEmbedder: Embedder {
    let modelID = "BAAI/bge-small-en-v1.5"   // 384-d, ~33M params: the "all-MiniLM-class" tradeoff the article recommends
    let dimension = 384
    private var container: ModelContainer?

    private func loadedContainer() async throws -> ModelContainer {
        if let c = container { return c }
        let c = try await loadModelContainer(
            from: HubClient.default,
            using: TokenizersLoader(),
            configuration: ModelConfiguration.bge_small)
        container = c
        return c
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let container = try await loadedContainer()
        return await container.perform { model, tokenizer, pooler in
            texts.map { text in
                let tokens = tokenizer.encode(text: text)
                let input = MLXArray(tokens).expandedDimensions(axis: 0)
                let output = model(input)
                let pooled = pooler(output, normalize: true)   // mean-pool + L2 normalize
                eval(pooled)
                return pooled.asArray(Float.self)
            }
        }
    }

    func unload() { container = nil }   // memory-pressure hook (N3)
}
```

Implementation notes:

- **Model choice.** Start with `bge_small` (strong quality/latency balance, matching the article's `all-MiniLM-L6-v2` guidance: small bi‑encoder first, upgrade only if Recall@k evidence demands it). Fallback candidates: MiniLM (smaller), Nomic or quantized Qwen3‑Embedding‑0.6B (better quality, ~350 MB, higher latency). The eval harness (§6) is what arbitrates — never vibes.
- **Query vs document prompts.** BGE‑family models expect a retrieval instruction prefix on the *query* side (e.g., "Represent this sentence for searching relevant passages: …"). Encapsulate this inside the embedder so callers can't get it wrong, and keep it identical between index build and query time.
- **Weights delivery.** Default: download-on-first-use from the Hub with progress UI + Background Assets as a fast follow; alternative: bundle weights in the app for fully offline first run (App Store size cost). Decision owner: release eng, by M2.
- **Simulator.** MLX needs Apple‑silicon Metal; run on device or macOS. CI evals run on Apple‑silicon Mac runners.

### 5.3 `ToolIndex` — precomputed vectors + persistence

```swift
struct ToolIndex: Codable {
    let fingerprint: String        // registry hash + embedder.modelID
    let ids: [String]
    let vectors: [[Float]]         // normalized; N x 384 floats — tiny at our scale
}

actor ToolIndexStore {
    /// Rebuild only when fingerprint changes (app update, spec edit, embedder swap).
    func loadOrBuild(registry: ToolRegistry, embedder: Embedder) async throws -> ToolIndex
}
```

- Persisted as a flat binary/JSON file in Application Support; rebuilt off the main actor on first launch after a change.
- **No vector database.** At ≤ 200 tools × 384 dims, brute‑force dot product over a contiguous `[Float]` buffer (Accelerate `vDSP` or MLX matmul) is < 1 ms. Revisit only if the registry grows 10×+ (then: category‑partitioned two‑stage routing *before* ANN indexes — the article's scaling order).

### 5.4 `SemanticRouter` — Stage 1

```swift
struct RoutingCandidate: Sendable { let spec: ToolSpec; let score: Float }

enum RoutingDecision: Sendable {
    case abstain(reason: AbstainReason)          // nothing similar enough
    case candidates([RoutingCandidate])          // hand to Stage 2
    case direct(ToolSpec)                        // Stage 0 fast path hit
}

struct RouterConfig: Sendable {
    var topK: Int = 4                 // article sweet spot 3–7; tune via ablation §6.6
    var defaultThreshold: Float = 0.35
    var minGapForDirect: Float?       // optional: skip Stage 2 when score1 - score2 is huge AND risk == readOnly
}

actor SemanticRouter {
    func route(_ query: String) async throws -> RoutingDecision {
        // 1) embed query (with BGE query prefix)  2) scores = index.vectors · q
        // 3) filter by max(spec.similarityThreshold, config.defaultThreshold)
        // 4) top-k by score → .candidates, else .abstain(.lowSimilarity(best:))
    }
}
```

Threshold policy (article §"Confidence Calibration"):

- Per‑tool thresholds override the global default; **destructive tools get higher thresholds** (a missed invocation is cheaper than a wrong one), read‑only converters can sit lower.
- Thresholds are **calibrated, not guessed**: §6.5 defines the sweep procedure over the golden dataset that picks the per‑tool operating points; calibrated values are checked into the specs with the eval run ID that produced them.
- Optional `minGapForDirect` allows skipping Stage 2 entirely for unambiguous read‑only cases (e.g., "convert 5 mi to km" → unit converter at 0.82 with the runner‑up at 0.31) — the embedding‑only end of the article's latency/accuracy curve, enabled per deployment only after eval evidence.

### 5.5 Stage 2 — Foundation Models session with the top‑k tools

Each qualifying tool has a FM `Tool` conformance generated next to its `ToolSpec` (name/description sourced *from* the spec):

```swift
import FoundationModels

struct CheckAvailabilityTool: Tool {
    let spec: ToolSpec
    var name: String { spec.id }
    var description: String { spec.description + " " + spec.scopeNote }

    @Generable
    struct Arguments {
        @Guide(description: "Day to check, e.g. 'Friday', '2026-08-07', or 'tomorrow'")
        var day: String
        @Guide(description: "Optional time window like '2pm-5pm'; omit for full day")
        var window: String?
    }

    func call(arguments: Arguments) async throws -> String {
        try await CalendarService.shared.availabilitySummary(day: arguments.day,
                                                             window: arguments.window)
    }
}
```

The agent turn:

```swift
actor AgentTurnRunner {
    func respond(to query: String, candidates: [RoutingCandidate]) async throws -> AgentReply {
        let tools = candidates.map { ToolFactory.make($0.spec) }   // k concrete Tool values
        let session = LanguageModelSession(tools: tools) {
            Instructions {
                """
                You are the in-app assistant. Use a tool only when it clearly matches the
                user's request. If no tool fits, answer directly from your own knowledge,
                or say you can't help with this. Never invent capabilities.
                For requests with several parts, call tools in dependency order and use
                earlier results to fill later arguments.
                """
            }
        }
        session.prewarm()
        let options = GenerationOptions(sampling: .greedy)   // deterministic in eval mode
        let response = try await session.respond(to: query, options: options)
        return AgentReply(text: response.content, transcript: session.transcript)
    }
}
```

Key points:

- **A fresh session per routed request** is the mechanism that makes routing *dynamic* — FM fixes tools at init, so "which tools does the session get" is exactly our Stage‑1 output. For multi‑turn conversations, we keep a session alive while the candidate set is stable and rebuild (carrying transcript context forward) when a new turn routes to a different candidate set.
- **The "none" option** from the article maps to instructions permitting direct answers; abstention is a first‑class outcome, not an error.
- **Multi‑tool chains come free‑ish:** within one `respond` call the framework loops — the model can call `search_sales_data`, read the output from the transcript, then call `calculator` with values derived from it (the article's `$reference` scratchpad, realized as the session transcript). Our job is (a) retrieving *all* tools the plan needs into the candidate set (§5.6) and (b) validating each call.
- **Risk gating:** `mutating`/`destructive` tools' `call` implementations route through a `ConfirmationBroker` (async UI confirmation) before side effects — the article's failure‑cost alignment, and the safe answer to "RL‑style exploration on real side effects."
- **Error handling:** catch context‑overflow (retry with condensed transcript / fewer tools), guardrail violations (apologize + no retry), and unsupported‑language errors (localized fallback message). Wrap all FM errors into one `AgentError` taxonomy for UI + telemetry.

### 5.6 Multi‑intent queries and orchestration

Compound queries ("find Q3 sales, compute growth vs Q2, and block 3h Friday") threaten Stage 1: one query vector vs several intents. Mitigations, in order of preference:

1. **Union top‑k:** retrieve top‑k = 4 as usual, but with per‑intent coverage — run a cheap `@Generable` decomposition pass (a tool‑free FM call that splits the query into sub‑requests), embed each sub‑request, and union the per‑sub‑request top‑2. This is the article's "selection → planning" shift with retrieval still doing the pruning.
2. Inside Stage 2, the model orders calls by data dependency itself (sequential) and may emit independent calls in one turn (parallel). Our executor enforces:
   - **Independence checks** beyond "different arguments": shared rate‑limited services and write‑write conflicts are declared on `ToolSpec.category`/`risk` and serialize automatically.
   - **Failure policy** per plan: default `best-effort` for read‑only chains, `all-or-nothing` with rollback hooks when any `mutating` step is involved.
3. ReAct‑style adaptation is inherent: because the model sees each tool result before the next call, a "room unavailable" result can redirect the plan without us pre‑enumerating branches.

### 5.7 Hallucination & validation layer

Defense in depth, mapped to the article's three mitigations:

| Threat | Defense | Where |
|---|---|---|
| Invented tool names | FM constrained tool calling can only emit registered tools of *this session* | framework |
| Real tool, schema‑invalid args | `@Generable` guided generation enforces types/guides at decode time | framework |
| Schema‑valid but implausible args ("location": "the moon") | Per‑tool `validate(arguments:)` sanity hooks + tool‑result reasonableness checks before use | `ToolFactory` wrapper |
| Right call, wrong tool for org policy | Risk gate + confirmation UX | `ConfirmationBroker` |

### 5.8 Observability

`os_signpost` intervals for `embed_query`, `similarity`, `fm_respond`, per‑tool `tool_call`; a `RoutingTrace` value (query hash, candidate ids + scores, decision, latencies, OS build, model availability state) retained in a ring buffer for debug UI and — with consent — aggregate, content‑free analytics. The article's "monitor selection distributions for drift" becomes: a weekly job compares per‑tool selection frequency against the eval baseline and flags shifts after OS updates.

### 5.9 Concurrency model

Swift 6 strict concurrency. `MLXEmbedder`, `ToolRegistry`, `ToolIndexStore`, `SemanticRouter` are actors; `ToolSpec`/decisions are `Sendable` values. App start: kick off (a) FM availability check, (b) embedder load + index build, (c) `prewarm()` for the default session — all off the main actor, gated behind the feature's first appearance.

### 5.10 Future extensions (explicitly out of v1)

- **Learned router** head over the same embeddings (article: for mature ecosystems with logged query→tool data); slot in behind the `SemanticRouter` protocol; keep embedding retrieval as long‑tail fallback.
- **Category → tool hierarchical routing** once N > ~100 (we already namespace ids and categories so this is additive, per the article's "plan hierarchy early").
- **Foundation Models adapter fine‑tuning** or embedder fine‑tuning on hard negatives if the eval plateaus below target after description/threshold hill‑climbing.

---

## 6. Evaluation Plan

We follow the Book Tracker sample's evaluation‑driven development loop end to end: build a small honest dataset → define heuristic metrics → set an optimization target → hill‑climb descriptions/thresholds/instructions → add model judges for the qualitative residue → grow the dataset synthetically. Evals live in a test target (`RouterEvals`) built with the latest SDK and run on Apple‑silicon Macs/devices in CI.

### 6.1 What is under test (subjects)

Three subjects, evaluated separately so failures localize:

- **S1 Retrieval:** `SemanticRouter` alone — does the gold tool appear in top‑k? (This bounds everything downstream: the article's "retrieval bottleneck".)
- **S2 End‑to‑end routing:** Stage 1 + Stage 2 → which tool (or none) actually got called, with what arguments. Deterministic mode: greedy sampling, pinned registry snapshot.
- **S3 Multi‑tool planning:** compound queries → sequence/set of calls + final answer quality.

### 6.2 Dataset design (`ModelSample`s)

Per the article's data‑curation guidance and Apple's "start with 20–30 focused samples, grow to hundreds+":

| Slice | Content | Initial size |
|---|---|---|
| Positives | Clear single‑tool queries, ≥ 2 per tool, formal + informal phrasing ("whats free fri arvo?") | ~2–3 × N tools |
| Hard negatives | Queries semantically close to tool A but belonging to tool B (calendar "what day is it?" → none/clock) | ~1 × N |
| Abstentions | In‑domain‑sounding but unsupported requests + fully off‑topic queries | 15–20 |
| Ambiguous | Legitimately two‑way queries; expected = accept‑set of tools | 10 |
| Multi‑tool | Compound queries with gold plans (ordered tool id lists + failure policy) | 10–15 |

```swift
struct ExpectedRoute: Codable, Sendable {
    let acceptableTools: [String]   // [] means "must abstain"
    let goldArguments: [String: String]?
    let goldPlan: [String]?         // ordered ids for multi-tool samples
}

var dataset = ArrayLoader(samples: [
    ModelSample(prompt: "whats 15% tip on 84.50",
                expected: ExpectedRoute(acceptableTools: ["math.calculate"],
                                        goldArguments: ["expression": "84.50 * 0.15"],
                                        goldPlan: nil)),
    ModelSample(prompt: "what day is it today",
                expected: ExpectedRoute(acceptableTools: [], goldArguments: nil, goldPlan: nil)),
])
```

**Growing the dataset:** use the framework's `SampleGenerator` (`seedSamples.makeSamples("Generate diverse user requests for <tool>, including typos and casual phrasing…", targetCount: …)`) per tool — the article's teacher‑generation step — then **verify** (human spot‑check + judge agreement) and **dedupe with our own MLX embedder** (drop pairs with cosine > 0.92) so redundant near‑duplicates don't waste the training/eval budget — the article's diversity filter, implemented with a component we already have.

### 6.3 Metrics — heuristic first (measure in code where possible)

| Metric | Subject | Evaluator logic | Target |
|---|---|---|---|
| `RecallAtK` | S1 | gold tool ∈ top‑k candidate ids (skip abstention samples) | ≥ 0.97 |
| `SelectionAccuracy` | S2 | called tool ∈ `acceptableTools` (or no call when accept‑set empty) | ≥ 0.90 |
| `AbstentionCorrect` | S2 | on abstention slice: no tool invoked | ≥ 0.85 |
| `FalseInvocationRate` | S2 | tool fired on abstention/hard‑negative slice (tracked, minimized) | ≤ 0.08 |
| `ArgValidity` | S2 | args parse + pass per‑tool `validate` + match gold where provided | ≥ 0.90 |
| `PlanOrderCorrect` | S3 | called sequence respects gold dependency order (subsequence match) | ≥ 0.80 |
| `Stage1LatencyMs` | S1 | scored (not pass/fail) → aggregate mean/stddev | p50 ≤ 50 |

Sketch, in the Book Tracker idiom:

```swift
import Evaluations

struct RoutingEvaluation: Evaluation {
    // subject: closure that runs Stage1+Stage2 on sample.prompt and returns a RoutingTrace
    var dataset = ArrayLoader(samples: RoutingDataset.v1)

    let selection = Metric("SelectionAccuracy")

    var evaluators: Evaluators {
        Evaluator { input, subject in
            let trace = subject.value                      // RoutingTrace
            let ok = input.expected!.acceptableTools.isEmpty
                ? trace.calledTools.isEmpty
                : trace.calledTools.first.map { input.expected!.acceptableTools.contains($0) } ?? false
            return ok ? selection.passing(rationale: "called \(trace.calledTools)")
                      : selection.failing(rationale: "called \(trace.calledTools), expected \(input.expected!.acceptableTools)")
        }
        // …RecallAtK, AbstentionCorrect, ArgValidity evaluators…
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: selection)
        aggregator.group("Latency") { $0.computeMean(of: stage1Latency); $0.computeStandardDeviation(of: stage1Latency) }
    }
}

@Test("Routing evals", .evaluates(RoutingEvaluation(), info: evaluationInfo))
func routing() async throws {
    let result = EvaluationContext.current.result
    #expect(result.aggregateValue(.mean(of: RoutingEvaluation().selection)) >= 0.90)  // optimization target
}
```

### 6.4 Model judges — qualitative residue only

Heuristics can pass while the experience is still wrong (the Book Tracker lesson). Add `ModelJudgeEvaluator` with `PrivateCloudComputeLanguageModel()` as judge for:

- **AnswerQuality** on abstention/direct answers (was the tool‑free reply actually helpful and honest?).
- **PlanQuality** on S3 — split into `ScoreDimension`s, each with an even‑numbered 1–4 scale (no neutral middle): `Completeness` (all sub‑requests addressed) and `Efficiency` (no redundant calls). Provide a `ModelJudgePrompt` describing our app ("an on‑device personal assistant where tools have real side effects; declining is better than a wrong destructive call") plus the gold plan as reference — without app context the judge can't score abstentions correctly, exactly as the Book Tracker session warns.
- Start the judge simple; read the per‑sample **rationales** and let them, not the aggregate number, dictate the next spec/instruction change.

### 6.5 Threshold calibration procedure

Offline job (macOS tool in the package): for each tool, sweep threshold 0.20→0.60 in 0.02 steps over the golden dataset; plot precision/recall of Stage‑1 firing; pick the per‑tool operating point maximizing F1 subject to a floor on precision for `destructive` tools (precision ≥ 0.95). Write results back into `ToolSpec.similarityThreshold` with the eval run ID. Re‑run on: embedder change, spec text change, every OS major beta.

### 6.6 Ablations (reproduce the article's trade‑off chart for *our* stack)

One config flag runs the same dataset through: LLM‑only (all tools in one session — only feasible ≤ ~15 tools), embedding‑only (`minGapForDirect` forced), hybrid k∈{3,4,5,7}. Report accuracy vs p50 latency per config; the expected shape (hybrid ≈ 90% of LLM‑only accuracy at a fraction of latency) validates the architecture on‑device and picks k with evidence.

### 6.7 Regression cadence

- CI: full heuristic suite on every PR touching specs/instructions/router; judges nightly (PCC quota).
- **On every iOS/macOS beta and release:** full suite re‑run — the OS updates the FM model under us, and the article is explicit that model updates silently move decision boundaries.
- Selection‑distribution drift monitor (§5.8) compared to the last green eval baseline.

---

## 7. Project & Module Structure

```
ToolRouterKit/                    // SwiftPM package
├── Package.swift                 // deps: mlx-swift, mlx-swift-lm (MLXEmbedders), swift-transformers hub
├── Sources/
│   ├── ToolRouterCore/           // ToolSpec, ToolRegistry, RoutingDecision, RouterConfig,
│   │                             // SemanticRouter, ToolIndexStore, validation, traces
│   ├── EmbeddingKit/             // Embedder protocol, MLXEmbedder, index math (vDSP)
│   ├── FMAgent/                  // Tool conformances, ToolFactory, AgentTurnRunner,
│   │                             // Instructions, ConfirmationBroker, AgentError
│   └── RouterSupport/            // signposts, ring-buffer trace log, config
├── Tests/
│   ├── ToolRouterCoreTests/      // pure unit tests (mock Embedder, mock LLM)
│   └── RouterEvals/              // Evaluations framework: datasets/, evaluations/, judges/,
│                                 // calibration tool, ablation runner  (latest SDK, mac/device only)
└── DemoApp/                      // SwiftUI assistant with 12–15 real tools, debug routing HUD
```

Dependency rules: `ToolRouterCore` knows nothing about MLX or FoundationModels (protocols only) → fully unit‑testable on any Mac; `EmbeddingKit` and `FMAgent` are the only modules importing platform ML frameworks.

---

## 8. Implementation Milestones

| # | Milestone | Contents | Exit criteria |
|---|---|---|---|
| M0 | Spikes (1 wk) | FM availability + tool‑calling hello‑world on device; MLXEmbedders load + embed on device; measure cold/warm latencies & memory | numbers recorded in this doc |
| M1 | Specs & registry | `ToolSpec`, authoring guide, 12–15 real tools written to guidelines, registry + fingerprint | spec lint passes; review sign‑off |
| M2 | Stage 1 | `MLXEmbedder`, `ToolIndexStore`, `SemanticRouter`, thresholds, weights‑delivery decision | Recall@4 ≥ 0.95 on seed dataset; p50 ≤ 50 ms warm |
| M3 | Stage 2 | Tool conformances, `AgentTurnRunner`, abstention instructions, error taxonomy, risk gate | E2E happy paths on device |
| M4 | Orchestration | decomposition pass, union top‑k, failure policies, validation layer | S3 samples pass PlanOrder ≥ 0.8 |
| M5 | Evaluation | RouterEvals target, golden dataset v1, heuristic metrics + targets, judge v1, calibration tool, ablations | CI green at §6.3 targets; k chosen |
| M6 | Hardening | telemetry, drift monitor, memory‑pressure unload, prewarm strategy, docs | ship‑readiness review |

Estimated total: ~6–8 engineer‑weeks for one iOS engineer familiar with Swift concurrency, plus review.

---

## 9. Best‑Practices Checklist (Article → Implementation)

Every article recommendation and where this design honors it — use this table in code review.

| # | Article best practice | Where implemented |
|---|---|---|
| 1 | Descriptions are the interface; clarity alone worth 15–20 pp | §5.1 `ToolSpec` + authoring rules; eval‑gated edits |
| 2 | Include when‑to‑use *and* when‑NOT‑to‑use + few‑shot examples | `useWhen` / `avoidWhen` / `scopeNote` fields |
| 3 | Examples must mirror real (informal) query distribution | authoring rule 4; dataset includes informal slice |
| 4 | Conventional, descriptive names; no clever identifiers | authoring rule 1 |
| 5 | Consistent action‑verb vocabulary across ecosystem | authoring rule 2 (controlled verb list) |
| 6 | Scope clarity incl. explicit non‑scope | `scopeNote` |
| 7 | Namespaces / hierarchy; plan for it before you need it | dotted ids + `category`; §5.10 hierarchical routing path |
| 8 | Deprecation steering in descriptions | `deprecatedBy` |
| 9 | Embed description **plus examples** (tool_text_construction) | `embeddingText` computed property |
| 10 | Embedding routing = fast coarse filter; recall is the ceiling | Stage 1 + dedicated `RecallAtK` metric |
| 11 | Hybrid cascade, k = 3–7, tune to tool overlap | `RouterConfig.topK`; §6.6 ablations pick k |
| 12 | Per‑tool calibrated thresholds; stricter for destructive tools | `similarityThreshold` + §6.5 calibration + risk floors |
| 13 | Always support abstention / explicit "none" | two abstention doors (§4); instructions permit direct answers; `AbstentionCorrect` metric |
| 14 | LLM routing leverages conversational context | session transcript reuse across turns (§5.5) |
| 15 | Constrained decoding as strongest anti‑hallucination defense | FM guided generation natively (§5.7) |
| 16 | Registry validation + downstream argument sanity checks | validation layer table (§5.7) |
| 17 | Sequential chains with scratchpad/refs | FM transcript loop; executor (§5.6) |
| 18 | Parallel only when truly independent; explicit failure policies | independence via category/risk; best‑effort vs all‑or‑nothing (§5.6) |
| 19 | ReAct interleaving over brittle upfront plans | inherent to FM tool loop (§5.6.3) |
| 20 | Balanced positives/negatives/ambiguous + hard negatives | dataset slices (§6.2) |
| 21 | Synthetic data: generate → verify → diversity‑dedupe | `SampleGenerator` + judge verify + embedding dedupe (§6.2) |
| 22 | Execution success as free feedback (rejection‑sampling spirit) | `ArgValidity` uses real validate/execution results (§6.3) |
| 23 | RL exploration unsafe with side effects → simulate/confirm | risk gate + mocked tools in evals; no live side effects in CI |
| 24 | Treat descriptions like code: A/B, monitor, regression on *model* updates | §6.7 cadence incl. every OS beta; drift monitor (§5.8) |
| 25 | ~20‑tool flat ceiling → architecture, not prompts | the entire two‑stage design; §5.10 hierarchy at 100+ |
| 26 | Align routing cost with failure cost | Stage‑0 fast paths, `minGapForDirect` only for readOnly, confirmation UX for destructive |
| 27 | Diverse test sets (informal, edge, multilingual‑aware) | dataset slices; unsupported‑language error path (§5.5) |

---

## 10. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Embedding recall too low for niche tools (long‑tail underexposure) | M | H | Recall@k metric per tool; enrich `useWhen`; synthetic query augmentation for rare tools; raise k for overlapping categories |
| FM context overflow on long transcripts + k tools | M | M | concise specs; k ≤ 5; transcript condensation on `exceededContextWindowSize` retry |
| API drift (FM `Tool` output type, MLXEmbedders loaders have both changed across releases) | H | M | pin package versions; thin adapter layers (`Embedder`, `ToolFactory`); M0 spike re‑verifies signatures |
| OS model update shifts routing behavior | H | M | §6.7 re‑run on every beta; drift monitor; thresholds re‑calibrated |
| First‑launch weight download UX / size | M | M | bundle‑vs‑download decision M2; Background Assets; feature degrades to LLM‑only over core tools until ready |
| Simulator/dev friction (MLX needs Apple silicon Metal) | H | L | macOS‑first dev loop; device farm for CI evals |
| Evaluations framework requires newest SDK | M | L | evals isolated in test target on latest Xcode; app deployment target unaffected |
| English‑centric embedder vs multilingual users | M | M | detect locale; route unsupported languages to graceful fallback; evaluate a multilingual embedder if metrics demand |
| PCC judge availability/quota in CI | M | L | judges nightly not per‑PR; heuristics carry the PR gate |

---

## 11. Appendix

### 11.1 Glossary

- **Routing / tool selection:** deciding which capability (or none) should handle a query.
- **Abstention:** choosing "no tool" — answering directly or declining.
- **Bi‑encoder / embedding model:** encoder mapping text to vectors where cosine similarity ≈ semantic similarity.
- **Top‑k retrieval / Recall@k:** taking the k most similar tools; the rate at which the correct tool is among them.
- **Hybrid routing:** embedding retrieval (coarse) + LLM ranking (fine) cascade.
- **Hard negative:** a query very close to a tool's territory that must route elsewhere.
- **Guided generation:** decode‑time constraint of model output to a schema (`@Generable`/`@Guide`).
- **Hill‑climbing / evaluation‑driven development:** change one thing → re‑run evals → keep if the target metric improved.
- **Model judge:** a second, stronger model scoring outputs on a rubric (`ModelJudgeEvaluator`).

### 11.2 References

1. M. Brenndoerfer, *Tool Selection for LLM Agents: Routing Strategies and Implementation* — https://mbrenndoerfer.com/writing/tool-selection-llm-agents-routing-strategies
2. WWDC26 *Meet the Evaluations framework* — https://developer.apple.com/videos/play/wwdc2026/298/
3. Apple sample: *Book Tracker — Using Evaluations to evaluate an intelligent feature* — https://developer.apple.com/documentation/Evaluations/book-tracker-using-evaluations-to-evaluate-an-intelligent-feature
4. Apple docs: *Designing evaluation datasets* and *Designing effective evaluations* (Evaluations framework documentation)
5. Foundation Models framework documentation & WWDC25 sessions (Meet / Deep dive / Code‑along)
6. MLX Swift LM (`MLXEmbedders`) — https://github.com/ml-explore/mlx-swift-lm (embeddings reference in `skills/mlx-swift-lm/references/embeddings.md`)

### 11.3 Open questions (track in issues)

1. Bundle BGE‑small weights vs first‑run download (owner: release eng, due M2).
2. Do we expose a user setting for "always confirm before tools act"? (design)
3. Session reuse policy across turns when candidate sets differ by one tool — rebuild vs superset? (measure in M3)
4. Multilingual support scope for v1.

---

*Verify exact API signatures (FM `Tool` output type, `MLXEmbedders` loader names, Evaluations types) against the pinned SDK/package versions during M0 — all three surfaces have evolved across recent releases; this doc reflects their shapes as of Aug 2026.*
