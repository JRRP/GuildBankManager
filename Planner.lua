local ADDON, GBM = ...

local function CloneSnapshot(bank)
    local out = { tabs = {} }
    for tab, td in pairs(bank.tabs) do
        out.tabs[tab] = { mode=td.mode, canDeposit=td.canDeposit, canWithdraw=td.canWithdraw, slots={} }
        for slot, s in pairs(td.slots) do
            out.tabs[tab].slots[slot] = {
                tab=tab, slot=slot, itemID=s.itemID, link=s.link, count=s.count or 0, locked=s.locked
            }
        end
    end
    return out
end

local function MaxStack(itemID)
    return select(8,GetItemInfo(itemID)) or 1
end

local function FindStorageDestination(state,itemID,amount)
    local partial={}
    local empty
    for tab=1,GBM.MAX_TABS do
        local td=state.tabs[tab]
        if td and td.mode=="storage" and td.canDeposit then
            for slot=1,GBM.SLOTS_PER_TAB do
                local s=td.slots[slot]
                if s and not s.locked then
                    if s.itemID==itemID and s.count<MaxStack(itemID) then
                        s.free=MaxStack(itemID)-s.count
                        table.insert(partial,s)
                    elseif not s.itemID and not empty then
                        empty=s
                    end
                end
            end
        end
    end
    table.sort(partial,function(a,b)
        local aFits=a.free>=amount
        local bFits=b.free>=amount
        if aFits~=bFits then return aFits end
        if aFits then return a.free<b.free end
        return a.free>b.free
    end)
    local dst=partial[1] or empty
    if dst then dst.free=nil end
    return dst
end

local function SortSources(out, needed)
    needed = math.max(1, needed or 1)
    table.sort(out,function(a,b)
        local aEnough = a.count >= needed
        local bEnough = b.count >= needed
        if aEnough ~= bEnough then return aEnough end
        if aEnough then return a.count < b.count end
        return a.count > b.count
    end)
    return out
end

local function FindSources(state, itemID, needed, publicTab, managedSlots)
    local out={}
    -- Matching stacks outside this Public tab's configured layout count toward
    -- its requested total and are consumed before Storage stock.
    local public=state.tabs[publicTab]
    if public and public.canWithdraw then
        for slot=managedSlots+1,GBM.SLOTS_PER_TAB do
            local s=public.slots[slot]
            if s and s.itemID==itemID and not s.locked and s.count>0 then
                table.insert(out,s)
            end
        end
    end
    if #out>0 then return SortSources(out,needed) end

    for tab,td in pairs(state.tabs) do
        if td.mode=="storage" and td.canWithdraw then
            for slot=1,GBM.SLOTS_PER_TAB do
                local s=td.slots[slot]
                if s and s.itemID==itemID and not s.locked and s.count>0 then table.insert(out,s) end
            end
        end
    end
    -- Prefer a source that can finish the destination in one transaction.
    -- Among qualifying stacks, use the smallest one to preserve larger stacks.
    -- If every source is short, consume the largest partial stack first so the
    -- destination needs as few additional transactions as possible.
    return SortSources(out,needed)
end

local function AddMove(plan, kind, src, dst, amount, why)
    table.insert(plan, {kind=kind, srcTab=src.tab, srcSlot=src.slot, dstTab=dst.tab, dstSlot=dst.slot, amount=amount, why=why})
end

local function VirtualWholeMove(src,dst)
    src.itemID,dst.itemID = dst.itemID,src.itemID
    src.link,dst.link = dst.link,src.link
    src.count,dst.count = dst.count,src.count
end

local function VirtualSplit(src,dst,amount)
    dst.itemID=src.itemID; dst.link=src.link; dst.count=amount
    src.count=src.count-amount
    if src.count<=0 then src.itemID=nil; src.link=nil; src.count=0 end
end

function GBM:BuildPlan()
    local state=CloneSnapshot(self.bank)
    local plan={}

    local function returnToStorage(src,amount,reason)
        local remaining=math.min(amount or src.count,src.count)
        while remaining>0 do
            local dst=FindStorageDestination(state,src.itemID,remaining)
            if not dst then return false end
            local maxStack=MaxStack(src.itemID)
            local capacity=dst.itemID and (maxStack-dst.count) or maxStack
            local take=math.min(remaining,capacity)
            local kind=take==src.count and "move" or "split"
            AddMove(plan,kind,src,dst,kind=="split" and take or nil,reason)
            if dst.itemID then
                dst.count=dst.count+take
            else
                dst.itemID=src.itemID; dst.link=src.link; dst.count=take
            end
            src.count=src.count-take
            if src.count<=0 then src.itemID=nil; src.link=nil; src.count=0 end
            remaining=remaining-take
        end
        return true
    end

    -- Phase 1: evacuate Public slots that are not already exactly correct.
    for tab=1,self.MAX_TABS do
        local cfg=self.db.tabs[tab]
        local td=state.tabs[tab]
        if cfg.mode=="public" and td then
            if not td.canDeposit or not td.canWithdraw then
                return nil, ("No deposit/withdraw permission for Public tab %d."):format(tab)
            end
            local desired={}
            local cursor=1
            for _,rule in ipairs(cfg.rules) do
                for _=1,rule.slots do
                    if cursor>self.SLOTS_PER_TAB then return nil,("Public tab %d layout exceeds 98 slots."):format(tab) end
                    desired[cursor]={itemID=rule.itemID,count=rule.stackSize}
                    cursor=cursor+1
                end
            end
            -- SAFETY: GBM only owns the slot range explicitly created by rules.
            -- A Public tab with zero rules is completely untouched. Slots after
            -- the configured layout are never cleared merely because of position;
            -- only excess copies of an explicitly configured item are handled.
            local managedSlots = cursor - 1
            for slot=1,managedSlots do
                local s=td.slots[slot]
                local d=desired[slot]

                if s.itemID and d then
                    if s.itemID ~= d.itemID then
                        -- Wrong item: the configured slot must be cleared completely.
                        if not returnToStorage(s,s.count,"clear wrong item from configured public slot") then
                            return nil,"Not enough stack capacity in Storage tabs to reorganize configured Public slots."
                        end
                    elseif s.count > d.count then
                        -- Correct item, but too many.  Keep the desired amount in place and
                        -- split only the excess back to Storage.  Moving the entire stack out
                        -- and rebuilding it can oscillate forever when Blizzard settles a split
                        -- or merge differently than the precomputed plan expected.
                        local excess = s.count - d.count
                        if not returnToStorage(s,excess,"return only excess from public stack") then
                            return nil,"Not enough stack capacity in Storage tabs to return excess from configured Public slots."
                        end
                    end
                    -- Correct item but short is deliberately left in place. Phase 2 tops it up.
                end
            end
        end
    end

    -- Phase 2: fill each configured Public slot from the pooled Storage tabs.
    for tab=1,self.MAX_TABS do
        local cfg=self.db.tabs[tab]
        local td=state.tabs[tab]
        if cfg.mode=="public" and td then
            local targetSlot=1
            local managedSlots=0
            for _,configuredRule in ipairs(cfg.rules) do
                managedSlots=managedSlots+configuredRule.slots
            end
            for _,rule in ipairs(cfg.rules) do
                local maxStack=select(8,GetItemInfo(rule.itemID)) or rule.stackSize
                local wanted=math.max(1,math.min(rule.stackSize,maxStack))
                for _=1,rule.slots do
                    local dst=td.slots[targetSlot]
                    if not (dst.itemID==rule.itemID and dst.count==wanted) then
                        -- If the target already has the correct item, request only
                        -- the missing quantity.  Asking for `wanted` here overfills
                        -- a short stack, which then forces the next replan to split
                        -- the same excess back out again.
                        local need=wanted-(dst.count or 0)
                        while need>0 do
                            local sources=FindSources(state,rule.itemID,need,tab,managedSlots)
                            local src=sources[1]
                            if not src then
                                return nil,("Storage is short %d of %s for Public tab %d."):format(need,rule.link or rule.name or ("item:"..rule.itemID),tab)
                            end
                            local take=math.min(need,src.count)
                            if not dst.itemID then
                                if take==src.count then
                                    AddMove(plan,"move",src,dst,nil,"stock public slot")
                                    VirtualWholeMove(src,dst)
                                else
                                    AddMove(plan,"split",src,dst,take,"split storage stack into public slot")
                                    VirtualSplit(src,dst,take)
                                end
                            else
                                -- dst already contains the correct item but is short; merge into it.
                                if take==src.count then
                                    AddMove(plan,"move",src,dst,nil,"top up public stack")
                                    dst.count=dst.count+src.count; src.itemID=nil; src.link=nil; src.count=0
                                else
                                    AddMove(plan,"split",src,dst,take,"top up public stack")
                                    dst.count=dst.count+take; src.count=src.count-take
                                end
                            end
                            need=wanted-dst.count
                        end
                    end
                    targetSlot=targetSlot+1
                end
            end
        end
    end

    -- Phase 3: all configured-item stacks left outside the managed layout are
    -- excess. Return them to Storage; unrelated tail items remain untouched.
    for tab=1,self.MAX_TABS do
        local cfg=self.db.tabs[tab]
        local td=state.tabs[tab]
        if cfg.mode=="public" and td then
            local configured={}
            local managedSlots=0
            for _,rule in ipairs(cfg.rules) do
                configured[rule.itemID]=true
                managedSlots=managedSlots+rule.slots
            end
            for slot=managedSlots+1,self.SLOTS_PER_TAB do
                local src=td.slots[slot]
                if src.itemID and configured[src.itemID] then
                    if not returnToStorage(src,src.count,"return excess configured item from public tab") then
                        return nil,"Not enough stack capacity in Storage tabs to return excess Public stock."
                    end
                end
            end
        end
    end

    return plan
end

function GBM:BeginSort()
    if self:InCombat() then self:Print("Cannot sort in combat."); return end
    local ok,err=self:IsGuildBankAvailable()
    if not ok then self:Print(err); return end
    if self.executing then self:Print("A sort is already running."); return end
    self.sortOriginalTab=GetCurrentGuildBankTab and GetCurrentGuildBankTab() or nil
    self.sortStartedAt=GetTime()
    self.lastSortDuration=nil
    self.lastSortMoves=nil
    self:QueryConfiguredTabs()
    C_Timer.After(0.4,function()
        GBM:ScanBank()
        local plan,why=GBM:BuildPlan()
        if not plan then
            GBM.sortOriginalTab=nil
            GBM.sortStartedAt=nil
            GBM:Print("Sort cancelled: "..why)
            if GBM.RefreshUI then GBM:RefreshUI() end
            return
        end
        if #plan==0 then
            GBM.lastSortDuration=math.max(0,GetTime()-(GBM.sortStartedAt or GetTime()))
            GBM.lastSortMoves=0
            GBM.sortOriginalTab=nil
            GBM.sortStartedAt=nil
            GBM:Print("Bank already matches the configured layout.")
            if GBM.RefreshUI then GBM:RefreshUI() end
            return
        end
        GBM.lastPlan=plan
        GBM:Print(("Planned %d bank move(s)."):format(#plan))
        GBM:StartExecutor(plan,function() return GBM:BuildPlan() end,"Sorting Bank")
    end)
end
