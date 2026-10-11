# Changelog

## 1.0.1 (2026-10-11)

- `omelette setup --remove` takes the shortcuts block back out of `bindings.lua`.
- README: removal instructions.
- Root `preview.jpg` for the plugin marketplace card.

## 1.0.0 (2026-10-11)

First release.

- Flip any window into the tile under the pointer with Super + Ctrl + scroll, or the focused tile with Super + Ctrl + Up / Down.
- One-swap rule: the chosen window and the tile's original trade places, nothing else moves.
- Live filmstrip of window thumbnails, including windows on other workspaces.
- Smart order: windows that want attention, then other workspaces, then on screen.
- Same-app mode with Shift.
- Search panel (Super + Ctrl + /) and undo (Super + Ctrl + Esc).
- Soft fade-in for the incoming window; the pointer stays where it was.
- `omelette setup` installs the shortcuts in a managed, backed-up block.
- Optional one-handed mode through a Wayland-Wheeltani button-gesture patch.
