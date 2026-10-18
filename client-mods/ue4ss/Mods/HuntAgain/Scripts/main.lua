print("[HA] HuntAgain loading...\n")
local UEHelpers = require("UEHelpers")
local FrameTick = require("FrameTick")

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
local pressedWall = nil -- os.time() of the press: wall clock, unlike the game's, survives the trip
local ourLegend = nil  -- the button legend (button bar) that shows our button

local function readHunt(pc)
    if not valid(pc) then return end
    local ok, id = pcall(function() return pc.IslandHuntPropertyData.HuntID:ToString() end)
    if ok and id and id ~= "" and id ~= lastHunt then
        lastHunt = id
        log("hunt: " .. id)
        -- A different hunt started before the queued one: never queue the old one later.
        if pending and id ~= pending then
            log("a different hunt started: hunt again for " .. pending .. " cancelled")
            pending = nil
        end
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
    pending, pressedWall = lastHunt, os.time()
    log("hunt again: " .. pending .. " - pressing Continue")
    pcall(function() cont:PressButton() end)
end

-- Add our button to a showing legend that has Continue, after a pursuit. Runs inside the last
-- end-of-hunt screen's CheckReady hook (game thread), never inside the game's own legend update.
local function addTo(legend)
    if pending or not valid(legend) or not isPursuit(lastHunt) then return end
    if not findHint(legend, isContinue) or findHint(legend, isOurs) then return end
    local ok, err = pcall(function() legend:AddButton({KeyName = FName(KEY)}, FText(LABEL)) end)
    if ok then ourLegend = legend end
    log(ok and ("button added for " .. lastHunt .. " (legend: " .. hintLabels(legend) .. ")")
        or ("could not add button: " .. tostring(err)))
end

NotifyOnNewObject("/Script/Archon.EndHuntScreen", function() pcall(readHunt, partyClient()) end)

-- The Continue button sits on a legend (button bar) that the game builds in advance and fills
-- without any hookable call, so look instead: while the last end-of-hunt screen is up, check
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

-- Clicks and R arrive on UE4SS's input thread and only set a flag; the next CheckReady acts on it.
-- Nothing here is queued with ExecuteInGameThread or ExecuteWithDelay, so Ctrl+R (hot reload)
-- never leaves a call pointing into an unloaded script: the Mod Menu found that crashed the game.
local clicked, rPressed = false, false
RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function() clicked = true end)
RegisterKeyBind(Key.R, function() rPressed = true end)

-- Still on this screen this long after pressing Continue: the press did nothing, so hunt again is
-- cancelled (otherwise the button never came back and any later trip to Ramsgate queued the hunt).
-- Leaving the island took about 30 s in testing.
local PRESS_TIMEOUT = 90
local pressedAt = nil

-- About every 0.3 s while the last end-of-hunt screen is up. A click or R from before the screen
-- is dropped on the first call, before our button exists.
local function onLastStage(self)
    local okW, w = pcall(function() return self:get() end)
    local now = FrameTick.Now(okW and w or nil)
    if not pending then
        pressedAt = nil
    elseif not pressedAt then
        pressedAt = now
    elseif now and now - pressedAt > PRESS_TIMEOUT then
        log("still on the end screen " .. PRESS_TIMEOUT .. " s after Continue: hunt again for " .. pending .. " cancelled")
        pending, pressedAt = nil, nil
    end
    local click, r = clicked, rPressed
    clicked, rPressed = false, false
    local h = ourHint()
    if h and click and hovered(h) then
        log("button clicked")
        huntAgain()
    elseif h and r then
        log("R pressed")
        huntAgain()
    end
    scan()
end

-- The last end-of-hunt screen is a blueprint: its CheckReady can be hooked only once its class is
-- loaded, which happens when the first such screen is built (or already, after a Ctrl+R).
local LAST_STAGE = "/Game/UI/EndOfHunt/EndOfHunt_LastStage.EndOfHunt_LastStage_C"
local lastStageHooked = false
local function hookLastStage()
    if lastStageHooked or not valid(StaticFindObject(LAST_STAGE .. ":CheckReady")) then return end
    local ok, err = pcall(function()
        RegisterHook(LAST_STAGE .. ":CheckReady", function(self) pcall(onLastStage, self) end)
    end)
    lastStageHooked = ok
    log(ok and "watching the last end-of-hunt screen" or ("could not hook the last end-of-hunt screen: " .. tostring(err)))
end
pcall(hookLastStage)
NotifyOnNewObject("/Script/UMG.UserWidget", function(w)
    if lastStageHooked then return end
    local ok, cls = pcall(function() return w:GetClass():GetFName():ToString() end)
    if ok and cls == "EndOfHunt_LastStage_C" then pcall(hookLastStage) end
end)

-- Back in Ramsgate: the player pawn spawns (ClientRestart); about 3 s later, queue the pursuit.
-- The wait runs on FrameTick (the HUD's per-frame hook, up in town) for the same Ctrl+R reason.
-- Arriving more than DETOUR_LIMIT after the press means Continue did not bring the player here
-- (they left some other way): cancelled, never queued. The direct trip took about 30 s.
local DETOUR_LIMIT = 120
local back = false      -- ClientRestart seen since Continue was pressed
local backAt = nil      -- FrameTick time of the first town tick after it (same map clock)
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    if pending then back, backAt = true, nil end
end)
FrameTick.Every(0.5, "queue", function(t)
    if not (pending and back) or onIsland() then return end
    if not backAt then
        backAt = t
        if os.time() - (pressedWall or 0) > DETOUR_LIMIT then
            log("back in Ramsgate more than " .. DETOUR_LIMIT .. " s after Continue: hunt again for " .. pending .. " cancelled")
            pending, back = nil, false
            return
        end
    end
    if t - backAt < 3 then return end
    back = false
    local hunt = pending
    local pc = partyClient()
    if not pc then log("back in Ramsgate, but no party client") return end
    local okM, busy = pcall(function() return pc:IsMatchmaking() end)
    if okM and busy then log("already matchmaking, not queueing again") pending = nil return end
    pending = nil
    local ok, res = pcall(function() return pc:FindHunt(FName(hunt), false, FName("None")) end)
    log("queued " .. hunt .. " ok=" .. tostring(ok) .. " result=" .. tostring(res))
end)
FrameTick.Start(log)

log("HuntAgain loaded (pursuits only)")
