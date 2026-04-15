# Research Backing

Cross-model code review — the architectural choice at the heart of Mangchi — is empirically supported by peer-reviewed research and independent industry studies. This document collects the primary sources an adopter can verify directly.

Only directly-verifiable academic papers and independent third-party research are cited. Secondary syntheses and vendor marketing numbers are intentionally excluded — the three sources below are sufficient to justify Mangchi's design without inflation.

---

## 1. Self-review is structurally flawed

> **Tsui et al. (2025). "Self-Correction Bench: Revealing and Addressing the Self-Correction Blind Spot in LLMs."**
> arXiv preprint [2507.02778](https://arxiv.org/abs/2507.02778). Presented at NeurIPS 2025 LLM Evaluation Workshop.

**Core finding**: Across 14 open-source LLMs, models exhibit a **64.5% self-correction blind spot** — they systematically fail to catch errors in their own output, but successfully correct identical errors when the errors are attributed to another source.

**Mechanism**: Training data rarely contains sequences where a model recognizes and corrects its own prior output, so the capability doesn't generalize naturally from normal pretraining.

**Why this matters for Mangchi**: If you ask the same model that generated code to review that code, you are structurally inside the 64.5% failure band. Switching to a different model family — with different training data, different architectures, and different alignment — breaks the blind-spot pattern.

---

## 2. The self-review gap is especially severe for code security

> **Gong et al. (2024). "How Well Do LLMs Serve as End-to-End Secure Code Agents?"**
> arXiv preprint [2408.10495](https://arxiv.org/abs/2408.10495).

**Core finding**: In a study of 4,900 code samples on SecurityEval with four models (GPT-3.5, GPT-4, Code Llama, CodeGeeX2), **over 75% of generated code was classifiable as insecure**, and models were **worst at repairing their own insecure code** while achieving meaningfully higher repair success rates on code produced by a different model.

**Why this matters for Mangchi**: Security review is one of Mangchi's five rotating axes. The paper provides direct evidence that cross-model review is especially load-bearing for the security dimension — the category where self-review is most likely to silently pass.

---

## 3. Different models catch different vulnerability classes

> **Semgrep (2025). "Finding Vulnerabilities in Modern Web Apps Using Claude Code and OpenAI Codex."**
> [semgrep.dev/blog/2025/finding-vulnerabilities-in-modern-web-apps-using-claude-code-and-openai-codex](https://semgrep.dev/blog/2025/finding-vulnerabilities-in-modern-web-apps-using-claude-code-and-openai-codex)

**Core finding**: On 11 real-world Python web applications, Claude Code and OpenAI Codex caught **different classes** of vulnerability. Specifically:

- Codex was notably stronger on **Path Traversal** (47% true-positive rate vs. Claude's lower rate)
- Claude was notably stronger on **IDOR** (22% vs. Codex's 0%)
- Findings between the two tools were **complementary rather than redundant**

The study also documents **non-determinism**: running the same tool on the same code three times produced 3, 6, and 11 findings across runs — a behavior Mangchi addresses with explicit audit trail per round rather than treating a single review as authoritative.

**Why this matters for Mangchi**: This is direct real-world evidence that the cross-model complementarity predicted by the academic literature is observable in production security tooling. It is the strongest third-party validation of the Claude-edit-plus-Codex-review architecture.

---

## What these sources do NOT claim

To avoid citation inflation common in AI tooling pitches, Mangchi deliberately does NOT claim the following based on these sources:

- **Specific "Nx more bugs" multipliers** — no academic paper in this list reports such a figure; claims like "3-5× more bugs" come from vendor reports that cite uneven mixtures of primary sources
- **Specific benchmark rankings** (SWE-bench, Terminal-Bench, etc.) — these numbers move monthly and should be checked against official leaderboards, not cited from static blog posts
- **Blind developer preference percentages** — typically from marketing-style comparison blogs, not independently replicable
- **Claims about OpenAI's own adversarial-review product** — unless you have verified the current state of any such plugin directly

Mangchi's value proposition does not depend on any of these; the three sources above are sufficient.

---

## Evidence from real-world use

In addition to the academic and industry research above, Mangchi's own operational record is documented in [`CASE-STUDIES.md`](CASE-STUDIES.md). The first case study (an OCR-pipeline hardening batch across 9 files) reports **23 real bugs caught including prompt-injection and European currency parsing corruption** — surfacing multiple defect classes of exactly the kind the research above predicts cross-model review would catch.

Research + reproducible track record + preserved audit artifacts. Verify the claims, then decide.
