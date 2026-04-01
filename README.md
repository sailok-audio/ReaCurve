# ReaCurve

A suite of REAPER scripts for generating and manipulating envelope points and automation items. Each tool can be launched standalone or together through the unified hub (`00_ReaCurve_Main.lua`).
Link to the github repository package for REAPER:

https://raw.githubusercontent.com/sailok-audio/ReaCurve/main/index.xml

## Tools

### RAND — Random Envelope Generator
Procedurally generates random automation curves.

- **Generation modes** — Free (point count) or grid-aligned (points per division)
- **Shape pool** — 6 shapes + Random-per-point mode
- **Seeded RNG** — Reproducible results, independent seeds for positions and shapes
- **Amplitude control** — 4 range presets, scaling, offset, quantize levels (2–16 steps)
- **Bezier tension** — Per-generation tension control
- **Preview** — Real-time graph with grid overlay

---

### LFO — Polygon LFO Generator
Generates automation shapes based on geometric polygon patterns.

- **Polygon control** — 2 to 16 sides, phase, warp
- **Segment shapes** — Linear, Square, Smooth, Fast Start, Fast End, Bezier (with tension)
- **Curve modes** — Off, Sinus, Alternate, Wave, Waveform Fold, Glitch
- **Cycle control** — Fixed count or grid-aligned
- **Quantize & align** — Snap vertices to a fixed grid
- **Amplitude ranges** — 4 presets (±100, ±50, 0→+100, -100→0)
- **Preset system** — File-based presets (`.lua`) saved in `LFOPresets/`, includes 9 built-in presets
- **Precision presets** — 5-tier quality control (Ultra-Precise → Aggressive)

---

### SCULPT — Envelope Manipulation Tool
Applies non-destructive transformations to existing envelopes.

- **Amplitude transforms** — Baseline, scale, skew, logarithmic tilt
- **Timing transforms** — Horizontal compress with anchor, vertical skew with pivot
- **Swing** — Offset even or odd-indexed points
- **Range selector** — Full, Upper, Lower, Center
- **Point shape & tension** — Edit shape type and Bezier tension of selected points
- **Multi-context** — Operates across multiple automation items and tracks simultaneously

---

### MORPH — Envelope Snapshot Morpher
Morphs smoothly between two captured envelope snapshots.

- **Capture modes** — Automation items or point selections, across multiple tracks
- **Morph slider** — Drag with Ctrl (fine) or Shift (slower) precision
- **Point reduction** — `shapeFit` algorithm: greedy forward scan + backward merge, keeps visual fidelity within a configurable error threshold
- **Precision presets** — 5 tiers from 0.10% to 3.00% max error
- **Preview** — Dual mini-graphs of the two captured sources

---



## Architecture

```
ReaCurve/
├── 00_ReaCurve_Main.lua      # Hub (4-tab unified window)
├── ReaCurve_LFO.lua          # LFO standalone entry point
├── ReaCurve_MORPH.lua        # MORPH standalone entry point
├── ReaCurve_RAND.lua         # RAND standalone entry point
├── ReaCurve_SCULPT.lua       # SCULPT standalone entry point
│
├── lib/
│   ├── LFO/                  # LFO logic (geometry, presets, state, writer)
│   ├── MORPH/                # MORPH logic (capture, engine, state, writer)
│   ├── RAND/                 # RAND logic (config, state, writer)
│   ├── SCULPT/               # SCULPT logic (engine, state, writer)
│   ├── UI/                   # Per-tool panel drawing (LFOPanel, MORPHPanel, …)
│   └── CommonFunction/       # Shared utilities
│       ├── EnvConvert.lua        # Linear ↔ envelope value conversion
│       ├── EnvelopeUtils.lua     # Range detection, normalization
│       ├── EnvWriter.lua         # Shared envelope write operations
│       ├── Generator.lua         # Seeded LCG RNG, curve interpolation
│       ├── GridUtils.lua         # REAPER grid & tempo calculations
│       ├── Logger.lua            # Centralized message bus
│       ├── ReaperUtils.lua       # REAPER API wrappers
│       ├── ScaleConverter.lua    # dB, semitone, BPM scale conversion
│       └── UI/
│           ├── Theme.lua             # Color palette & ImGui style helpers
│           ├── Widgets.lua           # Shared UI widgets
│           ├── Slider.lua            # Custom DrawList slider
│           ├── TitleBar.lua          # Custom title bar (dock, collapse, close)
│           ├── Toggle.lua            # Custom toggle widget
│           ├── StandaloneWindow.lua  # Standalone window management & persistence
│           └── Anim.lua              # Animation timing helpers
│
└── LFOPresets/               # Built-in and user LFO presets (.lua)
    ├── classics/             # Sine, square, triangle, sawtooth, ADSR, S&H
    ├── init.lua              # Default pentagon shape
    └── glitch.lua            # Glitch curve preset
```

## Dependencies

Install via **Extensions > ReaPack**:

| Extension | Required for |
|---|---|
| [ReaImGui](https://github.com/cfillion/reaimgui) | UI rendering |
| [SWS/S&M Extension](https://www.sws-extension.org/) | Envelope API access |
| [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) | Native file dialogs |

## License

[MIT](LICENSE)
