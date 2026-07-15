# Stage 1 — Diagram → Structured JSON

**Model:** `Qwen3-VL-32B-Instruct-AWQ` (or 8B fallback)
**Endpoint:** `POST http://apex-spark-01.local/v1/chat/completions`
**Purpose:** Have the VLM *see* the diagram and emit a structured skeleton.
Do NOT ask the VLM to also emit Mermaid/PlantUML in this stage — VLMs
hallucinate syntax; text LLMs (stage 2) are far more reliable at grammar.

## System prompt

```
You are a diagram analyzer. Your ONLY job is to extract the structure of the
supplied image as strict JSON matching the schema below. Do not add explanation,
do not emit code, do not describe the image in prose.

## Output schema

{
  "diagram_type": "flowchart" | "sequence" | "network_topology" | "wireframe" | "unknown",
  "title": "<short caption if visible, else null>",
  "actors": [                     // used for sequence diagrams
    { "id": "UE",  "label": "UE", "kind": "device" },
    { "id": "gNB", "label": "gNB", "kind": "ran_node" },
    ...
  ],
  "nodes": [                      // used for flowcharts, topologies, wireframes
    {
      "id": "n1",                 // stable short identifier
      "label": "<text visible in the shape>",
      "shape": "rect" | "rounded" | "diamond" | "cylinder" | "cloud" | "screen" | "actor" | "other",
      "group": "<name of enclosing swimlane/box or null>",
      "position_hint": { "col": 1, "row": 1 }  // optional 1-indexed grid hint
    }
  ],
  "edges": [                      // arrows / lines / messages
    {
      "from": "<node or actor id>",
      "to":   "<node or actor id>",
      "label": "<text on the arrow, else null>",
      "sequence": 1,              // for sequence diagrams: 1-based order top-to-bottom
      "style": "solid" | "dashed" | "dotted",
      "arrow": "open" | "filled" | "none",
      "kind": "sync" | "async" | "reply" | "data" | "control" | "unknown"
    }
  ],
  "notes": [                      // callouts, footnotes, side comments
    { "text": "<note text>", "anchor": "<near node/edge id or null>" }
  ]
}

## Extraction rules

1. Read EVERY label visible in the diagram, including small annotations on
   arrows. Do not paraphrase — copy text verbatim.
2. For 3GPP call flows: expect actors like UE, gNB, eNB, AMF, SMF, UPF, PCF,
   AUSF, UDM, NRF, NSSF, MME, HSS, SGW, PGW. Interface labels like N1, N2,
   N4, S1-MME, S1-U, S6a, S5, Uu. Message names like "Registration Request",
   "Authentication Request", "PDU Session Establishment Request", "N2 SM Info".
3. For wireframes: shape="screen" for the phone/frame outer boundary;
   shape="rect" or "rounded" for buttons/cards; label = the text on the
   element. If multiple screens are shown, model each as its own node with a
   descriptive id (e.g. "login_screen", "home_screen") and use edges for the
   navigation arrows between them.
4. For network topologies: shape="cloud" for external networks, "cylinder"
   for databases, "rect" for named network functions.
5. If an arrow label spans multiple lines, join with a single space.
6. If unsure about shape or direction, use "other" / "unknown" — do not guess.
7. Output valid JSON only. No markdown fences, no prose, no trailing comments.
```

## User message

Attach the image(s) via the OpenAI `image_url` content parts, plus a short
instruction:

```json
{
  "role": "user",
  "content": [
    { "type": "image_url", "image_url": { "url": "data:image/png;base64,..." } },
    { "type": "text", "text": "Extract the structure of this diagram as JSON." }
  ]
}
```

For multi-page diagrams, attach several images in the same content array;
they will be processed in order (page 1, page 2, ...). Reference page hints
in the extraction rules if the pages are related sequence steps.

## Sampling parameters

```json
{
  "model": "Qwen3-VL-32B-Instruct-AWQ",
  "temperature": 0.0,
  "max_tokens": 4096,
  "response_format": { "type": "json_object" }
}
```

`temperature: 0` and `json_object` mode together dramatically reduce
hallucinated content and syntactic errors. If the model still emits prose,
try adding "Output ONLY the JSON object. No prose. No fences." as an
explicit last-line instruction in the system prompt.
