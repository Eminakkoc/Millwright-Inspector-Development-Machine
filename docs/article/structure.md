# Article Structure — Millwright-Inspector Methodology

A dev.to article structure proposal.

## Decisions captured so far

| Decision | Choice |
| --- | --- |
| Intent | Practical pattern catalog — methodology-first, tool-agnostic |
| Target reader | Engineering leads / staff+ |
| Length | ~2,300 words / ~9 min read |
| Plugin visibility | Referenced once at the end as one implementation among many |
| Tone | Positive, no criticism of the traditional approach; tiny, neutral mentions only |
| Section order | What → Roles → Workflow elements → Comparison → Why it scales → Trying it |

## Cover image & metadata

- **Cover image**: `docs/article/mi-cover.svg`
- **Logo / icon**: `docs/article/icon.svg` — placed once near the closing "Trying it" section as a small visual anchor next to the plugin reference (a methodology article shouldn't lead with branding, but the icon belongs alongside the project link).
- **Title (working)**: *Millwright-Inspector: A Methodology for Software Development with AI Coding Agents*
- **Tags (dev.to max 4)**: `#ai`, `#agenticai`, `#softwareengineering`, `#productivity`
- **TL;DR callout at the very top** (3–4 lines): introduces the two roles, the artifact, and the relay in one breath so skimmers walk away with the core idea even if they bounce.

---

## 1. What is Millwright-Inspector *(~300 w)*

Opens with a one-paragraph framing: AI coding agents have become genuinely capable, and teams are now shaping how to work alongside them. The traditional flow remains the foundation that most teams operate on; **Millwright-Inspector adds a few structural pieces on top** so AI agents can take on more of the building while humans stay confidently in the loop.

One-sentence definition (blockquote callout):

> *Millwright-Inspector is a methodology where an AI agent generates each artifact of a software workflow, a human reviews it, and that approval is what advances the next step.*

Closes with a "here's what we'll cover" mini-roadmap: roles → artifacts → relay → repository → comparison → why it scales.

**Tone guardrails**: no claim that current practice is broken. Existing practice is "the foundation"; MI is "additional structure" laid alongside it.

---

## 2. The actors and their roles *(~350 w)*

Introduces the two roles using their factory-floor naming.

- **The Millwright (AI agent)** — owns artifact generation, summons sub-agents when needed, advances the workflow when an inspector approves, and makes the machine run.
- **The Inspector (human)** — supplies raw materials (specs, notes, decisions), reviews each artifact, and signals when the next step can begin. Doesn't write production artifacts directly; their authority lives in approvals and prompts.

Short subsection on **why renaming both sides matters**: the legacy "developer" identity bundled architect + coder + tester + reviewer + PM. Pulling the building work out from under that umbrella gives both the human and the AI a cleaner shape — and sidesteps the "AI takes the developer's job" framing entirely.

A compact two-column table summarizing what each role owns / doesn't own ends the section.

| | Millwright (AI) | Inspector (human) |
| --- | --- | --- |
| Generates artifacts | Yes | No |
| Reviews artifacts | No | Yes |
| Advances the workflow | When approved | By approving |
| Owns the git branch | No | Yes |
| Owns raw inputs (journal, specs) | No | Yes |

---

## 3. The elements of the workflow *(~750 w)*

The conceptual heart of the article. Three sub-sections, each labeled with an H3.

### 3.1 Context Artifacts *(~200 w)*

Definition: every document the workflow produces is a **context artifact** — a file that does two things at once:

1. A **human-readable inspection surface** an inspector can review.
2. A **machine-readable context carrier** the next agent in the workflow reads back to pick up.

The same `requirements.md` an inspector approves at one step is the same file the implementer reads at the next. Concrete examples: `requirements.md`, design notes, UML diagrams, manual test plans, review findings, completion summaries.

### 3.2 The Context Artifact Relay *(~350 w)*

**Image**: `docs/article/Context Artifact Relay.png` placed at the top of this subsection with a caption.

Walks through the relay analogy: an electrical relay is a switch that passes nothing until a control signal energizes its coil. In this methodology, the millwright drafts the artifact, but it doesn't flow into the next step on its own — it waits. The inspector's approval is the control signal; the signal closes the circuit, and the artifact becomes input to the next step.

Blockquote callout for the one-line summary:

> *The millwright fills the payload. The inspector throws the switch.*

Briefly mentions three properties of the relay — keep it short, dev.to readers aren't reading a spec:

- **Durable** — the payload is on disk, so the open circuit survives session breaks, model swaps, and multi-day pauses.
- **Layered** — what passes forward is a compact, purpose-built briefing rather than every previous byte.
- **Cascading** — one signal can carry the work through several automated steps.

Then two example sub-blocks with the example images and one-line captions:

- **Image**: `docs/article/CAR-Example-Requirements.png` — *Generating a requirements file. Context: a TODO list. Output: an approved `requirements.md`.*
- **Image**: `docs/article/CAR-Example-Code-Review.png` — *Reviewing a pull request. Context: the codebase + lessons-learned + UML diagrams. Output: an approved findings file.*

### 3.3 The Context Artifact Repository *(~200 w)*

The artifacts live in three folders that sit alongside the codebase:

| Folder | What lives there |
| --- | --- |
| **Journal** | Raw inputs — transcripts, notes, specs, PDFs, design hand-offs |
| **Quest** | Working state of the active cycle — tasks, summaries, queue, progress |
| **Workflow Stream** | Per-feature design and implementation artifacts — requirements, diagrams, reviews, test plans |

Frame it positively: everything the workflow remembers lives on disk in plain Markdown, so the workflow itself survives session breaks, model swaps, and multi-day pauses. **The codebase becomes a fourth artifact** alongside these three — readable by the same agents that read everything else.

---

## 4. Putting it side by side *(~200 w)*

**Image**: `docs/article/Workflow.png` placed at the top of this section.

A short, neutral framing: the familiar stages (analysis, design, implementation, test) stay where they are; what Millwright-Inspector adds is the Context Artifact Repository on the side, plus a relay at each step that reads from and writes to it. One short paragraph. No claim about which is better. The visual carries the comparison.

If this section feels too contrast-heavy in draft, it can shrink to caption-and-image with one sentence of body.

---

## 5. Where this scales *(~550 w)*

The advantages section — drawn from `docs/article/article.md`. Five short sub-sections, each one or two paragraphs, each tied back to a property of the methodology so it reads as *consequence*, not *claim*.

1. **One inspector, multiple workflows.** Because the relay holds artifacts on disk and waits for an inspector's signal, an inspector doesn't need to hold a workflow's full context in their head. They can approve one workflow's requirements, let the next step run, and switch to inspect another workflow's diagrams in the meantime.

2. **Inspectors can review each other.** A generated `requirements.md` is just a file — it can be opened for a second pair of eyes the same way pull requests are today. Collaboration across inspectors is a natural extension, not a separate workflow.

3. **Tasks become queryable artifacts.** When TODOs live in the artifact repository (not only in Jira / Linear), anyone — including non-developers — can point their own agent at them: *"summarize what shipped this week," "which workflows are blocked for more than an hour," "is the loyalty feature done?"*.

4. **The codebase joins the artifacts everyone can read.** With agents in the picture, the codebase is just another readable input. PMs, analysts, and customers can ask grounded questions of it via their own agents instead of asking a developer to translate.

5. **The repository invites lightweight tooling.** Because everything is plain Markdown with structured frontmatter, small custom tools fall out naturally — a notifier when a workflow finishes, a dashboard for blocked workflows, a metric for cycle time. The methodology doesn't prescribe these; it makes them cheap.

End with a compact bulleted recap of these five so skimmers leave with all of them in view at once.

---

## 6. Trying it *(~150 w)*

Honest, low-pressure closing.

- **Small icon** (`docs/article/icon.svg`) inline at the start of this section, sized small (~32–48px) — acts as a visual anchor for the methodology/project, marking the transition from "ideas" to "where to find it."
- These patterns are **tool-agnostic** — the relay shape, the artifact-as-handoff, the repository structure can be applied with any agentic stack a team is already using.
- One concrete implementation: a Claude Code plugin called *millwright-inspector-development-machine* that wires this together end-to-end. Link to the GitHub repo and `millwright-inspector.dev`.
- Invitation: *"I'd love to hear how teams are organizing their own AI-assisted workflows — comments open."*

---

## dev.to formatting notes

Writing-time reminders, not separate sections.

- **Subheadings every 200–300 words.** dev.to readers skim; the H2 / H3 ladder carries them through.
- **Bold the key term on first mention** — *Millwright*, *Inspector*, *Context Artifact*, *Context Artifact Relay*, *Context Artifact Repository*. Once each.
- **Blockquote callouts** for the two definitional sentences (the one-line definition in §1, the one-line summary in §3.2). Quote blocks render distinctly on dev.to and become natural pull-quotes when shared.
- **Three small tables** — the role-ownership table in §2, the repository table in §3.3, and an optional decisions table at the top of the article if you want a "quick context" feel.
- **Image captions** rather than alt-text-only — captions are visible on dev.to and let figures carry context for skimmers.
- **No code fences needed** unless a tiny frontmatter sample is added in §3.1 as flavor.
- **Liquid embed for the repo** at the closing: `{% embed https://github.com/Eminakkoc/Millwright-Inspector-Development-Machine %}` renders as a GitHub card on dev.to.
- **Save as draft, preview, publish** — dev.to's preview always surfaces subheading-density issues that aren't visible in source.

---

## Word-count budget

| Section | Target | Running total |
| --- | ---: | ---: |
| TL;DR + intro to §1 | 50 | 50 |
| §1 What is MI | 300 | 350 |
| §2 Actors | 350 | 700 |
| §3.1 Context Artifacts | 200 | 900 |
| §3.2 The Relay | 350 | 1,250 |
| §3.3 The Repository | 200 | 1,450 |
| §4 Side by side | 200 | 1,650 |
| §5 Where this scales | 550 | 2,200 |
| §6 Trying it | 150 | 2,350 |

Lands in the 2,000–2,500 / 8–10 min read range targeted up front.

---

## Open items before writing

These are deliberately left for the author to settle, but each one slightly changes the shape:

1. **Title** — the working title is functional. A sharper alternative might be *"Millwright and Inspector: a methodology for working with AI coding agents."*
2. **Tags** — `#ai`, `#agenticai`, `#softwareengineering`, `#productivity`. Swap `#productivity` for `#leadership` if the engineering-lead pitch should be more pointed; swap for `#architecture` if the focus is structural.
3. **§5 ordering** — the five advantages are currently ordered "from individual to organizational." Reordering to lead with "tasks become queryable artifacts" lands the PM / non-developer angle earlier; the current ordering lands the parallel-work angle earlier.
4. **Optional §3 frontmatter snippet** — showing a tiny YAML frontmatter example (id, contributors, date) in §3.1 makes "context artifact" feel concrete; leaving it out keeps the article purely conceptual. Decision belongs to the author.
