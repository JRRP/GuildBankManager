local ADDON, GBM = ...

local function NewTab(i)
    return {
        name = "Tab " .. i,
        mode = "ignore", -- public | storage | ignore
        rules = {},
    }
end

local function CopyTabs(tabs)
    local out={}
    for i=1,GBM.MAX_TABS do
        local src=tabs[i] or NewTab(i)
        local dst={name=src.name or ("Tab "..i),mode=src.mode or "ignore",rules={}}
        for _,rule in ipairs(src.rules or {}) do
            table.insert(dst.rules,{
                itemID=rule.itemID,link=rule.link,name=rule.name,icon=rule.icon,
                stackSize=rule.stackSize,slots=rule.slots,reserveMultiplier=rule.reserveMultiplier,
            })
        end
        out[i]=dst
    end
    return out
end

function GBM:InitDB()
    GuildBankManagerDB = GuildBankManagerDB or {}
    local db = GuildBankManagerDB
    db.version = 8
    db.options = db.options or {
        moveDelay = 0.25,
        returnExcess = true,
        backupMultiplier = 2,
        auctionatorListName = "Guild Bank Restock",
    }
    if db.options.moveDelay == nil then db.options.moveDelay = 0.25 end
    if db.options.backupMultiplier == nil then db.options.backupMultiplier = 2 end
    if not db.options.auctionatorListName then db.options.auctionatorListName = "Guild Bank Restock" end
    if db.options.autoOpenWithGuildBank == nil then db.options.autoOpenWithGuildBank = false end
    -- Migrate the previous conservative defaults. Preserve any custom value.
    if db.options.moveDelay == 0.35 or db.options.moveDelay == 0.45 or db.options.moveDelay == 0.55 then
        db.options.moveDelay = 0.25
    end
    db.tabs = db.tabs or {}
    db.profiles = db.profiles or {}
    for i = 1, self.MAX_TABS do
        db.tabs[i] = db.tabs[i] or NewTab(i)
        db.tabs[i].rules = db.tabs[i].rules or {}
        db.tabs[i].mode = db.tabs[i].mode or "ignore"
        db.tabs[i].name = db.tabs[i].name or ("Tab " .. i)
    end
    self.db = db
end

function GBM:SaveProfile(name)
    name=strtrim(name or "")
    if name=="" then return false,"Enter a profile name." end
    self.db.profiles[name]={tabs=CopyTabs(self.db.tabs),backupMultiplier=tonumber(self.db.options.backupMultiplier) or 2}
    return true
end

function GBM:LoadProfile(name)
    local profile=self.db.profiles[name]
    if not profile or not profile.tabs then return false,"Profile not found." end
    self.db.tabs=CopyTabs(profile.tabs)
    self.db.options.backupMultiplier=tonumber(profile.backupMultiplier) or 2
    return true
end

function GBM:DeleteProfile(name)
    if not self.db.profiles[name] then return false,"Profile not found." end
    self.db.profiles[name]=nil
    return true
end

function GBM:GetProfileNames()
    local names={}
    for name in pairs(self.db.profiles) do table.insert(names,name) end
    table.sort(names)
    return names
end

function GBM:ExportTabs(tabs,defaultMultiplier)
    defaultMultiplier=tonumber(defaultMultiplier) or tonumber(self.db.options.backupMultiplier) or 2
    local lines={"GBM1:"..tostring(defaultMultiplier)}
    tabs=tabs or self.db.tabs
    for tab=1,self.MAX_TABS do
        local cfg=tabs[tab] or NewTab(tab)
        table.insert(lines,("T:%d:%s"):format(tab,cfg.mode or "ignore"))
        for _,rule in ipairs(cfg.rules or {}) do
            table.insert(lines,("R:%d:%d:%d:%d:%s"):format(
                tab,tonumber(rule.itemID) or 0,
                math.max(1,math.floor(tonumber(rule.stackSize) or 1)),
                math.max(0,math.floor(tonumber(rule.slots) or 0)),
                tostring(tonumber(rule.reserveMultiplier) or defaultMultiplier)
            ))
        end
    end
    return table.concat(lines,"\n")
end

function GBM:ImportProfile(name,text)
    name=strtrim(name or "")
    if name=="" then return false,"Enter a profile name." end
    text=tostring(text or ""):gsub("\r","")
    local tabs={}
    local importedDefault=tonumber(self.db.options.backupMultiplier) or 2
    for i=1,self.MAX_TABS do tabs[i]=NewTab(i) end
    local first=true
    local ruleCount=0
    for line in text:gmatch("[^\n]+") do
        if first then
            first=false
            local header=strtrim(line)
            local headerMultiplier=header:match("^GBM1:([%d%.]+)$")
            if header~="GBM1" and not headerMultiplier then return false,"Invalid export header." end
            importedDefault=tonumber(headerMultiplier) or importedDefault
            if importedDefault<0 or importedDefault>100 then return false,"Invalid default backup multiplier." end
        else
            local tab,mode=line:match("^T:(%d+):([a-z]+)$")
            if tab then
                tab=tonumber(tab)
                if tab<1 or tab>self.MAX_TABS or (mode~="public" and mode~="storage" and mode~="ignore") then
                    return false,"Invalid tab entry."
                end
                tabs[tab].mode=mode
            else
                local ruleTab,itemID,stackSize,slots,multiplier=line:match("^R:(%d+):(%d+):(%d+):(%d+):([%d%.]+)$")
                if not ruleTab then
                    ruleTab,itemID,stackSize,slots=line:match("^R:(%d+):(%d+):(%d+):(%d+)$")
                end
                ruleTab,itemID,stackSize,slots=tonumber(ruleTab),tonumber(itemID),tonumber(stackSize),tonumber(slots)
                multiplier=tonumber(multiplier) or importedDefault
                if not ruleTab or ruleTab<1 or ruleTab>self.MAX_TABS or not itemID or itemID<1
                    or not stackSize or stackSize<1 or not slots or slots<0 or multiplier<0 or multiplier>100 then
                    return false,"Invalid rule entry."
                end
                local itemName,itemLink,_,_,_,_,_,maxStack,_,icon=GetItemInfo(itemID)
                table.insert(tabs[ruleTab].rules,{
                    itemID=itemID,link=itemLink,name=itemName or ("Item "..itemID),icon=icon,
                    stackSize=math.min(stackSize,maxStack or stackSize),slots=slots,reserveMultiplier=multiplier,
                })
                ruleCount=ruleCount+1
                if ruleCount>500 then return false,"Import contains too many rules." end
            end
        end
    end
    if first then return false,"Import is empty." end
    self.db.profiles[name]={tabs=CopyTabs(tabs),backupMultiplier=importedDefault}
    self.db.tabs=CopyTabs(tabs)
    self.db.options.backupMultiplier=importedDefault
    return true
end

function GBM:SetTabMode(tab, mode)
    if mode ~= "public" and mode ~= "storage" and mode ~= "ignore" then return end
    self.db.tabs[tab].mode = mode
    if mode ~= "public" then
        self.db.tabs[tab].rules = {}
    end
end

function GBM:AddRule(tab, itemID, itemLink)
    local cfg = self.db.tabs[tab]
    if not cfg or cfg.mode ~= "public" then return end
    for _, rule in ipairs(cfg.rules) do
        if rule.itemID == itemID then return rule end
    end
    local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    local maxStack = select(8, GetItemInfo(itemID)) or 1
    local rule = {
        itemID = itemID,
        link = itemLink or link,
        name = name or ("Item " .. itemID),
        icon = icon,
        stackSize = math.min(maxStack, 1),
        slots = 1,
        reserveMultiplier = nil,
    }
    table.insert(cfg.rules, rule)
    return rule
end

function GBM:RemoveRule(tab, index)
    local cfg = self.db.tabs[tab]
    if cfg and cfg.rules[index] then table.remove(cfg.rules, index) end
end
