# Windows accessibility contract

winghostty uses native Win32 accessibility for standard edit, button, list,
dialog, and settings controls. Custom UI Automation providers are limited to
owner-drawn surfaces whose semantics Win32 cannot infer.

| Surface | Contract | Provider |
| --- | --- | --- |
| Host window and custom caption | Window name, focus, native caption buttons | winghostty root chained to host provider |
| Terminal pane | Document name/value/text ranges, focus changes | winghostty terminal provider |
| Universal Palette | List name, navigable result rows, selected result announcements | winghostty list/row fragment providers; native edit for query |
| Tabs, search, settings, confirmation/update/recovery UI | Name, role, value/selection, keyboard focus | native HWND providers |

Automated acceptance is `test/windows/interactive-win11-accessibility.ps1`.
It emits `uia-tree.json`, requires Window and Document elements, checks focus
ownership, and records High Contrast state. The same script runs in the PR
interactive smoke lane. Before a public release, manually verify the current
build with Narrator and NVDA: navigate tabs and panes, read terminal text,
open/filter/invoke the palette, edit settings, and dismiss confirmation/update
surfaces at 100%, 200%, and 300% DPI with High Contrast both off and on.

Custom row fragments exist only for the owner-drawn Universal Palette list.
Standard native lists keep their HWND providers so Windows owns their roles,
navigation, selection patterns, focus, and events.
