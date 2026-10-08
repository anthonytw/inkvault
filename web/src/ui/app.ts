// The viewer's screens: open a vault, unlock it with a pasted key, then browse
// notebooks, tags and notes, search, and read a note. Read-only throughout.

import { type NoteState } from "../format/model.ts";
import { type NotebookNode, type SearchHit, canonicalNotebook, isWithinNotebook, notebookTree, search } from "../format/search.ts";
import { tagKey } from "../format/tags.ts";
import { type LoadedNote, type NoteSummary, loadNote, summarize } from "../vault/library.ts";
import { CachingSource } from "../vault/cache.ts";
import { type ViewerConfig, loadConfig } from "../vault/config.ts";
import { type ListingProgress, listVault } from "../vault/listing.ts";
import { HTTPSource, type HTTPMode, SourceError, type VaultSource, readOptional } from "../vault/source.ts";
import { type RecipientsStatus, UnlockedVault, VaultError, limits, parseIdentity, parseManifest, readOnlyReasons,
  recipientsWarningText, type VaultManifest } from "../vault/vault.ts";
import { newerSummary } from "../format/newer.ts";
import { clear, formatDate, h } from "./dom.ts";
import { NoteView, hasUnknownPaper } from "./noteview.ts";
import { RecordingsPanel } from "./recordings.ts";
import { VideosPanel } from "./videos.ts";
import { NoteBlobs } from "../vault/blobs.ts";
import { canPickDirectory, fromDrop, fromFileList, pickDirectory } from "./pickers.ts";
import { clearCacheButton, fileCache } from "./caching.ts";
import { passkeyVault, rememberOption, rememberScreen, rememberedCard } from "./passkey.ts";

type Filter =
  | { kind: "all" } | { kind: "favorites" } | { kind: "deleted" } | { kind: "problems" }
  | { kind: "notebook"; path: string } | { kind: "tag"; key: string; label: string };

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export class App {
  private source?: VaultSource;
  private manifest?: VaultManifest;
  private vault?: UnlockedVault;
  private notes = new Map<string, NoteSummary>();
  private loading: ListingProgress & { listed: boolean } = { checked: 0, total: 0, read: 0, toRead: 0, listed: false };
  /** The deployment's `config.json` (docs/web-viewer.md "Hosting"), if any. */
  private config?: ViewerConfig;
  private filter: Filter = { kind: "all" };
  private query = "";
  private hits?: Map<string, SearchHit>;
  private selected?: string;
  private view?: NoteView;
  private recordings?: RecordingsPanel;
  private videos?: VideosPanel;
  /** Recently opened notes; the list itself keeps summaries only. */
  private readonly cache = new Map<string, LoadedNote>();
  private generation = 0;

  private readonly sidebar = h("nav", { class: "sidebar", attrs: { "aria-label": "Notebooks and tags" } });
  private readonly list = h("section", { class: "note-list", attrs: { "aria-label": "Notes" } });
  private readonly detail = h("main", { class: "detail" });
  private readonly status = h("span", { class: "status", attrs: { role: "status" } });

  constructor(private readonly root: HTMLElement) {}

  start(): void {
    void loadConfig(location.href).then((config) => {
      this.config = config;
      if (config && !config.allowOtherVaults) {
        // The server decides: straight to the key prompt for its vault.
        void this.openSource(new HTTPSource(config.vault, config.listing));
      } else {
        this.showOpen();
      }
    }, (e: unknown) => this.showFatal(message(e)));
  }

  /** A deployment whose config cannot be read: nothing else is offered (fail closed). */
  private showFatal(error: string): void {
    clear(this.root);
    this.root.append(h("div", { class: "welcome" }, h("h1", { text: "Sempere viewer" }),
      h("p", { class: "error", text: error, attrs: { role: "alert" } })));
  }

  /** True when the deployment allows only its own vault. */
  private get locked(): boolean {
    return this.config !== undefined && !this.config.allowOtherVaults;
  }

  // MARK: - Open

  private showOpen(error?: string): void {
    if (this.locked) return this.showFatal(error ?? "This viewer opens only its configured vault.");
    const params = new URLSearchParams(location.search);
    const url = h("input", { attrs: { type: "url", placeholder: "https://example.org/Notes.sempere/", autocomplete: "url", spellcheck: "false" } });
    url.value = this.config?.vault ?? params.get("vault") ?? "";
    const mode = h("select", { attrs: { "aria-label": "Listing" } },
      h("option", { text: "Index file or WebDAV", attrs: { value: "auto" } }),
      h("option", { text: "Index file (sempere-index.json)", attrs: { value: "index" } }),
      h("option", { text: "WebDAV", attrs: { value: "webdav" } }));
    const openURL = (e: Event) => {
      e.preventDefault();
      try {
        void this.openSource(new HTTPSource(url.value.trim(), mode.value as HTTPMode));
      } catch (err) {
        this.showOpen(message(err));
      }
    };
    const dirInput = h("input", { attrs: { type: "file", webkitdirectory: "", multiple: "" }, class: "visually-hidden" });
    dirInput.addEventListener("change", () => {
      if (!dirInput.files || dirInput.files.length === 0) return;
      try {
        void this.openSource(fromFileList(dirInput.files));
      } catch (err) {
        this.showOpen(message(err));
      }
    });
    const pickButton = h("button", {
      text: "Open a vault folder…", attrs: { type: "button" },
      on: {
        click: () => {
          if (!canPickDirectory()) {
            dirInput.click();
            return;
          }
          pickDirectory().then((src) => this.openSource(src), (err: unknown) => {
            if (!(err instanceof DOMException && err.name === "AbortError")) this.showOpen(message(err));
          });
        },
      },
    });
    const drop = h("div", { class: "drop", text: "or drop the vault folder (*.sempere) here" });
    drop.addEventListener("dragover", (e) => {
      e.preventDefault();
      drop.classList.add("over");
    });
    drop.addEventListener("dragleave", () => drop.classList.remove("over"));
    drop.addEventListener("drop", (e) => {
      e.preventDefault();
      drop.classList.remove("over");
      if (!e.dataTransfer) return;
      fromDrop(e.dataTransfer.items).then((src) => this.openSource(src), (err: unknown) => this.showOpen(message(err)));
    });
    clear(this.root);
    this.root.append(h("div", { class: "welcome" },
      h("h1", { text: "Sempere viewer" }),
      h("p", { class: "lede", text: "Read an encrypted Sempere vault in this browser. Notes are decrypted here; the key never leaves this tab, and nothing is written anywhere." }),
      error ? h("p", { class: "error", text: error, attrs: { role: "alert" } }) : null,
      h("form", { class: "card", on: { submit: openURL } },
        h("h2", { text: "From a web server" }),
        h("label", { text: "Vault URL" }, url),
        h("label", { text: "Listing" }, mode),
        h("button", { text: "Open", attrs: { type: "submit" } }),
        h("p", { class: "hint", text: "A static server needs sempere-index.json (sempere vault index); a WebDAV share needs nothing. The URL must be allowed by this page's connect-src (docs/web-viewer.md)." })),
      h("div", { class: "card" },
        h("h2", { text: "From this computer" }), pickButton, dirInput, drop),
      h("p", { class: "hint" }, clearCacheButton())));
  }

  private async openSource(src: VaultSource): Promise<void> {
    this.status.textContent = "";
    let manifest: VaultManifest;
    try {
      manifest = parseManifest(await src.read("vault.json", limits.manifestBytes));
    } catch (e) {
      this.showOpen(e instanceof SourceError && e.notFound ? `${src.label} has no vault.json: is it a Sempere vault?` : message(e));
      return;
    }
    // Encrypted revisions and blobs fetched over HTTP are kept in the browser (write-once files).
    this.source = src instanceof HTTPSource ? new CachingSource(src, await fileCache(), `${src.label}\n${manifest.vaultId}`) : src;
    this.manifest = manifest;
    this.showUnlock();
  }

  // MARK: - Unlock

  private showUnlock(error?: string): void {
    const m = this.manifest, src = this.source;
    if (!m || !src) return this.showOpen();
    const key = h("textarea", {
      attrs: { rows: "4", placeholder: "AGE-SECRET-KEY-PQ-1…", autocomplete: "off", autocapitalize: "off", spellcheck: "false", "aria-label": "Key" },
    });
    const button = h("button", { text: "Unlock", attrs: { type: "submit" } });
    const unlock = async (text: string): Promise<string> => {
      const identity = parseIdentity(text);
      const journal = await readOptional(src, "rewrap-journal.json", limits.manifestBytes);
      this.vault = await UnlockedVault.unlock(m, identity, journal);
      return identity;
    };
    const failed = (err: unknown) =>
      this.showUnlock(err instanceof VaultError || err instanceof SourceError ? err.message : `Unlocking failed: ${message(err)}`);
    const remember = rememberOption();
    const submit = async (e: Event) => {
      e.preventDefault();
      button.disabled = true;
      button.textContent = "Unlocking…";
      try {
        const text = key.value;
        key.value = "";
        const identity = await unlock(text);
        const pv = passkeyVault();
        if (remember.checked() && pv) {
          clear(this.root);
          this.root.append(rememberScreen(pv, identity, m.vaultId, src.label, () => this.showMain()));
        } else {
          this.showMain();
        }
      } catch (err) {
        failed(err);
      }
    };
    const pv = passkeyVault();
    const remembered = pv ? rememberedCard(pv, m.vaultId,
      (text) => unlock(text).then(() => this.showMain(), (err: unknown) =>
        failed(err instanceof VaultError ? `The remembered key no longer opens this vault (${err.message}). Forget it and paste the key.` : err)),
      (msg) => this.showUnlock(msg), () => this.showUnlock()) : null;
    clear(this.root);
    this.root.append(h("div", { class: "welcome" },
      h("h1", { text: "Unlock vault" }),
      h("p", { class: "lede" }, "Vault ", h("code", { text: src.label }), ` · ${m.recipients.length} key${m.recipients.length === 1 ? "" : "s"}`),
      error ? h("p", { class: "error", text: error, attrs: { role: "alert" } }) : null,
      remembered,
      h("form", { class: "card", on: { submit: (e) => void submit(e) } },
        h("label", { text: "Paste your key (the AGE-SECRET-KEY-PQ-1… line, or the whole key file)" }, key),
        remember.element,
        h("div", { class: "row" }, button,
          this.locked ? null : h("button", { text: "Back", attrs: { type: "button" }, class: "secondary", on: { click: () => this.showOpen() } })),
        h("p", { class: "hint", text: "The key is kept in this tab's memory only: never sent, and stored only if you ask for a passkey (then encrypted under it). Closing the tab or Lock forgets it." })),
      h("p", { class: "hint" }, clearCacheButton())));
    key.focus();
  }

  // MARK: - Main

  private showMain(): void {
    const src = this.source;
    if (!src) return;
    const searchBox = h("input", { attrs: { type: "search", placeholder: "Search titles, tags and handwriting", "aria-label": "Search" } });
    let timer: number | undefined;
    searchBox.addEventListener("input", () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        this.query = searchBox.value;
        this.runSearch();
        this.renderList();
      }, 150);
    });
    clear(this.root);
    this.root.append(h("div", { class: "app" },
      h("header", { class: "topbar" },
        h("strong", { text: "Sempere" }), h("span", { class: "vault-label", text: src.label, title: src.label }), this.status,
        clearCacheButton(),
        h("button", { text: "Lock", class: "secondary", attrs: { type: "button" }, title: "Forget the key and close the vault", on: { click: () => this.lock() } })),
      ...recipientsWarning(this.vault?.recipientsStatus),
      h("div", { class: "columns" }, this.sidebar,
        h("div", { class: "list-column" }, h("div", { class: "search" }, searchBox), this.list),
        this.detail)));
    this.detail.replaceChildren(h("p", { class: "empty", text: "Select a note." }));
    void this.loadAll();
  }

  private lock(): void {
    this.generation++;
    this.vault = undefined;
    this.notes.clear();
    this.cache.clear();
    this.view?.destroy();
    this.videos?.destroy();
    // A reload drops every reference to the key and decrypted notes.
    location.reload();
  }

  private async loadAll(): Promise<void> {
    const src = this.source, vault = this.vault;
    if (!src || !vault) return;
    const gen = ++this.generation;
    let lastRender = 0;
    const render = (force = false) => {
      if (!force && performance.now() - lastRender < 250) return;
      lastRender = performance.now();
      this.updateStatus();
      this.runSearch();
      this.renderSidebar();
      this.renderList();
    };
    this.updateStatus();
    try {
      // The published summaries first (format.md §12), then only the notes that changed.
      await listVault(src, vault, {
        provisional: (rows) => {
          for (const r of rows) this.notes.set(r.id, r);
          render(true);
        },
        row: (r) => {
          this.notes.set(r.id, r);
          render();
        },
        gone: (id) => this.notes.delete(id),
        progress: (p) => {
          this.loading = { ...p, listed: false };
          render();
        },
        current: () => gen === this.generation,
      });
    } catch (e) {
      if (gen === this.generation) this.status.textContent = `Cannot list notes: ${message(e)}`;
      return;
    }
    if (gen !== this.generation) return;
    this.loading.listed = true;
    render(true);
  }

  private updateStatus(): void {
    const { checked, total, read, toRead, listed } = this.loading;
    const problems = [...this.notes.values()].filter((n) => n.error !== undefined || n.failures > 0).length;
    const count = listed ? total : this.notes.size;
    this.status.textContent = listed
      ? `${count} note${count === 1 ? "" : "s"}${problems ? ` · ${problems} with problems` : ""}`
      : read < toRead ? `Decrypting ${read} of ${toRead} changed notes… (${checked} of ${total} checked)`
        : total > 0 ? `Checking ${checked} of ${total} notes…` : "Listing notes…";
    // Content of a newer format version (format.md §7.3): shown as far as understood.
    const newer = (this.manifest ? readOnlyReasons(this.manifest) : []).length > 0
      || [...this.notes.values()].some((n) => n.newer);
    if (newer) this.status.textContent += " · written partly by a newer Sempere";
    this.status.title = this.manifest ? readOnlyReasons(this.manifest).join("; ") : "";
  }

  private visible(n: NoteSummary): boolean {
    const f = this.filter;
    switch (f.kind) {
      case "deleted": return n.deleted;
      case "problems": return n.error !== undefined || n.failures > 0;
      default: if (n.deleted) return false;
    }
    switch (f.kind) {
      case "all": return true;
      case "favorites": return n.favorite;
      case "notebook": return isWithinNotebook(n.notebook, f.path);
      case "tag": return n.tags.some((t) => tagKey(t) === f.key);
    }
  }

  private setFilter(f: Filter): void {
    this.filter = f;
    this.renderSidebar();
    this.renderList();
  }

  private renderSidebar(): void {
    const all = [...this.notes.values()];
    const live = all.filter((n) => !n.deleted);
    const isActive = (f: Filter) => JSON.stringify(f) === JSON.stringify(this.filter);
    const item = (label: string, f: Filter, count?: number) =>
      h("li", {}, h("button", {
        class: isActive(f) ? "active" : "", attrs: { type: "button" }, on: { click: () => this.setFilter(f) },
      }, h("span", { class: "label", text: label }), count !== undefined ? h("span", { class: "count", text: String(count) }) : null));
    const tree = (nodes: NotebookNode[]): HTMLElement => h("ul", {}, ...nodes.map((n) => {
      const li = item(n.name, { kind: "notebook", path: n.path }, live.filter((x) => isWithinNotebook(x.notebook, n.path)).length);
      if (n.children.length) li.append(tree(n.children));
      return li;
    }));
    const tags = new Map<string, { label: string; count: number }>();
    for (const n of live) {
      for (const t of n.tags) {
        const k = tagKey(t);
        const cur = tags.get(k);
        if (cur) cur.count++;
        else tags.set(k, { label: t, count: 1 });
      }
    }
    const tagList = [...tags.entries()].sort((a, b) => a[1].label.localeCompare(b[1].label));
    const problems = all.filter((n) => n.error !== undefined || n.failures > 0).length;
    clear(this.sidebar);
    this.sidebar.append(
      h("ul", {}, item("All notes", { kind: "all" }, live.length), item("Favorites", { kind: "favorites" }, live.filter((n) => n.favorite).length)),
      h("h3", { text: "Notebooks" }), tree(notebookTree(live.map((n) => n.notebook))),
      h("h3", { text: "Tags" }), h("ul", {}, ...tagList.map(([k, v]) => item(`#${v.label}`, { kind: "tag", key: k, label: v.label }, v.count))),
      h("h3", { text: "Other" }),
      h("ul", {}, item("Deleted", { kind: "deleted" }, all.length - live.length), problems ? item("Problems", { kind: "problems" }, problems) : null));
  }

  private runSearch(): void {
    this.hits = this.query.trim() === "" ? undefined
      : new Map(search(this.query, [...this.notes.values()]).map((hit) => [hit.id, hit]));
  }

  private renderList(): void {
    let notes = [...this.notes.values()].filter((n) => this.visible(n));
    const hits = this.hits;
    if (hits) {
      const rank = new Map([...hits.keys()].map((id, i) => [id, i]));
      notes = notes.filter((n) => hits.has(n.id)).sort((a, b) => (rank.get(a.id) ?? 0) - (rank.get(b.id) ?? 0));
    } else {
      notes.sort((a, b) => (b.modified ?? 0) - (a.modified ?? 0) || a.title.localeCompare(b.title));
    }
    clear(this.list);
    if (notes.length === 0) {
      this.list.append(h("p", { class: "empty", text: !this.loading.listed ? "Loading…" : hits ? "No matches." : "No notes here." }));
      return;
    }
    this.list.append(h("ul", {}, ...notes.map((n) => {
      const hit = hits?.get(n.id);
      const meta = [canonicalNotebook(n.notebook), ...n.tags.map((t) => `#${t}`)].filter(Boolean).join("  ");
      const badges: string[] = [];
      if (n.error !== undefined) badges.push("unreadable");
      else if (n.failures > 0) badges.push(`${n.failures} unreadable revision${n.failures === 1 ? "" : "s"}`);
      if (n.newer) badges.push("newer version");
      return h("li", {}, h("button", {
        class: n.id === this.selected ? "note active" : "note", attrs: { type: "button" },
        on: { click: () => void this.open(n.id, hit?.page?.number) },
      },
      h("span", { class: "title", text: n.title || "Untitled" }),
      h("span", { class: "sub", text: [formatDate(n.modified), `${n.pageCount} page${n.pageCount === 1 ? "" : "s"}`].filter(Boolean).join(" · ") }),
      meta ? h("span", { class: "sub", text: meta }) : null,
      hit?.snippet ? this.snippet(hit) : null,
      badges.length ? h("span", { class: "badge", text: badges.join(" · ") }) : null));
    })));
  }

  private snippet(hit: SearchHit): HTMLElement {
    const sn = hit.snippet;
    const el = h("span", { class: "snippet" });
    if (!sn) return el;
    if (hit.page) el.append(h("span", { class: "page-ref", text: `p. ${hit.page.number}: ` }));
    let at = 0;
    for (const [a, b] of sn.matches) {
      if (a < at) continue;
      el.append(sn.text.slice(at, a), h("mark", { text: sn.text.slice(a, b) }));
      at = b;
    }
    el.append(sn.text.slice(at));
    return el;
  }

  private async open(id: string, page?: number): Promise<void> {
    const src = this.source, vault = this.vault;
    if (!src || !vault) return;
    this.selected = id;
    this.renderList();
    const gen = this.generation;
    this.view?.destroy();
    this.view = undefined;
    this.recordings?.destroy();
    this.recordings = undefined;
    this.videos?.destroy();
    this.videos = undefined;
    this.detail.replaceChildren(h("p", { class: "empty", text: "Decrypting…" }));
    let note = this.cache.get(id);
    if (!note) {
      try {
        note = await loadNote(src, vault, id);
      } catch (e) {
        note = { id, error: message(e), failures: [], revisionCount: 0, hasAttachments: false };
      }
      this.cache.set(id, note);
      while (this.cache.size > 8) this.cache.delete(this.cache.keys().next().value ?? "");
      // What the revisions say wins over a published summary (format.md §12.3).
      if (gen === this.generation && this.notes.has(id)) {
        this.notes.set(id, summarize(note));
        this.renderSidebar();
      }
    }
    if (gen !== this.generation || this.selected !== id) return;
    this.renderNote(note, page);
  }

  private renderNote(note: LoadedNote, page?: number): void {
    const state: NoteState | undefined = note.state;
    const warnings: HTMLElement[] = [];
    if (note.failures.length) {
      warnings.push(h("details", { class: "warning" },
        h("summary", { text: `${note.failures.length} of ${note.revisionCount} revisions could not be read; the note is shown without them.` }),
        h("ul", {}, ...note.failures.map((f) => h("li", {}, h("code", { text: f.file }), ` ${f.message}`)))));
    }
    if (!state) {
      this.detail.replaceChildren(h("div", { class: "note-header" }, h("h2", { text: "This note cannot be opened" }),
        h("p", { class: "error", text: note.error ?? "unknown error" })), ...warnings);
      return;
    }
    if (note.newer) {
      warnings.push(h("p", { class: "warning", text:
        `Parts of this note were written by a newer version of Sempere (${newerSummary(note.newer)}); it is shown as far as this viewer understands it.` }));
    }
    if (state.deleted) warnings.push(h("p", { class: "warning", text: "This note is deleted (it stays in the vault until restored in the app)." }));
    if (hasUnknownPaper(state)) warnings.push(h("p", { class: "warning", text: "Some paper was made by a newer app; it is shown as blank paper." }));
    const m = state.meta;
    const notebook = canonicalNotebook(m.notebook);
    const meta = [notebook ? `Notebook: ${notebook.replaceAll("/", " › ")}` : "", `Created ${formatDate(m.created)}`,
      `${state.pages.length} page${state.pages.length === 1 ? "" : "s"}`].filter(Boolean).join(" · ");
    const blobs = this.source && this.vault ? new NoteBlobs(this.source, this.vault, note.id) : undefined;
    const videos = new VideosPanel(state, blobs);
    this.videos = videos;
    const recordings = new RecordingsPanel(state.recordings, blobs);
    this.recordings = recordings;
    this.view = new NoteView(state, blobs, (id) => void videos.play(id), (id) => recordings.play(id));
    this.detail.replaceChildren(
      h("div", { class: "note-header" },
        h("h2", { text: m.title || "Untitled" }), h("p", { class: "sub", text: meta }),
        m.tags.length ? h("p", { class: "tags" }, ...m.tags.map((t) => h("span", { class: "tag", text: `#${t}` }))) : null,
        ...warnings, this.view.problemsEl, this.recordings.root, videos.root),
      this.view.root);
    if (page !== undefined) requestAnimationFrame(() => requestAnimationFrame(() => this.view?.showPage(page)));
  }
}

/** A banner when vault.json's device list does not check (format.md §2.1). */
function recipientsWarning(status: RecipientsStatus | undefined): HTMLElement[] {
  const text = recipientsWarningText(status);
  return text ? [h("p", { class: "warning", attrs: { role: "alert" }, text })] : [];
}
