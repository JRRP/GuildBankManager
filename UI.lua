local ADDON, GBM = ...

local UI, content, tabTitle, tabDesc, status, profilePanel, restockPanel
local selectedTab = 1

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return ("%d seconds"):format(seconds)
end

local function RefreshStatus()
    if not status then return end
    if GBM.executing then
        local state = GBM.executorPending and "waiting for bank" or "preparing next move"
        local action=(GBM.executorPending and GBM.executorPending.action) or (GBM.queue and GBM.queue[1])
        if action and action.why then state=action.why.." — "..state end
        local elapsed = GetTime() - (GBM.executorStartedAt or GetTime())
        status:SetText(("%s: %d / %d moves complete — %s — %s elapsed"):format(
            GBM.executorLabel or "Sorting",
            GBM.executorProcessed or 0,
            GBM.executorTotalMoves or 0,
            state,
            FormatDuration(elapsed)
        ))
    elseif GBM.lastSortDuration then
        status:SetText(("%s complete: %d moves — %s elapsed"):format(
            GBM.lastSortLabel or "Sorting",
            GBM.lastSortMoves or 0,
            FormatDuration(GBM.lastSortDuration)
        ))
    else
        status:SetText(GBM.bankOpen and "Guild bank open." or "Open the guild bank before scanning or sorting.")
    end
end
local tabButtons = {}
local modeButtons = {}
local MODE_LABELS={public="SORTED",storage="STORAGE",ignore="IGNORED"}
local MODE_TEXT_COLORS={
    public={0.39,0.83,0.44},
    storage={0.95,0.78,0.15},
    ignore={0.84,0.48,0.15},
}

StaticPopupDialogs["GBM_CONFIRM_TAB_MODE"]={
    text="Change this tab mode?",
    button1=YES,
    button2=CANCEL,
    OnShow=function(self,data)
        self.Text:SetFormattedText(
            "Change %s from Sorted to %s?\n\nThis will permanently delete %d configured item rule(s).",
            data.name,MODE_LABELS[data.mode] or string.upper(data.mode),data.count
        )
    end,
    OnAccept=function(self,data)
        GBM:SetTabMode(data.tab,data.mode)
        GBM:RefreshUI()
    end,
    timeout=0,
    whileDead=true,
    hideOnEscape=true,
    preferredIndex=3,
}

local COLORS = {
    bg={0.035,0.04,0.045,0.98}, panel={0.07,0.075,0.085,0.96},
    button={0.10,0.11,0.12,1}, hover={0.14,0.16,0.18,1},
    border={0.20,0.22,0.24,1}, accent={0.15,0.55,0.85,1},
}

local function SetBackdrop(frame,bg,border)
    frame:SetBackdrop({
        bgFile="Interface\\Buttons\\WHITE8x8",
        edgeFile="Interface\\Buttons\\WHITE8x8",
        edgeSize=1,
    })
    frame:SetBackdropColor(unpack(bg))
    frame:SetBackdropBorderColor(unpack(border))
end

local function DarkButton(parent,text)
    local b=CreateFrame("Button",nil,parent,"BackdropTemplate")
    b.gbmBaseColor=COLORS.button
    SetBackdrop(b,COLORS.button,COLORS.border)
    b:SetNormalFontObject("GameFontHighlightSmall")
    b:SetText(text or "")
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    b:GetHighlightTexture():SetVertexColor(COLORS.accent[1],COLORS.accent[2],COLORS.accent[3],0.22)
    b:SetPushedTextOffset(1,-1)
    b:HookScript("OnMouseDown",function(self) self:SetBackdropColor(0.06,0.07,0.08,1) end)
    b:HookScript("OnMouseUp",function(self) self:SetBackdropColor(unpack(self.gbmBaseColor or COLORS.button)) end)
    return b
end

local function WipeChildren(frame)
    local children = {frame:GetChildren()}
    for _, c in ipairs(children) do
        c:Hide()
        c:SetParent(nil)
    end
    local regions = {frame:GetRegions()}
    for _, r in ipairs(regions) do r:Hide() end
end

local function CursorItem()
    local typ, id, link = GetCursorInfo()
    if typ == "item" then return id, link end
end

local function ActualTabName(tab)
    local name = GetGuildBankTabInfo(tab)
    if name and name ~= "" then
        if GBM.db and GBM.db.tabs and GBM.db.tabs[tab] then
            GBM.db.tabs[tab].name = name
        end
        return name
    end
    local cfg = GBM.db and GBM.db.tabs and GBM.db.tabs[tab]
    return (cfg and cfg.name) or ("Tab " .. tab)
end

local function ShortName(name, maxChars)
    name = tostring(name or "")
    if #name <= maxChars then return name end
    return name:sub(1, math.max(1, maxChars - 1)) .. "…"
end

local function FitButtonText(button,text,maxWidth)
    button:SetText(text)
    local fs=button:GetFontString()
    if not fs then return end
    local font,_,flags=fs:GetFont()
    local size=12
    fs:SetFont(font,size,flags)
    while fs:GetStringWidth()>maxWidth and size>8 do
        size=size-1
        fs:SetFont(font,size,flags)
    end
end

local function CreatePanel(parent, x, y, w, h)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetPoint("TOPLEFT", x, y)
    p:SetSize(w, h)
    SetBackdrop(p,COLORS.panel,COLORS.border)
    return p
end

local function MakeNumberBox(parent, x, value, onSave, allowDecimal, yOffset)
    local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    e:SetSize(60,22); e:SetPoint("LEFT",x,yOffset or 6); e:SetAutoFocus(false); e:SetNumeric(not allowDecimal); e:SetText(tostring(value))
    SetBackdrop(e,{0.025,0.03,0.035,1},COLORS.border)
    e:SetFontObject("ChatFontNormal"); e:SetTextInsets(6,6,0,0); e:SetTextColor(0.9,0.9,0.9)
    local saving = false
    local function Save()
        if saving then return end
        saving = true
        local n = tonumber(e:GetText())
        if n then onSave(n) end
        e:ClearFocus()
        saving = false
        GBM:RefreshUI()
    end
    e:SetScript("OnEnterPressed",Save)
    e:SetScript("OnEditFocusLost",function() if not saving then Save() end end)
    return e
end

local function RuleRow(parent, rule, index, y)
    local r = CreateFrame("Frame", nil, parent,"BackdropTemplate")
    r:SetSize(465,76); r:SetPoint("TOPLEFT",0,y)
    SetBackdrop(r,{0.055,0.06,0.07,0.85},{0.13,0.14,0.16,1})

    local icon = r:CreateTexture(nil,"ARTWORK")
    icon:SetSize(40,40); icon:SetPoint("LEFT",8,0); icon:SetTexture(rule.icon or C_Item.GetItemIconByID(rule.itemID))

    local n = r:CreateFontString(nil,"OVERLAY","GameFontNormal")
    n:SetPoint("TOPLEFT",54,-9); n:SetWidth(390); n:SetJustifyH("LEFT"); n:SetText(rule.link or rule.name or ("Item "..rule.itemID))

    MakeNumberBox(r,54,rule.stackSize,function(v) rule.stackSize=math.max(1,math.floor(v)) end,false,-3)
    MakeNumberBox(r,130,rule.slots,function(v) rule.slots=math.max(0,math.floor(v)) end,false,-3)
    MakeNumberBox(r,206,rule.reserveMultiplier or GBM.db.options.backupMultiplier or 2,function(v) rule.reserveMultiplier=math.max(0,v) end,true,-3)

    local a = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); a:SetPoint("LEFT",54,-21); a:SetText("stack")
    local b = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); b:SetPoint("LEFT",130,-21); b:SetText("slots")
    local c = r:CreateFontString(nil,"OVERLAY","GameFontHighlight"); c:SetPoint("LEFT",206,-21); c:SetText("backup X")

    local rem = DarkButton(r,"Remove")
    rem:SetSize(90,28); rem:SetPoint("RIGHT",-14,0); rem:SetText("Remove")
    rem.gbmBaseColor={0.34,0.055,0.055,1}
    rem:SetBackdropColor(unpack(rem.gbmBaseColor))
    rem:SetBackdropBorderColor(0.72,0.12,0.12,1)
    rem:GetHighlightTexture():SetVertexColor(1,0.15,0.15,0.28)
    rem:SetScript("OnClick",function() GBM:RemoveRule(selectedTab,index); GBM:RefreshUI() end)
end

local function DropBox(parent)
    local b = CreateFrame("Button",nil,parent,"BackdropTemplate")
    b:SetSize(465,48)
    SetBackdrop(b,{0.035,0.04,0.05,1},COLORS.accent)
    local fs = b:CreateFontString(nil,"OVERLAY","GameFontNormal")
    fs:SetPoint("CENTER"); fs:SetText("Drag an item here to add it to " .. ActualTabName(selectedTab))
    fs:SetTextColor(unpack(COLORS.accent))
    local function Drop()
        local id,link=CursorItem()
        if not id then GBM:Print("Drag an item from your bags or guild bank onto the box."); return end
        ClearCursor(); GBM:AddRule(selectedTab,id,link); GBM:RefreshUI()
    end
    b:SetScript("OnReceiveDrag",Drop); b:SetScript("OnClick",Drop)
    return b
end

local function ToggleProfileManager()
    if not profilePanel then
        profilePanel=CreateFrame("Frame",nil,UI,"BackdropTemplate")
        profilePanel:SetSize(680,460); profilePanel:SetPoint("CENTER"); profilePanel:SetFrameStrata("DIALOG")
        SetBackdrop(profilePanel,{0.025,0.03,0.035,0.99},COLORS.accent)
        profilePanel:Hide()

        local heading=profilePanel:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        heading:SetPoint("TOPLEFT",14,-14); heading:SetText("Profile Manager"); heading:SetTextColor(0.25,0.65,0.95)

        local close=DarkButton(profilePanel,"×")
        close:SetSize(26,22); close:SetPoint("TOPRIGHT",-8,-8); close:SetScript("OnClick",function() profilePanel:Hide() end)

        local name=CreateFrame("EditBox",nil,profilePanel,"BackdropTemplate")
        name:SetSize(220,26); name:SetPoint("TOPLEFT",14,-48); name:SetAutoFocus(false); name:SetMaxLetters(40)
        name:SetFontObject("ChatFontNormal"); name:SetTextInsets(7,7,0,0)
        SetBackdrop(name,{0.02,0.025,0.03,1},COLORS.border)
        profilePanel.nameBox=name

        local defaultLabel=profilePanel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        defaultLabel:SetPoint("TOPLEFT",300,-18); defaultLabel:SetText("Default backup ×")
        local defaultBox=CreateFrame("EditBox",nil,profilePanel,"BackdropTemplate")
        defaultBox:SetSize(60,24); defaultBox:SetPoint("LEFT",defaultLabel,"RIGHT",8,0); defaultBox:SetAutoFocus(false)
        defaultBox:SetFontObject("ChatFontNormal"); defaultBox:SetTextInsets(6,6,0,0)
        SetBackdrop(defaultBox,{0.02,0.025,0.03,1},COLORS.border)
        defaultBox:SetScript("OnEnterPressed",function(self)
            local value=tonumber(self:GetText())
            if value and value>=0 and value<=100 then GBM.db.options.backupMultiplier=value end
            self:ClearFocus(); GBM:RefreshUI()
        end)
        defaultBox:SetScript("OnEditFocusLost",function(self)
            local value=tonumber(self:GetText())
            if value and value>=0 and value<=100 then GBM.db.options.backupMultiplier=value end
        end)
        profilePanel.defaultBox=defaultBox

        local listPanel=CreateFrame("Frame",nil,profilePanel,"BackdropTemplate")
        listPanel:SetPoint("TOPLEFT",14,-84); listPanel:SetSize(220,310)
        SetBackdrop(listPanel,COLORS.panel,COLORS.border)
        profilePanel.listButtons={}
        for i=1,10 do
            local b=DarkButton(listPanel,"")
            b:SetSize(202,25); b:SetPoint("TOPLEFT",9,-8-(i-1)*29)
            profilePanel.listButtons[i]=b
        end

        local textPanel=CreateFrame("Frame",nil,profilePanel,"BackdropTemplate")
        textPanel:SetPoint("TOPLEFT",246,-48); textPanel:SetSize(420,346)
        SetBackdrop(textPanel,{0.02,0.025,0.03,1},COLORS.border)
        local scroll=CreateFrame("ScrollFrame",nil,textPanel,"UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",8,-8); scroll:SetPoint("BOTTOMRIGHT",-28,8)
        local edit=CreateFrame("EditBox",nil,scroll)
        edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetFontObject("ChatFontNormal")
        edit:SetSize(370,330); edit:SetTextInsets(4,4,4,4); edit:SetJustifyH("LEFT"); edit:SetJustifyV("TOP")
        edit:SetScript("OnTextChanged",function(self)
            local _,lines=self:GetText():gsub("\n","")
            self:SetHeight(math.max(330,(lines+2)*15))
        end)
        edit:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
        scroll:SetScrollChild(edit); profilePanel.textBox=edit

        local function RefreshProfiles()
            local names=GBM:GetProfileNames()
            for i,b in ipairs(profilePanel.listButtons) do
                local profileName=names[i]
                b:SetShown(profileName~=nil)
                if profileName then
                    b:SetText(ShortName(profileName,28))
                    b:SetScript("OnClick",function()
                        name:SetText(profileName)
                        local profile=GBM.db.profiles[profileName]
                        edit:SetText(GBM:ExportTabs(profile.tabs,profile.backupMultiplier))
                    end)
                end
            end
        end
        profilePanel.RefreshProfiles=RefreshProfiles

        local save=DarkButton(profilePanel,"SAVE CURRENT")
        save:SetSize(105,28); save:SetPoint("BOTTOMLEFT",14,18)
        save:SetScript("OnClick",function()
            local ok,err=GBM:SaveProfile(name:GetText())
            GBM:Print(ok and "Profile saved." or err); if ok then RefreshProfiles() end
        end)
        local load=DarkButton(profilePanel,"LOAD")
        load:SetSize(72,28); load:SetPoint("LEFT",save,"RIGHT",6,0)
        load:SetScript("OnClick",function()
            local ok,err=GBM:LoadProfile(name:GetText())
            GBM:Print(ok and "Profile loaded." or err); if ok then GBM:RefreshUI() end
        end)
        local del=DarkButton(profilePanel,"DELETE")
        del:SetSize(72,28); del:SetPoint("LEFT",load,"RIGHT",6,0)
        del:SetScript("OnClick",function()
            local ok,err=GBM:DeleteProfile(name:GetText())
            GBM:Print(ok and "Profile deleted." or err)
            if ok then name:SetText(""); edit:SetText(""); RefreshProfiles() end
        end)
        local export=DarkButton(profilePanel,"EXPORT CURRENT")
        export:SetSize(125,28); export:SetPoint("LEFT",del,"RIGHT",18,0)
        export:SetScript("OnClick",function() edit:SetText(GBM:ExportTabs()); edit:HighlightText(); edit:SetFocus() end)
        local import=DarkButton(profilePanel,"IMPORT & LOAD")
        import:SetSize(125,28); import:SetPoint("LEFT",export,"RIGHT",6,0)
        import:SetBackdropBorderColor(unpack(COLORS.accent))
        import:SetScript("OnClick",function()
            local ok,err=GBM:ImportProfile(name:GetText(),edit:GetText())
            GBM:Print(ok and "Profile imported and loaded." or err)
            if ok then RefreshProfiles(); GBM:RefreshUI() end
        end)
    end
    profilePanel:SetShown(not profilePanel:IsShown())
    if profilePanel:IsShown() then
        profilePanel.defaultBox:SetText(tostring(GBM.db.options.backupMultiplier or 2))
        profilePanel.RefreshProfiles()
    end
end

local function ShowRestockPreview(entries,total)
    if not restockPanel then
        restockPanel=CreateFrame("Frame",nil,UI,"BackdropTemplate")
        restockPanel:SetSize(620,440); restockPanel:SetPoint("CENTER"); restockPanel:SetFrameStrata("DIALOG")
        SetBackdrop(restockPanel,{0.025,0.03,0.035,0.99},COLORS.accent)
        local title=restockPanel:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        title:SetPoint("TOPLEFT",14,-14); title:SetText("Auctionator Restock Preview"); title:SetTextColor(0.25,0.65,0.95)
        local close=DarkButton(restockPanel,"×")
        close:SetSize(26,22); close:SetPoint("TOPRIGHT",-8,-8); close:SetScript("OnClick",function() restockPanel:Hide() end)
        local textPanel=CreateFrame("Frame",nil,restockPanel,"BackdropTemplate")
        textPanel:SetPoint("TOPLEFT",14,-48); textPanel:SetPoint("BOTTOMRIGHT",-14,58)
        SetBackdrop(textPanel,{0.02,0.025,0.03,1},COLORS.border)
        local scroll=CreateFrame("ScrollFrame",nil,textPanel,"UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",8,-8); scroll:SetPoint("BOTTOMRIGHT",-28,8)
        local edit=CreateFrame("EditBox",nil,scroll)
        edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetFontObject("ChatFontNormal")
        edit:SetSize(545,320); edit:SetTextInsets(4,4,4,4); edit:SetJustifyH("LEFT"); edit:SetJustifyV("TOP")
        edit:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
        edit:SetScript("OnTextChanged",function(self)
            local _,lines=self:GetText():gsub("\n","")
            self:SetHeight(math.max(320,(lines+2)*15))
        end)
        scroll:SetScrollChild(edit); restockPanel.textBox=edit
        local create=DarkButton(restockPanel,"CREATE / REPLACE LIST")
        create:SetSize(190,30); create:SetPoint("BOTTOMRIGHT",-14,16); create:SetBackdropBorderColor(unpack(COLORS.accent))
        create:SetScript("OnClick",function()
            local ok,nameOrError=GBM:CreateAuctionatorList(restockPanel.entries or {})
            if ok then
                GBM:Print(("Auctionator list '%s' updated with %d item(s)."):format(nameOrError,#(restockPanel.entries or {})))
                restockPanel:Hide()
            else
                GBM:Print(nameOrError)
            end
        end)
    end
    restockPanel.entries=entries
    local lines={("%d item(s), %d total unit(s) to buy"):format(#entries,total),""}
    for _,entry in ipairs(entries) do
        table.insert(lines,("%s - Sorted %d/%d, Storage %d/%d, Buy %d"):format(
            entry.name,entry.currentPublic,entry.publicTarget,entry.currentStorage,entry.storageTarget,entry.missing
        ))
    end
    if #entries==0 then table.insert(lines,"All configured items meet their Sorted and Storage reserve targets.") end
    restockPanel.textBox:SetText(table.concat(lines,"\n"))
    restockPanel:Show()
end

local function RefreshTabButtons()
    local n = math.min(GetNumGuildBankTabs() or GBM.MAX_TABS, GBM.MAX_TABS)
    for i = 1, GBM.MAX_TABS do
        local b = tabButtons[i]
        if b then
            local name = ActualTabName(i)
            FitButtonText(b,name,81)
            local cfg=GBM.db.tabs[i]
            local color=MODE_TEXT_COLORS[(cfg and cfg.mode) or "ignore"]
            if b:GetFontString() and color then b:GetFontString():SetTextColor(unpack(color)) end
            b:SetShown(i <= n or (GetNumGuildBankTabs() or 0) == 0)
            if i == selectedTab then
                b:LockHighlight()
            else
                b:UnlockHighlight()
            end
        end
    end
end

local function RefreshModeButtons(mode)
    for m,b in pairs(modeButtons) do
        local color=MODE_TEXT_COLORS[m]
        if b:GetFontString() and color then b:GetFontString():SetTextColor(unpack(color)) end
        if m == mode then b:LockHighlight() else b:UnlockHighlight() end
    end
end

function GBM:RefreshUI()
    if not UI or not UI:IsShown() then return end

    local n = GetNumGuildBankTabs() or 0
    if n > 0 and selectedTab > n then selectedTab = n end
    if selectedTab < 1 then selectedTab = 1 end

    RefreshTabButtons()

    local cfg = self.db.tabs[selectedTab]
    local realName = ActualTabName(selectedTab)
    tabTitle:SetText(realName .. "  —  " .. (MODE_LABELS[cfg.mode] or string.upper(cfg.mode)))
    local titleColor=MODE_TEXT_COLORS[cfg.mode]
    if titleColor then tabTitle:SetTextColor(unpack(titleColor)) end
    RefreshModeButtons(cfg.mode)
    WipeChildren(content)

    if cfg.mode == "public" then
        tabDesc:SetText("GBM fills the configured layout below. Matching stock elsewhere on this tab counts toward the total; excess returns to Storage while unrelated items remain untouched.")
        local drop = DropBox(content); drop:SetPoint("TOPLEFT",0,-4)
        local y = -66
        for i,rule in ipairs(cfg.rules) do RuleRow(content,rule,i,y); y=y-78 end
        content:SetHeight(math.max(430,-y+20))
    elseif cfg.mode == "storage" then
        tabDesc:SetText("Unrestricted shared stockpile. No item rules are needed; GBM searches this tab whenever a Sorted tab needs stock.")
        local fs = content:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        fs:SetPoint("TOPLEFT",8,-16); fs:SetWidth(445); fs:SetJustifyH("LEFT")
        fs:SetText("Shared Storage\n\nDump anything here. GBM only removes items when a configured Sorted tab needs them. There is no per-item storage layout.")
        content:SetHeight(430)
    else
        tabDesc:SetText("GBM never intentionally moves items into or out of this tab.")
        local fs = content:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        fs:SetPoint("TOPLEFT",8,-16); fs:SetWidth(445); fs:SetJustifyH("LEFT")
        fs:SetText("Ignored by Guild Bank Manager\n\nUse this for anything GBM should never touch.")
        content:SetHeight(430)
    end

    RefreshStatus()
end

local function BuildUI()
    if UI then return end

    UI = CreateFrame("Frame","GuildBankManagerFrame",UIParent,"BackdropTemplate")
    table.insert(UISpecialFrames,"GuildBankManagerFrame")
    UI:SetSize(790,656)
    local savedPosition=GBM.db.options.windowPosition
    if type(savedPosition)=="table" and tonumber(savedPosition.x) and tonumber(savedPosition.y) then
        UI:SetPoint("CENTER",UIParent,"CENTER",tonumber(savedPosition.x),tonumber(savedPosition.y))
    else
        UI:SetPoint("CENTER")
    end
    UI:SetMovable(true); UI:EnableMouse(true); UI:RegisterForDrag("LeftButton"); UI:SetClampedToScreen(true)
    SetBackdrop(UI,COLORS.bg,{0.12,0.14,0.16,1})
    UI:SetScript("OnDragStart",UI.StartMoving)
    UI:SetScript("OnDragStop",function(self)
        self:StopMovingOrSizing()
        local x,y=self:GetCenter()
        local parentX,parentY=UIParent:GetCenter()
        if x and y and parentX and parentY then
            GBM.db.options.windowPosition={x=x-parentX,y=y-parentY}
        end
    end)
    UI:Hide()
    UI:SetScript("OnUpdate",function(self, elapsed)
        self.statusElapsed = (self.statusElapsed or 0) + elapsed
        if self.statusElapsed >= 1 then
            self.statusElapsed = 0
            RefreshStatus()
        end
    end)
    local header=CreateFrame("Frame",nil,UI,"BackdropTemplate")
    header:SetPoint("TOPLEFT",1,-1); header:SetPoint("TOPRIGHT",-1,-1); header:SetHeight(30)
    SetBackdrop(header,{0.055,0.06,0.07,1},{0.12,0.14,0.16,1})
    local title=header:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("LEFT",10,0); title:SetText("Guild Bank Manager"); title:SetTextColor(0.25,0.65,0.95)
    local close=CreateFrame("Button",nil,header)
    close:SetSize(32,28); close:SetPoint("RIGHT",-4,0); close:SetNormalFontObject("GameFontNormalLarge"); close:SetText("X")
    close:GetFontString():SetTextColor(0.82,0.86,0.89)
    close:SetScript("OnEnter",function(self) self:GetFontString():SetTextColor(1,0.22,0.22) end)
    close:SetScript("OnLeave",function(self) self:GetFontString():SetTextColor(0.82,0.86,0.89) end)
    close:SetScript("OnMouseDown",function(self) self:SetPushedTextOffset(1,-1) end)
    close:SetScript("OnMouseUp",function(self) self:SetPushedTextOffset(0,0) end)
    close:SetScript("OnClick",function() UI:Hide() end)

    -- Actual guild-bank tab names across the top.
    for i = 1, GBM.MAX_TABS do
        local b = DarkButton(UI,"Tab "..i)
        b:SetSize(89,27)
        b:SetPoint("TOPLEFT",22+(i-1)*94,-36)
        b:SetText("Tab "..i)
        b:SetScript("OnClick",function() selectedTab=i; GBM:RefreshUI() end)
        b:SetScript("OnEnter",function(self)
            GameTooltip:SetOwner(self,"ANCHOR_TOP")
            GameTooltip:AddLine(ActualTabName(i))
            GameTooltip:AddLine("Guild bank tab "..i,1,1,1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave",GameTooltip_Hide)
        tabButtons[i] = b
    end

    local function ModeButton(text, mode, x)
        local b = DarkButton(UI,text)
        b:SetSize(112,27); b:SetPoint("TOPLEFT",x,-74); b:SetText(text)
        b:SetScript("OnClick",function()
            local cfg=GBM.db.tabs[selectedTab]
            if cfg.mode=="public" and mode~="public" and #(cfg.rules or {})>0 then
                StaticPopup_Show("GBM_CONFIRM_TAB_MODE",nil,nil,{
                    tab=selectedTab,mode=mode,count=#cfg.rules,name=ActualTabName(selectedTab),
                })
                return
            end
            GBM:SetTabMode(selectedTab,mode)
            GBM:RefreshUI()
        end)
        modeButtons[mode] = b
    end
    ModeButton("SORTED","public",15)
    ModeButton("STORAGE","storage",132)
    ModeButton("IGNORED","ignore",249)

    tabTitle = UI:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    tabTitle:SetPoint("TOPLEFT",18,-116)

    tabDesc = UI:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    tabDesc:SetPoint("TOPLEFT",18,-145); tabDesc:SetWidth(745); tabDesc:SetJustifyH("LEFT"); tabDesc:SetWordWrap(true)

    local leftPanel = CreatePanel(UI, 14, -178, 520, 430)
    local scroll = CreateFrame("ScrollFrame",nil,leftPanel,"UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",14,-14); scroll:SetPoint("BOTTOMRIGHT",-32,14)
    content = CreateFrame("Frame",nil,scroll); content:SetSize(465,390); scroll:SetScrollChild(content)

    local operationsPanel = CreatePanel(UI, 544, -178, 215, 430)
    local operationsTitle=operationsPanel:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    operationsTitle:SetPoint("TOPLEFT",14,-14); operationsTitle:SetWidth(187); operationsTitle:SetJustifyH("CENTER")
    operationsTitle:SetText("Operations"); operationsTitle:SetTextColor(0.25,0.65,0.95)
    local operationsDesc=operationsPanel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    operationsDesc:SetPoint("TOPLEFT",14,-42); operationsDesc:SetWidth(187); operationsDesc:SetJustifyH("CENTER")
    operationsDesc:SetText("Bank-wide tools and saved layouts")

    local sort=DarkButton(operationsPanel,"SCAN & SORT BANK")
    sort:SetSize(187,34); sort:SetPoint("TOPLEFT",14,-78); sort:SetBackdropBorderColor(unpack(COLORS.accent))
    sort:SetScript("OnClick",function() GBM:BeginSort() end)

    local storageSort=DarkButton(operationsPanel,"SORT STORAGE")
    storageSort:SetSize(187,30); storageSort:SetPoint("TOPLEFT",14,-122)
    storageSort:SetScript("OnClick",function() GBM:BeginStorageSort() end)

    local auction=DarkButton(operationsPanel,"BUILD AUCTION LIST")
    auction:SetSize(187,30); auction:SetPoint("TOPLEFT",14,-160)
    auction:SetScript("OnClick",function() GBM:BeginAuctionatorRestock(ShowRestockPreview) end)

    local divider=operationsPanel:CreateTexture(nil,"ARTWORK")
    divider:SetColorTexture(0.20,0.22,0.24,1); divider:SetHeight(1); divider:SetPoint("TOPLEFT",14,-208); divider:SetPoint("TOPRIGHT",-14,-208)

    local profiles=DarkButton(operationsPanel,"MANAGE PROFILES")
    profiles:SetSize(187,30); profiles:SetPoint("TOPLEFT",14,-226)
    profiles:SetScript("OnClick",ToggleProfileManager)

    local autoOpen=CreateFrame("CheckButton",nil,operationsPanel,"BackdropTemplate")
    autoOpen:SetSize(16,16); autoOpen:SetPoint("TOPLEFT",17,-273)
    SetBackdrop(autoOpen,{0.045,0.05,0.06,1},COLORS.border)
    autoOpen:SetChecked(GBM.db.options.autoOpenWithGuildBank)
    local autoOpenLabel=operationsPanel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    autoOpenLabel:SetPoint("LEFT",autoOpen,"RIGHT",7,0); autoOpenLabel:SetText("Auto-open with guild bank")
    autoOpen:SetHitRectInsets(0,-165,0,0)
    local function RefreshAutoOpenCheck(self)
        if self:GetChecked() then
            self:SetBackdropColor(COLORS.accent[1],COLORS.accent[2],COLORS.accent[3],1)
            self:SetBackdropBorderColor(COLORS.accent[1],COLORS.accent[2],COLORS.accent[3],1)
        else
            self:SetBackdropColor(0.045,0.05,0.06,1)
            self:SetBackdropBorderColor(unpack(COLORS.border))
        end
    end
    RefreshAutoOpenCheck(autoOpen)
    autoOpen:SetScript("OnClick",function(self)
        GBM.db.options.autoOpenWithGuildBank=not not self:GetChecked()
        RefreshAutoOpenCheck(self)
    end)
    autoOpen:SetScript("OnEnter",function(self) self:SetBackdropBorderColor(unpack(COLORS.accent)) end)
    autoOpen:SetScript("OnLeave",RefreshAutoOpenCheck)

    -- Dedicated status bar.  The old summary text and status text occupied the
    -- same bottom-left area, which caused messages such as "Guild bank open."
    -- to draw over the summary.  Keep the status in its own panel instead.
    local statusPanel = CreatePanel(UI, 14, -617, 745, 30)
    status = statusPanel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    status:SetPoint("LEFT",12,0)
    status:SetWidth(720)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)

end

function GBM:ShowUI()
    BuildUI()
    UI:Show()
    if self.bankOpen then self:QueryConfiguredTabs() end
    self:RefreshUI()
end

function GBM:ToggleUI()
    BuildUI()
    if UI:IsShown() then UI:Hide() else self:ShowUI() end
end
