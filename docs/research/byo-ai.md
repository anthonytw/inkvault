# Bring your own AI model: design

Status 2026-10-09 (maintainer request of the same day). Companion to
`docs/research/handwriting-to-latex.md`: on-device handwriting → LaTeX models
reach about 15 % exact match, too few to be useful, so users may connect an
LLM provider of their own and run tasks that Sempere defines on ink they pick.
This changes one earlier decision ("on-device AI only", `docs/HANDOFF.md`,
`DESIGN.md` goal 5) in a bounded way, at the maintainer's request: on-device
stays the default and the only thing that ever runs on its own; a provider is
used only when the user configured it and asked for that one request.

## 1. Constraints (from the request; not negotiable)

- **Off by default.** No provider is configured on a fresh install. Each
  provider is added explicitly, with a consent step that names it.
- **Every request is user-initiated.** Nothing is sent automatically, in the
  background, on a schedule, or as a retry the user did not see. The one
  automatic follow-up is the validation retry of §5 (same content, inside
  the request the user started, at most once), and the sheet says so.
- **Plain disclosure.** Before the first send to a provider, and in Settings,
  the app says that the selected content leaves the device **unencrypted** to
  the chosen provider and is handled under that provider's terms.
- **Only the selection.** A request carries the picked ink rendered as an
  image plus the task's prompt text. Never the vault, keys, note titles,
  other strokes, other notes, recognised text, tags or file names. The app
  and the CLI show what will be sent (the image and the prompt) before
  sending.
- **Keys stay local.** App: Keychain, this device only by default; iCloud
  Keychain only when the user turns it on for that provider. CLI:
  `$XDG_CONFIG_HOME/sempere/ai.json`, mode 0600 in a 0700 folder (or the
  name of an environment variable that holds the key). Never in the vault,
  logs, exports, crash reports, `UserDefaults`, error messages or `--json`.
- **No Sempere server or proxy.** Requests go from the device straight to
  the provider's endpoint.

## 2. Providers

Three wire protocols cover every provider the request names. A provider is
a `kind`, a base URL, a model id and (usually) a key; presets fill in the
first three.

| Kind | Endpoint | Auth header | Covers |
| --- | --- | --- | --- |
| `anthropic` | `POST {base}/v1/messages` | `x-api-key`, `anthropic-version: 2023-06-01` | Claude (`https://api.anthropic.com`) |
| `openai` (OpenAI-compatible) | `POST {base}/chat/completions` | `Authorization: Bearer` (optional for local servers) | OpenAI (`https://api.openai.com/v1`), Gemini's compatibility endpoint (`https://generativelanguage.googleapis.com/v1beta/openai`), OpenRouter (`https://openrouter.ai/api/v1`), Ollama (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`) |
| `gemini` (native) | `POST {base}/v1beta/models/{model}:generateContent` | `x-goog-api-key` | Gemini (`https://generativelanguage.googleapis.com`) |

Gemini is reachable both ways; the native kind exists because its safety
feedback (`promptFeedback.blockReason`, `finishReason: SAFETY`) is clearer
than the compatibility layer's, and it is little code.

**Image input.** Every request carries one PNG, inline as base64
(Anthropic `image` block with `source.type = base64`; OpenAI `image_url` with
a `data:image/png;base64,` URL; Gemini `inlineData`). The model must accept
images; a text-only local model fails with the provider's own error.

**Token limits.** Anthropic requires `max_tokens` (we send 1024); Gemini
native takes `generationConfig.maxOutputTokens` (1024). The OpenAI-compatible
request sends no limit: OpenAI's current models reject `max_tokens` in favour
of `max_completion_tokens`, which several compatible servers do not know. The
answer is bounded on our side instead (§4: at most 1 MiB read).

**Default models** (2026-10-09; every one is editable per provider, and
`ai providers test` lists what the key can use):

| Preset | Kind | Base URL | Default model |
| --- | --- | --- | --- |
| `anthropic` | anthropic | `https://api.anthropic.com` | `claude-sonnet-5-5` (Opus 5.5 `claude-opus-5-5` reads messier ink, at about 5× the price; Haiku 5.5 `claude-haiku-5-5` is cheapest) |
| `openai` | openai | `https://api.openai.com/v1` | `gpt-5.5` |
| `gemini` | gemini | `https://generativelanguage.googleapis.com` | `gemini-3.8-flash` |
| `gemini-openai` | openai | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-3.8-flash` |
| `openrouter` | openai | `https://openrouter.ai/api/v1` | `anthropic/claude-sonnet-5-5` |
| `ollama` | openai | `http://localhost:11434/v1` | `qwen3-vl` (any vision model the user pulled) |
| `lmstudio` | openai | `http://localhost:1234/v1` | none: the user types the loaded model's id |

Model ids move faster than releases: the defaults are only a starting value,
stored per provider when it is added, never silently changed later.

**Transport security.** `https` is required, except for hosts that cannot
leave the user's network: loopback (`localhost`, `127.0.0.0/8`, `::1`),
private IPv4 (RFC 1918), link-local and `*.local` names (Ollama / LM Studio
on another Mac). Redirects are not followed (a redirect could carry the key
to another host); the user sees the status and the `Location` host instead.
Requests use the system proxy settings; no certificate pinning (providers
rotate certificates; the OS trust store decides).

**Timeouts.** 60 s per request for cloud providers, 180 s for the local
presets (a cold local model loads first); per provider, editable
(`--timeout`, 5–600 s). No automatic retry on timeouts or network errors.

## 3. Authentication: API keys only

Every provider above authenticates third-party apps with an **API key**
billed per token to the user's developer account. Findings (2026-10-09):

- **Consumer chat subscriptions cannot be used.** Claude Free/Pro/Max logins
  are for claude.ai and Claude Code only: Anthropic's terms (clarified
  February 2026, reworded since) say products built by others must use API
  keys and may not offer Claude.ai login or route requests through a
  subscriber's plan. The Gemini app's subscriptions (Google AI Pro/Ultra)
  likewise do not grant Gemini API access. Users need a key from the
  provider's developer console (Anthropic Console, Google AI Studio, OpenAI
  Platform, OpenRouter).
- **OAuth for third-party apps.**
  - *Anthropic*: none for the API.
  - *Google*: the Gemini API accepts OAuth user credentials, but only through
    a Google Cloud project the app owner registers, with consent-screen
    verification for external users; tokens are billed to that project, not
    to the user's subscription. Not usable for a no-server, user-billed app.
  - *OpenAI*: "Sign in with ChatGPT" (late September 2026, per trade press;
    not checked against OpenAI's own documentation) lets launch partners
    spend a ChatGPT subscriber's plan allowance through an OAuth scope. It
    needs a partner agreement and a registered client; not available to us
    today. Worth revisiting if it opens up, since it would spare users a key.
  - *OpenRouter*: OAuth PKCE with no client registration and no backend:
    the user approves in the browser and the app receives an ordinary
    OpenRouter key (optionally with a spending limit). This fits our model
    (no server) and is the only OAuth option available now. Not in this
    first version (it needs a callback URL scheme and an
    `ASWebAuthenticationSession` flow); the key it produces is stored exactly
    like a pasted one, so it can be added later without format changes.
- Local servers (Ollama, LM Studio) need no key.

## 4. Requests, answers and errors

The request and answer formats are built and parsed in pure Swift
(`Sources/SempereAI`), shared by the CLI and the app, tested on Linux with
recorded answers and a fuzz target (answers are untrusted bytes:
`docs/format.md` §9 applies).

- **Answer size**: at most 1 MiB is read; more is `AIError.badResponse`.
- **Decoding**: `JSONDecoder` into small `Decodable` shapes; anything missing
  or of the wrong type is `badResponse`, never a trap.
- **Text**: the concatenated text parts of the first choice/candidate.
- **Usage**: input/output token counts when the provider reports them, shown
  to the user (`--json` `usage`, the sheet's footer), so cost is visible.

Typed errors (`AIError`), each with a message that names the provider and
never contains the key or the request body:

| Case | From | Meaning |
| --- | --- | --- |
| `unauthorized` | 401, 403 | key missing, wrong or without access to the model |
| `notFound` | 404 | wrong base URL or unknown model |
| `rateLimited(retryAfter:)` | 429 | rate or spend limit; `Retry-After` when sent |
| `overloaded` | 503, 529 | try later |
| `http(status:message:)` | other 4xx/5xx | the provider's `error.message`, cut to 300 characters, control characters removed |
| `redirected(host:)` | 3xx | not followed (§2) |
| `refused(reason:)` | Anthropic `stop_reason: refusal`, OpenAI `refusal` / `finish_reason: content_filter`, Gemini block/`SAFETY` | the provider declined |
| `truncated` | `max_tokens` / `length` / `MAX_TOKENS` | the answer was cut |
| `emptyAnswer` | no text | |
| `invalidOutput(why:answer:)` | §5 validation, after the retry | the answer, cut, so the user can fix it by hand |
| `timedOut`, `network(String)` | transport | |
| `insecureEndpoint`, `invalidConfiguration` | before sending | |

**Cost note.** A converted equation is one image (the ink, at most 1568 px on
its long side; a typical line is about 1200 × 300 px, around 500 input tokens
on Claude) plus about 250 prompt tokens, and an answer of 20–100 tokens. At
mid-tier prices (2026: about $3 per million input and $15 per million output
tokens) that is well under one US cent per conversion; a validation retry
roughly doubles it. The provider bills the user; Sempere never sees the bill.

## 5. Task registry

Tasks are defined in code (`AITask`, `AITaskRegistry`), never fetched. Each has:

| Field | `ink-to-latex` | `ink-to-text` |
| --- | --- | --- |
| id / prompt version | `ink-to-latex` / 1 | `ink-to-text` / 1 |
| input kind | ink image | ink image |
| system prompt | transcribe handwritten mathematics as LaTeX math mode | transcribe handwriting as plain text |
| output | one LaTeX source, math mode, no `$` | plain text, line breaks kept |
| clean-up | strip code fences, `$…$`, `$$…$$`, `\[…\]`, `\(…\)`, a leading `latex:` label | strip code fences and surrounding quotes |
| validation | `NoteOps.math` (NFC, `MathSource.check`: length, braces, allowed commands) | `NoteOps.text` (no control characters, text-box limits), at most 4,000 characters |
| "nothing there" | the model answers `NONE` → `AIError.emptyAnswer` | same |
| result | a `math` item (`NoteOps.convertInk(_:toMath:)`) | a text box (`NoteOps.convertInk(_:toText:)`) |

Input kinds reserved for later tasks: `text` (a text box's content) and
`notePage` (a page rendered as an image). Neither ships now; a task that uses
them must show its input the same way before sending.

**Prompt.** The system prompt states the task and the output rules; the user
turn holds the image and one sentence. The prompt never includes note
content. Both are shown in "what will be sent" (`--show-request`, the
sheet's disclosure).

**Validation and retry.** The answer is cleaned and validated. When it fails,
the same request is sent once more with the model's answer and the
validation error appended ("Your answer was rejected: … Reply again with only
…"). A second failure is `invalidOutput`, carrying the last answer so the
app can put it in the editor for the user to fix. Never more than two
requests per user action.

**Image.** `AIInkImage` draws the picked strokes with `MathInkImage` (black,
uniform width, white background, grey PNG): the model sees the ink and
nothing else on the page (no paper lines, images or other strokes). The
image keeps the ink's aspect ratio, at 4 px per point capped so that its long
side is at most 1568 px (Anthropic's recommended maximum; others downscale
anyway) and its short side at least 64 px; stroke width 3 px; 16 px padding.

## 6. Where results go

Both tasks end like the on-device recogniser: the user sees and can edit
the result, then chooses **Replace Ink** (one delta: a `removeStroke` per
picked stroke and the new item's `addItem`) or **Place Beside** (the `addItem`
only). Nothing about the format changes: a converted equation is an ordinary
`math` item, converted text an ordinary text box. The text box is as wide as
the ink (at least 120 pt), at a font size from the ink's line height
(10–48 pt), beside the ink or below it like `convertedMathFrame`.

## 7. CLI

```
sempere ai providers add NAME --preset P | --kind K --base-url URL  [--model ID]
                             [--key-stdin | --key-env VAR | --no-key] [--timeout S] --yes
sempere ai providers list | remove NAME | test NAME
sempere ai tasks
sempere ai run TASK NOTE [--provider NAME] [--page N] (--strokes … | --rect … | --lasso … | --all-ink)
                         [--show-request] [--save-image F] [--place replace|beside] [--dry-run]
sempere recognize-math NOTE --provider NAME …      (same path as `ai run ink-to-latex`)
```

- `add` prints the disclosure and requires `--yes` (scripts pass it; there
  is no interactive prompt, so a pipe never hangs). The key is read from
  standard input, never from an argument (arguments leak into shell history
  and `ps`). `--key-env VAR` stores only the variable's name.
- The config file is `$SEMPERE_AI_CONFIG`, else
  `$XDG_CONFIG_HOME/sempere/ai.json` (default `~/.config/sempere/ai.json`);
  written atomically with mode 0600 in a 0700 folder. A file readable by
  group or others is refused with the `chmod` to fix it.
- `list` and `--json` never print a key: they say `stored`, `env VAR` or `none`.
- `test` sends a free request (`GET …/models`; Gemini native `GET
  /v1beta/models`) to check the URL and the key, and says whether the
  configured model is listed. It sends no note content.
- `run --show-request` prints exactly what would be sent (provider, endpoint
  host, model, prompt text, image size and bytes) and sends nothing;
  `--save-image` writes the PNG. Without `--place` the answer is printed and
  nothing is written; `--place` writes one delta through `Vault.apply`.
- With one provider configured, `--provider` may be omitted.

## 8. App

- **Settings ▸ AI Providers** (`AIProvidersSettingsSection`): off until a
  provider is added. The section's footer states the disclosure. "Add
  Provider…" opens a sheet: preset, name, base URL (editable), model, key
  (secure field; not for local presets), "Sync key with iCloud Keychain" (off),
  "Test Connection", and an "I understand" switch next to the disclosure
  that must be on before Save. Rows show name, host and model; each has Test
  and Remove (removing deletes the Keychain item).
- **Keys** (`AIKeyStore`, `KeychainAIKeyStore`): generic-password items,
  service `io.github.anthonytw.sempere.ai`, account = provider id;
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, or `kSecAttrSynchronizable`
  with `kSecAttrAccessibleWhenUnlocked` when the user opts into iCloud
  Keychain. No Face ID gate (an API key is a billing credential, not the vault
  key; the provider's spending limit is the backstop). Non-secret settings
  (name, kind, URL, model, timeout, consent date) are in `UserDefaults`. Tests
  use `MemoryAIKeyStore`.
- **Equation from Handwriting…** appears when an on-device model is installed
  *or* a provider is configured. The sheet lists "Read on This Device" (when
  available) and "Read with ‹provider›" for each provider, plus a
  disclosure group "What will be sent" with the image and the prompt. The
  first send to each provider asks once more (alert with the disclosure;
  remembered per provider id). The answer fills the LaTeX field; the SwiftMath
  preview, Replace Ink / Place Beside and undo are unchanged.
- **Text from Handwriting…** (new, Insert menu, providers only): the same
  lasso, then a sheet with the image, the providers, an editable text field,
  Replace Ink / Place Beside; one delta, one undo step ("Convert to Text").
- Nothing about a provider is in the vault, so it is per device; the
  CLI's config and the app's settings are separate.

## 9. Privacy policy and App Store

- **Privacy policy** (both copies, same date): a section "Optional AI
  providers": off by default; when the user adds a provider of their own
  and asks for a conversion, the picked ink is sent as an image, with
  Sempere's instructions, directly from the device to that provider, outside
  Sempere's end-to-end encryption, and handled under that provider's terms;
  Sempere has no server in between and receives nothing; keys stay in the
  Keychain.
- **App Review guideline 5.1.2(i)** requires disclosing where personal data
  is shared with third parties, "including with third-party AI", and
  obtaining explicit permission first: the consent switch when adding a
  provider and the first-send confirmation are that permission.
- **Nutrition label**: unchanged ("Data Not Collected"). Apple counts data as
  collected when the developer or its partners can access it; here the user
  contracts with the provider directly, using their own key, and Sempere has
  no relationship with or access through the provider (like a mail client
  sending to the user's own server). Open question for the maintainer in the
  PR, since Apple's wording on third-party processing is not explicit about
  user-supplied services.
- **Mac sandbox**: outgoing connections need
  `com.apple.security.network.client` (Catalyst entitlements file; the iPad
  build has no entitlements file). Added to the release check's allow-list
  and `docs/release/app-store.md`.
- **Export compliance**: HTTPS through the system's TLS only; no change to
  the "exempt" answer.
- **Local network**: reaching Ollama on another Mac triggers iPadOS's local
  network prompt; `NSLocalNetworkUsageDescription` explains it.

## 10. What is not done

- OpenRouter OAuth PKCE (§3), streaming answers, cost estimates before
  sending (token counts are shown after), tasks with text or page input,
  per-vault provider settings, a provider on the web viewer.
