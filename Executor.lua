local ADDON, GBM = ...

-- Guild-bank updates can be slow/coalesced, especially when an action touches a
-- tab that is not currently visible in Blizzard's Guild Bank frame.  The
-- executor therefore prepares each action by explicitly querying its source and
-- destination tabs, performs exactly one transaction, then continues querying
-- those affected tabs while waiting for the real bank state to settle.

GBM.executing = false
GBM.queue = nil
GBM.queueIndex = 0
GBM.executorTicker = nil
GBM.executorPending = nil
GBM.executorProcessed = 0
GBM.executorTotalMoves = 0
GBM.executorStartedAt = nil
GBM.executorStalls = 0
GBM.executorNextActionAt = 0
GBM.executorPreparedKey = nil
GBM.executorPrepareUntil = 0
GBM.executorPlanBuilder = nil
GBM.executorLabel = nil

local POLL_INTERVAL = 0.05
local EVENT_SETTLE = 0.15
local ACTION_TIMEOUT = 10.0
local REQUERY_INTERVAL = 0.30
local PREPARE_DELAY = 0.25
local MAX_STALLS = 4
local MAX_ACTIONS = 600

local function CursorClear()
    return GetCursorInfo() == nil
end

local function SlotInfo(tab, slot)
    local _, count, locked = GetGuildBankItemInfo(tab, slot)
    local link = GetGuildBankItemLink(tab, slot)
    return {
        itemID = GBM:ItemIDFromLink(link),
        count = count or 0,
        locked = locked and true or false,
    }
end

local function SlotUnlocked(tab, slot)
    local _, _, locked = GetGuildBankItemInfo(tab, slot)
    return not locked
end

local function Signature(a, b)
    return table.concat({
        tostring(a.itemID or 0), tostring(a.count or 0), tostring(a.locked and 1 or 0),
        tostring(b.itemID or 0), tostring(b.count or 0), tostring(b.locked and 1 or 0),
    }, ":")
end

local function CurrentSignature(action)
    return Signature(SlotInfo(action.srcTab, action.srcSlot), SlotInfo(action.dstTab, action.dstSlot))
end

local function ActionKey(action)
    return table.concat({
        tostring(action.kind or "move"),
        tostring(action.srcTab), tostring(action.srcSlot),
        tostring(action.dstTab), tostring(action.dstSlot),
        tostring(action.amount or 0),
    }, ":")
end

local function QueryActionTabs(action)
    if not action then return end
    QueryGuildBankTab(action.srcTab)
    if action.dstTab ~= action.srcTab then
        QueryGuildBankTab(action.dstTab)
    end
    if SetCurrentGuildBankTab and GetCurrentGuildBankTab and GetCurrentGuildBankTab() ~= action.srcTab then
        SetCurrentGuildBankTab(action.srcTab)
    end
end

local function SourceTabReady(action)
    return not GetCurrentGuildBankTab
        or GetCurrentGuildBankTab()==action.srcTab
end

local function DoAction(action)
    if not SlotUnlocked(action.srcTab, action.srcSlot) or not SlotUnlocked(action.dstTab, action.dstSlot) then
        return false, "locked"
    end
    if not CursorClear() then
        return false, "cursor"
    end

    local before = CurrentSignature(action)

    if action.kind == "split" then
        SplitGuildBankItem(action.srcTab, action.srcSlot, action.amount)
    else
        PickupGuildBankItem(action.srcTab, action.srcSlot)
    end

    -- Do not touch the destination unless Blizzard actually placed the source
    -- item on the cursor. A stale/locked source can otherwise make the second
    -- pickup act on the destination itself.
    if CursorClear() then
        return false, "source"
    end

    if action.srcTab~=action.dstTab and SetCurrentGuildBankTab then
        SetCurrentGuildBankTab(action.dstTab)
    end
    -- All drops are staged on a later tick. Guild-bank merges can settle
    -- asynchronously even within one tab; issuing pickup and drop in the same
    -- frame and immediately checking the cursor can misclassify a valid merge.
    return true, before, true
end

function GBM:OnBankSlotsChanged(tab)
    if not self.executing or not self.executorPending then return end
    self.executorPending.sawEvent = true
    self.executorPending.lastEventAt = GetTime()
end

function GBM:StopExecutor(reason)
    local wasExecuting = self.executing
    if self.executorTicker then
        self.executorTicker:Cancel()
        self.executorTicker = nil
    end
    if self.executing and reason then self:Print(reason) end
    self.executing = false
    self.queue = nil
    self.queueIndex = 0
    self.executorPending = nil
    self.executorProcessed = 0
    self.executorTotalMoves = 0
    self.executorStartedAt = nil
    self.executorStalls = 0
    self.executorNextActionAt = 0
    self.executorPreparedKey = nil
    self.executorPrepareUntil = 0
    if wasExecuting and self.bankOpen and self.sortOriginalTab and SetCurrentGuildBankTab then
        SetCurrentGuildBankTab(self.sortOriginalTab)
        QueryGuildBankTab(self.sortOriginalTab)
    end
    if wasExecuting then self.sortOriginalTab=nil end
end

local function FinishSort()
    local processed = GBM.executorProcessed or 0
    GBM.lastSortLabel = GBM.executorLabel or "Sorting"
    GBM.lastSortDuration = math.max(0, GetTime() - (GBM.executorStartedAt or GBM.sortStartedAt or GetTime()))
    GBM.lastSortMoves = processed
    GBM:StopExecutor()
    GBM:Print(("%s complete. %d transaction(s) processed in %d seconds."):format(GBM.lastSortLabel,processed,math.floor(GBM.lastSortDuration)))
    if GBM.RefreshUI then GBM:RefreshUI() end
    C_Timer.After(0.5, function()
        if GBM.bankOpen then
            GBM:QueryConfiguredTabs()
            C_Timer.After(0.35, function()
                if GBM.bankOpen then
                    GBM:ScanBank()
                    if GBM.RefreshUI then GBM:RefreshUI() end
                end
            end)
        end
    end)
end

local function BuildCurrentPlan()
    if GBM.executorPlanBuilder then return GBM.executorPlanBuilder() end
    return GBM:BuildPlan()
end

local function ReplanAfterTransaction()
    GBM:ScanBank()
    local plan, why = BuildCurrentPlan()
    if not plan then
        GBM:StopExecutor("Sort stopped after rescan: " .. tostring(why))
        return
    end

    if #plan == 0 then
        FinishSort()
        return
    end

    GBM.queue = plan
    GBM.queueIndex = 1
    GBM.executorTotalMoves = (GBM.executorProcessed or 0) + #plan
    -- Prepare the next action during the configured inter-transaction delay.
    -- Previously these waits ran one after the other (move delay, then prepare
    -- delay), adding roughly half a second to every bank operation.
    local nextAction = plan[1]
    local now = GetTime()
    QueryActionTabs(nextAction)
    GBM.executorPreparedKey = ActionKey(nextAction)
    GBM.executorPrepareUntil = now + PREPARE_DELAY
    GBM.executorNextActionAt = now + math.max(0.20, tonumber(GBM.db.options.moveDelay) or 0.25)
    if GBM.RefreshUI then GBM:RefreshUI() end
end

local function PendingFinished()
    local p = GBM.executorPending
    if not p then return end

    local now = GetTime()
    local action = p.action

    if p.needsDrop then
        if GetCurrentGuildBankTab and GetCurrentGuildBankTab()~=action.dstTab then
            SetCurrentGuildBankTab(action.dstTab)
            p.dropAfter=now+PREPARE_DELAY
            return
        end
        if p.dropAttempted then
            if CursorClear() then
                p.needsDrop=false
                p.lastEventAt=now
                p.sawEvent=true
                return
            end
            if now<(p.dropResultAt or 0) then return end
        else
            if now<(p.dropAfter or 0) then return end
            QueryGuildBankTab(action.dstTab)
            PickupGuildBankItem(action.dstTab,action.dstSlot)
            p.dropAttempted=true
            p.dropResultAt=now+EVENT_SETTLE
            if CursorClear() then
                p.needsDrop=false
                p.lastEventAt=now
                p.sawEvent=true
            end
            return
        end
        p.needsDrop=false
        p.needsRollback=true
        p.rollbackAfter=now+PREPARE_DELAY
        if SetCurrentGuildBankTab then SetCurrentGuildBankTab(action.srcTab) end
        return
    end

    if p.needsRollback then
        if GetCurrentGuildBankTab and GetCurrentGuildBankTab()~=action.srcTab then
            SetCurrentGuildBankTab(action.srcTab)
            p.rollbackAfter=now+PREPARE_DELAY
            return
        end
        if not p.rollbackAttempted then
            if now<(p.rollbackAfter or 0) then return end
            PickupGuildBankItem(action.srcTab,action.srcSlot)
            p.rollbackAttempted=true
            p.rollbackResultAt=now+EVENT_SETTLE
            return
        end
        if not CursorClear() and now<(p.rollbackResultAt or 0) then return end
        if not CursorClear() then
            GBM:StopExecutor("Sort stopped: a rejected move could not be returned to its source slot.")
            return
        end
        GBM.executorPending=nil
        GBM.executorStalls=GBM.executorStalls+1
        GBM.executorPreparedKey=nil
        GBM.executorNextActionAt=now+0.40
        QueryActionTabs(action)
        return
    end

    -- Keep non-visible tabs warm while Blizzard processes a cross-tab action.
    if now >= (p.nextQueryAt or 0) then
        QueryActionTabs(action)
        p.nextQueryAt = now + REQUERY_INTERVAL
    end

    if not SlotUnlocked(action.srcTab, action.srcSlot) or not SlotUnlocked(action.dstTab, action.dstSlot) then
        if now - p.startedAt > ACTION_TIMEOUT then
            GBM:StopExecutor("Sort stopped: a guild-bank slot stayed locked too long.")
        end
        return
    end

    if not CursorClear() then
        if now - p.startedAt > ACTION_TIMEOUT then
            GBM:StopExecutor("Sort stopped: an item remained on the cursor. Clear the cursor and try again.")
        end
        return
    end

    if p.sawEvent and (now - (p.lastEventAt or p.startedAt)) < EVENT_SETTLE then
        return
    end

    local after = CurrentSignature(action)
    local changed = after ~= p.beforeSignature

    -- Events are useful, but not authoritative for non-visible tabs.  A changed,
    -- unlocked slot pair is sufficient confirmation even if Blizzard coalesced
    -- the GUILDBANKBAGSLOTS_CHANGED event.
    if changed and now - p.startedAt >= 0.20 then
        GBM.executorPending = nil
        GBM.executorStalls = 0
        GBM.executorProcessed = GBM.executorProcessed + 1
        if GBM.executorProcessed >= MAX_ACTIONS then
            GBM:StopExecutor("Sort stopped after too many transactions; rescan the bank and try again.")
            return
        end
        ReplanAfterTransaction()
        return
    end

    if now - p.startedAt <= ACTION_TIMEOUT then
        return
    end

    -- Last-chance reconciliation: refresh the affected tabs, rebuild from the
    -- actual bank snapshot, and only stop if the exact same action is still the
    -- next required move.  This avoids false timeouts on hidden tabs.
    QueryActionTabs(action)
    GBM:ScanBank()
    local plan, why = BuildCurrentPlan()
    if not plan then
        GBM:StopExecutor("Sort stopped after timeout rescan: " .. tostring(why))
        return
    end
    if #plan == 0 then
        GBM.executorProcessed = GBM.executorProcessed + 1
        GBM.executorPending = nil
        FinishSort()
        return
    end

    local nextAction = plan[1]
    if ActionKey(nextAction) ~= ActionKey(action) then
        GBM.executorProcessed = GBM.executorProcessed + 1
        GBM.executorPending = nil
        GBM.queue = plan
        GBM.executorPreparedKey = nil
        GBM.executorNextActionAt = GetTime() + 0.35
        if GBM.RefreshUI then GBM:RefreshUI() end
        return
    end

    GBM.executorStalls = GBM.executorStalls + 1
    if GBM.executorStalls >= MAX_STALLS then
        GBM:StopExecutor("Sort stopped: the same guild-bank move could not be confirmed after repeated refreshes.")
        return
    end

    -- Do not immediately duplicate the action.  Drop the pending state and go
    -- through the full query/prepare phase again before one controlled retry.
    GBM.executorPending = nil
    GBM.queue = plan
    GBM.executorPreparedKey = nil
    GBM.executorPrepareUntil = 0
    GBM.executorNextActionAt = GetTime() + 0.75
end

local function Tick()
    if not GBM.executing then return end
    if GBM:InCombat() then GBM:StopExecutor("Sort stopped: entered combat."); return end
    if not GBM.bankOpen then GBM:StopExecutor("Sort stopped: guild bank is not open."); return end

    if GBM.executorPending then
        PendingFinished()
        return
    end

    if GetTime() < (GBM.executorNextActionAt or 0) then return end

    local action = GBM.queue and GBM.queue[1]
    if not action then
        ReplanAfterTransaction()
        return
    end

    if not CursorClear() then
        GBM:StopExecutor("Sort stopped: clear the item from your cursor before sorting.")
        return
    end

    local key = ActionKey(action)
    if GBM.executorPreparedKey ~= key then
        QueryActionTabs(action)
        GBM.executorPreparedKey = key
        GBM.executorPrepareUntil = GetTime() + PREPARE_DELAY
        return
    end
    if GetTime() < (GBM.executorPrepareUntil or 0) then return end

    if not SourceTabReady(action) then
        QueryActionTabs(action)
        GBM.executorPrepareUntil = GetTime() + PREPARE_DELAY
        return
    end

    -- Refresh the local snapshot after the explicit tab query.  If the plan has
    -- changed while we waited, use the newly-calculated first action instead of
    -- executing stale coordinates.
    GBM:ScanBank()
    local freshPlan, why = BuildCurrentPlan()
    if not freshPlan then
        GBM:StopExecutor("Sort stopped before move: " .. tostring(why))
        return
    end
    if #freshPlan == 0 then
        FinishSort()
        return
    end
    if ActionKey(freshPlan[1]) ~= key then
        GBM.queue = freshPlan
        GBM.executorPreparedKey = nil
        GBM.executorPrepareUntil = 0
        return
    end

    action = freshPlan[1]
    GBM.queue = freshPlan

    local ok, result, needsDrop = DoAction(action)
    if not ok then
        if result == "locked" then
            QueryActionTabs(action)
            GBM.executorPreparedKey = nil
            GBM.executorNextActionAt = GetTime() + 0.40
            return
        end
        if result == "source" or result == "destination" then
            GBM.executorStalls = GBM.executorStalls + 1
            if GBM.executorStalls >= MAX_STALLS then
                GBM:StopExecutor("Sort stopped: a guild-bank destination repeatedly rejected the move; the item was returned to its source slot.")
                return
            end
            QueryActionTabs(action)
            GBM.executorPreparedKey = nil
            GBM.executorNextActionAt = GetTime() + 0.40
            return
        end
        if result == "rollback" then
            GBM:StopExecutor("Sort stopped: a destination rejected the move and the item could not be returned. Place the cursor item back into its source slot.")
            return
        end
        GBM:StopExecutor("Sort stopped: could not start bank move (" .. tostring(result) .. ").")
        return
    end

    GBM.executorPending = {
        action = action,
        beforeSignature = result,
        startedAt = GetTime(),
        lastEventAt = nil,
        sawEvent = false,
        nextQueryAt = GetTime() + REQUERY_INTERVAL,
        needsDrop = needsDrop,
        dropAfter = needsDrop and (GetTime() + (action.srcTab==action.dstTab and 0.10 or PREPARE_DELAY)) or nil,
    }
    GBM.executorPreparedKey = nil
    GBM.executorPrepareUntil = 0

    if GBM.RefreshUI then GBM:RefreshUI() end
end

function GBM:StartExecutor(plan,planBuilder,label)
    self:StopExecutor()

    if not CursorClear() then
        self:Print("Clear the item from your cursor before sorting.")
        return
    end

    self.executing = true
    self.executorPlanBuilder = planBuilder
    self.executorLabel = label or "Sorting"
    self.queue = plan
    self.queueIndex = 1
    self.executorProcessed = 0
    self.executorTotalMoves = #plan
    self.executorStartedAt = self.sortStartedAt or GetTime()
    self.executorStalls = 0
    self.executorPending = nil
    local firstAction = plan and plan[1]
    local now = GetTime()
    if firstAction then
        QueryActionTabs(firstAction)
        self.executorPreparedKey = ActionKey(firstAction)
        self.executorPrepareUntil = now + PREPARE_DELAY
    else
        self.executorPreparedKey = nil
        self.executorPrepareUntil = 0
    end
    self.executorNextActionAt = now + 0.15

    self.executorTicker = C_Timer.NewTicker(POLL_INTERVAL, Tick)
    if self.RefreshUI then self:RefreshUI() end
end
