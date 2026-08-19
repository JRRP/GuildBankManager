local ADDON, GBM = ...
_G[ADDON] = GBM

GBM.name = ADDON
GBM.version = "1.1.8"
GBM.MAX_TABS = 8
GBM.SLOTS_PER_TAB = 98

function GBM:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff4aa3ffGBM|r " .. tostring(msg))
end

function GBM:ItemIDFromLink(link)
    if not link then return nil end
    return tonumber(link:match("item:(%d+)"))
end

function GBM:InCombat()
    return InCombatLockdown and InCombatLockdown()
end

SLASH_GUILDBANKMANAGER1 = "/gbm"
SLASH_GUILDBANKMANAGER2 = "/guildbankmanager"
SlashCmdList.GUILDBANKMANAGER = function(msg)
    msg = strtrim(msg or "")
    if msg == "sort" then
        GBM:BeginSort()
    elseif msg == "scan" then
        GBM:BeginSort()
    else
        GBM:ToggleUI()
    end
end
