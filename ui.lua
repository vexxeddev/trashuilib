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

local BOX_W = 212
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
    local prev = _G[RUN_KEY]
    if prev then
        prev:Destroy()
        print("[ui] removed previous instance")
    end

    opts = opts or {}
    local w = setmetatable({}, UI.Window)
    w.pos = opts.Position or Vector2.new(40, 40)
    w.toggleKey = opts.ToggleKey or VK_RSHIFT
    w.open = false
    w.running = false
    w.sections = {}
    w.drop = {}   -- every Drawing object (park + cleanup)

    _G[RUN_KEY] = w
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
                self.pos = Vector2.new(
                    clamp(d.ox + dx, 4, vw - BOX_W - 4),
                    clamp(d.oy + dy, 4, vh - boxH - 4)
                )
            end
        else
            self._drag = nil
        end
    end
end

function UI.Window:Start()
    if self.running then return end
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
    if _G[RUN_KEY] == self then
        _G[RUN_KEY] = nil
    end
end

-- ---------------------------------------------------------------- export

-- expose the library so a loader script can build menus:
--   loadstring(game:HttpGet("https://raw/github/.../ui.lua"))()
--   local Win = UI.Window.new({})
--   local Main = Win:Section("Main")
--   Main:Button("test", function() print("[ui] clicked") end)
--   Win:Start()
_G.UI = UI