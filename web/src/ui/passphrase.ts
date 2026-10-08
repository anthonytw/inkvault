// The unlock screen's passphrase parts (docs/web-viewer.md "Unlocking with a
// passphrase"): the card for the vault's own passphrase-wrapped key files
// (`keys/`, format.md §3.2), and the passphrase field of the paste form for a
// paper kit's armored copy or a chosen key file. The passphrase is read once,
// cleared from the field, handed to the key worker and never stored.

import { type VaultManifest } from "../vault/vault.ts";
import { KeyFileError, keyFileName, maxKeyFileBytes, workFactor, wrappedBytes } from "../vault/keyfile.ts";
import { type VaultSource, readOptional } from "../vault/source.ts";
import { h } from "./dom.ts";
import { unwrapKeyInWorker } from "./keyunwrap.ts";
import { rememberOption } from "./passkey.ts";

export function keyFileMessage(e: unknown): string {
  if (e instanceof KeyFileError) return e.message.charAt(0).toUpperCase() + e.message.slice(1) + ".";
  return `Unlocking failed: ${e instanceof Error ? e.message : String(e)}`;
}

/** How long scrypt may take, said before it starts. */
export function workNote(logN: number): string {
  return logN <= 16 ? "" : ` Deriving the key from the passphrase takes a few seconds${logN >= 19 ? " and up to 1 GiB of memory" : ""}.`;
}

/** A stored key file of one of the vault's recipients. */
interface StoredKey {
  label: string;
  path: string;
  file: Uint8Array;
}

/** The vault's passphrase-wrapped key files, for its current recipients only (as the CLI offers them). */
export async function storedKeys(src: VaultSource, m: VaultManifest): Promise<StoredKey[]> {
  const out: StoredKey[] = [];
  for (const r of m.recipients) {
    const path = `keys/${await keyFileName(r.key)}`;
    let bytes: Uint8Array | undefined;
    try {
      bytes = await readOptional(src, path, maxKeyFileBytes);
    } catch {
      bytes = undefined;
    }
    if (!bytes) continue;
    try {
      const file = wrappedBytes(bytes);
      workFactor(file);
      out.push({ label: r.label.trim() || `${r.key.slice(0, 16)}…`, path, file });
    } catch {
      // Not a usable key file: not offered.
    }
  }
  return out;
}

/**
 * "Unlock with your passphrase": shown once a stored key file is found
 * (hidden otherwise). `unlock` gets the identity and whether to remember it
 * with a passkey.
 */
export function storedKeyCard(src: VaultSource, m: VaultManifest,
  unlock: (identity: string, remember: boolean) => Promise<void>, failed: (message: string) => void): HTMLElement {
  const card = h("form", { class: "card", attrs: { hidden: "" } });
  void storedKeys(src, m).then((keys) => {
    const [first] = keys;
    if (!first) return;
    const pass = h("input", {
      attrs: { type: "password", autocomplete: "current-password", spellcheck: "false", "aria-label": "Passphrase" },
    });
    const select = h("select", { attrs: { "aria-label": "Key" } },
      ...keys.map((k, i) => h("option", { text: k.label, attrs: { value: String(i) } })));
    const remember = rememberOption();
    const button = h("button", { text: "Unlock", attrs: { type: "submit" } });
    const logN = workFactor(first.file);
    card.addEventListener("submit", (e) => {
      e.preventDefault();
      const key = keys[Number(select.value)] ?? first;
      const passphrase = pass.value;
      pass.value = "";
      button.disabled = true;
      button.textContent = "Unlocking…";
      unwrapKeyInWorker(key.file, passphrase)
        .then((identity) => unlock(identity, remember.checked()))
        .catch((err: unknown) => failed(keyFileMessage(err)));
    });
    card.append(
      h("h2", { text: "Unlock with your passphrase" }),
      ...(keys.length > 1 ? [h("label", { text: "Key" }, select)] : []),
      h("label", { text: "Passphrase of the vault's stored key" }, pass),
      remember.element,
      h("div", { class: "row" }, button),
      h("p", { class: "hint", text: `The vault keeps this key locked with your passphrase (${keys.map((k) => k.path).join(", ")}). The passphrase is used once, in this tab, and never stored or sent.${workNote(logN)}` }));
    card.removeAttribute("hidden");
    pass.focus();
  });
  return card;
}

/**
 * The paste form's passphrase field: shown while the pasted text is an
 * armored age file (a paper kit's passphrase copy) or the chosen file is a
 * locked key file.
 */
export class PassphraseField {
  readonly element: HTMLElement;
  private readonly input = h("input", {
    attrs: { type: "password", autocomplete: "off", spellcheck: "false", "aria-label": "Passphrase of the key" },
  });
  private readonly note = h("p", { class: "hint" });

  constructor() {
    this.element = h("label", { attrs: { hidden: "" } }, "Passphrase of the locked key", this.input, this.note);
  }

  /** Shows the field for `file` (a wrapped key), or hides it (undefined). */
  show(file: Uint8Array | undefined): void {
    this.element.hidden = file === undefined;
    if (!file) {
      this.input.value = "";
      return;
    }
    try {
      const logN = workFactor(file);
      this.note.textContent = `This key is locked with a passphrase.${workNote(logN)}`;
    } catch (e) {
      this.note.textContent = keyFileMessage(e);
    }
  }

  /** The passphrase, read once: the field is cleared. */
  take(): string {
    const p = this.input.value;
    this.input.value = "";
    return p;
  }

  focus(): void {
    this.input.focus();
  }
}
