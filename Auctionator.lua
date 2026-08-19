local ADDON, GBM = ...

local CALLER_ID="GuildBankManager"

local function GetItemTier(itemID,link)
    if not C_TradeSkillUI then return nil end
    local tier
    if C_TradeSkillUI.GetItemReagentQualityByItemInfo then
        tier=C_TradeSkillUI.GetItemReagentQualityByItemInfo(link or itemID)
            or C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemID)
    end
    if not tier and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
        tier=C_TradeSkillUI.GetItemCraftedQualityByItemInfo(link or itemID)
            or C_TradeSkillUI.GetItemCraftedQualityByItemInfo(itemID)
    end
    tier=tonumber(tier)
    if tier and tier>=1 and tier<=5 then return tier end
end

local function AuctionatorAPI()
    return Auctionator and Auctionator.API and Auctionator.API.v1
end

function GBM:BuildRestockList()
    local wanted={}
    local currentPublic={}
    local currentStorage={}

    for tab=1,self.MAX_TABS do
        local cfg=self.db.tabs[tab]
        if cfg.mode=="public" then
            for _,rule in ipairs(cfg.rules) do
                local publicTarget=(tonumber(rule.stackSize) or 1)*(tonumber(rule.slots) or 0)
                local multiplier=tonumber(rule.reserveMultiplier)
                    or tonumber(self.db.options.backupMultiplier) or 2
                local entry=wanted[rule.itemID] or {
                    itemID=rule.itemID,name=rule.name,link=rule.link,
                    publicTarget=0,storageTarget=0,
                }
                entry.publicTarget=entry.publicTarget+publicTarget
                entry.storageTarget=entry.storageTarget+math.ceil(publicTarget*multiplier)
                wanted[rule.itemID]=entry
            end
        end
    end

    for _,td in pairs(self.bank.tabs or {}) do
        if td.mode=="public" or td.mode=="storage" then
            for _,slot in pairs(td.slots or {}) do
                if slot.itemID then
                    local bucket=td.mode=="public" and currentPublic or currentStorage
                    bucket[slot.itemID]=(bucket[slot.itemID] or 0)+(slot.count or 0)
                end
            end
        end
    end

    local result={}
    for itemID,entry in pairs(wanted) do
        entry.currentPublic=currentPublic[itemID] or 0
        entry.currentStorage=currentStorage[itemID] or 0
        entry.current=entry.currentPublic+entry.currentStorage
        entry.totalTarget=entry.publicTarget+entry.storageTarget
        entry.missing=math.max(0,entry.totalTarget-entry.current)
        if entry.missing>0 then
            local name,link=GetItemInfo(itemID)
            entry.name=name or entry.name or ("Item "..itemID)
            entry.link=link or entry.link
            entry.tier=GetItemTier(itemID,entry.link)
            table.insert(result,entry)
        end
    end
    table.sort(result,function(a,b) return tostring(a.name):lower()<tostring(b.name):lower() end)
    return result
end

function GBM:CreateAuctionatorList(entries)
    local api=AuctionatorAPI()
    local manager=Auctionator and Auctionator.Shopping and Auctionator.Shopping.ListManager
    if not api or not api.ConvertToSearchString or not manager then
        return false,"Auctionator is not enabled or its shopping-list API is unavailable."
    end

    local baseName=self.db.options.auctionatorListName or "Guild Bank Restock"
    local temporaryLabel=AUCTIONATOR_L_TEMPORARY_LOWER_CASE or "temporary"
    local listName=("%s (%s)"):format(baseName,temporaryLabel)
    local ok,err=pcall(function()
        local searchStrings={}
        for _,entry in ipairs(entries) do
            local term={searchString=entry.name,isExact=true,quantity=entry.missing}
            if entry.tier then term.tier=entry.tier end
            local searchString=api.ConvertToSearchString(CALLER_ID,term)
            table.insert(searchStrings,searchString)
        end

        -- Remove both the old persistent GBM list and the previous temporary copy.
        if manager:GetIndexForName(baseName) then manager:Delete(baseName) end
        if manager:GetIndexForName(listName) then manager:Delete(listName) end
        manager:Create(listName,true)
        local list=manager:GetByName(listName)
        list:AppendItems(searchStrings)

        if Auctionator.EventBus and Auctionator.Shopping.Events then
            Auctionator.EventBus
                :RegisterSource(GBM.CreateAuctionatorList,"GuildBankManager temporary shopping list")
                :Fire(GBM.CreateAuctionatorList,Auctionator.Shopping.Events.ListImportFinished,listName)
                :UnregisterSource(GBM.CreateAuctionatorList)
        end
    end)
    if not ok then return false,"Auctionator rejected the list: "..tostring(err) end
    return true,listName
end

function GBM:BeginAuctionatorRestock(onReady)
    if self.executing then self:Print("Wait for the current sort to finish."); return end
    local ok,err=self:IsGuildBankAvailable()
    if not ok then self:Print(err); return end
    self:QueryConfiguredTabs()
    C_Timer.After(0.4,function()
        if not GBM.bankOpen then return end
        GBM:ScanBank()
        local entries=GBM:BuildRestockList()
        local total=0
        for _,entry in ipairs(entries) do total=total+entry.missing end
        if onReady then onReady(entries,total); return end
        local made,nameOrError=GBM:CreateAuctionatorList(entries)
        if not made then GBM:Print(nameOrError); return end
        GBM:Print(("Auctionator list '%s' updated: %d item(s), %d unit(s) to buy."):format(nameOrError,#entries,total))
    end)
end
