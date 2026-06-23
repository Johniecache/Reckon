-- =============================================================================
--  Reckon  -  a lightweight live DPS meter for The Elder Scrolls Online
-- =============================================================================
--  WHAT IT SHOWS
--    * You              -> your real DPS, read straight from your own combat
--                          events (incl. pet / companion). Always accurate.
--    * Each group member -> exact DPS for anyone running Hodor Reflexes or any
--                          addon built on LibGroupCombatStats (shared over the
--                          sanctioned group-data channel). Per-player mode.
--    * Unknown ~        -> everyone you CANNOT measure individually, combined:
--                          (estimated group total) - (you + everyone sharing).
--                          The group total is estimated from the target's
--                          health drain, so this fills the gap for players who
--                          don't have a compatible addon. Rough, not a parse.
--    * Group estimate   -> a compact "You vs Others ~" view (toggle).
--
--  TWO DATA SOURCES, COMBINED
--    A. LibGroupCombatStats  -> exact per-player numbers, but only for sharers.
--    B. Target health drain  -> a true group TOTAL incl. non-sharers, but not
--                               attributable to individuals.
--    Unknown ~ = B - (sum of A). It sharpens toward a single player as more of
--    the group shares. We self-calibrate A's units against your own known DPS
--    so the magnitudes line up regardless of the library's encoding.
--
--  SAFETY: sharing goes only through LibGroupCombatStats (the rate-limited,
--  Hodor-compatible channel). We never roll our own broadcast -> no kick risk.
--  Everything degrades gracefully: with no library installed, Reckon still runs
--  in group-estimate mode as a standalone addon.
-- =============================================================================

local Reckon = {}

local COLORS = {
    you    = { 0.20, 0.80, 0.74 },
    others = { 0.45, 0.55, 0.75 },
}
local PALETTE = {
    { 0.91, 0.45, 0.42 }, { 0.45, 0.70, 0.95 }, { 0.55, 0.80, 0.45 }, { 0.85, 0.65, 0.35 },
    { 0.75, 0.55, 0.90 }, { 0.40, 0.80, 0.78 }, { 0.90, 0.78, 0.40 }, { 0.78, 0.50, 0.62 },
    { 0.60, 0.75, 0.55 }, { 0.50, 0.62, 0.88 }, { 0.86, 0.58, 0.45 },
}

local UI = {
    body      = { 0.05, 0.05, 0.06, 0.94 },   -- window background
    bar       = { 0.12, 0.12, 0.15, 0.97 },   -- header / footer strips
    track     = { 1.00, 1.00, 1.00, 0.05 },   -- empty part of a row
    selftrack = { 1.00, 1.00, 1.00, 0.12 },   -- YOUR row gets a faint highlight
    gloss     = { 1.00, 1.00, 1.00, 0.13 },   -- highlight strip over a fill
    title     = { 0.97, 0.81, 0.46, 1.00 },   -- header title (gold)
    text      = { 0.97, 0.98, 1.00, 1.00 },   -- row text
    dim       = { 0.70, 0.74, 0.80, 1.00 },   -- header / footer text
}

local CLASS_COLORS = {
    [1]   = { 0.85, 0.42, 0.24 },   -- Dragonknight  (fire / poison)
    [2]   = { 0.36, 0.58, 0.95 },   -- Sorcerer      (storm)
    [3]   = { 0.80, 0.32, 0.48 },   -- Nightblade    (shadow)
    [4]   = { 0.48, 0.76, 0.38 },   -- Warden        (nature)
    [5]   = { 0.62, 0.42, 0.85 },   -- Necromancer   (death)
    [6]   = { 0.93, 0.80, 0.36 },   -- Templar       (light)
    [117] = { 0.27, 0.76, 0.72 },   -- Arcanist      (Apocrypha)
}

local FONT_TITLE = "$(BOLD_FONT)|19|soft-shadow-thin"
local FONT_ROW   = "$(BOLD_FONT)|16|soft-shadow-thin"
local FONT_VALUE = "$(MEDIUM_FONT)|16|soft-shadow-thin"
local FONT_META  = "$(MEDIUM_FONT)|15|soft-shadow-thin"

local function clip(s, n)
    s = s or ""
    if #s > n then return s:sub(1, n - 1) .. ".." end
    return s
end

local COUNTED = {
    [ACTION_RESULT_DAMAGE]            = true,
    [ACTION_RESULT_CRITICAL_DAMAGE]   = true,
    [ACTION_RESULT_DOT_TICK]          = true,
    [ACTION_RESULT_DOT_TICK_CRITICAL] = true,
    [ACTION_RESULT_BLOCKED_DAMAGE]    = true,
}

local HEAL_COUNTED = {
    [ACTION_RESULT_HEAL]              = true,
    [ACTION_RESULT_CRITICAL_HEAL]     = true,
    [ACTION_RESULT_HOT_TICK]          = true,
    [ACTION_RESULT_HOT_TICK_CRITICAL] = true,
}

local UI_UPDATE = "ReckonUIUpdate"
local HP_POLL   = "ReckonHpPoll"

local function norm(name)
    name = name or ""
    return (name:gsub("^@", "")):lower()
end

-- =============================================================================
--  YOUR DAMAGE  (combat events, filtered to player + pet at registration)
-- =============================================================================
local function OnCombatEvent(_, result, _, abilityName, _, _, _, _, _, _, hitValue, _, _, _, _, _, abilityId)
    if not hitValue or hitValue <= 0 then return end
    if COUNTED[result] then
        Reckon:AddYourDamage(hitValue, abilityId, abilityName)
    elseif HEAL_COUNTED[result] then
        Reckon:AddYourHealing(hitValue, abilityId, abilityName)
    end
end

function Reckon:AddYourDamage(amount, abilityId, abilityName)
    local f = self.fight
    if not f.active then return end
    if not f.startMs then f.startMs = GetGameTimeMilliseconds() end
    f.yourDamage = f.yourDamage + amount
    if abilityId then
        local a = f.abilities[abilityId]
        if not a then
            a = { name = abilityName or "", dmg = 0, hits = 0 }
            f.abilities[abilityId] = a
        end
        a.dmg  = a.dmg + amount
        a.hits = a.hits + 1
        if (not a.name or a.name == "") and abilityName and abilityName ~= "" then
            a.name = abilityName
        end
    end
end

function Reckon:AddYourHealing(amount, abilityId, abilityName)
    local f = self.fight
    if not f.active then return end
    if not f.startMs then f.startMs = GetGameTimeMilliseconds() end
    f.yourHealing = f.yourHealing + amount
    if abilityId then
        local a = f.healAbilities[abilityId]
        if not a then
            a = { name = abilityName or "", dmg = 0, hits = 0 }
            f.healAbilities[abilityId] = a
        end
        a.dmg  = a.dmg + amount
        a.hits = a.hits + 1
        if (not a.name or a.name == "") and abilityName and abilityName ~= "" then
            a.name = abilityName
        end
    end
end

-- =============================================================================
--  GROUP TOTAL ESTIMATE  (target health drain -> includes non-sharers)
-- =============================================================================
function Reckon:AccrueUnit(tag)
    local cur  = GetUnitPower(tag, COMBAT_MECHANIC_FLAGS_HEALTH)
    local name = GetUnitName(tag)
    local key  = (name ~= "" and name) or tag
    local last = self.fight.trackedHealth[key]
    self.fight.trackedHealth[key] = cur
    if last and cur < last then return last - cur end
    return 0
end

function Reckon:PollHealth()
    local f = self.fight
    if not f.active then return end
    local added, anyBoss = 0, false
    for i = 1, 6 do
        local tag = "boss" .. i
        if DoesUnitExist(tag) then
            anyBoss = true
            added = added + self:AccrueUnit(tag)
        end
    end
    if anyBoss then
        f.sawBoss = true
        if not f.bossName then
            local bn = GetUnitName("boss1")
            if bn and bn ~= "" then f.bossName = bn end
        end
    end
    if not anyBoss then
        if DoesUnitExist("reticleover") and GetUnitReaction("reticleover") == UNIT_REACTION_HOSTILE then
            added = added + self:AccrueUnit("reticleover")
        end
    end
    if added > 0 then
        if not f.startMs then f.startMs = GetGameTimeMilliseconds() end
        f.groupDamage = f.groupDamage + added
    end
end

-- =============================================================================
--  FIGHT LIFECYCLE
-- =============================================================================
function Reckon:ResetFight()
    self.fight.active        = false
    self.fight.startMs       = nil
    self.fight.endMs         = nil
    self.fight.yourDamage    = 0
    self.fight.groupDamage   = 0
    self.fight.yourHealing   = 0
    self.fight.trackedHealth = {}
    self.fight.abilities     = {}
    self.fight.healAbilities = {}
    self.fight.sawBoss       = false
    self.fight.bossName      = nil
    self.fight.index         = nil
end

function Reckon:GetElapsedSeconds()
    local f = self.fight
    if not f.startMs then return 0 end
    local endMs = f.endMs or GetGameTimeMilliseconds()
    return math.max((endMs - f.startMs) / 1000, 0)
end

function Reckon:MyRawDps()
    local e = self:GetElapsedSeconds()
    return e > 0 and (self.fight.yourDamage / e) or 0
end

function Reckon:MyRawHps()
    local e = self:GetElapsedSeconds()
    return e > 0 and (self.fight.yourHealing / e) or 0
end

function Reckon:MyName()
    local n = GetUnitName("player")
    return (n and n ~= "") and n or "You"
end

function Reckon:GroupTotalEst()
    local e = self:GetElapsedSeconds()
    return e > 0 and (self.fight.groupDamage / e) or 0
end

function Reckon:OnCombatState(inCombat)
    if inCombat then
        local now     = GetGameTimeMilliseconds()
        local resetMs = (self.sv.resetDelay or 6) * 1000
        local resume  = self.fight.startMs and self.fight.endMs
                        and (now - self.fight.endMs) <= resetMs
        if resume then
            self.fight.endMs = nil
        else
            self:ResetFight()
            self.fightCount  = (self.fightCount or 0) + 1
            self.fight.index = self.fightCount
        end
        self.histPos = 0
        self.fight.active = true
        EVENT_MANAGER:RegisterForUpdate(HP_POLL,   100, function() self:PollHealth() end)
        EVENT_MANAGER:RegisterForUpdate(UI_UPDATE, self.sv.updateMs or 200, function() self:Render() end)
        self:Render()
    else
        self.fight.active = false
        self.fight.endMs  = GetGameTimeMilliseconds()
        EVENT_MANAGER:UnregisterForUpdate(HP_POLL)
        EVENT_MANAGER:UnregisterForUpdate(UI_UPDATE)
        self:SnapshotFight()
        self:Render()
        if self.sv.printSummary then self:PrintSummary() end
    end
end

-- =============================================================================
--  DATA -> ROWS
-- =============================================================================
function Reckon:BuildEntriesGroup()
    local myRaw    = self:MyRawDps()
    local reliable = self.fight.sawBoss
    local groupEst = reliable and math.max(self:GroupTotalEst(), myRaw) or myRaw
    local others   = reliable and math.max(groupEst - myRaw, 0) or 0
    local entries  = { { label = self:MyName(), dps = myRaw, key = "you", isYou = true, unit = "player" } }
    if reliable and (others > 0 or (GetGroupSize() or 0) > 1) then
        entries[#entries + 1] = { label = "Others ~", dps = others, key = "est", est = true }
    end
    return entries, groupEst
end

function Reckon:BuildEntriesPlayers()
    local myRaw   = self:MyRawDps()
    local entries = { { label = self:MyName(), dps = myRaw, key = "you", isYou = true, unit = "player" } }
    local sumKnown = myRaw

    local lgcs = self.lgcs
    if lgcs then
        local me    = norm(GetDisplayName())
        local stats = lgcs:GetGroupStats() or {}

        for _, s in pairs(stats) do
            local dp = s.dps
            if dp and (dp.dps or 0) > 0 and norm(s.displayName) == me and myRaw > 0 then
                local sc = myRaw / dp.dps
                if sc > 10 and sc < 100000 then self.libScale = sc end
            end
        end

        for tag, s in pairs(stats) do
            local dp = s.dps
            if dp and (dp.dps or 0) > 0 and norm(s.displayName) ~= me then
                local raw  = dp.dps * (self.libScale or 1000)
                local name = (s.name and s.name ~= "" and s.name) or (s.displayName or "?")
                sumKnown = sumKnown + raw
                entries[#entries + 1] = { label = name, dps = raw, key = tostring(tag), unit = tag }
            end
        end
    end

    local reliable = self.fight.sawBoss
    local groupEst = reliable and math.max(self:GroupTotalEst(), sumKnown) or sumKnown
    local unknown  = reliable and math.max(groupEst - sumKnown, 0) or 0
    if reliable and unknown > 0 and (GetGroupSize() or 0) > 1 then
        entries[#entries + 1] = { label = "Unknown ~", dps = unknown, key = "est", est = true }
    end
    return entries, groupEst
end

function Reckon:BuildEntriesHeal()
    local entries, total = {}, 0
    local lgcs = self.lgcs

    if lgcs then
        local me, meFound, known = norm(GetDisplayName()), false, {}
        for tag, s in pairs(lgcs:GetGroupStats() or {}) do
            local hp = s.hps
            if hp and (hp.hps or 0) > 0 then
                local isMe = norm(s.displayName) == me
                if isMe then meFound = true end
                known[#known + 1] = {
                    label = isMe and self:MyName() or ((s.name and s.name ~= "" and s.name) or s.displayName or "?"),
                    dps   = hp.hps * 1000,
                    key   = isMe and "you" or tostring(tag),
                    unit  = isMe and "player" or tag,
                    isYou = isMe,
                }
            end
        end
        if not meFound then
            known[#known + 1] = { label = self:MyName(), dps = self:MyRawHps(), key = "you", isYou = true, unit = "player" }
        end

        if self.sv.displayMode == "players" then
            for _, k in ipairs(known) do entries[#entries + 1] = k; total = total + k.dps end
        else
            local you, others = 0, 0
            for _, k in ipairs(known) do
                total = total + k.dps
                if k.isYou then you = k.dps else others = others + k.dps end
            end
            entries[#entries + 1] = { label = self:MyName(), dps = you, key = "you", isYou = true, unit = "player" }
            if others > 0 then entries[#entries + 1] = { label = "Others", dps = others, key = "est", est = true } end
        end
    else
        local myRaw = self:MyRawHps()
        entries[#entries + 1] = { label = self:MyName(), dps = myRaw, key = "you", isYou = true, unit = "player" }
        total = myRaw
    end

    return entries, total
end

function Reckon:BuildEntries()
    if self.sv.metric == "heal" then
        return self:BuildEntriesHeal()
    end
    if self.sv.displayMode == "players" and self.useSharedData then
        return self:BuildEntriesPlayers()
    end
    return self:BuildEntriesGroup()
end

function Reckon:PaletteFor(key)
    self.colorByKey = self.colorByKey or {}
    local c = self.colorByKey[key]
    if not c then
        self.colorIdx = (self.colorIdx or 0) + 1
        c = PALETTE[((self.colorIdx - 1) % #PALETTE) + 1]
        self.colorByKey[key] = c
    end
    return c
end

function Reckon:ColorForEntry(e)
    if e.est then return COLORS.others end
    if e.unit then
        local cc = CLASS_COLORS[GetUnitClassId(e.unit)]
        if cc then return cc end
    end
    return self:PaletteFor(e.key)
end

function Reckon:AbilityEntriesFrom(tbl, elapsed)
    local entries, total = {}, 0
    for id, a in pairs(tbl or {}) do
        local dmg = a.dmg or 0
        if dmg > 0 then
            total = total + dmg
            entries[#entries + 1] = {
                label = (a.name and a.name ~= "") and a.name or ("Ability " .. tostring(id)),
                dps   = (elapsed > 0) and (dmg / elapsed) or 0,
                key   = "ab" .. tostring(id),
            }
        end
    end
    return entries, total
end

function Reckon:BuildAbilityEntries()
    local src = (self.sv.metric == "heal") and self.fight.healAbilities or self.fight.abilities
    return self:AbilityEntriesFrom(src, self:GetElapsedSeconds())
end

-- =============================================================================
--  FIGHT HISTORY  (page back through finished fights)
-- =============================================================================
local HISTORY_MAX = 15

function Reckon:SnapshotFight()
    local f = self.fight
    if not f.startMs then return end
    local dur = self:GetElapsedSeconds()
    if dur < 1 then return end

    local label = (f.bossName and f.bossName ~= "") and f.bossName
                  or ("Fight " .. tostring(f.index or (#self.history + 1)))

    local dmgE, dmgT
    if self.useSharedData and self.sv.displayMode == "players" then
        dmgE, dmgT = self:BuildEntriesPlayers()
    else
        dmgE, dmgT = self:BuildEntriesGroup()
    end
    local healE, healT = self:BuildEntriesHeal()
    local dAbE,  dAbT  = self:AbilityEntriesFrom(f.abilities, dur)
    local hAbE,  hAbT  = self:AbilityEntriesFrom(f.healAbilities, dur)

    local snap = {
        id = f.startMs, label = label, dur = dur, sawBoss = f.sawBoss,
        youDps = self:MyRawDps(), youHps = self:MyRawHps(),
        dmg  = { entries = dmgE,  total = dmgT },  heal     = { entries = healE, total = healT },
        dmgAbil = { entries = dAbE, total = dAbT }, healAbil = { entries = hAbE, total = hAbT },
    }

    local h = self.history
    if h[#h] and h[#h].id == snap.id then
        h[#h] = snap
    else
        h[#h + 1] = snap
        while #h > HISTORY_MAX do table.remove(h, 1) end
    end
end

function Reckon:ViewSnapshot()
    if (self.histPos or 0) <= 0 then return nil end
    return self.history[#self.history - self.histPos + 1]
end

function Reckon:HistoryStep(delta)
    self.histPos = math.max(0, math.min(#self.history, (self.histPos or 0) + delta))
    self.abilityView = false
    self:Render()
end

-- =============================================================================
--  FORMATTERS
-- =============================================================================
function Reckon:FmtNum(v)
    v = v or 0
    if v >= 1000000 then return string.format("%.2fM", v / 1000000) end
    if v >= 1000    then return string.format("%.1fk", v / 1000)    end
    return string.format("%d", math.floor(v + 0.5))
end

function Reckon:FmtTime(s)
    s = math.floor(s or 0)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function Reckon:PrintSummary()
    local entries, groupEst = self:BuildEntries()
    if self:GetElapsedSeconds() < 1 then return end
    local yourDps = 0
    for _, e in ipairs(entries) do if e.isYou then yourDps = e.dps end end
    local pct = groupEst > 0 and (yourDps / groupEst * 100) or 0
    d(string.format("|cFFD700Reckon|r %s  -  You %s  (~%d%% of ~%s group)",
        self:FmtTime(self:GetElapsedSeconds()), self:FmtNum(yourDps),
        math.floor(pct + 0.5), self:FmtNum(groupEst)))
end

function Reckon:PrintStatus()
    d("|cFFD700Reckon status|r")
    d("  LibGroupCombatStats: " .. (LibGroupCombatStats and "|c66FF66found|r" or "|cFF6666NOT found|r (per-player needs it + LibCombat + LibGroupBroadcast)"))
    d("  sharing my DPS: " .. (self.sv.shareMyDps and "on" or "off"))
    d("  per-player active: " .. (self.useSharedData and "yes" or "no (running group-estimate mode)"))
    d("  ESO group size: " .. (GetGroupSize() or 0))
    if not self.lgcs then return end
    d("  library group size: " .. (self.lgcs:GetGroupSize() or 0))
    local me, n = norm(GetDisplayName()), 0
    for tag, s in pairs(self.lgcs:GetGroupStats() or {}) do
        n = n + 1
        local dp = s.dps or {}
        local hp = s.hps or {}
        d(string.format("   - %s %s%s  dps=%s  hps=%s",
            tostring(tag),
            tostring(s.name ~= "" and s.name or s.displayName),
            (norm(s.displayName) == me) and " (you)" or "",
            tostring(dp.dps or 0), tostring(hp.hps or 0)))
    end
    if n == 0 then d("   (library has no group member data yet - fight something together first)") end
end

-- =============================================================================
--  UI  (built in pure Lua, no XML / no external UI deps)
-- =============================================================================
function Reckon:Backdrop(name, parent, r, g, b, a)
    local bd = WINDOW_MANAGER:CreateControl(name, parent, CT_BACKDROP)
    bd:SetCenterColor(r, g, b, a)
    bd:SetEdgeColor(0, 0, 0, 0)
    bd:SetEdgeTexture("", 8, 1, 0)
    bd:SetInsets(0, 0, 0, 0)
    return bd
end

function Reckon:CreateRow(i)
    local wm  = WINDOW_MANAGER
    local row = wm:CreateControl("ReckonRow" .. i, self.window, CT_CONTROL)
    row:SetDimensions(self.rowW, self.rowH)
    row:SetAnchor(TOPLEFT, self.window, TOPLEFT, 0, self.headerH + (i - 1) * self.rowH)

    local track = self:Backdrop("ReckonRow" .. i .. "Track", row, unpack(UI.track))
    track:SetAnchor(TOPLEFT,     row, TOPLEFT,     1, 1)
    track:SetAnchor(BOTTOMRIGHT, row, BOTTOMRIGHT, -1, 0)

    local fill = self:Backdrop("ReckonRow" .. i .. "Fill", row, COLORS.you[1], COLORS.you[2], COLORS.you[3], 0.9)
    fill:SetAnchor(TOPLEFT,    row, TOPLEFT,    1, 1)
    fill:SetAnchor(BOTTOMLEFT, row, BOTTOMLEFT, 1, 0)
    fill:SetWidth(0)

    local gloss = self:Backdrop("ReckonRow" .. i .. "Gloss", row, unpack(UI.gloss))
    gloss:SetAnchor(TOPLEFT, row, TOPLEFT, 1, 1)
    gloss:SetHeight(math.max(1, math.floor(self.rowH / 2)))
    gloss:SetWidth(0)

    local left = wm:CreateControl("ReckonRow" .. i .. "Left", row, CT_LABEL)
    left:SetFont(FONT_ROW)
    left:SetColor(unpack(UI.text))
    left:SetAnchor(LEFT, row, LEFT, 6, 0)

    local right = wm:CreateControl("ReckonRow" .. i .. "Right", row, CT_LABEL)
    right:SetFont(FONT_VALUE)
    right:SetColor(unpack(UI.text))
    right:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)
    right:SetAnchor(RIGHT, row, RIGHT, -6, 0)

    row:SetHidden(true)
    local rec = { row = row, track = track, fill = fill, gloss = gloss, left = left, right = right }
    row:SetMouseEnabled(true)
    row:SetHandler("OnMouseUp", function(_, button, upInside)
        if upInside then self:OnRowClick(rec.entry, button) end
    end)
    return rec
end

function Reckon:OnRowClick(entry, button)
    if button == MOUSE_BUTTON_INDEX_RIGHT then
        if self.abilityView then self.abilityView = false; self:Render() end
        return
    end
    if self.abilityView then
        self.abilityView = false; self:Render(); return
    end
    if not entry then return end
    if entry.isYou then
        self.abilityView = true; self:Render()
    elseif not entry.est and not self.hintedDrill then
        self.hintedDrill = true
        d("|cFFD700Reckon|r per-ability detail is only available for you - ESO doesn't share other players' abilities.")
    end
end

function Reckon:OpenSettings()
    if LibAddonMenu2 and self.lamPanel then
        LibAddonMenu2:OpenToPanel(self.lamPanel)
    else
        d("|cFFD700Reckon|r commands: /reckon mode | heal | abilities | lock | scale <n> | resetdelay <s>")
    end
end
function Reckon:ToggleMetric()
    self.sv.metric   = (self.sv.metric == "heal") and "damage" or "heal"
    self.abilityView = false
    self:Render()
end

function Reckon:ToggleMode()
    self.sv.displayMode = (self.sv.displayMode == "players") and "group" or "players"
    self.histPos        = 0
    self.abilityView    = false
    self:Render()
end

function Reckon:HeaderButton(name, text, onClick)
    local b = WINDOW_MANAGER:CreateControl(name, self.window, CT_LABEL)
    b:SetFont(FONT_META)
    b:SetColor(unpack(UI.dim))
    b:SetText(text)
    b:SetMouseEnabled(true)
    b:SetHandler("OnMouseUp", function(_, _, inside) if inside then onClick() end end)
    return b
end

function Reckon:UpdateHeaderButtons()
    if not self.btnMetric then return end
    self.btnMetric:SetText((self.sv.metric == "heal") and "HEAL" or "DMG")
    self.btnMetric:SetColor(unpack(UI.title))
    self.btnMode:SetText((self.sv.displayMode == "players") and "PLY" or "GRP")
    self.btnMode:SetColor(unpack(UI.title))
    if self.histPos < #self.history then self.btnOlder:SetColor(unpack(UI.title))
    else self.btnOlder:SetColor(0.35, 0.37, 0.40, 1) end
    if self.histPos > 0 then self.btnNewer:SetColor(unpack(UI.title))
    else self.btnNewer:SetColor(0.35, 0.37, 0.40, 1) end
end

function Reckon:CreateUI()
    local wm = WINDOW_MANAGER
    self.width      = 292
    self.headerH    = 24
    self.footerH    = 20
    self.rowH       = 21
    self.rowW       = self.width
    self.colorByKey = self.colorByKey or {}
    self.colorIdx   = self.colorIdx or 0

    local tlw = wm:CreateTopLevelWindow("ReckonWindow")
    tlw:SetDimensions(self.width, self.headerH + self.rowH + self.footerH)
    tlw:SetClampedToScreen(true)
    tlw:SetMouseEnabled(true)
    tlw:SetMovable(not self.sv.locked)
    tlw:SetHandler("OnMoveStop", function() self:SavePosition() end)
    self.window = tlw

    if self.sv.left and self.sv.top then
        tlw:ClearAnchors()
        tlw:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, self.sv.left, self.sv.top)
    else
        tlw:SetAnchor(CENTER, GuiRoot, CENTER, 0, -150)
    end
    tlw:SetScale(self.sv.scale or 1)

    local bg = self:Backdrop("ReckonBG", tlw, unpack(UI.body))
    bg:SetAnchor(TOPLEFT,     tlw, TOPLEFT,     0, 0)
    bg:SetAnchor(BOTTOMRIGHT, tlw, BOTTOMRIGHT, 0, 0)

    local header = self:Backdrop("ReckonHeader", tlw, unpack(UI.bar))
    header:SetAnchor(TOPLEFT,  tlw, TOPLEFT,  0, 0)
    header:SetAnchor(TOPRIGHT, tlw, TOPRIGHT, 0, 0)
    header:SetHeight(self.headerH)

    local title = wm:CreateControl("ReckonTitle", tlw, CT_LABEL)
    title:SetFont(FONT_TITLE)
    title:SetColor(unpack(UI.title))
    title:SetAnchor(LEFT, header, LEFT, 8, 0)
    title:SetText("Reckon")
    self.title = title

    local cog = wm:CreateControl("ReckonCog", header, CT_BUTTON)
    cog:SetDimensions(18, 18)
    cog:SetAnchor(RIGHT, header, RIGHT, -6, 0)
    cog:SetNormalTexture("EsoUI/Art/Menu/menuBar_settings_up.dds")
    cog:SetMouseOverTexture("EsoUI/Art/Menu/menuBar_settings_over.dds")
    cog:SetPressedTexture("EsoUI/Art/Menu/menuBar_settings_down.dds")
    cog:SetHandler("OnClicked", function() self:OpenSettings() end)

    self.btnNewer = self:HeaderButton("ReckonNewer", ">", function() self:HistoryStep(-1) end)
    self.btnNewer:SetAnchor(RIGHT, cog, LEFT, -8, 0)

    self.btnOlder = self:HeaderButton("ReckonOlder", "<", function() self:HistoryStep(1) end)
    self.btnOlder:SetAnchor(RIGHT, self.btnNewer, LEFT, -5, 0)

    self.btnMode = self:HeaderButton("ReckonModeBtn", "PLY", function() self:ToggleMode() end)
    self.btnMode:SetAnchor(RIGHT, self.btnOlder, LEFT, -10, 0)

    self.btnMetric = self:HeaderButton("ReckonMetricBtn", "DMG", function() self:ToggleMetric() end)
    self.btnMetric:SetAnchor(RIGHT, self.btnMode, LEFT, -8, 0)

    local footer = self:Backdrop("ReckonFooter", tlw, unpack(UI.bar))
    footer:SetAnchor(BOTTOMLEFT,  tlw, BOTTOMLEFT,  0, 0)
    footer:SetAnchor(BOTTOMRIGHT, tlw, BOTTOMRIGHT, 0, 0)
    footer:SetHeight(self.footerH)

    local total = wm:CreateControl("ReckonTotal", tlw, CT_LABEL)
    total:SetFont(FONT_META)
    total:SetColor(unpack(UI.dim))
    total:SetAnchor(LEFT, footer, LEFT, 8, 0)
    total:SetText("")
    self.totalLabel = total

    local time = wm:CreateControl("ReckonTime", tlw, CT_LABEL)
    time:SetFont(FONT_META)
    time:SetColor(unpack(UI.dim))
    time:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)
    time:SetAnchor(RIGHT, footer, RIGHT, -8, 0)
    time:SetText("")
    self.timeLabel = time

    self.rows = {}
    for i = 1, 14 do self.rows[i] = self:CreateRow(i) end
end

function Reckon:Render()
    if not self.window then return end
    local heal = (self.sv.metric == "heal")
    local snap = self:ViewSnapshot()
    local entries, pctDenom

    if snap then
        if self.abilityView then
            local box = heal and snap.healAbil or snap.dmgAbil
            entries  = box.entries
            pctDenom = (snap.dur > 0) and (box.total / snap.dur) or 0
            self.title:SetText(clip(snap.label, 12) .. (heal and " - Heals" or " - Abilities"))
            self.totalLabel:SetText("You " .. self:FmtNum(heal and snap.youHps or snap.youDps))
        else
            local box = heal and snap.heal or snap.dmg
            entries  = box.entries
            pctDenom = box.total
            self.title:SetText(string.format("%s  (%d/%d)", clip(snap.label, 13), self.histPos, #self.history))
            local est = (not heal) and snap.sawBoss
            self.totalLabel:SetText((est and "Total ~" or "Total ") .. self:FmtNum(box.total))
        end
        self.timeLabel:SetText(self:FmtTime(snap.dur))
    elseif self.abilityView then
        local ents, yourTotal = self:BuildAbilityEntries()
        local elapsed = self:GetElapsedSeconds()
        entries  = ents
        pctDenom = (elapsed > 0) and (yourTotal / elapsed) or 0
        self.title:SetText(clip(self:MyName(), 12) .. (heal and " - Heals" or " - Abilities"))
        self.totalLabel:SetText("You " .. self:FmtNum(heal and self:MyRawHps() or self:MyRawDps()))
        self.timeLabel:SetText(self:FmtTime(elapsed))
    else
        local ents, total = self:BuildEntries()
        entries  = ents
        pctDenom = total
        if heal then
            self.title:SetText("Healing Done")
            self.totalLabel:SetText("Total " .. self:FmtNum(total))
        else
            self.title:SetText("Damage Done")
            local est = self.fight.sawBoss
            self.totalLabel:SetText((est and "Total ~" or "Total ") .. self:FmtNum(total))
        end
        self.timeLabel:SetText(self:FmtTime(self:GetElapsedSeconds()))
    end

    self:UpdateHeaderButtons()

    table.sort(entries, function(a, b) return a.dps > b.dps end)
    local topDps = (entries[1] and entries[1].dps) or 0
    if topDps   <= 0 then topDps   = 1 end
    if pctDenom <= 0 then pctDenom = topDps end

    for i = 1, #self.rows do
        local r, e = self.rows[i], entries[i]
        if e then
            r.entry = e
            r.row:SetHidden(false)
            r.track:SetCenterColor(unpack(e.isYou and UI.selftrack or UI.track))
            local frac = e.dps / topDps
            frac = (frac < 0 and 0) or (frac > 1 and 1) or frac
            local w = math.max(1, (self.rowW - 2) * frac)
            r.fill:SetWidth(w)
            r.gloss:SetWidth(w)
            local c = self:ColorForEntry(e)
            r.fill:SetCenterColor(c[1], c[2], c[3], 0.92)
            local pct = pctDenom > 0 and (e.dps / pctDenom * 100) or 0
            r.left:SetText(string.format("%d. %s", i, clip(e.label, 15)))
            r.right:SetText(string.format("%s  %.1f%%", self:FmtNum(e.dps), pct))
        else
            r.entry = nil
            r.row:SetHidden(true)
        end
    end

    self.window:SetHeight(self.headerH + #entries * self.rowH + self.footerH)
end

function Reckon:SavePosition()
    if not self.window then return end
    self.sv.left = self.window:GetLeft()
    self.sv.top  = self.window:GetTop()
end

function Reckon:RunTest()
    local now = GetGameTimeMilliseconds()
    self.fightCount        = (self.fightCount or 0) + 1
    self.fight.startMs     = now - 8000
    self.fight.endMs       = now
    self.fight.sawBoss     = true
    self.fight.bossName    = "Target Dummy"
    self.fight.index       = self.fightCount
    self.fight.yourDamage  = 78000 * 8
    self.fight.groupDamage = 190000 * 8
    self.fight.abilities = {
        [1] = { name = "Force Pulse",       dmg = 31000 * 8, hits = 40 },
        [2] = { name = "Crystal Fragments", dmg = 22000 * 8, hits = 12 },
        [3] = { name = "Flame Reach",       dmg = 14000 * 8, hits = 16 },
        [4] = { name = "Light Attack",      dmg = 11000 * 8, hits = 30 },
    }
    self.fight.yourHealing = 42000 * 8
    self.fight.healAbilities = {
        [10] = { name = "Combat Prayer",   dmg = 18000 * 8, hits = 20 },
        [11] = { name = "Healing Springs", dmg = 15000 * 8, hits = 24 },
        [12] = { name = "Mutagen",         dmg =  9000 * 8, hits = 16 },
    }
    self:SnapshotFight()
    self.fight.startMs  = now - 20000
    self.fight.bossName = "Practice Dummy"
    self.fight.yourDamage, self.fight.groupDamage = 60000 * 12, 120000 * 12
    self:SnapshotFight()
    self.fight.startMs  = now - 8000
    self.fight.bossName = "Target Dummy"
    self.fight.yourDamage, self.fight.groupDamage = 78000 * 8, 190000 * 8
    self.histPos = 0
    self:Render()
    d("|cFFD700Reckon|r sample data + 2 history entries. Title bar drags; click your bar for abilities; DMG/HEAL, PLY/GRP and < > live in the header.")
end

-- =============================================================================
--  LibGroupCombatStats INTEGRATION
-- =============================================================================
function Reckon:IntegrateGroupStats()
    self.lgcs          = nil
    self.useSharedData = false
    self.libScale      = 1000

    local GCS = LibGroupCombatStats
    if not GCS then return end
    if not self.sv.shareMyDps then return end

    local obj = GCS.RegisterAddon("Reckon", { "DPS", "HPS" })
    if not obj then return end
    self.lgcs          = obj
    self.useSharedData = true

    local function refresh() self:Render() end
    if GCS.EVENT_GROUP_DPS_UPDATE  then obj:RegisterForEvent(GCS.EVENT_GROUP_DPS_UPDATE,  refresh) end
    if GCS.EVENT_PLAYER_DPS_UPDATE then obj:RegisterForEvent(GCS.EVENT_PLAYER_DPS_UPDATE, refresh) end
    if GCS.EVENT_GROUP_HPS_UPDATE  then obj:RegisterForEvent(GCS.EVENT_GROUP_HPS_UPDATE,  refresh) end
    if GCS.EVENT_PLAYER_HPS_UPDATE then obj:RegisterForEvent(GCS.EVENT_PLAYER_HPS_UPDATE, refresh) end
end

-- =============================================================================
--  SETTINGS
-- =============================================================================
function Reckon:BuildSettings()
    local LAM = LibAddonMenu2
    if not LAM then return end

    self.lamPanel = LAM:RegisterAddonPanel("ReckonPanel", {
        type = "panel", name = "Reckon", author = "you", version = "0.8.0",
        registerForRefresh = true, registerForDefaults = true,
    })
    LAM:RegisterOptionControls("ReckonPanel", {
        {
            type = "dropdown", name = "Metric", choices = { "Damage", "Healing" },
            tooltip = "Damage shows DPS (with the group estimate). Healing shows HPS for you and anyone sharing - no estimate for non-sharers.",
            getFunc = function() return self.sv.metric == "heal" and "Healing" or "Damage" end,
            setFunc = function(v) self.sv.metric = (v == "Healing") and "heal" or "damage"; self.abilityView = false; self:Render() end,
        },
        {
            type = "dropdown", name = "Display mode", choices = { "Per-player", "Group estimate" },
            tooltip = "Per-player shows a bar for each sharer plus an Unknown estimate. Group estimate is the compact You-vs-Others view.",
            getFunc = function() return self.sv.displayMode == "players" and "Per-player" or "Group estimate" end,
            setFunc = function(v) self.sv.displayMode = (v == "Per-player") and "players" or "group"; self:Render() end,
        },
        {
            type = "checkbox", name = "Share my DPS with the group",
            tooltip = "Exchanges DPS with Hodor Reflexes and any LibGroupCombatStats addon. Off = receive nothing, estimate only.",
            warning = "Requires /reloadui to take effect.",
            getFunc = function() return self.sv.shareMyDps end,
            setFunc = function(v) self.sv.shareMyDps = v end,
        },
        {
            type = "checkbox", name = "Print fight summary to chat",
            tooltip = "When a fight ends, post your DPS, the group estimate and your share to chat.",
            getFunc = function() return self.sv.printSummary end,
            setFunc = function(v) self.sv.printSummary = v end,
        },
        {
            type = "checkbox", name = "Lock window",
            getFunc = function() return self.sv.locked end,
            setFunc = function(v) self.sv.locked = v; self.window:SetMovable(not v) end,
        },
        {
            type = "slider", name = "Scale", min = 50, max = 200, step = 5,
            getFunc = function() return (self.sv.scale or 1) * 100 end,
            setFunc = function(v) self.sv.scale = v / 100; self.window:SetScale(v / 100) end,
        },
        {
            type = "slider", name = "Update interval (ms)", min = 100, max = 1000, step = 50,
            getFunc = function() return self.sv.updateMs or 200 end,
            setFunc = function(v) self.sv.updateMs = v end,
        },
        {
            type = "slider", name = "Reset delay (s)", min = 0, max = 60, step = 1,
            tooltip = "After a fight, keep the numbers on screen. Re-entering combat within this gap continues the same parse instead of wiping it.",
            getFunc = function() return self.sv.resetDelay or 6 end,
            setFunc = function(v) self.sv.resetDelay = v end,
        },
        {
            type = "button", name = "Reset position",
            func = function()
                self.window:ClearAnchors()
                self.window:SetAnchor(CENTER, GuiRoot, CENTER, 0, -150)
                self.sv.left, self.sv.top = nil, nil
            end,
        },
    })
end

-- =============================================================================
--  SLASH COMMANDS  ->  /reckon
-- =============================================================================
local function SlashHandler(args)
    args = (args or ""):lower()
    local cmd, rest = args:match("^(%S*)%s*(.*)$")

    if cmd == "" or cmd == "toggle" then
        Reckon.window:SetHidden(not Reckon.window:IsHidden())
    elseif cmd == "mode" then
        Reckon:ToggleMode()
        local extra = ""
        if Reckon.sv.displayMode == "players" and not Reckon.useSharedData then
            extra = " (no shared data - showing group estimate; install LibGroupCombatStats / Hodor)"
        end
        d("|cFFD700Reckon|r mode: " .. Reckon.sv.displayMode .. extra)
    elseif cmd == "heal" or cmd == "metric" then
        Reckon:ToggleMetric()
        d("|cFFD700Reckon|r metric: " .. (Reckon.sv.metric == "heal" and "Healing" or "Damage"))
    elseif cmd == "share" then
        Reckon.sv.shareMyDps = not Reckon.sv.shareMyDps
        d("|cFFD700Reckon|r share my DPS: " .. (Reckon.sv.shareMyDps and "ON" or "OFF") .. " (/reloadui to apply)")
    elseif cmd == "lock" then
        Reckon.sv.locked = true;  Reckon.window:SetMovable(false); d("|cFFD700Reckon|r locked.")
    elseif cmd == "unlock" then
        Reckon.sv.locked = false; Reckon.window:SetMovable(true);  d("|cFFD700Reckon|r unlocked - drag to move.")
    elseif cmd == "reset" then
        Reckon.window:ClearAnchors()
        Reckon.window:SetAnchor(CENTER, GuiRoot, CENTER, 0, -150)
        Reckon.sv.left, Reckon.sv.top = nil, nil
        d("|cFFD700Reckon|r position reset.")
    elseif cmd == "scale" then
        local s = tonumber(rest)
        if s and s >= 0.5 and s <= 2 then
            Reckon.sv.scale = s; Reckon.window:SetScale(s); d("|cFFD700Reckon|r scale " .. s)
        else
            d("|cFFD700Reckon|r usage: /reckon scale 0.5 - 2.0")
        end
    elseif cmd == "summary" then
        Reckon.sv.printSummary = not Reckon.sv.printSummary
        d("|cFFD700Reckon|r chat summary " .. (Reckon.sv.printSummary and "ON" or "OFF"))
    elseif cmd == "resetdelay" then
        local s = tonumber(rest)
        if s and s >= 0 and s <= 60 then
            Reckon.sv.resetDelay = s
            d("|cFFD700Reckon|r reset delay: " .. s .. "s (keeps the bar between pulls within this gap)")
        else
            d("|cFFD700Reckon|r usage: /reckon resetdelay 0 - 60  (seconds)")
        end
    elseif cmd == "status" or cmd == "dev" then
        Reckon:PrintStatus()
    elseif cmd == "history" or cmd == "older" then
        Reckon:HistoryStep(1)
    elseif cmd == "live" or cmd == "newer" then
        Reckon:HistoryStep(-1)
    elseif cmd == "abilities" or cmd == "drill" then
        Reckon.abilityView = not Reckon.abilityView
        Reckon:Render()
    elseif cmd == "settings" or cmd == "config" then
        Reckon:OpenSettings()
    elseif cmd == "test" then
        Reckon:RunTest()
    else
        d("|cFFD700Reckon|r: toggle | mode | heal | abilities | history | live | settings | share | summary | resetdelay <s> | lock | unlock | reset | scale <n> | test")
    end
end

-- =============================================================================
--  INIT
-- =============================================================================
function Reckon:Initialize()
    self.sv = ZO_SavedVars:NewAccountWide("ReckonSavedVars", 1, nil, {
        left = nil, top = nil, locked = false, scale = 1, updateMs = 200,
        printSummary = true, displayMode = "players", shareMyDps = true, resetDelay = 6,
        metric = "damage",
    })
    self.fight = { active = false, startMs = nil, endMs = nil, yourDamage = 0, groupDamage = 0,
                   yourHealing = 0, trackedHealth = {}, abilities = {}, healAbilities = {},
                   sawBoss = false, bossName = nil, index = nil }
    self.history    = {}
    self.histPos    = 0
    self.fightCount = 0

    self:CreateUI()
    self:BuildSettings()
    self:IntegrateGroupStats()

    EVENT_MANAGER:RegisterForEvent("ReckonDmgPlayer", EVENT_COMBAT_EVENT, OnCombatEvent)
    EVENT_MANAGER:AddFilterForEvent("ReckonDmgPlayer", EVENT_COMBAT_EVENT,
        REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
    EVENT_MANAGER:RegisterForEvent("ReckonDmgPet", EVENT_COMBAT_EVENT, OnCombatEvent)
    EVENT_MANAGER:AddFilterForEvent("ReckonDmgPet", EVENT_COMBAT_EVENT,
        REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER_PET)

    EVENT_MANAGER:RegisterForEvent("ReckonCombatState", EVENT_PLAYER_COMBAT_STATE,
        function(_, inCombat) self:OnCombatState(inCombat) end)

    SLASH_COMMANDS["/reckon"] = SlashHandler

    self:Render()
    local mode = self.useSharedData and "per-player ready" or "group-estimate mode"
    d("|cFFD700Reckon|r loaded (" .. mode .. ").  /reckon for options.")
end

EVENT_MANAGER:RegisterForEvent("Reckon", EVENT_ADD_ON_LOADED, function(_, name)
    if name ~= "Reckon" then return end
    EVENT_MANAGER:UnregisterForEvent("Reckon", EVENT_ADD_ON_LOADED)
    Reckon:Initialize()
end)
