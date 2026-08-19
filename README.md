# Guild Bank Manager

Generic Retail WoW guild-bank stock manager.

## Tab types

- **SORTED**: user-defined item layouts. Drag an item into the GUI, then set desired stack size and number of slots.
- **STORAGE**: unrestricted dump/source tabs. No per-item setup at all. All Storage tabs are treated as one shared inventory pool.
- **IGNORED**: never intentionally touched.

The addon has no built-in concept of flasks, potions, herbs, ore, consumables, or AH categories. Any item can be configured by the user.

## Install

### WowUp

In WowUp, choose **Get Addons → Install from URL**, paste `https://github.com/JRRP/GuildBankManager`, and click **Import**. WowUp will follow future GitHub releases automatically.

### Manual

Extract the `GuildBankManager` folder to:

`World of Warcraft/_retail_/Interface/AddOns/`

Then enable the addon and use `/gbm`.

## Workflow

1. Open the guild bank.
2. Open Guild Bank Manager with `/gbm` or enable **Auto-open with guild bank**.
3. Mark one or more tabs as **STORAGE**.
4. Mark distribution/layout tabs as **SORTED**.
5. On a Sorted tab, drag items from your bags or guild bank onto the drop area.
6. Set the desired stack size, number of slots, and backup multiplier.
7. Click **SCAN & SORT BANK**.

## Sorting behavior

- Correct Sorted stacks are left alone.
- Incorrect or excess Sorted stacks are returned to available Storage space.
- Sorted slots are filled from the combined inventory of all Storage tabs.
- Storage itself has no per-item layout rules.
- Ignored tabs are excluded.

## Additional tools

- **Sort Storage** consolidates partial stacks and orders stored items.
- **Build Auction List** creates a temporary, exact-quality Auctionator restock list.
- **Manage Profiles** saves, imports, and exports shareable layouts.

## Safety

The sorter queues one verified guild-bank transaction at a time. It stops on combat, bank closure, repeated locked-slot or cursor failures, insufficient Storage space, missing stock, or missing bank permissions.

Guild-rank withdrawal limits are intentionally outside this addon's scope.

## Releases

See [CHANGELOG.md](CHANGELOG.md) for the complete version history and the [GitHub Releases page](https://github.com/JRRP/GuildBankManager/releases) for downloadable packages.
