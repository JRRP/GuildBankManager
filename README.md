# Guild Bank Manager

Generic Retail WoW guild-bank stock manager.

## Tab types

- **SORTED**: user-defined item layouts. Drag an item into the GUI, then set desired stack size and number of slots.
- **STORAGE**: unrestricted dump/source tabs. No per-item setup at all. All Storage tabs are treated as one shared inventory pool.
- **IGNORED**: never intentionally touched.

The addon has no built-in concept of flasks, potions, herbs, ore, consumables, or AH categories. Any item can be configured by the user.

## Install

### WowUp

In WowUp, choose **Get Addons → Install from URL**, paste the public GitHub repository URL, and click **Import**. WowUp will follow future GitHub releases automatically.

### Manual

Extract the `GuildBankManager` folder to:

`World of Warcraft/_retail_/Interface/AddOns/`

Then enable the addon and use `/gbm`.

## Releases

Release ZIPs are built automatically when a version tag such as `v1.1.6` is pushed. Keep the tag, `## Version` in `GuildBankManager.toc`, and `GBM.version` in `Core.lua` synchronized.

## Workflow

1. Open the guild bank.
2. `/gbm`
3. Mark one or more tabs as STORAGE.
4. Mark distribution/layout tabs as SORTED.
5. On a SORTED tab, drag items from your bags or guild bank onto the drop area.
6. Set stack size and number of slots.
7. Click **SORT BANK**.

## Sorting behavior

- Correct Sorted stacks are left alone.
- Incorrect/excess Sorted stacks are returned to available Storage space.
- Sorted slots are then filled from the combined inventory of all Storage tabs.
- Storage itself has no layout rules.
- Ignored tabs are excluded.

## Safety

The sorter queues guild-bank operations with a delay instead of issuing many operations in one frame. It stops on combat, bank closure, repeated locked-slot/cursor failures, insufficient Storage space, missing stock, or missing bank permissions.

Guild-rank withdrawal limits are intentionally outside this addon's scope.


## 0.4.2 safety change

- A Public tab with no rules is never touched.
- Only the slots explicitly covered by Public rules are managed.
- Unrelated items in unconfigured tail slots are never moved to Storage.
- A non-matching item is moved out only when it physically occupies a configured target slot that GBM needs to stock.

## 0.4.3 executor safety

- Executes only one guild-bank transaction at a time.
- Waits for `GUILDBANKBAGSLOTS_CHANGED`, slot unlock, and a quiet settle period.
- Rescans the real guild bank and rebuilds the remaining plan after every accepted move.
- No longer clears a non-empty cursor automatically.
- Increased the default inter-transaction delay to 0.45 seconds.
- This prevents stale static plans from producing incorrect target stack counts after a delayed split/merge.

## 0.4.4

- Top navigation now uses the guild bank's actual tab names instead of numbers/custom addon names.
- Removed addon-side tab renaming from the main UI; rename guild-bank tabs normally and GBM follows them.
- Cleaner panel-based UI matching the newer mockup.
- Hidden/non-viewed source and destination tabs are explicitly queried before each transaction.
- Pending moves periodically re-query both affected tabs while waiting for Blizzard to settle.
- Confirmation timeout increased and now reconciles/replans before stopping, reducing false "did not confirm" failures on tabs you are not currently viewing.
- Default move delay increased to 0.55 seconds.


## 0.4.5
- Public stacks now converge in place: short stacks are topped up; oversized stacks split only the excess to Storage.
- Wrong-item stacks are still cleared normally.
- Bottom status text now has a dedicated panel and no longer overlaps the summary/status area.

## 0.4.6
- Fixed short Public stacks receiving the full configured amount instead of only the missing amount.
- The next bank move is now prepared during the normal inter-transaction delay, removing a redundant wait while retaining per-move verification.

## 0.4.7
- Storage source selection now prefers a stack large enough to finish the destination in one move.
- When no single stack is large enough, the largest partial stack is used first to minimize transactions.

## 0.4.8
- Restored the live total move-count status as `completed / total` while sorting.

## 0.4.9
- Added a live elapsed duration to the sorting status text.

## 0.5.0
- Reduced redundant transaction timing from roughly one second per move to about half a second under normal guild-bank response times.
- Retained cursor, slot-lock, state-change, rescan, timeout, and retry safeguards.

## 0.5.1
- Changed the live elapsed timer to display total seconds.

## 0.5.2
- Combined the GUI scan and sort controls into one `SCAN & SORT` button.
- `/gbm scan` now runs the same scan-and-sort operation instead of scanning alone.

## 0.5.3
- The elapsed timer now starts when `SCAN & SORT` is pressed, including scan and planning time.
- The completed move count and total duration remain visible after sorting finishes.

## 0.6.0
- Matching configured items anywhere on their Public tab now count toward the requested stock.
- Matching stacks outside the managed layout are used before Storage stock is pulled.
- Any configured-item stock still outside the layout after filling is returned to Storage as excess.
- Unrelated items outside the managed layout remain untouched.

## 0.6.1
- Items returned to Storage now top up existing partial stacks before occupying empty slots.
- Storage capacity checks account for both partial-stack space and empty slots.

## 0.6.2
- Failed Storage drops now immediately return the cursor item to its source slot.
- Source and destination pickup failures are retried after a fresh tab query and stop safely after repeated rejection.

## 0.6.3
- Cross-tab moves now select and wait for the destination guild-bank tab before dropping the cursor item.
- This fixes Public-to-Storage moves failing while the Public tab remains displayed.

## 0.6.4
- Cross-tab moves now run in two stages: activate and pick up from the source, then activate and drop into the destination.
- Rejected cross-tab drops switch back to the source before rolling the cursor item back.

## 0.6.5
- Sorting now returns the guild-bank window to the tab that was active when `SCAN & SORT` was pressed.
- The original tab is also restored when sorting stops because of an error.

## 0.7.0
- Restyled the interface with an ElvUI-inspired dark charcoal theme.
- Added flat dark panels, subtle borders, blue accents, dark inputs, and compact custom buttons.

## 0.8.0
- Added named sort profiles with save, load, and delete controls.
- Added a safe, shareable `GBM1` text export format for tab modes and item rules.
- Imports are validated, saved as a named profile, and loaded without executing Lua code.

## 0.8.1
- The Guild Bank Manager window can now be closed with the Escape key.

## 0.8.2
- Fixed the Profile Manager requiring two clicks to open the first time.

## 0.9.0
- Added a per-item Storage backup multiplier, defaulting to `2×` the configured Public quantity.
- Added an Auctionator shopping-list preview and generation using current Public and Storage inventory shortages.
- Added `SORT STORAGE` to consolidate partial stacks and order Storage by item class, subclass, name, and stack size.
- Profile exports now include reserve multipliers while remaining compatible with older `GBM1` exports.

## 0.9.1
- Storage sorting now builds the complete move plan up front, making `moves complete` accurate.
- Storage tabs are consolidated and sorted independently, eliminating cross-tab Storage cursor moves.

## 0.9.2
- Same-tab guild-bank moves now stage pickup and drop on separate ticks.
- The executor waits for asynchronous merge settlement before attempting cursor rollback.

## 0.9.3
- Guild-bank tab labels now shrink their font to fit instead of truncating names.
- Leaving Public mode now requires confirmation when doing so would delete configured item rules.

## 0.9.4
- Fixed the Public-mode confirmation dialog for the current Retail static-popup frame API.

## 0.9.5
- Restyled item Remove buttons with a clear dark-red destructive-action treatment.
- Enlarged the backup multiplier label and replaced the small multiplication glyph with `X`.

## 0.9.6
- Centered the guild-tab button row with visually equal left and right padding.

## 0.9.7
- Removed the blue accent border from the Profiles button.

## 1.0.0
- Redesigned the main window around a fixed right-side Operations console.
- Compacted item configuration into two-line rows so the full interface remains within the original 790×690 window.
- Moved scan/sort, Storage sorting, Auctionator, and profile actions into the Operations console.
- Expanded the bottom status panel across the full content width.

## 1.0.1
- Renamed the user-facing tab modes to `SORTED`, `STORAGE`, and `IGNORED` without changing saved-profile compatibility.

## 1.0.2
- Compacted configured-item rows while preserving readable controls and labels.
- Replaced the boxed title-bar close button with a larger borderless `X` and red hover feedback.

## 1.1.0
- Auctionator restock searches now specify the exact crafted-quality tier of each configured item.

## 1.1.1
- Guild Bank Restock is now created as an Auctionator temporary list and is discarded on UI reload/logout.

## 1.1.2
- The main window now restores its last dragged position and remains clamped to the screen.

## 1.1.3
- Added an optional `Auto-open with guild bank` setting to the Operations panel.
- Removed the redundant guild-bank return-tab hint from the Operations panel.

## 1.1.4
- Restyled the auto-open checkbox as a compact square with the addon's blue accent fill when enabled.

## 1.1.5
- Added the `Achievement_GuildPerk_CashFlow` artwork as the addon's metadata icon.

## 1.1.6
- Added Baganator-compatible guild-bank detection through Retail player-interaction events.
- Deduplicated overlapping Blizzard and player-interaction open/close notifications.

## 1.1.7
- Finalized automated GitHub release packaging for URL-based addon managers.
