-- ui.lua - vape-style Drawing UI library for Matcha
-- Look matches the confirmed-good single-box design:
--   box fill (28,28,28) / section labels (219,219,219) / white divider
--   widget rows (156,156,156), clickable + press highlight, draggable,
--   RightShift toggle.
--
-- CRITICAL quirk (learned the hard way on this build):
--   * Never write Visible=false on a Drawing object - it can permanently
--     kill it (it stops rendering forever). To hide, objects are parked
--     off-screen instead. Visible=true is written exactly once per object.
--   * Never set Transparency on filled squares.
--   * Avoid pure red.
--
-- Usage:
--   local Win = UI.Window.new({})
--   local Main = Win:Section("Main")
--   Main:Button("test", function() print("[ui] clicked") end)
--   Main:Toggle("AutoClicker", true, function(v) print("ac =", v) end)
--   Main:Keybind("Mode", function(vk) print("bound", vk) end)
--   Win:Start()

local VK_RSHIFT = 0xA1
local DRAG_THRESHOLD = 3
local RUN_KEY = "__UI_MENU"
local OFFSCREEN = Vector2.new(-30000, -30000)

local BOX_BG    = Color3.fromRGB(28, 28, 28)
local PRESS_BG  = Color3.fromRGB(94, 94, 94)
local LINE      = Color3.new(1, 1, 1)
local LABEL_CL  = Color3.fromRGB(219, 219, 219)
local ROW_CL    = Color3.fromRGB(156, 156, 156)
local ON_CL     = Color3.new(0, 1, 0)

local FONT_BOLD = Drawing.Fonts.SystemBold

local BOX_W = 248
local SEC_H = 38  -- section label zone (divider sits at its bottom)
local ROW_H = 30
local ROW_GAP = 4
local SEC_GAP = 8
local END_PAD = 8

local ROW_STEP = ROW_H + ROW_GAP

local function inRect(px, py, x, y, w, h)
    return px >= x and px <= x + w and py >= y and py <= y + h
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil, nil
end

-- keys that a keybind can capture
local BIND_KEYS = {}
for i = 0x30, 0x39 do table.insert(BIND_KEYS, i) end              -- 0-9
for i = 0x41, 0x5A do table.insert(BIND_KEYS, i) end              -- A-Z
for i = 0x70, 0x7B do table.insert(BIND_KEYS, i) end              -- F1-F12
BIND_KEYS[#BIND_KEYS + 1] = 0x20 -- space

local KEY_NAME = {}
for k = 0x41, 0x5A do KEY_NAME[k] = string.char(k) end
for k = 0x30, 0x39 do KEY_NAME[k] = string.char(k) end
KEY_NAME[0x20] = "Space"
for i = 0, 11 do KEY_NAME[0x70 + i] = "F" .. (i + 1) end

local UI = {}
UI.Window = {}
UI.Window.__index = UI.Window

-- multi-window registry: each fresh ui.lua load tears down every window from
-- a previous run, then registers windows as they are created in this run.
local cur = _G[RUN_KEY]
if cur then
    local removed = 0
    if type(cur) == "table" and cur.sections then
        pcall(function() cur:Destroy() end)
        removed = 1
    elseif type(cur) == "table" then
        for _, w in ipairs(cur) do
            pcall(function() w:Destroy() end)
            removed = removed + 1
        end
    end
    if removed > 0 then print("[ui] removed previous instance") end
end
local WINDOWS = {}
_G[RUN_KEY] = WINDOWS

local function arrangeWindow(w)
    local vw, vh = 1920, 1080
    local cam = game.Workspace and game.Workspace.CurrentCamera
    if cam and cam.ViewportSize then
        vw, vh = cam.ViewportSize.X, cam.ViewportSize.Y
    end
    local estH = END_PAD
    for _, sec in ipairs(w.sections) do
        estH = estH + SEC_H + SEC_GAP + #sec.widgets * ROW_STEP
    end
    local idx = 1
    for i, o in ipairs(WINDOWS) do
        if o == w then idx = i break end
    end
    local n = idx - 1
    local gap = 16
    local totalW = #WINDOWS * BOX_W + (math.max(0, #WINDOWS - 1) * gap)
    local x = (vw - totalW) / 2 + n * (BOX_W + gap)
    local y = (vh - estH) / 2
    return Vector2.new(math.max(4, x), math.max(4, y))
end

-- note: this build renders Text only while Visible=true is written (proven:
-- probe text + earlier menu both re-wrote it every frame). So always write
-- Visible=true, never false; hiding is done by parking off-screen.
local function wShow(w, o)
    if not o then return end
    pcall(function() o.Visible = true end)
end

local function wPark(o)
    if not o then return end
    pcall(function() o.Position = OFFSCREEN end)
end

function UI.Window.new(opts)
    opts = opts or {}
    local w = setmetatable({}, UI.Window)
    w.pos = opts.Position
    w.toggleKey = opts.ToggleKey or VK_RSHIFT
    w.open = false
    w.running = false
    w.sections = {}
    w.drop = {}   -- every Drawing object (park + cleanup)

    table.insert(WINDOWS, w)
    return w
end

function UI.Window:Section(name)
    local sec = {
        label = tostring(name),
        widgets = {},
        _text = nil,
        _divider = nil,
    }
    table.insert(self.sections, sec)
    return setmetatable({ _sec = sec, _win = self }, UI.Section)
end

-- ------------------------------------------------------------ widgets

UI.Section = {}
UI.Section.__index = UI.Section

local function newWidget(win, sec, type)
    local wid = { type = type, d = {}, _win = win, bg = nil, highlight = false }
    table.insert(sec.widgets, wid)
    return wid
end

local function widText(wid, idx, color)
    local t = wid.d[idx]
    if not t then
        t = Drawing.new("Text")
        t.Font = FONT_BOLD
        t.Color = color
        t.Outline = false
        wid.d[idx] = t
        table.insert(wid._win.drop, t)
    end
    return t
end

local function widBg(wid)
    local b = wid.bg
    if not b then
        b = Drawing.new("Square")
        b.Filled = true
        b.Color = PRESS_BG
        wid.bg = b
        table.insert(wid._win.drop, b)
    end
    return b
end

function UI.Section:Button(label, callback)
    local win, sec = self._win, self._sec
    local wid = newWidget(win, sec, "button")
    wid.labelText = tostring(label)
    wid.callback = callback or function() end
end

function UI.Section:Toggle(label, default, onChange)
    local win, sec = self._win, self._sec
    local wid = newWidget(win, sec, "toggle")
    wid.labelText = tostring(label)
    wid.value = default and true or false
    wid.onChange = onChange or function() end
end

function UI.Section:Keybind(label, onChange)
    local win, sec = self._win, self._sec
    local wid = newWidget(win, sec, "keybind")
    wid.labelText = tostring(label)
    wid.vk = nil
    wid.listening = false
    wid.onChange = onChange or function() end
end

-- ------------------------------------------------------------ frame

function UI.Window:update()
    local rsh = safe(iskeypressed, self.toggleKey) or false
    if rsh and not self._rsWas then
        self.open = not self.open
        if self.open then print("[ui] opened") end
    end
    self._rsWas = rsh

    local vw, vh = 1920, 1080
    local cam = game.Workspace and game.Workspace.CurrentCamera
    if cam and cam.ViewportSize then
        vw, vh = cam.ViewportSize.X, cam.ViewportSize.Y
    end

    -- layout: label zones + widget rows
    local rows = {}
    local y = 0
    for _, sec in ipairs(self.sections) do
        rows[#rows + 1] = { type = "label", sec = sec, y = y }
        y = y + SEC_H
        for _, wid in ipairs(sec.widgets) do
            rows[#rows + 1] = { type = "widget", wid = wid, y = y }
            y = y + ROW_STEP
        end
        y = y + SEC_GAP
    end
    local boxH = y + END_PAD

    -- closed: park everything off-screen (never Visible=false)
    if not self.open then
        for _, o in ipairs(self.drop) do
            wPark(o)
        end
        return
    end

    local bx, by = self.pos.X, self.pos.Y

    if not self.box then
        self.box = Drawing.new("Square")
        self.box.Filled = true
        self.box.Color = BOX_BG
        self.box.Corner = 8
        table.insert(self.drop, self.box)
    end
    self.box.Position = Vector2.new(bx, by)
    self.box.Size = Vector2.new(BOX_W, boxH)
    wShow(self, self.box)

    -- mouse
    local mx, my = 0, 0
    local lplr = game.Players.LocalPlayer
    if lplr then
        local mouse = lplr:GetMouse()
        if mouse then mx, my = mouse.X, mouse.Y end
    end
    local m1 = safe(ismouse1pressed) or false

    -- keybind capture: if any bind is listening, scan for a key
    local captureVk = nil
    for _, sec in ipairs(self.sections) do
        for _, wid in ipairs(sec.widgets) do
            if wid.type == "keybind" and wid.listening then
                for _, k in ipairs(BIND_KEYS) do
                    if safe(iskeypressed, k) then captureVk = k end
                end
            end
        end
    end

    for _, r in ipairs(rows) do
        if r.type == "label" then
            local sec = r.sec
            if not sec._text then
                sec._text = Drawing.new("Text")
                sec._text.Font = FONT_BOLD
                sec._text.Color = LABEL_CL
                sec._text.Outline = false
                table.insert(self.drop, sec._text)
            end
            sec._text.Text = sec.label
            sec._text.Position = Vector2.new(bx + 12, by + r.y + 9)
            wShow(self, sec._text)

            if not sec._divider then
                sec._divider = Drawing.new("Square")
                sec._divider.Filled = true
                sec._divider.Color = LINE
                table.insert(self.drop, sec._divider)
            end
            sec._divider.Position = Vector2.new(bx + 12, by + r.y + SEC_H - 4)
            sec._divider.Size = Vector2.new(BOX_W - 24, 1)
            wShow(self, sec._divider)
        else
            local wid = r.wid
            local ry = by + r.y

            -- persistent highlight background (toggled on click)
            if wid.highlight then
                local b = widBg(wid)
                b.Position = Vector2.new(bx + 12, ry)
                b.Size = Vector2.new(BOX_W - 24, ROW_H)
                wShow(self, b)
            elseif wid.bg then
                wPark(wid.bg)
            end

            if wid.type == "button" then
                local text = widText(wid, 1, ROW_CL)
                text.Text = wid.labelText
                text.Position = Vector2.new(bx + 12, ry + (ROW_H - 16) * 0.5)
                wShow(self, text)
            elseif wid.type == "toggle" then
                local text = widText(wid, 1, ROW_CL)
                local state = widText(wid, 2, ROW_CL)
                state.Center = true
                text.Text = wid.labelText
                text.Position = Vector2.new(bx + 12, ry + (ROW_H - 16) * 0.5)
                state.Text = wid.value and "ON" or "OFF"
                state.Color = wid.value and ON_CL or ROW_CL
                state.Position = Vector2.new(bx + BOX_W - 30, ry + (ROW_H - 16) * 0.5)
                wShow(self, text)
                wShow(self, state)
            elseif wid.type == "keybind" then
                local text = widText(wid, 1, ROW_CL)
                local key = widText(wid, 2, ROW_CL)
                key.Center = true
                text.Text = wid.labelText
                text.Position = Vector2.new(bx + 12, ry + (ROW_H - 16) * 0.5)
                key.Text = wid.listening and "..." or (KEY_NAME[wid.vk] and KEY_NAME[wid.vk] or "NONE")
                key.Color = wid.listening and LABEL_CL or ROW_CL
                key.Position = Vector2.new(bx + BOX_W - 30, ry + (ROW_H - 16) * 0.5)
                wShow(self, text)
                wShow(self, key)
            end
        end
    end

    -- click handling (press edge)
    local press = m1 and not self._m1Was
    self._m1Was = m1

    if press then
        local clicked = false
        for _, r in ipairs(rows) do
            if r.type == "widget" then
                local wid = r.wid
                if inRect(mx, my, bx + 12, by + r.y, BOX_W - 24, ROW_H) then
                    clicked = true
                    wid.highlight = not wid.highlight
                    if wid.type == "button" then
                        wid.callback()
                    elseif wid.type == "toggle" then
                        wid.value = not wid.value
                        wid.onChange(wid.value)
                    elseif wid.type == "keybind" then
                        wid.listening = not wid.listening
                    end
                    break
                end
            end
        end

        if not clicked then
            if inRect(mx, my, bx, by, BOX_W, boxH) then
                self._drag = { sx = mx, sy = my, ox = bx, oy = by, dragging = false }
            else
                self._drag = nil
            end
        end
    end

    -- apply a newly captured bind
    if captureVk then
        for _, sec in ipairs(self.sections) do
            for _, wid in ipairs(sec.widgets) do
                if wid.type == "keybind" and wid.listening then
                    wid.vk = captureVk
                    wid.listening = false
                    pcall(wid.onChange, captureVk)
                end
            end
        end
    end

    if self._drag then
        if m1 then
            local d = self._drag
            local dx, dy = mx - d.sx, my - d.sy
            if not d.dragging and (math.abs(dx) > DRAG_THRESHOLD or math.abs(dy) > DRAG_THRESHOLD) then
                d.dragging = true
            end
            if d.dragging then
                local hx = clamp(d.ox + dx, 4, vw - BOX_W - 4)
                local hy = clamp(d.oy + dy, 4, vh - boxH - 4)
                self.pos = Vector2.new(
                    self.pos.X + (hx - self.pos.X) * 0.22,
                    self.pos.Y + (hy - self.pos.Y) * 0.22
                )
            end
        else
            self._drag = nil
        end
    end
end

function UI.Window:Start()
    if self.running then return end
    if not self.pos then self.pos = arrangeWindow(self) end
    self.running = true
    print("[ui] menu loaded")
    spawn(function()
        while self.running do
            local ok, err = pcall(self.update, self)
            if not ok then
                print("[ui] update error:", err)
            end
            wait(0.016)
        end
        self:DestroyObjects()
    end)
end

function UI.Window:DestroyObjects()
    for _, o in ipairs(self.drop) do
        pcall(function() o:Remove() end)
    end
    self.drop = {}
end

function UI.Window:Destroy()
    self.running = false
    self:DestroyObjects()
    for i, w in ipairs(WINDOWS) do
        if w == self then table.remove(WINDOWS, i) break end
    end
end

-- ------------------------------------------------------------ kit view ESP

UI.KitView = {}
UI.KitView.__index = UI.KitView

UI.KitView.NAMES = {
    sword_shield = "Sword & Shield",
    archer = "Archer",
    baker = "Baker",
    barbarian = "Barbarian",
    beast = "Beast",
    builder = "Builder",
    farmer = "Farmer",
    cleetus = "Cleetus",
    pirate = "Pirate Davey",
    melody = "Melody",
    infernal_shielder = "Infernal Shielder",
    fish = "Fish",
    vulture = "Vulture",
    mel = "Mel",
    hannah = "Hannah",
    ember = "Ember",
    grim_reaper = "Grim Reaper",
    eldric = "Eldric",
    aery = "Aery",
    crypt = "Crypt",
    kaliyah = "Kaliyah",
    kaida = "Kaida",
    isabel = "Isabel",
    skoll = "Skoll",
    terra = "Terra",
    lian = "Lian",
    lumen = "Lumen",
    nyx = "Nyx",
    pyrose = "Pyro",
    zarrah = "Zarrah",
    sheila = "Sheila",
    sheep_herder = "Sheep Herder",
    whimm = "Whim",
    caitlyn = "Caitlyn",
    adetunde = "Adetunde",
    agni = "Agni",
    crocowolf = "Crocoman",
    evelynn = "Evelynn",
    freiya = "Freiya",
    fortunna = "Fortuna",
    ramil = "Ramil",
    void_knight = "Void Knight",
    xu_rot = "Xu'rot",
    lassy = "Lassy",
    nazar = "Nazar",
    spirit_assassin = "Spirit Assassin",
    falconer = "Falconer",
    trapper = "Trapper",
    valkyrie = "Valkyrie",
    reaper = "Reaper",
}

local function humanize(id)
    if not id or id == "" then return "?" end
    local parts = {}
    for w in tostring(id):gmatch("[^_]+") do
        table.insert(parts, w:sub(1, 1):upper() .. w:sub(2))
    end
    if #parts == 0 then return tostring(id) end
    return table.concat(parts, " ")
end

local function prettyKit(kit)
    if not kit or kit == "" then return "?" end
    local known = UI.KitView.NAMES
    if known[kit] then return known[kit] end
    return humanize(kit)
end

function UI.KitView.new(opts)
    opts = opts or {}
    local self = setmetatable({}, UI.KitView)
    self.offset = opts.Offset or Vector3.new(0, 3.4, 0)
    self.running = false
    self.drawn = {}  -- player -> text drawing
    return self
end

function UI.KitView:draw()
    local seen = {}
    local players = game.Players and game.Players:GetPlayers()
    if not players then return end

    for _, p in ipairs(players) do
        seen[p] = true
        local slot = self.drawn[p]
        if not slot then
            slot = {}
            self.drawn[p] = slot
        end

        local me = game.Players and game.Players.LocalPlayer
        local char = p.Character
        if p == me then char = nil end
        local head = char and char:FindFirstChild("Head")
        local kit = nil
        if head then
            local ok, v = pcall(function() return p:GetAttribute("PlayingAsKits") end)
            kit = ok and v or nil
        end

        local label = kit and prettyKit(kit) or nil

        if head and kit and label then
            local pos, on = WorldToScreen(head.Position + self.offset)
            if on then
                if not slot.text then
                    slot.text = Drawing.new("Text")
                    slot.text.Font = FONT_BOLD
                    slot.text.Center = true
                    slot.text.Color = Color3.new(1, 1, 1)
                    slot.text.Outline = true
                end
                slot.text.Text = label
                slot.text.Position = pos
                pcall(function() slot.text.Visible = true end)
            else
                if slot.text then pcall(function() slot.text.Position = OFFSCREEN end) end
            end
        else
            if slot.text then pcall(function() slot.text.Position = OFFSCREEN end) end
        end
    end

    -- players that left: park their labels
    for p, slot in pairs(self.drawn) do
        if not seen[p] then
            if slot.text then pcall(function() slot.text.Position = OFFSCREEN end) end
        end
    end
end

function UI.KitView:Start()
    if self.running then return end
    self.running = true
    print("[kitview] started")
    spawn(function()
        while self.running do
            local ok, err = pcall(self.draw, self)
            if not ok then
                print("[kitview] error:", err)
            end
            wait(0.05)
        end
        for p, slot in pairs(self.drawn) do
            if slot.text then pcall(function() slot.text:Remove() end) end
        end
        self.drawn = {}
        print("[kitview] stopped")
    end)
end

function UI.KitView:Stop()
    self.running = false
end

-- ----------------------------------------------------------- item held esp

UI.ItemHeld = {}
UI.ItemHeld.__index = UI.ItemHeld

function UI.ItemHeld.new(opts)
    opts = opts or {}
    local self = setmetatable({}, UI.ItemHeld)
    self.offset = opts.Offset or Vector3.new(0, -1.8, 0)
    self.label = opts.Label or ""
    self.running = false
    self.drawn = {}
    return self
end

function UI.ItemHeld:draw()
    local seen = {}
    local players = game.Players and game.Players:GetPlayers()
    if not players then return end

    for _, p in ipairs(players) do
        seen[p] = true
        local slot = self.drawn[p]
        if not slot then
            slot = {}
            self.drawn[p] = slot
        end

        local me = game.Players and game.Players.LocalPlayer
        local char = p.Character
        if p == me then char = nil end
        local head = char and char:FindFirstChild("Head")
        local item = nil
        if char then
            local hand = char:FindFirstChild("HandInvItem")
            if hand then
                local ok, v = pcall(function() return hand.Value end)
                if ok and v then
                    local nm = v.Name
                    if type(nm) == "string" and #nm > 0 and nm ~= "Unreadable_name" then
                        item = nm
                    end
                end
            end
        end

        if head and item then
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local base = root or head
            local pos, on = WorldToScreen(base.Position + self.offset)
            if on then
                if not slot.text then
                    slot.text = Drawing.new("Text")
                    slot.text.Font = FONT_BOLD
                    slot.text.Center = true
                    slot.text.Color = Color3.fromRGB(99, 168, 156)
                    slot.text.Outline = false
                end
                slot.text.Text = (self.label ~= "" and (self.label .. " ") or "") .. humanize(item)
                slot.text.Position = pos
                pcall(function() slot.text.Visible = true end)
            else
                if slot.text then pcall(function() slot.text.Position = OFFSCREEN end) end
            end
        else
            if slot.text then pcall(function() slot.text.Position = OFFSCREEN end) end
        end
    end

    for p, slot in pairs(self.drawn) do
        if not seen[p] then
            if slot.text then pcall(function() slot.text.Position = OFFSCREEN end) end
        end
    end
end

function UI.ItemHeld:Start()
    if self.running then return end
    self.running = true
    print("[itemheld] started")
    spawn(function()
        while self.running do
            local ok, err = pcall(self.draw, self)
            if not ok then
                print("[itemheld] error:", err)
            end
            wait(0.05)
        end
        for p, slot in pairs(self.drawn) do
            if slot.text then pcall(function() slot.text:Remove() end) end
        end
        self.drawn = {}
        print("[itemheld] stopped")
    end)
end

function UI.ItemHeld:Stop()
    self.running = false
end

-- --------------------------------------------------------------- Autoclicker

UI.Autoclicker = {}
UI.Autoclicker.__index = UI.Autoclicker

function UI.Autoclicker.new(opts)
    opts = opts or {}
    local self = setmetatable({}, UI.Autoclicker)
    self.cps = opts.Cps or 100
    self.button = opts.Button or "left" -- "left" | "right" | "both"
    self.running = false
    return self
end

function UI.Autoclicker:Start()
    if self.running then return end
    self.running = true
    print("[autoclicker] started at", self.cps, "cps", "(" .. self.button .. ")")
    spawn(function()
        while self.running do
            local n = math.max(1, math.floor(self.cps * 0.05))
            if self.button == "left" then
                for _ = 1, n do
                    pcall(mouse1click)
                end
            elseif self.button == "right" then
                for _ = 1, n do
                    pcall(mouse2click)
                end
            else
                for _ = 1, n do
                    pcall(mouse1click)
                    pcall(mouse2click)
                end
            end
            wait(0.05)
        end
        print("[autoclicker] stopped")
    end)
end

function UI.Autoclicker:Stop()
    self.running = false
    pcall(mouse1release)
    pcall(mouse2release)
end

-- --------------------------------------------------------------- HUD / show enabled

UI.HUD = {}
UI.HUD.__index = UI.HUD

function UI.HUD.new(opts)
    opts = opts or {}
    local self = setmetatable({}, UI.HUD)
    self.title = opts.Title
    self.imageUrl = opts.ImageUrl
    self.rightPad = opts.RightPad or 12
    self.rowGap = opts.RowGap or 24
    self.imageSize = opts.ImageSize or Vector2.new(160, 64)
    self.running = false
    self.visible = opts.Enabled ~= false
    self.names = {}   -- ordered array of row names
    self.states = {}  -- name -> bool (enabled)
    self.rows = {}    -- name -> text drawing
    self.imageObj = nil
    self.titleObj = nil
    self.imageState = "none" -- "none" | "loading" | "ok" | "fail"
    self.imageData = nil
    return self
end

local function viewport()
    local ok, cam = pcall(function() return workspace.CurrentCamera end)
    if ok and cam then
        local ok2, vs = pcall(function() return cam.ViewportSize end)
        if ok2 and vs then return vs end
    end
    return Vector2.new(1920, 1080)
end

function UI.HUD:Set(name, on)
    if not self.states[name] and on then
        table.insert(self.names, name)
    end
    self.states[name] = not not on
end

function UI.HUD:SetEnabled(b)
    self.visible = not not b
end

function UI.HUD:render()
    local vs = viewport()
    local anchorX = vs.X - self.rightPad

    if not self.visible then
        if self.imageObj then pcall(function() self.imageObj.Position = OFFSCREEN end) end
        if self.titleObj then pcall(function() self.titleObj.Position = OFFSCREEN end) end
        for _, row in pairs(self.rows) do
            pcall(function() row.Position = OFFSCREEN end)
        end
        return
    end

    local y = math.floor(vs.Y * 0.5) -- middle-right

    if self.imageUrl then
        if self.imageState == "none" then
            self.imageState = "loading"
            spawn(function()
                local ok, b = pcall(function() return game:HttpGet(self.imageUrl, true) end)
                if ok and type(b) == "string" and #b > 0 then
                    self.imageState = "ok"
                    self.imageData = b
                else
                    self.imageState = "fail"
                end
            end)
        end
        if self.imageState == "ok" and self.imageData then
            if not self.imageObj then
                self.imageObj = Drawing.new("Image")
                self.imageObj.Size = self.imageSize
            end
            pcall(function() self.imageObj.Data = self.imageData end)
            pcall(function() self.imageObj.Position = Vector2.new(anchorX - self.imageSize.X / 2, y) end)
            pcall(function() self.imageObj.Visible = true end)
            y = y + self.imageSize.Y + 8
        elseif self.title then
            if not self.titleObj then
                self.titleObj = Drawing.new("Text")
                self.titleObj.Font = FONT_BOLD
                self.titleObj.Center = true
                self.titleObj.Color = Color3.fromRGB(219, 219, 219)
                self.titleObj.Outline = false
            end
            self.titleObj.Text = self.title
            self.titleObj.Position = Vector2.new(anchorX, y)
            pcall(function() self.titleObj.Visible = true end)
            y = y + self.rowGap
        end
    elseif self.title then
        if not self.titleObj then
            self.titleObj = Drawing.new("Text")
            self.titleObj.Font = FONT_BOLD
            self.titleObj.Center = true
            self.titleObj.Color = Color3.fromRGB(219, 219, 219)
            self.titleObj.Outline = false
        end
        self.titleObj.Text = self.title
        self.titleObj.Position = Vector2.new(anchorX, y)
        pcall(function() self.titleObj.Visible = true end)
        y = y + self.rowGap
    end

    for _, name in ipairs(self.names) do
        local row = self.rows[name]
        if not row then
            row = Drawing.new("Text")
            row.Font = FONT_BOLD
            row.Center = true
            row.Color = Color3.fromRGB(0, 255, 0)
            row.Outline = false
            self.rows[name] = row
        end
        if self.states[name] then
            row.Text = name
            row.Position = Vector2.new(anchorX, y)
            pcall(function() row.Visible = true end)
            y = y + self.rowGap
        else
            pcall(function() row.Position = OFFSCREEN end)
        end
    end
end

function UI.HUD:Start()
    if self.running then return end
    self.running = true
    spawn(function()
        while self.running do
            local ok, err = pcall(self.render, self)
            if not ok then
                print("[hud] error:", err)
            end
            wait(0.06)
        end
        if self.imageObj then pcall(function() self.imageObj:Remove() end) end
        if self.titleObj then pcall(function() self.titleObj:Remove() end) end
        for _, row in pairs(self.rows) do
            pcall(function() row:Remove() end)
        end
    end)
end

function UI.HUD:Stop()
    self.running = false
end

-- ---------------------------------------------------------------- export

-- expose the library so a loader script can build menus:
--   loadstring(game:HttpGet("https://raw/github/.../ui.lua"))()
--   local Win = UI.Window.new({})
--   local Main = Win:Section("Main")
--   Main:Button("test", function() print("[ui] clicked") end)
--   Win:Start()
_G.UI = UI

-- ---------------------------------------------------------------- auto demo

-- runs the demo menu automatically so ui.lua can be executed on its own.
local okDemo, errDemo = pcall(function()
    local kv = UI.KitView.new({})
    local ih = UI.ItemHeld.new({})
    local ac = UI.Autoclicker.new({ Cps = 100 })

    local kvOn, ihOn, acOn = false, false, false

    local Visuals = UI.Window.new({})
    local Vs = Visuals:Section("Visuals")
    Vs:Button("KitView", function()
        kvOn = not kvOn
        if kvOn then kv:Start() else kv:Stop() end
    end)
    Vs:Button("Item Held", function()
        ihOn = not ihOn
        if ihOn then ih:Start() else ih:Stop() end
    end)

    local Combat = UI.Window.new({})
    local Cs = Combat:Section("Combat")
    Cs:Button("Autoclicker", function()
        acOn = not acOn
        if acOn then ac:Start() else ac:Stop() end
    end)

    Visuals:Start()
    Combat:Start()
end)
if not okDemo then print("[ui] demo error:", errDemo) end
