local ADDON, GBM = ...

GBM.bankOpen = false
GBM.bank = { tabs = {} }

local function CanUseTab(tab, role)
    local name, icon, canView, canDeposit, numWithdrawals = GetGuildBankTabInfo(tab)
    if not name or not canView then return false end
    if role == "deposit" then return canDeposit end
    if role == "withdraw" then return numWithdrawals ~= 0 end
    return canDeposit and numWithdrawals ~= 0
end

function GBM:IsGuildBankAvailable()
    if not IsInGuild() then return false, "You are not in a guild." end
    if not self.bankOpen then return false, "Open the guild bank first." end
    return true
end

function GBM:QueryConfiguredTabs()
    local n = math.min(GetNumGuildBankTabs() or 0, self.MAX_TABS)
    for tab = 1, n do
        if self.db.tabs[tab].mode ~= "ignore" then
            QueryGuildBankTab(tab)
        end
    end
end

function GBM:ScanBank()
    local snapshot = { tabs = {}, byItem = {} }
    local n = math.min(GetNumGuildBankTabs() or 0, self.MAX_TABS)
    for tab = 1, n do
        local cfg = self.db.tabs[tab]
        local realName = GetGuildBankTabInfo(tab)
        if realName and realName ~= "" then cfg.name = realName end
        local tabData = {
            mode = cfg.mode,
            slots = {},
            canDeposit = CanUseTab(tab, "deposit"),
            canWithdraw = CanUseTab(tab, "withdraw"),
        }
        snapshot.tabs[tab] = tabData
        if cfg.mode ~= "ignore" then
            for slot = 1, self.SLOTS_PER_TAB do
                local texture, count, locked = GetGuildBankItemInfo(tab, slot)
                local link = GetGuildBankItemLink(tab, slot)
                local itemID = self:ItemIDFromLink(link)
                local s = { tab=tab, slot=slot, itemID=itemID, link=link, count=count or 0, locked=locked and true or false }
                tabData.slots[slot] = s
                if itemID then
                    snapshot.byItem[itemID] = snapshot.byItem[itemID] or {}
                    table.insert(snapshot.byItem[itemID], s)
                end
            end
        end
    end
    self.bank = snapshot
    return snapshot
end

function GBM:RefreshBank(verbose)
    local ok, err = self:IsGuildBankAvailable()
    if not ok then self:Print(err); return end
    self:QueryConfiguredTabs()
    C_Timer.After(0.35, function()
        GBM:ScanBank()
        if verbose then GBM:Print("Guild bank scanned.") end
        if GBM.RefreshUI then GBM:RefreshUI() end
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("GUILDBANKFRAME_OPENED")
events:RegisterEvent("GUILDBANKFRAME_CLOSED")
events:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

local function OpenGuildBank()
    if GBM.bankOpen then return end
    GBM.bankOpen = true
    if GBM.db.options.autoOpenWithGuildBank and GBM.ShowUI then GBM:ShowUI() end
    GBM:RefreshBank(false)
end

local function CloseGuildBank()
    if not GBM.bankOpen then return end
    GBM.bankOpen = false
    GBM:StopExecutor("Guild bank closed.")
end

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        GBM:InitDB()
    elseif event == "GUILDBANKFRAME_OPENED" then
        OpenGuildBank()
    elseif event == "GUILDBANKFRAME_CLOSED" then
        CloseGuildBank()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
        and arg1 == Enum.PlayerInteractionType.GuildBanker then
        OpenGuildBank()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE"
        and arg1 == Enum.PlayerInteractionType.GuildBanker then
        CloseGuildBank()
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        if GuildBankFrame and GuildBankFrame:IsShown() then GBM.bankOpen = true end
        if GBM.executing and GBM.OnBankSlotsChanged then
            GBM:OnBankSlotsChanged(arg1)
        elseif GBM.bankOpen then
            C_Timer.After(0.15, function() if GBM.bankOpen and not GBM.executing then GBM:ScanBank() end end)
        end
    end
end)
