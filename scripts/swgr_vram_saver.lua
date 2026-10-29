-- SWGR VRAM Saver (SV20) - Star Wars Galactic Racer (UE 5.7), UEVR panel "SWGR - VRAM saver".
-- Settings: data/swgr_vram_saver_sv9.json (same file since SV9; older SV5-SV8 settings taken over once).
--
-- "Enable VRAM Saver" switches the whole panel.
--   MEMORY              Lumen surface cache and shadow page pool, % of the game's value.
--   AMBIENT OCCLUSION   compute shader + radius scale (Bodycam EX8 style). AO itself is switched on with
--                       r.AmbientOcclusionLevels on the UEVR Cvars page (this script never writes it).
-- SV14: Ultra Performance (= in-game GI Low, no extra gain) and the GI-off brightness control removed.
-- SV15: AO section greyed out (and not written) while r.AmbientOcclusionLevels is 0; Reset AO = compute off,
--       radius 8.5; shorter memory notes.
-- SV16: Ultra Performance back (on/off only, no brightness): r.Lumen.DiffuseIndirect.Allow 0 = what in-game
--       GI Low does. Applied only at launch (switching it live froze the game in SV12); not switched back on
--       script reset / Enable unticked until the game restarts.
-- SV17: section renamed GI PERFORMANCE (experimental); live on/off again (user tested: works, frame gen may
--       need a moment to resync); only acts at in-game GI Medium / High / Epic (at Low it holds 0 = Low's own
--       value, never turns GI back on). Advanced Monitor added (game / target / live values, recent changes).
-- SV18: freeze hunt - every change is logged BEFORE it is sent ('sending ...'), so a hang shows which one;
--       the Advanced Monitor reads nothing during the start wait and refreshes its values once a second
--       (cached) instead of every frame.
-- SV19: "Lumen reflections off" checkbox (from Bodycam VS2) in MEMORY: r.Lumen.Reflections.Allow 0 only -
--       Lumen GI and in-game Global Illumination are untouched. Game value captured fresh each launch.
-- SV20: Ultra Performance waits until ULTRA_GAP (5 s) after the last other change before it switches.
--       With ody's cockpit v2.2.0, Ultra saved as On hung the game in the main menu: it was sent 0.5 s after
--       the surface cache / shadow pool changes ('sending r.Lumen.DiffuseIndirect.Allow 0' never returned;
--       v2.1.1 fine). Switched on by hand a few seconds after the start batch it works (user tested
--       2026-10-29), so it still switches in the main menu - just after the others have settled.
-- Safety (30 s is required: 20 s froze on 2026-10-27 - memory changes landed during the intro movies):
-- nothing changes in the first 30 s after loading (changes during UEVR's headset setup froze the
-- game at start); then one cvar change per 0.5 s. A cvar on the UEVR Cvars page wins ("held").
-- Values a script sets stay locked until restart: after changing in-game graphics, restart the game.
-- UEVR imgui.combo lists entries in Lua table order and returns the key -> 1-based item tables only.

local TAG = '[SWGR VRAM SAVER SV20] '
local START_DELAY = 30.0
local ULTRA_GAP = 5.0                    -- Ultra Performance: seconds after the last other change before it switches
local ULTRA_CVAR = 'r.Lumen.DiffuseIndirect.Allow'
local SAVE_FILE = 'swgr_vram_saver_sv9.json'
local OLD_FILE = 'swgr_vram_saver_sv5.json'
local api = uevr.api

local function log(m) pcall(function() uevr.params.functions.log_info(TAG .. m) end) end
local function round(x) return math.floor(x + 0.5) end

local DEFAULTS = {master = true, ao_compute = false, ao_radius = 1.0, reflections = false}
local S = {sel = {}, stock = {}}
for k, v in pairs(DEFAULTS) do S[k] = v end
local st = {status = {}, failed = {}, reverts = {}, lastOk = {}, frozen = {}, clock = 0, nextCheck = 0,
    saveDirty = false, saveTimer = 0, stopped = false, lastError = nil, recent = {}, writes = 0,
    lastWriteT = -1e9}                   -- clock of the last change sent other than Ultra Performance

-------------------------------------------------------------------------------------------------
-- cvar rows. sel 0 = the game's value.
local AO_RESET_RADIUS = 8.5
local function ao_level()
    local ok, v = pcall(function() return api:get_console_manager():find_variable('r.AmbientOcclusionLevels'):get_int() end)
    return ok and v or nil
end
local function ao_on() return ao_level() ~= 0 end     -- 0 = AO off; the AO section is then locked and untouched

local ROWS = {
    {id = 'ao_compute', cvars = {'r.AmbientOcclusion.Compute'},
     active = function() return S.ao_compute and ao_on() end, vals = function() return {1} end},
    {id = 'ao_radius', cvars = {'r.AmbientOcclusionRadiusScale'}, float = true,
     active = function() return math.abs(S.ao_radius - 1.0) > 1e-3 and ao_on() end, vals = function() return {S.ao_radius} end},
    {id = 'reflections', cvars = {'r.Lumen.Reflections.Allow'},
     active = function() return S.reflections end, vals = function() return {0} end},
    {id = 'atlas', group = 'mem', label = 'Lumen surface cache', cvars = {'r.LumenScene.SurfaceCache.AtlasSize'},
     pct = {0.25, 0.5, 0.75}, info = 'Lower = more VRAM savings but may cause blotchier GI in busy scenes.',
     vals = function(g, p)
         local v = math.max(512, round(g[1] * math.sqrt(1 - p) / 128) * 128)
         return {v}, 1 - (v / g[1]) ^ 2
     end},
    {id = 'pool', group = 'mem', label = 'Shadow page pool', cvars = {'r.Shadow.Virtual.MaxPhysicalPages'},
     pct = {0.25, 0.5, 0.75}, info = 'Lower = more VRAM savings but may cause blotchy / flickering far shadows.',
     vals = function(g, p) local v = math.max(1, round(g[1] * (1 - p))); return {v}, 1 - v / g[1] end},
    {id = 'ultra', group = 'ultra', label = 'Ultra Performance', cvars = {'r.Lumen.DiffuseIndirect.Allow'},
     items = {'Off', 'On'}, needsGI = true, vals = function() return {0} end},
}
for _, r in ipairs(ROWS) do
    if r.pct then
        r.items = {'100%'}
        for i = 1, #r.pct do r.items[i + 1] = string.format('%d%%', round((1 - r.pct[i]) * 100)) end
    end
end

-------------------------------------------------------------------------------------------------
local function read_name(name, isFloat)
    local ok, v = pcall(function() return api:get_console_manager():find_variable(name) end)
    if not ok or not v then return nil end
    local okI, i = pcall(function() return v:get_int() end)
    local okF, f = pcall(function() return v:get_float() end)
    if isFloat then
        if okF and type(f) == 'number' then return f end
        return okI and i or nil
    end
    if okI and type(i) == 'number' then
        if okF and type(f) == 'number' and math.abs(f - i) > 1e-4 then return f end
        return i
    end
    if okF then return f end
end

local function same(a, b)
    if a == nil or b == nil then return false end
    return math.abs(a - b) <= math.max(1e-3, math.abs(b) * 1e-4)
end

local function fmt(v)
    if v == nil then return '?' end
    if math.abs(v - round(v)) < 1e-4 then return string.format('%d', round(v)) end
    local s = string.format('%.4f', v):gsub('0+$', ''):gsub('%.$', '')
    return s
end

local function write(name, isFloat, value)
    local current = read_name(name, isFloat)
    if current == nil then return nil, 'not in game' end
    if same(current, value) then st.failed[name] = nil; return current end
    if st.failed[name] == value or st.frozen[name] then return current end
    if st.budget ~= nil then
        if st.budget <= 0 then st.pending = true; return current end
        st.budget = st.budget - 1
    end
    if st.lastOk[name] == value then
        st.reverts[name] = (st.reverts[name] or 0) + 1
        if st.reverts[name] >= 3 then
            st.frozen[name] = true
            st.lastError = name .. ' held by UEVR Cvars page'
            log(st.lastError)
            return current
        end
    end
    log('sending ' .. name .. ' ' .. fmt(value))
    local ok, err = pcall(function() api:execute_command(name .. ' ' .. fmt(value)) end)
    current = read_name(name, isFloat)
    st.writes = st.writes + 1
    if name ~= ULTRA_CVAR then st.lastWriteT = st.clock end
    table.insert(st.recent, 1, string.format('%6.0f s  %s %s%s', st.clock, name, fmt(value),
        (ok and same(current, value)) and '' or '  (did not stick)'))
    if #st.recent > 8 then table.remove(st.recent) end
    if not ok or not same(current, value) then
        st.failed[name] = value
        st.lastError = name .. ' ' .. fmt(value) .. ' did not stick' .. (ok and '' or (': ' .. tostring(err)))
        log(st.lastError)
    else
        st.lastOk[name] = value
        log(name .. ' = ' .. fmt(value))
    end
    return current
end

local function game_values(r)
    local g = {}
    for i, c in ipairs(r.cvars) do
        g[i] = S.stock[c]
        if g[i] == nil then g[i] = read_name(c, r.float) end
        if g[i] == nil then return nil end
    end
    return g
end

local function target(r, sel)
    local g = game_values(r)
    if not g or sel < 1 then return nil end
    local ok, vals, cut = pcall(r.vals, g, r.pct and r.pct[sel])
    if not ok then return nil end
    return vals, cut
end

-------------------------------------------------------------------------------------------------
local function load_settings()
    local ok, data = pcall(json.load_file, SAVE_FILE)
    local function take_sel(src)
        for _, r in ipairs(ROWS) do
            local i = src[r.id]
            if r.items and type(i) == 'number' and i >= 0 and i < #r.items then S.sel[r.id] = math.floor(i) end
        end
    end
    if ok and type(data) == 'table' then
        if type(data.sel) == 'table' then take_sel(data.sel) end
        if type(data.stock) == 'table' then
            for _, r in ipairs(ROWS) do
                for _, c in ipairs(r.cvars) do
                    if type(data.stock[c]) == 'number' then S.stock[c] = data.stock[c] end
                end
            end
        end
        for k, def in pairs(DEFAULTS) do if type(data[k]) == type(def) then S[k] = data[k] end end
        S.ao_radius = math.max(0, math.min(10, S.ao_radius))
        return
    end
    local okO, old = pcall(json.load_file, OLD_FILE)
    if okO and type(old) == 'table' then
        if type(old.master) == 'boolean' then S.master = old.master end
        if type(old.sel) == 'table' then
            take_sel({atlas = old.sel.atlas, pool = old.sel.pool, ultra = (old.sel.gi == 1) and 1 or nil})
        end
        log('settings taken over from SV5-SV8')
    end
    st.saveDirty = true
end

local function save_settings()
    local out = {sel = S.sel, stock = S.stock}
    for k in pairs(DEFAULTS) do out[k] = S[k] end
    local ok, err = pcall(json.dump_file, SAVE_FILE, out, 4)
    if not ok then st.lastError = 'save failed: ' .. tostring(err) end
end

load_settings()
local function gi_level()
    local ok, v = pcall(function() return api:get_console_manager():find_variable('sg.GlobalIlluminationQuality'):get_int() end)
    return ok and v or nil
end

local function active_sel(r)
    if not S.master then return 0 end
    if r.needsGI and (gi_level() or 0) < 1 then return 0 end
    if r.active then return r.active() and 1 or 0 end
    return S.sel[r.id] or 0
end

local function changed()
    st.nextCheck = st.clock
    st.saveDirty = true; st.saveTimer = 0
    st.failed, st.reverts, st.lastOk, st.frozen = {}, {}, {}, {}
end

local function apply_rows()
    for _, r in ipairs(ROWS) do
        local sel = active_sel(r)
        local status
        -- Ultra Performance (SV20): not right on top of other changes - it waits ULTRA_GAP s after the last one
        local ultraWait = false
        if r.id == 'ultra' and st.clock - st.lastWriteT < ULTRA_GAP then
            local c = r.cvars[1]
            local want = nil
            if sel > 0 then want = 0
            elseif S.stock[c] ~= nil then want = ((r.needsGI and (gi_level() or 0) < 1) and 0) or S.stock[c] end
            local now = read_name(c, r.float)
            if want ~= nil and now ~= nil and not same(now, want) and not st.frozen[c] then
                ultraWait = true
                st.pending = true
                status = string.format('switches %d s after the other changes', math.ceil(ULTRA_GAP - (st.clock - st.lastWriteT)))
            end
        end
        if ultraWait then
            -- (left as it is this round)
        elseif sel > 0 then
            for _, c in ipairs(r.cvars) do
                if S.stock[c] == nil then
                    local v = read_name(c, r.float)
                    if v ~= nil then S.stock[c] = v; st.saveDirty = true end
                end
            end
            local vals, cut = target(r, sel)
            if not vals then status = 'not in game'
            else
                for i, c in ipairs(r.cvars) do
                    local _, e = write(c, r.float, vals[i])
                    if e then status = e
                    elseif st.frozen[c] then status = 'held by Cvars page'
                    elseif st.failed[c] ~= nil then status = 'did not stick' end
                end
                if not status and cut == 0 then status = 'already at that value' end
            end
        elseif r.needsGI and (gi_level() or 0) < 1 and S.stock[r.cvars[1]] ~= nil then
            -- in-game GI Low wants Lumen GI off too: hold 0 (our earlier write keeps Low from setting it itself)
            write(r.cvars[1], r.float, 0)
            status = 'in-game GI is Low'
        else
            for _, c in ipairs(r.cvars) do
                if S.stock[c] ~= nil then
                    st.failed[c] = nil
                    local now = write(c, r.float, S.stock[c])
                    if now == nil or same(now, S.stock[c]) then S.stock[c] = nil; st.saveDirty = true end
                end
            end
        end
        st.status[r.id] = status
    end
end

-------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------
local function restore_all()
    st.budget = nil
    for _, r in ipairs(ROWS) do
        for _, c in ipairs(r.cvars) do
            if S.stock[c] ~= nil and not st.frozen[c] then
                local back = S.stock[c]
                if r.needsGI and (gi_level() or 0) < 1 then back = 0 end   -- at GI Low, Low's own value
                st.failed[c] = nil; pcall(write, c, r.float, back)
            end
        end
    end
end

uevr.sdk.callbacks.on_pre_engine_tick(function(_, dt)
    if st.stopped then return end
    dt = type(dt) == 'number' and dt or 0.016
    st.clock = st.clock + dt
    if st.clock < START_DELAY then return end
    if st.clock >= st.nextCheck then
        st.budget, st.pending = 1, false
        local ok, err = pcall(apply_rows)
        if not ok then st.lastError = tostring(err) end
        st.budget = nil
        st.nextCheck = st.clock + (st.pending and 0.5 or 2.0)
    end
    if st.saveDirty then
        st.saveTimer = st.saveTimer + dt
        if st.saveTimer >= 1.0 then st.saveDirty = false; st.saveTimer = 0; save_settings() end
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    st.stopped = true
    pcall(restore_all)
    S.stock = {}
    save_settings()
end)

-------------------------------------------------------------------------------------------------
-- UI
local GREY = 0xFFA0A0A0
local function dim(t) if imgui.text_colored then imgui.text_colored(t, GREY) else imgui.text(t) end end
local function width(w) if imgui.set_next_item_width then pcall(imgui.set_next_item_width, w) end end

local function row_ui(r)
    local items = {}
    for i, t in ipairs(r.items) do items[i] = t end
    if r.pct then
        for i = 1, #r.pct do
            local _, cut = target(r, i)
            if cut then items[i + 1] = string.format('%d%%', round((1 - cut) * 100)) end
        end
    end
    local missing = game_values(r) == nil
    local locked = missing or (r.needsGI and (gi_level() or 0) < 1)
    if locked then imgui.begin_disabled() end
    width(120)
    local c, key = imgui.combo(r.label .. '##' .. r.id, (S.sel[r.id] or 0) + 1, items)
    if c and type(key) == 'number' then S.sel[r.id] = key - 1; changed() end
    if locked then imgui.end_disabled() end
    local s = missing and 'not in game' or st.status[r.id]
    if s then imgui.same_line(); imgui.text('  ' .. s) end
    if r.info then dim('      ' .. r.info) end
end

local monitor
local LEVELS = {[0] = 'Low', [1] = 'Medium', [2] = 'High', [3] = 'Epic', [4] = 'Cinematic'}
local function v(name, isFloat) local x = read_name(name, isFloat); return x == nil and '-' or fmt(x) end
local function by_id(id) for _, r in ipairs(ROWS) do if r.id == id then return r end end end

local monCache, monT = nil, -1
local function monitor_lines()
    local L = {}
    local function add(t) L[#L + 1] = t end
    add(string.format('Script: %s   %s   changes written this session: %d', S.master and 'enabled' or 'disabled',
        st.clock < START_DELAY and string.format('starts in %d s', math.ceil(START_DELAY - st.clock))
            or string.format('running %d s', math.floor(st.clock)), st.writes))
    if st.pending then add('  Changes waiting: applying one every 0.5 s') end

    add('-')
    add('MEMORY')
    do
        local r = by_id('reflections')
        local g = game_values(r)
        add('  Lumen reflections off')
        add(string.format('    r.Lumen.Reflections.Allow   game %s   target %s   now %s   %s', g and fmt(g[1]) or '-',
            active_sel(r) > 0 and '0' or '-', v('r.Lumen.Reflections.Allow'),
            st.status.reflections or (active_sel(r) > 0 and 'ON' or 'game value')))
    end
    for _, id in ipairs({'atlas', 'pool'}) do
        local r = by_id(id)
        local c = r.cvars[1]
        local g = game_values(r)
        local sel = active_sel(r)
        local want = '-'
        if sel > 0 then
            local vals, cut = target(r, sel)
            if vals then want = string.format('%s (%d%% of game)', fmt(vals[1]), round((1 - (cut or 0)) * 100)) end
        end
        add(string.format('  %s', r.label))
        add(string.format('    %s   game %s   target %s   now %s   %s', c, g and fmt(g[1]) or '-', want,
            v(c), st.status[id] or (sel > 0 and 'ON' or 'game value')))
    end
    add('  Lumen surface cache only saves VRAM while Lumen GI or Lumen reflections run (see below).')

    add('-')
    add('GI PERFORMANCE')
    local lvl = gi_level()
    local r = by_id('ultra')
    local giAllow, giMethod = read_name('r.Lumen.DiffuseIndirect.Allow'), read_name('r.DynamicGlobalIlluminationMethod')
    local reflM, reflA = read_name('r.ReflectionMethod'), read_name('r.Lumen.Reflections.Allow')
    add(string.format('  In-game Global Illumination: %s (sg %s)   Ultra Performance: %s%s', LEVELS[lvl] or '?',
        lvl == nil and '-' or tostring(lvl), (S.sel.ultra or 0) == 1 and 'On' or 'Off',
        active_sel(r) > 0 and '  (active)' or ''))
    add(string.format('    r.Lumen.DiffuseIndirect.Allow   game %s   now %s   %s',
        S.stock['r.Lumen.DiffuseIndirect.Allow'] ~= nil and fmt(S.stock['r.Lumen.DiffuseIndirect.Allow']) or v('r.Lumen.DiffuseIndirect.Allow'),
        v('r.Lumen.DiffuseIndirect.Allow'), st.status.ultra or (active_sel(r) > 0 and 'ON' or 'game value')))
    add(string.format('    Lumen GI: %s   (GI method %s, 1 = Lumen)', (giMethod == 1 and giAllow ~= 0) and 'RUNNING' or 'off',
        giMethod == nil and '-' or fmt(giMethod)))
    add(string.format('    Lumen reflections: %s   (r.ReflectionMethod %s, r.Lumen.Reflections.Allow %s)',
        (reflM == 1 and reflA ~= 0) and 'RUNNING' or 'off', v('r.ReflectionMethod'), v('r.Lumen.Reflections.Allow')))
    add(string.format('    Hardware ray tracing: r.RayTracing %s, r.Lumen.HardwareRayTracing %s',
        v('r.RayTracing'), v('r.Lumen.HardwareRayTracing')))

    add('-')
    add('Recent changes (newest first)')
    if #st.recent == 0 then add('  none yet') end
    for _, line in ipairs(st.recent) do add('  ' .. line) end
    if st.lastError then add('Last error: ' .. st.lastError) end
    add('  Total VRAM use can\'t be read from a script; use the benchmark tool or an overlay for that.')
    return L
end

monitor = function()
    if not imgui.tree_node('Advanced Monitor') then return end
    if st.clock < START_DELAY then
        imgui.text(string.format('  Starts reading in %d s.', math.ceil(START_DELAY - st.clock)))
    else
        if monCache == nil or st.clock - monT >= 1.0 then
            local ok, lines = pcall(monitor_lines)
            monCache = ok and lines or {'monitor error: ' .. tostring(lines)}
            monT = st.clock
        end
        for _, t in ipairs(monCache) do if t == '-' then imgui.separator() else imgui.text(t) end end
    end
    imgui.tree_pop()
end

local function draw()
    imgui.text('VRAM SAVER (SV20)')
    local c, v = imgui.checkbox('Enable VRAM Saver', S.master)
    if c then S.master = v; changed() end
    dim('      Turns on everything below. Untick = game values.')
    if st.clock < START_DELAY then
        dim(string.format('      Starts in %d s (waits after launch so the headset view sets up first).', math.ceil(START_DELAY - st.clock)))
    elseif st.pending then dim('      Applying changes one at a time...') end
    imgui.begin_disabled(not S.master)

    imgui.separator()
    imgui.text('MEMORY')
    c, v = imgui.checkbox('Lumen reflections off', S.reflections)
    if c then S.reflections = v; changed() end
    if st.status.reflections then imgui.same_line(); imgui.text('  ' .. st.status.reflections) end
    dim('      r.Lumen.Reflections.Allow 0 - reflections only, Lumen GI stays as set in game. Untick = game value.')
    for _, r in ipairs(ROWS) do if r.group == 'mem' then row_ui(r) end end

    imgui.separator()
    imgui.text('AMBIENT OCCLUSION (works for Global Illumination LOW setting only)')
    dim('      Set Cvars r.AmbientOcclusionLevels to 1 or higher to enable this section.')
    local aoOff = not ao_on()
    if aoOff then imgui.begin_disabled() end
    c, v = imgui.checkbox('Compute shader (r.AmbientOcclusion.Compute 1)', S.ao_compute)
    if c then S.ao_compute = v; changed() end
    width(200)
    c, v = imgui.slider_float('Radius scale (r.AmbientOcclusionRadiusScale)', S.ao_radius, 0.0, 10.0, '%.2f')
    if c then S.ao_radius = v; changed() end
    dim('      1.0 = game value. Higher reduces the left/right eye mismatch;')
    dim('      low values give a stylized, comic-book look.')
    for _, id in ipairs({'ao_compute', 'ao_radius'}) do
        if st.status[id] then imgui.text('      ' .. id .. ': ' .. st.status[id]) end
    end
    if imgui.button('Reset AO to defaults') then S.ao_compute = false; S.ao_radius = AO_RESET_RADIUS; changed() end
    if aoOff then imgui.end_disabled(); dim('      Ambient occlusion is 0 (off): section locked.') end

    imgui.separator()
    imgui.text('GI PERFORMANCE (experimental)')
    dim('      Choose Global Illumination Med, High, or Epic to enable. Tune the image using the Ambient')
    dim('      Occlusion settings above and VR Picture/Brightness settings, in the Script UI Add-on effects.')
    dim('      It\'s possible to turn on/off during play (may need to wait for framegen to resync), but')
    dim('      better to restart.')
    for _, r in ipairs(ROWS) do if r.group == 'ultra' then row_ui(r) end end

    imgui.end_disabled()
    imgui.separator()
    if st.lastError then imgui.text('Last error: ' .. st.lastError) end
    monitor()
end

uevr.lua.add_script_panel('SWGR - VRAM saver', function()
    local ok, err = pcall(draw)
    if not ok then st.lastError = tostring(err); imgui.text('VRAM saver menu error: ' .. st.lastError) end
end)

log('loaded')
