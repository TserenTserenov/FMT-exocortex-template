# IWE Visual Diagrams for Beginners

> Diagrams in Mermaid format. They render in GitHub, VS Code (with the Mermaid extension), and most Markdown editors.

---

## Diagram 1. Four IWE Components

> IWE = OS for intellectual work. Four components, you at the center, tools are delivery mechanisms.

```mermaid
graph TB
    subgraph core["<b>THINKING CORE</b>"]
        direction LR
        THEORIES["<b>Theories</b><br/>Systems Thinking<br/>Methodology, management"]
        EXO["<b>Exocortex</b><br/>Second memory:<br/>plans, context, conclusions"]
        PACK["<b>Pack</b><br/>Second principles:<br/>your domain knowledge"]
    end

    subgraph culture["<b>WORK CULTURE</b>"]
        direction LR
        PROTOCOLS["<b>Protocols</b><br/>Opening/Work/Closing, ArchGate<br/>Day Open/Close"]
        SKILLS["<b>Skills</b><br/>Capture, Self-correction<br/>Distinctions"]
        FORMATS["<b>Formats</b><br/>Pack structure<br/>WP-context"]
    end

    subgraph mastery["<b>MASTERY MODEL</b>"]
        M1["Apprentice"] --> M2["Intellectual"] --> M3["Professional"] --> M4["Researcher"] --> M5["Enlightener"]
    end

    subgraph community["<b>COMMUNITY</b>"]
        COMM["<b>Creator environment</b><br/>Exchange, review, support"]
    end

    subgraph pair["<b>THE PAIR: YOU + AI</b>"]
        direction LR
        USER["<b>You</b><br/>Make decisions<br/>Think, direct"]
        AI["<b>Claude Code</b><br/>Amplifies, structures<br/>Handles routine"]
        USER <-->|"collaboration"| AI
    end

    core -->|"what you think with"| pair
    culture -->|"how you work"| pair
    mastery -->|"where you grow"| pair
    community -->|"where you live"| pair

    style core fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style culture fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style mastery fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style community fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style pair fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
```

---

## Diagram 2. User Journey: From Zero to a Working IWE

> Five steps. Each step has a concrete outcome.

```mermaid
graph LR
    S1["<b>Step 1</b><br/>Understand why<br/><i>~15 min</i><br/>────────<br/>Read this<br/>document"]
    S2["<b>Step 2</b><br/>Install<br/><i>~20 min</i><br/>────────<br/>VS Code + Claude Code<br/>+ GitHub account"]
    S3["<b>Step 3</b><br/>First session<br/><i>~30 min</i><br/>────────<br/>Strategic document<br/>+ weekly plan"]
    S4["<b>Step 4</b><br/>Practice<br/><i>1–2 weeks</i><br/>────────<br/>Opening/Work/Closing rituals<br/>every day"]
    S5["<b>Step 5</b><br/>Theories<br/><i>your own pace</i><br/>────────<br/>Systems Thinking<br/>and courses"]

    S1 -->|"AI will help"| S2
    S2 -->|"Claude guides"| S3
    S3 -->|"you adapt"| S4
    S4 -->|"ready for depth"| S5

    style S1 fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style S2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S3 fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style S4 fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
    style S5 fill:#fce4ec,stroke:#e53935,stroke-width:2px
```

---

## Diagram 3. Opening/Work/Closing Ritual (Daily Cycle)

> One pattern for the day and for each work session.

```mermaid
graph TD
    O["<b>OPENING</b><br/>«Open the day»<br/>────────<br/>Plan for today<br/>Priorities<br/>Yesterday's context"]
    R["<b>WORK</b><br/>Execute tasks<br/>────────<br/>At each work milestone:<br/>record conclusions<br/>and knowledge"]
    Z["<b>CLOSING</b><br/>«Close the day»<br/>────────<br/>Day results<br/>Update plans<br/>What is next"]

    O -->|"morning"| R
    R -->|"evening"| Z
    Z -->|"tomorrow"| O

    style O fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style R fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style Z fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
```

---

## Diagram 3.5. Work Culture — Three Element Types

> 14 elements of IWE work culture, divided into three types. Culture is what you get paid for.

```mermaid
graph TD
    subgraph culture["<b>WORK CULTURE (14 elements)</b>"]
        direction TB

        subgraph protocols["<b>Protocols</b> (follow step by step)"]
            P1["Opening/Work/Closing"]
            P2["ArchGate"]
            P3["Day Open/Close"]
            P4["Week Close"]
        end

        subgraph skills["<b>Skills</b> (build through practice)"]
            S1["Capture"]
            S2["Self-correction"]
            S3["Distinctions"]
            S4["WP Gate"]
        end

        subgraph formats["<b>Formats</b> (structure to standard)"]
            F1["Pack structure"]
            F2["WP-context"]
            F3["Collapsible sections"]
        end
    end

    protocols -->|"formalized"| RESULT["<b>Result:</b><br/>established work culture<br/>= creator's lifestyle"]
    skills -->|"situational"| RESULT
    formats -->|"to standard"| RESULT

    style protocols fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style skills fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style formats fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style RESULT fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
```

---

## Diagram 4. IWE Connection Path (Local Environment Setup)

> Start with Stage 1. Add components as you are ready. This is building your own environment — not an access tier (T0→T4, DP.ARCH.002) and not a Mastery stage (FORM.089).

```mermaid
graph BT
    E1["<b>Stage 1 — Start</b><br/>Claude Code + exocortex<br/>────────<br/>An AI assistant that<br/>remembers you"]
    E2["<b>Stage 2 — Rituals</b><br/>+ Opening/Work/Closing + daily plan<br/>────────<br/>Structured work<br/>without losing context"]
    E3["<b>Stage 3 — Knowledge Base</b><br/>+ Pack + bot @aist_me_bot<br/>────────<br/>Knowledge base +<br/>mobile access"]
    E4["<b>Stage 4 — Automation</b><br/>+ roles + agents<br/>────────<br/>AI agents work<br/>independently"]

    E1 --> E2
    E2 --> E3
    E3 --> E4

    style E1 fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style E2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style E3 fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style E4 fill:#fce4ec,stroke:#e53935,stroke-width:2px
```

---

## Diagram 5. Theories → Principles → Practice

> IWE is grounded in theories. Theories produce principles. Principles are embedded in the AI and studied by you.

```mermaid
graph TD
    THEORIES["<b>THEORIES</b><br/>Systems Thinking, methodology<br/>management, engineering<br/><i>Courses</i>"]

    ZP["<b>Zeroth principles (ZP)</b><br/>Basic rules of thinking<br/><i>Provided by IWE</i>"]
    FPF["<b>First principles (FPF)</b><br/>Correctness framework<br/><i>Provided by IWE</i>"]
    PACK["<b>Second principles (Pack)</b><br/>Domain knowledge<br/><i>Created by you</i>"]
    DS["<b>Third principles (DS)</b><br/>Implementation<br/><i>Created by you + AI</i>"]

    THEORIES -->|"produce"| ZP
    ZP -->|"form"| FPF
    FPF -->|"guide"| PACK
    PACK -->|"define"| DS

    USER["<b>You</b><br/>Study theories →<br/>Systems Thinking"]
    AI["<b>AI</b><br/>Theories embedded in rules"]

    THEORIES -.->|"you study"| USER
    ZP -.->|"embedded"| AI
    FPF -.->|"embedded"| AI
    USER -->|"creates"| PACK
    PACK -->|"enriches"| AI
    AI -->|"helps structure"| PACK

    style THEORIES fill:#e8eaf6,stroke:#3f51b5,stroke-width:2px
    style ZP fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style FPF fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style PACK fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style DS fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style USER fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
    style AI fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
```

---

## Diagram 6. Exobody vs Prosthetic

> The key IWE Distinction: AI **extends** thinking, it does not **replace** it. IWE = exobody for thinking.

```mermaid
graph LR
    subgraph bad["<b>PROSTHETIC</b>"]
        direction TB
        B1["AI thinks for you"]
        B2["You stop<br/>developing"]
        B3["Dependence<br/>on the tool"]
        B1 --> B2 --> B3
    end

    subgraph good["<b>EXOBODY (IWE)</b>"]
        direction TB
        G1["AI handles routine"]
        G2["You think<br/>better and faster"]
        G3["Skills grow<br/>together with the tool"]
        G1 --> G2 --> G3
    end

    style bad fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style good fill:#e8f5e9,stroke:#43a047,stroke-width:2px
```

---

## Diagram 7. Problem → Solution

> Mapping between common problems and IWE components.

```mermaid
graph LR
    P1["Knowledge<br/>gets lost"]
    P2["Plans<br/>do not work"]
    P3["AI does not<br/>truly help"]

    S1["<b>Thinking Core</b><br/>Exocortex + Pack<br/>+ GitHub"]
    S2["<b>Work Culture</b><br/>Opening/Work/Closing rituals<br/>+ Claude Code"]
    S3["<b>Core + culture</b><br/>Claude Code<br/>+ exocortex"]

    P1 -->|"solved by"| S1
    P2 -->|"solved by"| S2
    P3 -->|"solved by"| S3

    style P1 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style P2 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style P3 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style S1 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S3 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
```

---

*Created: 2026-03-17 | Updated: 2026-03-27 | WP-120 | [FMT-exocortex-template](https://github.com/TserenTserenov/FMT-exocortex-template)*