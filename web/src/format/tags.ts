// Tag normalisation and keys (format.md §5.4.1), as `NoteOps` in
// Sources/Sempere/Edit.swift.

const whitespace = /\p{White_Space}+/u;

/** The tag as stored: trimmed, inner runs of whitespace collapsed to one space. */
export function normalizedTag(tag: string): string {
  return tag.split(whitespace).filter((w) => w.length > 0).join(" ");
}

/** The case-insensitive key tags are matched by: "Math" and "math" are one tag. */
export function tagKey(tag: string): string {
  return normalizedTag(tag).toLowerCase();
}
