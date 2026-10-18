# Client mods (UE4SS)

Optional client-side mods, installed automatically next to the game exe (`Archon/Binaries/Win64`):

- **UE4SS 3.0.1** (`dwmapi.dll`, `ue4ss/UE4SS.dll`; MIT, see `ue4ss/LICENSE`): the Lua mod loader.
- **Behemoth Health Bars**: a fixed HP and shield bar at the bottom of the screen (two bars when two behemoths are up).
  Off on new installs (`BehemothHealthBars : 0`): switched on from the launcher's Mods page or the in-game Mod Menu.
- **Behemoth Tracker**: an arrow and distance to the behemoth in the top right.
- **Mod Menu**: Home opens it, Up/Down (or PgUp/PgDn) choose, End flips the chosen switch. MODS turns
  whole mods on or off (applied on Ctrl+R); SETTINGS changes the mods live (shield bar, HP numbers,
  two bars in escalations, tracker at any distance, uncrafted weapon colour). Settings are saved in
  `ue4ss/Mods/shared/ModSettings/settings.txt` on each PC and never shipped or overwritten.
- **Uncrafted Weapons** (`CraftStar`): in the weapon crafting list, weapons you have never crafted get
  `>> ` in front of their name, in red, gold or purple (picked in the Mod Menu).
- **Hunt Again** (`HuntAgain`, by RB): after a pursuit, the last end-of-hunt screen gets a HUNT AGAIN
  button next to Continue (left click; R on the keyboard). It presses Continue and queues the same
  pursuit again once you are back in Ramsgate. Off by default (`HuntAgain : 0`): switched on from the
  launcher's Mods page or the in-game Mod Menu. Made and tested on CachyOS (Linux, Proton).

- **PS5Icons**: PlayStation 5 button prompts and a DualSense picture for the Controls screen. They
  are not a UE4SS mod: the client DLL (`UndauntedInternalServer.dll`) shows them while a DualSense
  is connected. Based on "PS5 Button Icons and Controls" by Zacksly (CC BY 3.0, modified; see
  `PS5Icons/LICENSE.txt`).

They only change your own game (Hunt Again also presses Continue and queues the hunt for you). The
game works without them.

## How they get installed

- **Launcher**: on install, repair and before every launch (`UndauntedLauncher/src/main/client-mods.ts`).
- **Friend kit**: `friend-kit/setup.ps1` (skip with `-NoMods`).

Both install only files whose SHA-256 matches `manifest.json`, and check them again after copying.
`ue4ss/UE4SS-settings.ini` is written only when missing. Existing `mods.txt` switches are kept; new bundled mods are added and retired mods are disabled. Under Wine/Proton UE4SS loads only when the launcher is started with `WINEDLLOVERRIDES=dwmapi=n,b` (Wine otherwise uses its built-in `dwmapi.dll` instead of the UE4SS one next to the exe); the launcher's Mods page explains this and shows whether it is on.

The launcher puts deleted files back before the next launch. To turn a mod off, use the Mod Menu or
set it to 0 in `ue4ss/Mods/mods.txt` (that file is kept).

## Changing a mod

Edit the files here, then rebuild the manifest and commit both:

    powershell -ExecutionPolicy Bypass -File client-mods\update-manifest.ps1

`.gitattributes` keeps every file byte-for-byte, so the hashes stay valid on every checkout.

Updates preserve existing mod switches, add newly shipped mods to `mods.txt`, and remove/disable the retired ZFX Status indicator. CraftStar is added before Keybinds on existing installations; an explicit CraftStar off setting is preserved.
