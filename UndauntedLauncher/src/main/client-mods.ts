// UE4SS and the client mods (health bars, tracker, mod menu) from the repository's
// client-mods/ folder, shipped as the launcher resource "client-mods" (forge.config.ts extraResource).
// Installed next to the game exe on install, repair and before every launch, the same way as the
// pinned DLLs: every file must match client-mods/manifest.json before it is copied and after.
// Files marked "keep" (mods.txt, UE4SS-settings.ini) are only written when missing, so a player's
// own choices (mods switched off in the in-game menu) survive. Failures never block the game:
// the caller logs them and launches anyway. Files that earlier versions installed and that the
// bundle dropped since (manifest "remove") are deleted, with any folder they leave empty, and mods
// named in "disable" are switched off in the kept mods.txt (only their own line changes).

import { promises as fsp } from "node:fs";
import path from "node:path";
import { hashFile } from "./verify";
import { unblock, win64Dir } from "./dlls";

export interface ClientModFile {
  path: string;
  sha256: string;
  size: number;
  keep: boolean;
}

export interface ClientModsManifest {
  version: number;
  target: string;
  files: ClientModFile[];
  remove?: string[];
  disable?: string[];
}

export interface ClientModsResult {
  installed: number;
  kept: number;
  upToDate: number;
  removed: number;
  disabled: number;
}

export class ClientModsError extends Error {
  constructor(public readonly file: string, message: string) {
    super(`${file}: ${message}`);
    this.name = "ClientModsError";
  }
}

export const CLIENT_MODS_RESOURCE = "client-mods";

// Only plain relative paths inside the bundle, written with "/": no backslashes (Windows would read
// "..\x" as a step up), no drive letters or colons, no "." or "..", no absolute paths.
export function safeRelative(rel: string): string {
  const parts = rel.split("/");
  if (rel.length === 0 || rel.startsWith("/") || /[\\:]/.test(rel) || parts.some((p) => p === "" || p === "." || p === "..")) {
    throw new ClientModsError(rel, "unsafe path in manifest.json");
  }
  return path.join(...parts);
}

// root + rel, refused unless the result is really inside root (a last guard on top of safeRelative).
export function insideRoot(root: string, rel: string): string {
  const base = path.resolve(root);
  const full = path.resolve(base, safeRelative(rel));
  if (!full.startsWith(base + path.sep)) throw new ClientModsError(rel, "path outside the game folder");
  return full;
}

export async function readClientModsManifest(resourcesDir: string): Promise<ClientModsManifest | null> {
  const file = path.join(resourcesDir, CLIENT_MODS_RESOURCE, "manifest.json");
  let text: string;
  try {
    text = await fsp.readFile(file, "utf8");
  } catch {
    return null; // launcher built without client mods
  }
  const m = JSON.parse(text) as ClientModsManifest;
  if (m.version !== 1 || !Array.isArray(m.files)) throw new ClientModsError("manifest.json", "unknown format");
  return m;
}

export async function installClientMods(resourcesDir: string, installDir: string): Promise<ClientModsResult | null> {
  const manifest = await readClientModsManifest(resourcesDir);
  if (!manifest) return null;
  const srcRoot = path.join(resourcesDir, CLIENT_MODS_RESOURCE);
  const dstRoot = path.resolve(win64Dir(installDir));
  const result: ClientModsResult = { installed: 0, kept: 0, upToDate: 0, removed: 0, disabled: 0 };

  // Dropped files first. A path the bundle still ships is never removed, an unsafe one is skipped;
  // folders are removed only while empty, and never the Win64 folder or anything above it.
  const shipped = new Set(manifest.files.map((f) => f.path));
  for (const r of Array.isArray(manifest.remove) ? manifest.remove : []) {
    if (typeof r !== "string" || shipped.has(r)) continue;
    let target: string;
    try {
      target = insideRoot(dstRoot, r);
    } catch {
      continue;
    }
    try {
      await fsp.unlink(target);
      result.removed++;
    } catch {
      continue; // already gone
    }
    let dir = path.dirname(target);
    while (dir.startsWith(dstRoot + path.sep)) {
      try {
        await fsp.rmdir(dir); // fails when not empty: stop there
      } catch {
        break;
      }
      dir = path.dirname(dir);
    }
  }

  for (const f of manifest.files) {
    const rel = safeRelative(f.path);
    const want = f.sha256.toLowerCase();
    const target = insideRoot(dstRoot, f.path);

    let present = false;
    try {
      await fsp.access(target);
      present = true;
    } catch {
      /* missing: copy it */
    }
    if (present && f.keep) {
      if (f.path === "ue4ss/Mods/mods.txt") {
        const source = path.join(srcRoot, rel);
        if ((await hashFile(source)) !== want) throw new ClientModsError(f.path, "the launcher's copy does not match manifest.json");
        const before = await fsp.readFile(target, "utf8");
        const after = addMissingModLines(before, await fsp.readFile(source, "utf8"));
        if (after !== before) {
          await fsp.writeFile(`${target}.new`, after, "utf8");
          await fsp.rename(`${target}.new`, target);
        }
      }
      result.kept++;
      continue;
    }
    if (present) {
      try {
        if ((await hashFile(target)) === want) {
          result.upToDate++;
          continue;
        }
      } catch {
        /* unreadable: replace it */
      }
    }

    const source = path.join(srcRoot, rel);
    let sourceHash: string;
    try {
      sourceHash = await hashFile(source);
    } catch {
      throw new ClientModsError(f.path, "missing from the launcher's resources");
    }
    if (sourceHash !== want) throw new ClientModsError(f.path, "the launcher's copy does not match manifest.json");

    await fsp.mkdir(path.dirname(target), { recursive: true });
    const tmp = `${target}.new`;
    await fsp.copyFile(source, tmp);
    if ((await hashFile(tmp)) !== want) {
      await fsp.unlink(tmp).catch(() => undefined);
      throw new ClientModsError(f.path, "changed while copying (antivirus?)");
    }
    try {
      await fsp.rename(tmp, target);
    } catch (e) {
      await fsp.unlink(tmp).catch(() => undefined); // the target is in use (the game is running)
      throw e;
    }
    await unblock(target);
    result.installed++;
  }

  result.disabled = await disableInModsTxt(path.join(dstRoot, "ue4ss", "Mods", "mods.txt"), Array.isArray(manifest.disable) ? manifest.disable : []);
  return result;
}

// "Name : 1" -> "Name : 0" in mods.txt for each name (mod folder names only), keeping every other
// line, the order and the line endings exactly. Returns how many lines changed.
export function disableModLines(text: string, names: readonly unknown[]): { text: string; changed: number } {
  const off = new Set(names.filter((n): n is string => typeof n === "string" && /^[A-Za-z0-9_]+$/.test(n)));
  let changed = 0;
  const out = text.replace(/^([ \t]*)([A-Za-z0-9_]+)([ \t]*:[ \t]*)1([ \t]*)(\r?)$/gm, (line, pre: string, name: string, sep: string, post: string, cr: string) => {
    if (!off.has(name)) return line;
    changed++;
    return `${pre}${name}${sep}0${post}${cr}`;
  });
  return { text: out, changed };
}

async function disableInModsTxt(file: string, names: readonly unknown[]): Promise<number> {
  if (names.length === 0) return 0;
  let text: string;
  try {
    text = await fsp.readFile(file, "utf8");
  } catch {
    return 0; // no mods.txt: nothing to switch off
  }
  const r = disableModLines(text, names);
  if (r.changed === 0) return 0;
  const tmp = `${file}.new`;
  await fsp.writeFile(tmp, r.text, "utf8");
  await fsp.rename(tmp, file);
  return r.changed;
}

// Add newly shipped mods without changing a player's existing enabled/disabled choices.
// Put additions first so the built-in Keybinds entry stays at the end.
export function addMissingModLines(text: string, defaults: string): string {
  const names = new Set(Array.from(text.matchAll(/^[ \t]*([A-Za-z0-9_]+)[ \t]*:/gm), m => m[1].toLowerCase()));
  const missing: string[] = [];
  for (const m of defaults.matchAll(/^[ \t]*([A-Za-z0-9_]+)[ \t]*:[ \t]*([01])[ \t]*\r?$/gm)) {
    if (!names.has(m[1].toLowerCase())) {
      missing.push(`${m[1]} : ${m[2]}`);
      names.add(m[1].toLowerCase());
    }
  }
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  return missing.length ? missing.join(eol) + eol + text : text;
}

// ------------------------------------------------------------------ Mods page switches
// Separate from the install code above (which never changes a player's switches): the launcher's
// Mods page reads and flips single mods here, in the same mods.txt the in-game Mod Menu writes.

const MOD_LINE = /^([ \t]*)([A-Za-z0-9_]+)([ \t]*:[ \t]*)([01])([ \t]*)(\r?)$/gm;

function modsTxtFile(installDir: string): string {
  return path.join(path.resolve(win64Dir(installDir)), "ue4ss", "Mods", "mods.txt");
}

// The mod's switch in mods.txt text: true for "Name : 1", false for "Name : 0" or no line at all
// (a mod without a line is not loaded).
export function modSwitchOn(text: string, name: string): boolean {
  for (const m of text.matchAll(MOD_LINE)) {
    if (m[2].toLowerCase() === name.toLowerCase()) return m[4] === "1";
  }
  return false;
}

// Sets the mod's line to "Name : 1" or "Name : 0", keeping every other line, the order and the line
// endings. A mod without a line gets one at the top, as addMissingModLines adds new mods.
export function setModSwitchLine(text: string, name: string, on: boolean): string {
  let found = false;
  const out = text.replace(MOD_LINE, (line, pre: string, n: string, sep: string, _v: string, post: string, cr: string) => {
    if (n.toLowerCase() !== name.toLowerCase()) return line;
    found = true;
    return `${pre}${n}${sep}${on ? "1" : "0"}${post}${cr}`;
  });
  if (found) return out;
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  return `${name} : ${on ? "1" : "0"}${eol}${text}`;
}

// Each named mod's switch in the game's mods.txt, or null when there is no mods.txt yet (the game
// is not installed, or the launcher has not installed the mods into it).
export async function readModSwitches<N extends string>(installDir: string, names: readonly N[]): Promise<Record<N, boolean> | null> {
  let text: string;
  try {
    text = await fsp.readFile(modsTxtFile(installDir), "utf8");
  } catch {
    return null;
  }
  const out = {} as Record<N, boolean>;
  for (const n of names) out[n] = modSwitchOn(text, n);
  return out;
}

// Switches one mod in the game's mods.txt. False when there is no mods.txt to change. Callers pass
// only names from a fixed list.
export async function writeModSwitch(installDir: string, name: string, on: boolean): Promise<boolean> {
  if (!/^[A-Za-z0-9_]+$/.test(name)) return false;
  const file = modsTxtFile(installDir);
  let text: string;
  try {
    text = await fsp.readFile(file, "utf8");
  } catch {
    return false;
  }
  const next = setModSwitchLine(text, name, on);
  if (next === text) return true;
  // Its own temp name: a quick second click, or an install writing mods.txt.new, never shares it.
  const tmp = `${file}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.new`;
  await fsp.writeFile(tmp, next, "utf8");
  await fsp.rename(tmp, file);
  return true;
}

// True when WINEDLLOVERRIDES makes Wine load the dwmapi.dll next to the game exe first ("dwmapi=n,b"
// or "dwmapi=n"). That file is UE4SS's loader: without it Wine uses its built-in dwmapi.dll and no
// mod loads. Entries are "name[,name]=mode" separated by ";"; the last one naming dwmapi counts.
export function dwmapiNativeFirst(overrides: string | undefined): boolean {
  let native = false;
  for (const entry of (overrides ?? "").split(";")) {
    const eq = entry.indexOf("=");
    if (eq < 0) continue;
    const names = entry.slice(0, eq).split(",").map((n) => n.trim().toLowerCase().replace(/^\*/, "").replace(/\.dll$/, ""));
    if (names.includes("dwmapi")) native = entry.slice(eq + 1).trim().toLowerCase().startsWith("n");
  }
  return native;
}
