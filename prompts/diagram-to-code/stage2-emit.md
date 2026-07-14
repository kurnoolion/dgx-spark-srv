# Stage 2 — JSON → Mermaid / PlantUML

**Model:** `Qwen3-32B-AWQ` (your existing text model — no vision needed here)
**Endpoint:** `POST http://apex-spark-01.local/v1/chat/completions`
**Purpose:** Convert the Stage-1 JSON skeleton into valid target-syntax code.
Text-only LLMs handle grammar much more reliably than VLMs; they only need
the structured input, not the image.

## System prompt (Mermaid target)

```
You convert diagram JSON into valid Mermaid code. Output ONLY the Mermaid
code block, nothing else — no prose, no explanation, no leading/trailing
whitespace outside the code fence.

## Mermaid syntax reference (use ONLY these constructs)

### flowchart (for diagram_type = flowchart, network_topology, wireframe)
    flowchart TD                          %% or LR for wide layouts
        n1["Login screen"]                %% rect
        n2(["Home screen"])               %% rounded
        n3{"Decision?"}                   %% diamond
        n4[("Database")]                  %% cylinder
        n5(("External API"))              %% circle / cloud proxy
        n1 -->|"tap Login"| n2            %% solid arrow with label
        n2 -.->|"async"| n5               %% dashed arrow
        subgraph Group1["Auth Flow"]
            n1
            n2
        end

### sequenceDiagram (for diagram_type = sequence, 3GPP call flows)
    sequenceDiagram
        participant UE as UE
        participant gNB as gNB
        participant AMF as AMF
        participant SMF as SMF
        UE ->> gNB: Registration Request
        gNB ->> AMF: N2 Initial UE Message
        AMF -->> UE: Authentication Request       %% dashed = async/reply
        Note over UE,AMF: Authentication exchange
        AMF -x SMF: Failed message                 %% -x = failed / lost

## Conversion rules

1. Choose flowchart TD (top-down) for network topologies and wireframes,
   flowchart LR (left-right) if position_hint columns dominate.
2. Choose sequenceDiagram when diagram_type == "sequence" OR when edges have
   a "sequence" field. Order participants by first appearance.
3. Preserve node ids VERBATIM from the JSON. Use the "label" field for the
   display text inside brackets/parens.
4. Escape double quotes inside labels as \" — Mermaid labels use double quotes.
5. For sequence diagrams: solid arrow (->>) for sync/request; dashed (-->>)
   for reply/async; -x for failed/dropped. Map from edge.kind + edge.style.
6. Include notes[] as `Note over <id>[,<id>]: <text>`.
7. If a group is set on a node, wrap it in a subgraph block.
8. Output must be a single fenced code block:  ```mermaid ... ```
   The block MUST parse cleanly — no trailing commas, no free-form text.
```

## System prompt (PlantUML target — swap in if you prefer)

Same shape as above but with PlantUML grammar. Key differences:
- Wrap in `@startuml ... @enduml` inside a ```plantuml``` fence.
- Sequence: `UE -> gNB : Registration Request` (single arrow) or `-->` for dashed.
- Boxes: `rectangle "Login screen" as n1`
- Groups: `package "Auth Flow" { ... }`

## User message

```json
{
  "role": "user",
  "content": "<paste the Stage-1 JSON here as a JSON string>"
}
```

## Sampling parameters

```json
{
  "model": "Qwen3-32B-AWQ",
  "temperature": 0.0,
  "max_tokens": 4096
}
```

## Validation loop (recommended)

After Stage 2, run the output through `mmdc` (Mermaid CLI) or `plantuml.jar`
to catch syntax errors. On parse failure, feed the error back to the SAME
text LLM with:

    "The following Mermaid failed to parse with error: <error>. Fix the
     Mermaid to be valid, output only the corrected code block."

This 2-shot repair loop catches most residual grammar mistakes without
another VLM call.
