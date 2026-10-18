print("[HA] HuntAgain loading...\n")
local UEHelpers = require("UEHelpers")

-- HuntAgain: after a pursuit, the last end-of-hunt screen gets a "Hunt again" button next to
-- Continue and Leave hunt (keyboard: R). It presses Continue for you, and once you are back in
-- Ramsgate it queues the same pursuit again. Pursuits only for now.
--
-- What it relies on (found with a probe script that only logged):
--   * The hunt id is ArchonPartyClient.IslandHuntPropertyData.HuntID; GetPlayerHuntID is already
--     empty when the end screens show.
--   * ArchonPartyClient:FindHunt(PlayerHuntId, false, None) queues a hunt (tested from Ramsgate).
--   * The button is added with the screen's own ButtonLegend:AddButton, so it looks native.
--   * Queue from Ramsgate, never from the island: a server limited to one hunt at a time
--     (MAX_LOCAL_HUNTS=1) only closes the finished hunt's server once you have left it.
-- By RB, made and tested on CachyOS (Linux, Proton). Off by default: switched on from the
-- launcher's Mods page or the in-game Mod Menu (mods.txt "HuntAgain : 1").
-- Log: lines starting with [HA] in Archon/Binaries/Win64/ue4ss/UE4SS.log. Ctrl+R reloads.

local KEY = "R"
local LABEL = "HUNT AGAIN"   -- upper case, like the game's own CONTINUE

local function log(msg) print("[HA] " .. msg .. "\n") end

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end

local function name(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and s or "?"
end

local function isPursuit(id) return id ~= nil and id:find("Pursuit") ~= nil end

local function onIsland()
    local ok, path = pcall(function() return UEHelpers.GetWorld():GetFullName() end)
    return ok and path:find("/islands/") ~= nil
end

-- FindFirstOf can return the class default object ("Default__..."), which never has a hunt.
local function partyClient()
    for _, pc in ipairs(FindAllOf("ArchonPartyClient") or {}) do
        if valid(pc) and not name(pc):find("^Default__") then return pc end
    end
end

local lastHunt = nil   -- the pursuit being played, remembered across the trip back to Ramsgate
local pending = nil    -- the pursuit to queue once back in Ramsgate
local ourLegend = nil  -- the button legend (button bar) that shows our button

local function readHunt(pc)
    if not valid(pc) then return end
    local ok, id = pcall(function() return pc.IslandHuntPropertyData.HuntID:ToString() end)
    if ok and id and id ~= "" and id ~= lastHunt then
        lastHunt = id
        log("hunt: " .. id)
    end
end

pcall(function()
    RegisterHook("/Script/Archon.ArchonPartyClient:OnRep_IslandHuntPropertyData", function(self) readHunt(self:get()) end)
end)

-- Legend buttons ("hints") live in two rows of the legend.
local function findHint(legend, match)
    for _, box in ipairs({"Hint_Box", "Left_Hint_Box"}) do
        local ok, found = pcall(function()
            local row = legend[box]
            for i = 0, row:GetChildrenCount() - 1 do
                local h = row:GetChildAt(i)
                if valid(h) and match(h) then return h end
            end
        end)
        if ok and found then return found end
    end
end

local function keyOf(h)
    local ok, k = pcall(function() return h.Key.KeyName:ToString() end)
    return ok and k or ""
end

local function labelOf(h)
    local ok, t = pcall(function() return h.Label:ToString() end)
    return ok and t or ""
end

local function isOurs(h) return keyOf(h) == KEY and labelOf(h) == LABEL end
local function isContinue(h) return labelOf(h):lower():find("continue") ~= nil end

local function showing(w)
    if not valid(w) then return false end
    local ok, v = pcall(function() return w:IsVisible() end)
    return ok and v
end

local function hintLabels(legend)
    local labels = {}
    findHint(legend, function(h) labels[#labels + 1] = keyOf(h) .. "=" .. labelOf(h) return false end)
    return table.concat(labels, ", ")
end

local function huntAgain()
    if pending or not showing(ourLegend) or not isPursuit(lastHunt) then return end
    local cont = findHint(ourLegend, isContinue)
    if not cont then log("no Continue button to press") return end
    pending = lastHunt
    log("hunt again: " .. pending .. " - pressing Continue")
    pcall(function() cont:PressButton() end)
end

-- Add our button to a legend that has Continue, after a pursuit. Deferred to the next game-thread
-- turn so it never runs inside the game's own legend update.
local function addTo(legend)
    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function()
            if pending or not valid(legend) or not isPursuit(lastHunt) then return end
            if not findHint(legend, isContinue) or findHint(legend, isOurs) then return end
            local ok, err = pcall(function() legend:AddButton({KeyName = FName(KEY)}, FText(LABEL)) end)
            if ok then ourLegend = legend end
            log(ok and ("button added for " .. lastHunt .. " (legend: " .. hintLabels(legend) .. ")")
                or ("could not add button: " .. tostring(err)))
        end)
    end)
end

NotifyOnNewObject("/Script/Archon.EndHuntScreen", function() pcall(readHunt, partyClient()) end)

-- The Continue button sits on a legend (button bar) that the game builds in advance and fills
-- without any hookable call, so look instead: once a second while on a pursuit island, check
-- every showing legend and add ours next to a Continue. Each legend's buttons are logged when
-- they change, to see what the game shows.
local seen = {}
local function scan()
    if pending or not onIsland() or not isPursuit(lastHunt) then return end
    for _, cls in ipairs({"w_button_legend_C", "ButtonLegendWidget"}) do
        for _, legend in ipairs(FindAllOf(cls) or {}) do
            if showing(legend) then
                local labels = hintLabels(legend)
                if seen[name(legend)] ~= labels then
                    seen[name(legend)] = labels
                    log("legend " .. name(legend) .. ": " .. labels)
                end
                addTo(legend)
            end
        end
    end
end
local function loop()
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function() pcall(scan) end)
        loop()
    end)
end
loop()

-- The game handles clicks on legend buttons natively, out of reach of Lua hooks, and the button's
-- blueprint only has hover events. So a click is: left mouse button pressed while the pointer is
-- over our button. R on the keyboard does the same.
local function ourHint()
    return showing(ourLegend) and findHint(ourLegend, isOurs) or nil
end

local function hovered(h)
    local ok, v = pcall(function() return h:IsHovered() or h.Button:IsHovered() end)
    return ok and v
end

RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
    ExecuteInGameThread(function()
        local h = ourHint()
        if h and hovered(h) then
            log("button clicked")
            huntAgain()
        end
    end)
end)
RegisterKeyBind(Key.R, function()
    ExecuteInGameThread(function()
        local h = ourHint()
        log("R pressed" .. (h and "" or " (no button showing)"))
        if h then huntAgain() end
    end)
end)

-- Back in Ramsgate: the player pawn spawns (ClientRestart), then queue the pursuit.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    if not pending then return end
    local hunt = pending
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            if pending ~= hunt or onIsland() then return end
            local pc = partyClient()
            if not pc then log("back in Ramsgate, but no party client") return end
            local okM, busy = pcall(function() return pc:IsMatchmaking() end)
            if okM and busy then log("already matchmaking, not queueing again") pending = nil return end
            pending = nil
            local ok, res = pcall(function() return pc:FindHunt(FName(hunt), false, FName("None")) end)
            log("queued " .. hunt .. " ok=" .. tostring(ok) .. " result=" .. tostring(res))
        end)
    end)
end)

log("HuntAgain loaded (pursuits only)")
