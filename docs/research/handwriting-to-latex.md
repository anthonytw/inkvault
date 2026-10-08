# Handwriting → LaTeX on device (G1 part 2): research and what was built

Status 2026-10-08. Companion to `docs/attachments.md` §14 G1 (part 1, math items, is on `main`
since #96). This note answers four questions: which on-device recognisers exist for iPadOS 26 /
macOS 26, which of them we may ship, how good and how fast they are, and what this branch builds
around the one we pick. It does not relitigate decisions in `docs/HANDOFF.md` (on-device AI only,
GPL-3.0 + App Store exception, iPadOS 26 floor).

**Short answer.** No Apple API reads math. The models that read handwritten math well are all
trained, at least in part, on CROHME or HME100K (research-only or undocumented terms); the
smallest good one (Texo, 20 M parameters) is AGPL-3.0. Accuracy and size are good enough for a
first version; the **licence of the training data is not settled**, so this branch ships the
whole pipeline behind a setting with **no model in the catalogue** (`MathModelCatalog.entries` is
empty) and leaves the choice to the maintainer (§6). Everything else is built and tested: lasso,
rasterisation, Core ML inference (run on a tiny random model in macOS CI), beam search, clean-up,
the one-delta conversion with undo, a hash-verified model store and download, and
`sempere recognize-math`.

## 1. Constraints

- On device only, no server recognition, ever (DESIGN.md goal 5, HANDOFF decisions).
- The app is GPL-3.0-or-later with an App Store exception (`LICENSE-EXCEPTION`). Code and
  weights we distribute must be under GPL-3-compatible, redistributable terms (MIT, BSD,
  Apache-2.0, GPL-3, CC BY, CC BY-SA 4.0 one-way). Non-commercial (NC), research-only and
  unlicensed material is out. The exception covers only code the project holds copyright in, so
  third-party AGPL/GPL code in the App Store build needs its author's own permission.
- iPadOS 26 on an iPad Pro 12.9" 4th gen (A12Z, 6 GB RAM, 2020 Neural Engine), and Macs (Catalyst).
- Input is our own vector ink: both online (stroke) and offline (image) models fit.

## 2. Apple

| API | Math? | Availability | Verdict |
| --- | --- | --- | --- |
| Vision `VNRecognizeTextRequest` | no: text lines only | iOS 13+ | used for handwriting search already (`VisionText`) |
| Vision `RecognizeDocumentsRequest` | no: `DocumentObservation.Container` has text, paragraphs, lists, tables, barcodes, title only | iOS 26 | no |
| PencilKit `PKStrokeRecognizer` | no: `recognizedText(strokeIDs:)`, `indexableContent`, `search`; WWDC26 session 203 never mentions math | **iPadOS/macOS 27 only** | no (text only, and the user's iPad is capped at 26) |
| Math Notes (Notes / Calculator) | yes | system feature, no public API | no |

Sources: developer.apple.com/documentation/vision/documentobservation/container,
developer.apple.com/documentation/pencilkit/pkstrokerecognizer,
developer.apple.com/videos/play/wwdc2026/203/.

## 3. Open models

Accuracy is ExpRate (whole expression exactly right) on CROHME 2014/2016/2019 unless noted. "HWE"
is UniMERNet's handwritten-expression test set (6 332 samples), reported as BLEU / edit distance.
"(search)" marks a figure taken from a search snippet of the primary page, which the research
environment could not open (Hugging Face and arXiv are blocked by its proxy); treat it as likely,
not verified.

| Model | Code / weights licence | Training data | Size | Handwritten accuracy | Export | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **Texo** (alephpi, 2026, arXiv 2602.17189) | **AGPL-3.0** (verified); the author granted an LGPL exception to one other app | distilled from PP-FormulaNet-S, fine-tuned on UniMER-1M (includes CROHME and HME100K) | **20 M** params (HGNetV2-B4 encoder, 2-layer mBART decoder, d = 384); ≈ 40 MB fp16 | HWE BLEU 0.861, edit distance 0.0995 (README, verified) | ONNX; runs in a browser | **best size/accuracy**; needs the author's grant for the App Store build, and the data question |
| **UniMERNet** T / S / B (OpenDataLab) | Apache-2.0 / Apache-2.0 (code verified, weights search) | UniMER-1M (1 061 791 pairs; handwritten part from CROHME and HME100K, which UniMER does not redistribute "for copyright compliance", search) | T ≈ 100 M (repo 441 MB), S 202 M, B 325 M | HWE BLEU 0.883 / ED 0.078 (T); CROHME 14/16/19 ≈ 67.4 / 68.4 / 65.4 (cited in the TexTeller paper, search) | PaddleX port; PyTorch | good accuracy, clean code licence; 5× Texo's size and the same data question |
| **TexTeller 3.0** (OleehyO) | Apache-2.0 / Apache-2.0 (badge) | latex-formulas-80M; its handwritten part "collected from existing open-source handwritten datasets (including both training and test sets)" | **298 M** params | 88.0 / 85.9 / 85.8, HME100K 90.7 (paper, model trained without the test sets; the public weights include them) | ONNX | too large for an A12Z; scores of the public weights are contaminated |
| PP-FormulaNet-S / plus-S (PaddleOCR) | Apache-2.0 | papers, books, exams (printed) | 57 M (224 MB) / 248 MB | printed En-BLEU 87.0 / 88.7; no handwritten benchmark found | Paddle; ONNX via paddle2onnx | plausible, no evidence on handwriting |
| Pix2Text MFR 1.5 (breezedeus) | MIT / MIT (search) | "formula images", handwriting share unknown | TrOCR-style, ONNX encoder 87.5 MB + decoder 32 MB fp32 (search) | no handwritten benchmark | **ONNX only**, no PyTorch weights (issue #202), decoder without KV cache | no numbers to judge; ONNX → Core ML has no supported path in coremltools 8+ |
| pix2tex / LaTeX-OCR | MIT | im2latex-100k + rendered Wikipedia/arXiv formulas | ViT-hybrid encoder, 4-layer decoder | printed only ("support handwritten formulae: kinda done") | none | printed only |
| Texify | GPL-3.0 / CC BY-SA 4.0 | web LaTeX images, im2latex | Donut-based | none (printed) | none | not for handwriting; successor surya is OpenRAIL-M (incompatible) |
| TAMER / ICAL / CoMER | **no licence file** | CROHME, HME100K | 6–8 M | TAMER 61.2 / 60.3 / 62.0, HME100K 68.5; ICAL 60.6 / 58.8 / 60.5; CoMER 58.4 / 57.0 / 59.1 | none | not redistributable |
| PosFormer | "only free for academic research purposes" | CROHME, M2E | 6.4 M | 62.7 / 61.0 / 65.0 (search) | none | not usable |
| BTTR | MIT (template never filled in) | CROHME | ≈ 6 M | 54.0 / 52.3 / 53.0 | none | usable code, weak accuracy |
| CAN | MIT | CROHME / HME100K | 17 M (search) | unverified | none | not researched further |
| Seshat (falvaro) | **GPL-3.0** | CROHME (bundled models) | small; grammar + BLSTM, **online (stroke) input**, C++ | ≈ 37 % on CROHME 2014 (the winning UPV system, search) | native C++ | licence fits, accuracy far behind |
| TrOCR fine-tunes on MathWriting (`fhswf/TrOCR_Math_handwritten`, `tjoab/latex_finetuned`) | AFL-3.0 (GPL-incompatible) / MIT (unverified) | **MathWriting, CC BY-NC-SA 4.0** | 334–558 M | 14.9 % CER (tjoab, own set) | ONNX | NC data, too large |
| UniRec-0.1B (OpenOCR) | Apache-2.0 | UniRec40M (printed text and formulas) | 0.1 B; a Core ML port exists (82 MB encoder + 191 MB decoder fp16) whose card warns the encoder computes wrongly on the Neural Engine | no handwritten results | Core ML | not handwriting |
| MyScript iink | proprietary SDK | — | — | good | — | excluded (licence, closed) |

Datasets: **MathWriting** (Google, 230 k human + 400 k synthetic online inks) is CC BY-NC-SA 4.0
(verified); **CROHME** 2011–2013 is "freely available only for research purpose without any
commercial use" (search; later editions have no terms we could find); **HME100K** (TAL) terms are
not published and UniMER withholds it; **im2latex-100k** has no data licence (code MIT).

Licence sources: raw.githubusercontent.com LICENSE files of each repository (alephpi/Texo,
opendatalab/UniMERNet, OleehyO/TexTeller, PaddlePaddle/PaddleOCR, breezedeus/Pix2Text,
lukas-blecher/LaTeX-OCR, VikParuchuri/texify, falvaro/seshat, Topdu/OpenOCR, Green-Wood/BTTR,
LBH1024/CAN, harvardnlp/im2markup) and READMEs (TAMER, ICAL, CoMER, PosFormer), checked 2026-10-08.

### Findings

1. **No Apple API**, on 26 or 27, returns math.
2. **Every model that reads handwritten math well depends on CROHME and/or HME100K.** The code and
   weight licences (MIT, Apache-2.0, AGPL) do not settle whether weights trained on research-only
   data may be shipped or offered in an App Store app. This is the blocking question, and it is a
   legal one for the maintainer, not an engineering one.
3. **Size**: on an A12Z, ≤ 100 M parameters (≤ 200 MB fp16, ≤ 100 MB 8-bit) is the realistic
   ceiling; 20 M (Texo) is comfortable. TexTeller (298 M) is out.
4. **Licence fit**: UniMERNet-T (Apache-2.0) is the cleanest code licence with good handwritten
   numbers; Texo is better sized but AGPL (needs its author's permission for the App Store build,
   which the author has granted another app before).

## 4. Measurements made here

The research VM cannot reach Hugging Face, so no real weights were converted or evaluated here,
and there is no Apple hardware: **accuracy on the user's handwriting and A12Z latency remain to be
measured** (§6). What was measured, on the VM's CPU (Intel Xeon 2.1 GHz, 4 threads, PyTorch 2.7,
random weights of the same shapes):

| Shape (encoder / decoder) | Params | fp16 | Encoder | Decoder step, padded to 16 / 64 / 256 tokens | 64 tokens, beam 3: padded to 256 | with length buckets | with a KV cache |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ≈ Texo (ViT d384×6 / d384×2, 1 200 tokens) | 16.7 M | 33 MB | 47 ms | 4.4 / 5.6 / 15.2 ms | 2.96 s | **1.02 s** | 0.27 s |
| ≈ UniMERNet-T (ViT d512×12 / d512×6, 50 000 tokens) | 89.9 M | 180 MB | 159 ms | 25 / 36 / 85 ms | 16.4 s | **6.2 s** | 1.28 s |

(`tools/math-model/bench.py` reproduces the table; the totals add the encoder once.) Readings:

- The decoder dominates, not the encoder. Re-running it over the whole padded sequence each step
  (what a converted model without KV cache does) costs 3–12× a cached step.
- **Length buckets** (Core ML enumerated shapes 16, 32, 64, …, each step padded to the shortest
  that fits) recover about 3× and are built (`MathModelManifest.Decoder.lengths`).
- A stateful KV cache (coremltools 8 `StateType`, iOS 18+) is the next 4–6×; it needs a
  model-specific decoder wrapper, so it waits for the model choice.
- An A12Z GPU is roughly in the range of this 4-thread CPU for such small models (published
  numbers for ViT/Swin encoders on A12Z do not exist; the Neural Engine can compute some
  encoders wrongly, as the UniRec Core ML card reports, so `computeUnits` defaults to `cpuAndGPU`).
  For a Texo-sized model the estimate is ≈ 1 s per equation with buckets, ≈ 0.3 s with a cache: within
  the 1 s target. A UniMERNet-T-sized model needs the cache.
- Pure-Swift costs around the model are small: `MathInkImage.render` draws a few dozen strokes
  into a 384 × 384 image in milliseconds; beam search bookkeeping is O(width × vocabulary) per step.

## 5. What this branch builds

Design: the model is an implementation detail behind `MathRecognizing`; everything else is
shared, pure Swift and tested on Linux, and the app and the CLI do the same thing.

| Piece | Where | Tested |
| --- | --- | --- |
| Lasso selection: a stroke is taken when ≥ 50 % of its control points (through its transform) are inside the loop (even-odd), loops thinned to ≤ 1 024 vertices | `InkLasso` (Sources/Sempere/InkToMath.swift) | `InkToMathTests` |
| Conversion: ONE delta of `removeStroke` per stroke (replace) and the `addItem`; frame as tall as the ink (scale 0.25–4× of the typeset size), at the ink (replace) or right of it / below it (beside) | `NoteOps.convertInk`, `convertedMathFrame` | `InkToMathTests` (reducer round trip) |
| Model image: uniform black strokes of the model's width on white, scaled into the padded box, left-aligned or centred, optional cap on ink height, inversion and per-channel normalisation | `MathInkImage`, `MathImageSpec` (SempereRender) | `MathRecognitionTests` |
| Vocabulary (byte-level BPE as in TrOCR/mBART/Nougat tokenizers, or space-joined LaTeX tokens as CROHME models), parsed defensively | `MathVocabulary` | idem |
| Beam search with early stopping on next-token logits; output clean-up (delimiters, `\displaystyle`, spaces) before `MathSource.check` | `MathBeamSearch`, `LaTeXCleanup` | idem |
| Model folder format `sempere-math-model/1`: manifest with every file's SHA-256 and size, image spec, decoder ids and length buckets, Core ML feature names, compute units; strict path and size checks | `MathModelManifest` | idem |
| Verified store: install only after every file matches; a catalogue entry pins the manifest's SHA-256; loads re-check sizes and a marker | `MathModelStore`, `MathModelCatalogEntry`, `MathModelCatalog` (empty) | idem |
| Core ML inference: encoder once, decoder per step at the bucket length, beam search | `CoreMLMathRecognizer` (`#if canImport(CoreML)`) | runs a tiny random model (`Fixtures/math-tiny`, 0.6 MB) in the macOS CI job |
| Converter: Hugging Face `VisionEncoderDecoderModel` (TrOCR, Pix2Text, UniMERNet, Texo's FormulaNet, TexTeller) → two `.mlpackage`s, tokenizer, manifest; `--tiny` for a pipeline check | `tools/math-model/convert.py` | the fixture was made with it |
| CLI | `sempere recognize-math NOTE --strokes/--rect/--lasso/--all-ink [--model DIR \| --latex SRC] [--place replace\|beside] [--save-image]` | `CLIRecognizeMathTests` |
| App | Settings ▸ Handwritten Math (off by default; model list with size before download, progress, remove); Insert ▸ Equation from Handwriting… (only with a model) → lasso on the canvas → the equation sheet reads the ink, offers the readings, the LaTeX stays editable with the SwiftMath preview → Convert (Replace Ink / Place Beside), one delta, one undo step | `MathConversionTests` |

Decisions taken in the build:

- **Our own lasso**, not PencilKit's: PencilKit's selection has no public API on iPadOS 26. The
  math lasso is a mode (like "Tap Ink to Play"), with a hint and Cancel.
- **The image is drawn in pure Swift in the app too**, not with PencilKit: the model sees the
  same pixels in the app and the CLI, and uniform stroke widths match how training images are made.
- **Stroke removal goes through the ledger** (`NoteEditor.takeInk` / `putInkBack`), exactly like an
  erase, so the `removeStroke` ops and the `addItem` land in one delta and undo revives the strokes
  (same ids before the save, new ids with `parent` after, format.md §5.2).
- **No format change**: the result is an ordinary math item (§8.2.8) with a render.
- **No network code in `Sources/`**: the CLI takes a model folder; the app downloads.
- **The download is written but dormant**: the app today "makes no network connections of its
  own" (privacy policy) and its Mac sandbox has no `network.client` entitlement. With an empty
  catalogue no request can be made. Offering a model means a privacy-policy change (both copies),
  the entitlement (and `scripts/release-check.sh`'s allow-list), and hosting the files.
- `SEMPERE_DEBUG_MATH_MODEL=<folder>` (DEBUG builds) uses a converted folder without a catalogue
  entry, for device testing before anything is published.

## 6. Recommendation and what the maintainer decides

1. **The data question** (blocking): may the app offer weights trained on CROHME / HME100K? If
   not, no current model qualifies, and the clean path is our own small model trained on data we
   may license (synthetic ink from permissively licensed glyphs, plus volunteered, explicitly
   licensed samples); the pipeline here does not change for it.
2. If yes: **Texo** (20 M, best size; ask its author for an App Store permission like the one
   already granted) or **UniMERNet-T** (Apache-2.0, 100 M; needs the KV-cache decoder for latency).
3. Convert with `tools/math-model/convert.py` on a Mac, check on the iPad with
   `SEMPERE_DEBUG_MATH_MODEL`, and accept only if, on the A12Z: ExpRate ≥ 50 % on CROHME 2019 (for
   evaluation only) and on a set of the user's own equations, and ≤ 1 s per typical equation.
4. Host the files (a GitHub release of this repository is enough: HTTPS, and every file is pinned
   by hash), add the catalogue entry (manifest URL, its SHA-256, the total size), add the Mac
   `network.client` entitlement, and update the privacy policy: "When you ask for the handwriting
   model, Sempere downloads it from <host>; the request carries none of your data."
5. Then a KV-cache decoder (stateful Core ML) for the chosen model, and logits for the last
   position only.
