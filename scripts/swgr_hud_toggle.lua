-- SWGR HUD Toggle (HT29) - Star Wars Galactic Racer
-- HT28/29: "HUD opacity when on" slider (20-100 %, 100 % = the game's own). HUD off is still fully invisible.
-- HT29: above 100 % removed - tested: no visible change (Slate clamps widget opacity / vertex alpha at 1). While the HUD is on at a value other than
-- 100 %, the on-screen HUD widgets are re-checked twice a second (new ones get the same opacity).
-- Press L3 (left-stick click) to fade the race HUD out / in, with an optional game UI sound. Menus are not affected.
-- Panel: Script UI -> "SWGR - HUD toggle": master switch, fade times, HUD off / HUD on sound, pitch, volume
-- (saved in data/swgr_hud_toggle.json). The HUD itself always starts ON (visible) - that state is never saved.
--
-- HUD = every on-screen widget whose class name starts with WBP_Hud (covers each vehicle's own HUD).
-- Races only: a race = your pawn is a Griffin vehicle with a valid vehicle state (checked 1 s in menus, 2 s in a
-- race). Every race starts with the HUD on. The game's pause menu takes the race HUD off the screen (it never
-- reports itself paused), so L3 / Hide HUD only act while the race HUD is on screen: no toggle, no sound in pause.
--
-- Hiding = render opacity 0. Pausing: the game is not fought. If the HUD is hidden when the pause menu opens (the
-- race HUD leaves the screen), the script quietly switches back to "HUD on" (no sound) and the game shows the HUD
-- normally on resume. So: visible -> pause -> resume = visible; hidden -> pause -> resume = visible. The next L3
-- hides it again with the HUD-off sound (sounds always match what you see).
--
-- Safety: no game object is kept between uses. HUD widgets and sounds are always taken from the game's current
-- live lists (UEVR_UObjectHook.exists is not usable here - it reports these live widgets as missing), so the
-- script can never touch something the game has freed (race end / level change).

local SOUNDS = {                          -- dropdown name, game asset (MetaSoundSource)
    { 'None', nil },
    { 'Accept', '/Game/Griffin/Audio/UI/MS_UI_Accept.MS_UI_Accept' },
    { 'Back', '/Game/Griffin/Audio/UI/MS_UI_Back.MS_UI_Back' },
    { 'Navigate', '/Game/Griffin/Audio/UI/MS_UI_Navigate.MS_UI_Navigate' },
    { 'Toggle', '/Game/Griffin/Audio/UI/MS_UI_SettingsToggleValueChanged.MS_UI_SettingsToggleValueChanged' },
    { 'Panel open', '/Game/Griffin/Audio/UI/MS_UI_BuildMenu_Open.MS_UI_BuildMenu_Open' },
    { 'Panel close', '/Game/Griffin/Audio/UI/MS_UI_BuildMenu_Close.MS_UI_BuildMenu_Close' },
    { 'Settings open', '/Game/Griffin/Audio/UI/MS_UI_SettingsOpen.MS_UI_SettingsOpen' },
    { 'Settings close', '/Game/Griffin/Audio/UI/MS_UI_SettingsClose.MS_UI_SettingsClose' },
    { 'Ability select', '/Game/Griffin/Audio/Vehicles/Abilities/Core/MS_UI_Ability_Select.MS_UI_Ability_Select' },
    { 'Planet scroll', '/Game/Griffin/Audio/UI/MS_UI_PlanetScreen_Scroll.MS_UI_PlanetScreen_Scroll' },
}
local L3, R3 = 0x0040, 0x0080
local HOLD_EVERY = 0.25                 -- while hidden: keep the current HUD widgets hidden / notice a pause
local VIS_EVERY = 0.5                   -- while on at a custom opacity: keep new HUD widgets at it
local FADE_STEP = 1 / 30                -- fade updates at most 30x a second
local SAVE_FILE = 'swgr_hud_toggle.json'

local S = {
    enabled = true,
    fade_out = 0.3, fade_in = 0.3,                       -- seconds (0 = instant)
    off_sound = 'Panel close', off_pitch = 1.0, off_volume = 1.0,
    on_sound = 'Panel open', on_pitch = 1.0, on_volume = 1.0,
    on_opacity = 1.0,                                   -- HUD opacity when on (1 = game)
}

local api = uevr.api
local hidden, l3Enabled = false, true                  -- HUD always starts ON
local inRace, raceCheckT = false, 0
local held, r3Seen = false, false
local level = 1                                         -- 1 = fully visible, 0 = fully faded out
local holdT, fadeT, visT = 0, 0, 0
local appliedVis = 1.0                                  -- on-opacity last written to the widgets
local function vis() return S.on_opacity end
local function custom() return math.abs(S.on_opacity - 1) > 0.001 end
local lastError = nil

local function hasBit(b, m) return math.floor(b / m) % 2 == 1 end
local function clamp(x, lo, hi, d) x = tonumber(x) or d; return math.max(lo, math.min(hi, x)) end

---------------------------------------------------------------- settings
local function sound_index(name)
    for i, s in ipairs(SOUNDS) do if s[1] == name then return i end end
    return 1
end

pcall(function()
    local data = json.load_file(SAVE_FILE)
    if type(data) ~= 'table' then return end
    if type(data.enabled) == 'boolean' then S.enabled = data.enabled end
    S.fade_out = clamp(data.fade_out, 0, 2, S.fade_out)
    S.fade_in = clamp(data.fade_in, 0, 2, S.fade_in)
    S.on_opacity = clamp(data.on_opacity, 0.2, 1, S.on_opacity)
    for _, k in ipairs({ 'off', 'on' }) do
        if type(data[k .. '_sound']) == 'string' then S[k .. '_sound'] = SOUNDS[sound_index(data[k .. '_sound'])][1] end
        S[k .. '_pitch'] = clamp(data[k .. '_pitch'], 0.5, 2, S[k .. '_pitch'])
        S[k .. '_volume'] = clamp(data[k .. '_volume'], 0, 6, S[k .. '_volume'])
    end
end)

local function save() pcall(json.dump_file, SAVE_FILE, S, 4) end

---------------------------------------------------------------- engine classes (native, never unloaded)
local userWidget, gameplayStatics, vehicleClass, msClass = nil, nil, nil, nil
local initDone = false
local function init()
    if initDone then return end
    initDone = true
    pcall(function() userWidget = api:find_uobject('Class /Script/UMG.UserWidget') end)
    pcall(function()
        gameplayStatics = api:find_uobject('Class /Script/Engine.GameplayStatics'):get_class_default_object()
    end)
    pcall(function() msClass = api:find_uobject('Class /Script/MetasoundEngine.MetaSoundSource') end)
    pcall(function() vehicleClass = api:find_uobject('Class /Script/Griffin.VehiclePawn') end)
end
if S.enabled then init() end

---------------------------------------------------------------- live HUD widgets (nothing kept)
-- Any widget whose class name starts with "WBP_Hud" (any case) counts as HUD - the game picks a different HUD per
-- vehicle / race type (68 HUD widgets in its files). Only the ones directly on screen are faded: the pieces inside
-- a HUD screen disappear with it, and their own game-driven fades are never touched.
-- The main HUD screens (in /UI/Screens/: WBP_Hud_Race, WBP_Hud_Memory, WBP_Hud_EventIntermission) also tell
-- the pause menu apart: none of them on screen = pause menu.
-- Class address -> kind ('screen' / 'hud' / false); names are read once per class from a live widget's class,
-- the class objects themselves are never used again. Cleared at every race start / end.
local classKind = {}
local topAddrs = {}                                     -- widget address -> true: HUD widgets faded this hide (kept
                                                        -- until the HUD is fully back, so pause can restore them)

local function hud_widgets()
    local out = {}
    if not userWidget then return out end
    local ok, list = pcall(function() return userWidget:get_objects_matching(false) end)
    for _, w in ipairs(ok and list or {}) do
        pcall(function()
            local cls = w:get_class()
            local ca = cls:get_address()
            local kind = classKind[ca]
            if kind == nil then
                local full = cls:get_full_name()
                local short = (full:match('%.([^%.]+)$') or full):lower()
                if short:find('^wbp_hud') then
                    kind = full:find('/UI/Screens/', 1, true) and 'screen' or 'hud'
                else
                    kind = false
                end
                classKind[ca] = kind
            end
            if kind then out[#out + 1] = { w = w, screen = (kind == 'screen'), addr = w:get_address() } end
        end)
    end
    return out
end

-- Find the HUD widgets on screen now (remembered by address only). Returns whether a main HUD screen is on screen.
local function scan_on_screen()
    local screenOn = false
    for _, h in ipairs(hud_widgets()) do
        local ok, v = pcall(function() return h.w:IsInViewport() end)
        if ok and v == true then
            topAddrs[h.addr] = true
            if h.screen then screenOn = true end
        end
    end
    return screenOn
end

-- Set opacity on the on-screen HUD widgets (only writes what differs). rescan = look for on-screen widgets again
-- first (and report whether a main HUD screen is on screen); otherwise use the last scan's addresses (fade steps).
local function apply(opacity, rescan)
    local screenOn = nil
    if rescan then screenOn = scan_on_screen() end
    for _, h in ipairs(hud_widgets()) do
        if topAddrs[h.addr] then
            pcall(function()
                local cur = tonumber(h.w:GetRenderOpacity()) or 1
                if math.abs(cur - opacity) > 0.001 then h.w:SetRenderOpacity(opacity) end
            end)
        end
    end
    return screenOn
end

local function race_hud_on_screen() return scan_on_screen() end

---------------------------------------------------------------- sound (looked up fresh on each play)
local soundName = {}                                    -- sound address -> full name (cleared every race)
local function find_sound(path)
    if not msClass then return nil end
    local want = 'MetaSoundSource ' .. path
    local ok, list = pcall(function() return msClass:get_objects_matching(false) end)
    for _, o in ipairs(ok and list or {}) do
        local okA, addr = pcall(function() return o:get_address() end)
        if okA and addr then
            local n = soundName[addr]
            if n == nil then
                local okN, full = pcall(function() return o:get_full_name() end)
                n = okN and full or false
                soundName[addr] = n
            end
            if n == want then return o end
        end
    end
    return nil
end

local function play(name, pitch, volume)
    local path = SOUNDS[sound_index(name)][2]
    if not path or volume <= 0 or not gameplayStatics then return end
    local snd = find_sound(path)
    if not snd then
        lastError = 'sound "' .. name .. '" is not loaded by the game yet'
        return
    end
    local ok, err = pcall(function()
        local ctx = api:get_player_controller(0) or api:get_engine()
        gameplayStatics:PlaySound2D(ctx, snd, volume, pitch, 0.0, nil, nil, true)
    end)
    if ok then lastError = nil else lastError = 'sound: ' .. tostring(err) end
end

---------------------------------------------------------------- race
local function check_race()
    local p = api:get_local_pawn(0)
    if p == nil or vehicleClass == nil or not p:is_a(vehicleClass) then return false end
    local v = p.VehicleState
    if v == nil or not v.Valid then return false end
    return true
end

local function set_race(r)
    if r and (level ~= 1 or appliedVis ~= 1) then pcall(apply, 1, true) end
    appliedVis = 1.0
    inRace = r
    hidden, held = false, false
    level = 1
    classKind, soundName, topAddrs = {}, {}, {}         -- the game may unload / reload classes and sounds
end

local function toggle(h)
    if not inRace or h == hidden then return end
    if not race_hud_on_screen() then return end         -- pause menu / no HUD: no toggle, no sound
    hidden = h
    holdT, fadeT = 0, FADE_STEP                         -- (race_hud_on_screen above just scanned what is on screen)
    if hidden then play(S.off_sound, S.off_pitch, S.off_volume) else play(S.on_sound, S.on_pitch, S.on_volume) end
end

---------------------------------------------------------------- callbacks
-- L3 tap toggles; L3 + R3 (UEVR's menu combo) is ignored.
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if not S.enabled or not inRace or user_index ~= 0 or not state or not l3Enabled then
        held = false
        return
    end
    local ok, b = pcall(function() return tonumber(state.Gamepad.wButtons) end)
    if not ok or not b then return end
    if hasBit(b, L3) then
        if not held then held, r3Seen = true, false end
        if hasBit(b, R3) then r3Seen = true end
    elseif held then
        held = false
        if not r3Seen then toggle(not hidden) end
    end
end)

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not S.enabled then return end
    local dt = tonumber(delta) or 0.016
    raceCheckT = raceCheckT + dt
    if raceCheckT >= (inRace and 2.0 or 1.0) then
        raceCheckT = 0
        local ok, r = pcall(check_race)
        if not ok then r = false end
        if r ~= inRace then set_race(r) end
    end
    if not inRace then return end
    local target = hidden and 0 or 1
    if level ~= target then
        local time = target < level and S.fade_out or S.fade_in
        if time <= 0 then
            level = target
        else
            local step = dt / time
            if target < level then level = math.max(target, level - step) else level = math.min(target, level + step) end
        end
        fadeT = fadeT + dt
        if fadeT >= FADE_STEP or level == target then
            fadeT = 0
            pcall(apply, level * vis(), level == 1)
            if level == 1 then
                appliedVis = vis()
                if not custom() then topAddrs = {} end  -- fully back at the game's own opacity
            end
        end
    elseif not hidden then
        -- HUD on: keep it at the chosen opacity (new widgets, slider changes); 100 % = leave the game alone
        visT = visT + dt
        if custom() or appliedVis ~= 1 then
            if visT >= VIS_EVERY or appliedVis ~= vis() then
                visT = 0
                pcall(apply, vis(), true)
                appliedVis = vis()
                if not custom() then topAddrs = {} end
            end
        end
    elseif hidden then
        holdT = holdT + dt
        if holdT >= HOLD_EVERY then
            holdT = 0
            local ok, raceOn = pcall(apply, 0, true)
            if ok and raceOn == false then
                -- pause menu opened (race HUD off screen): don't fight the game - back to "HUD on", no sound
                hidden, level = false, 1
                pcall(apply, vis(), false)              -- the widgets that were faded (their addresses)
                appliedVis = vis()
                if not custom() then topAddrs = {} end
            end
        end
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    if inRace and (hidden or level ~= 1 or appliedVis ~= 1) then pcall(apply, 1, false) end
    appliedVis = 1.0
    hidden, level = false, 1
end)

---------------------------------------------------------------- panel
local function set_enabled(on)
    S.enabled = on
    save()
    if on then
        init()
    else
        if inRace and (hidden or level ~= 1 or appliedVis ~= 1) then pcall(apply, 1, false) end
        hidden, held, inRace, level = false, false, false, 1
        appliedVis = 1.0
        lastError = nil
    end
end

local ITEMS = {}
for i, s in ipairs(SOUNDS) do ITEMS[i - 1] = s[1] end

local function sound_block(k, label)
    local c, v = imgui.combo(label .. '##' .. k, sound_index(S[k .. '_sound']) - 1, ITEMS)
    if c then
        S[k .. '_sound'] = SOUNDS[v + 1][1]; save()
        play(S[k .. '_sound'], S[k .. '_pitch'], S[k .. '_volume'])      -- preview
    end
    c, v = imgui.slider_float('Pitch##' .. k, S[k .. '_pitch'], 0.5, 2.0, '%.2f')
    if c then S[k .. '_pitch'] = clamp(v, 0.5, 2, 1); save() end
    c, v = imgui.slider_float('Volume##' .. k, S[k .. '_volume'], 0.0, 6.0, '%.2f')
    if c then S[k .. '_volume'] = clamp(v, 0, 6, 1); save() end
end

uevr.lua.add_script_panel('SWGR - HUD toggle', function()
    local c, v = imgui.checkbox('Enable HUD control', S.enabled)
    if c then set_enabled(v) end
    if not S.enabled then
        imgui.text('Off: the script does nothing; the HUD is exactly as the game shows it.')
        return
    end
    imgui.separator()
    if inRace then
        c, v = imgui.checkbox('Hide HUD', hidden)
        if c then toggle(v) end
    else
        imgui.text('Hide HUD: only during a race (settings below can be changed now)')
    end
    c, v = imgui.checkbox('L3 (left-stick click) toggles the HUD', l3Enabled)
    if c then l3Enabled = v; held = false end
    c, v = imgui.slider_float('HUD opacity when on (%)', S.on_opacity * 100, 20.0, 100.0, '%.0f')
    if c then S.on_opacity = clamp(v / 100, 0.2, 1, 1); save() end
    imgui.text('  100 = the game\'s own. Lower = more see-through.')
    imgui.text('  HUD off is always fully invisible.')
    if imgui.button('Opacity back to 100') then S.on_opacity = 1.0; save() end
    imgui.separator()
    c, v = imgui.slider_float('HUD fade-out time (s)', S.fade_out, 0.0, 2.0, '%.2f')
    if c then S.fade_out = clamp(v, 0, 2, 0.3); save() end
    sound_block('off', 'HUD off sound')
    imgui.separator()
    c, v = imgui.slider_float('HUD fade-in time (s)', S.fade_in, 0.0, 2.0, '%.2f')
    if c then S.fade_in = clamp(v, 0, 2, 0.3); save() end
    sound_block('on', 'HUD on sound')
    if lastError then imgui.text(lastError) end
end)
