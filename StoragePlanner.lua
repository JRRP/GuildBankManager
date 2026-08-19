local ADDON, GBM = ...

local function Action(plan,kind,src,dst,amount,why)
    table.insert(plan,{kind=kind,srcTab=src.tab,srcSlot=src.slot,dstTab=dst.tab,dstSlot=dst.slot,amount=amount,why=why})
end

local function MoveWhole(src,dst)
    dst.itemID=src.itemID; dst.link=src.link; dst.count=src.count
    src.itemID=nil; src.link=nil; src.count=0
end

local function ItemKey(slot)
    local name,_,_,_,_,_,_,_,_,_,_,classID,subclassID=GetItemInfo(slot.itemID)
    if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(slot.itemID) end
    return classID or 999,subclassID or 999,(name or ("item "..slot.itemID)):lower(),slot.itemID
end

local function DesiredBefore(a,b)
    local ac,as,an,ai=ItemKey(a)
    local bc,bs,bn,bi=ItemKey(b)
    if ac~=bc then return ac<bc end
    if as~=bs then return as<bs end
    if an~=bn then return an<bn end
    if ai~=bi then return ai<bi end
    return a.count>b.count
end

local function CloneTab(td,tab)
    local slots={}
    for slot=1,GBM.SLOTS_PER_TAB do
        local src=td.slots[slot]
        if src.locked then return nil,"A Storage slot is locked; wait a moment and try again." end
        slots[slot]={tab=tab,slot=slot,itemID=src.itemID,link=src.link,count=src.count or 0}
    end
    return slots
end

local function ConsolidateTab(plan,slots)
    local changed=true
    while changed do
        changed=false
        local byItem={}
        for _,slot in ipairs(slots) do
            if slot.itemID then
                byItem[slot.itemID]=byItem[slot.itemID] or {}
                table.insert(byItem[slot.itemID],slot)
            end
        end
        for itemID,stacks in pairs(byItem) do
            local maxStack=select(8,GetItemInfo(itemID)) or 1
            local partial={}
            for _,slot in ipairs(stacks) do if slot.count<maxStack then table.insert(partial,slot) end end
            if #partial>1 then
                table.sort(partial,function(a,b) return a.count>b.count end)
                local dst=partial[1]
                local src=partial[#partial]
                local take=math.min(maxStack-dst.count,src.count)
                if take>0 then
                    local kind=take==src.count and "move" or "split"
                    Action(plan,kind,src,dst,kind=="split" and take or nil,"consolidate storage stack")
                    dst.count=dst.count+take
                    src.count=src.count-take
                    if src.count<=0 then src.itemID=nil; src.link=nil; src.count=0 end
                    changed=true
                    break
                end
            end
        end
    end
end

local function SortTab(plan,slots)
    local desired={}
    local empty
    for _,slot in ipairs(slots) do
        if slot.itemID then
            table.insert(desired,{itemID=slot.itemID,count=slot.count})
        elseif not empty then
            empty=slot
        end
    end
    table.sort(desired,DesiredBefore)

    for i,wanted in ipairs(desired) do
        local target=slots[i]
        if target.itemID~=wanted.itemID or target.count~=wanted.count then
            if target.itemID then
                if not empty then return false,"Storage tab "..target.tab.." needs one empty slot to reorder different items." end
                Action(plan,"move",target,empty,nil,"open buffer slot for storage sorting")
                MoveWhole(target,empty)
                empty=target
            end
            local source
            for j=i+1,#slots do
                local candidate=slots[j]
                if candidate.itemID==wanted.itemID and candidate.count==wanted.count then source=candidate; break end
            end
            if not source then return false,"Storage changed while building its sort plan; scan again." end
            Action(plan,"move",source,target,nil,"sort storage by item type and name")
            MoveWhole(source,target)
            empty=source
        end
    end
    return true
end

function GBM:BuildStoragePlan()
    local plan={}
    local found=false
    for tab=1,self.MAX_TABS do
        local td=self.bank.tabs[tab]
        if td and td.mode=="storage" then
            found=true
            if not td.canDeposit or not td.canWithdraw then
                return nil,("Storage tab %d requires deposit and withdrawal permission."):format(tab)
            end
            local slots,err=CloneTab(td,tab)
            if not slots then return nil,err end
            ConsolidateTab(plan,slots)
            local ok,why=SortTab(plan,slots)
            if not ok then return nil,why end
        end
    end
    if not found then return nil,"Mark at least one guild-bank tab as Storage." end
    return plan
end

function GBM:BeginStorageSort()
    if self:InCombat() then self:Print("Cannot sort in combat."); return end
    local ok,err=self:IsGuildBankAvailable()
    if not ok then self:Print(err); return end
    if self.executing then self:Print("A sort is already running."); return end
    self.sortOriginalTab=GetCurrentGuildBankTab and GetCurrentGuildBankTab() or nil
    self.sortStartedAt=GetTime(); self.lastSortDuration=nil; self.lastSortMoves=nil
    self:QueryConfiguredTabs()
    C_Timer.After(0.4,function()
        if not GBM.bankOpen then return end
        GBM:ScanBank()
        local plan,why=GBM:BuildStoragePlan()
        if not plan then GBM.sortOriginalTab=nil; GBM:Print("Storage sort cancelled: "..why); return end
        if #plan==0 then GBM.sortOriginalTab=nil; GBM:Print("Storage is already consolidated and sorted."); return end
        GBM:Print(("Planned %d Storage move(s)."):format(#plan))
        GBM:StartExecutor(plan,function() return GBM:BuildStoragePlan() end,"Sorting Storage")
    end)
end
