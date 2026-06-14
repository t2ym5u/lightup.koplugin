local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local T               = require("ffi/util").template

local ScreenBase         = require("screen_base")
local MenuHelper         = require("menu_helper")
local LightUpBoard       = lrequire("board")
local LightUpBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

-- ---------------------------------------------------------------------------
-- LightUpScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Light Up (Akari) — Rules

Place light bulbs so that every white cell is illuminated.

Rules:
• Bulbs shine horizontally and vertically until blocked by a black cell or the grid edge.
• Two bulbs may not illuminate each other (they cannot be in the same row/column without a black cell between them).
• Black cells with a number show exactly how many bulbs must be placed in the four orthogonally adjacent cells.
• Black cells with no number have no constraint on adjacent bulbs.

Solve the puzzle when every white cell is lit and no bulb illuminates another.
]])

local GAME_RULES_FR = [[
Illumination (Akari) — Règles

Placez des ampoules de façon à ce que toutes les cases blanches soient éclairées.

Règles :
• Les ampoules éclairent horizontalement et verticalement jusqu'à être bloquées par une case noire ou le bord de la grille.
• Deux ampoules ne peuvent pas s'éclairer mutuellement (elles ne peuvent pas être sur la même ligne ou colonne sans case noire entre elles).
• Les cases noires portant un chiffre indiquent exactement combien d'ampoules doivent être placées dans les quatre cases orthogonalement adjacentes.
• Les cases noires sans chiffre n'ont aucune contrainte sur les ampoules adjacentes.

Résolvez le puzzle quand toutes les cases blanches sont éclairées et qu'aucune ampoule n'en éclaire une autre.
]]

local LightUpScreen = ScreenBase:extend{}

function LightUpScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n",     LightUpBoard.DEFAULT_N)
    local diff  = self.plugin:getSetting("difficulty", "medium")
    self.board  = LightUpBoard:new{ n = n, difficulty = diff }
    if not self.board:load(state) then
        -- fresh puzzle
    end
    ScreenBase.init(self)
end

function LightUpScreen:serializeState()
    return self.board:serialize()
end

function LightUpScreen:buildLayout()
    local sw           = DeviceScreen:getWidth()
    local sh           = DeviceScreen:getHeight()
    local is_landscape = self:isLandscape()

    local btn_width = is_landscape
        and math.max(math.floor(sw * 0.35), 100)
        or  math.floor(sw * 0.9)

    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = btn_width,
        buttons = {{
            { text = _("New"),  callback = function() self:onNewGame() end },
            { id = "size_btn",  text = self:_sizeLabel(),
              callback = function() self:openSizeMenu() end },
            { id = "diff_btn",  text = self:_diffLabel(),
              callback = function() self:openDiffMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
            self:makeCloseButtonConfig(),
        }},
    }
    self.size_btn = top_buttons:getButtonById("size_btn")
    self.diff_btn = top_buttons:getButtonById("diff_btn")

    local margin      = Size.margin.default
    local padding     = Size.padding.large
    local frame_extra = (padding + margin) * 2
    local board_max
    if is_landscape then
        board_max = math.min(sw - math.floor(sw * 0.4) - frame_extra, sh - frame_extra)
    else
        board_max = math.min(sw - frame_extra, sh - 160 - frame_extra)
    end
    board_max = math.max(board_max, 80)

    self.board_widget = LightUpBoardWidget:new{
        board      = self.board,
        max_width  = board_max,
        max_height = board_max,
        onCellTap  = function(r, c) self:onCellTap(r, c) end,
        onCellHold = function(r, c) self:onCellHold(r, c) end,
    }

    local board_frame = FrameContainer:new{
        padding = padding,
        margin  = margin,
        self.board_widget,
    }

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = btn_width,
        buttons = {{
            { text = _("Undo"),   callback = function() self:onUndo() end },
            { text = _("Check"),  callback = function() self:onCheck() end },
            { text = _("Reveal"), callback = function() self:onReveal() end },
        }},
    }

    if is_landscape then
        local panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align  = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
    self:updateStatus()
end

function LightUpScreen:onCellTap(r, c)
    self.board:cycleCell(r, c)
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState(self.board:serialize())
end

function LightUpScreen:onCellHold(r, c)
    self.board:setMark(r, c, LightUpBoard.MARK_DOT)
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState(self.board:serialize())
end

function LightUpScreen:onUndo()
    self.board:undoMove()
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState(self.board:serialize())
end

function LightUpScreen:onCheck()
    self.board:check()
    self.board_widget:refresh()
    self:updateStatus()
end

function LightUpScreen:onReveal()
    self.board:reveal()
    self.board_widget:refresh()
    self:updateStatus(_("Solution revealed."))
    self.plugin:saveState(self.board:serialize())
end

function LightUpScreen:onNewGame()
    local n    = self.plugin:getSetting("grid_n",     LightUpBoard.DEFAULT_N)
    local diff = self.plugin:getSetting("difficulty", "medium")
    self.board = LightUpBoard:new{ n = n, difficulty = diff }
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function LightUpScreen:openSizeMenu()
    local items = {}
    for _, n in ipairs(LightUpBoard.SIZES) do
        items[#items + 1] = { id = n, text = string.format("%d\xC3\x97%d", n, n) }
    end
    MenuHelper.openPickerMenu{
        title      = _("Grid size"),
        items      = items,
        current_id = self.plugin:getSetting("grid_n", LightUpBoard.DEFAULT_N),
        parent     = self,
        on_select  = function(n)
            self.plugin:saveSetting("grid_n", n)
            if self.size_btn then
                self.size_btn:setText(self:_sizeLabel(), self.size_btn.width)
            end
            self:onNewGame()
        end,
    }
end

function LightUpScreen:openDiffMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        parent    = self,
        on_select = function(diff)
            self.plugin:saveSetting("difficulty", diff)
            if self.diff_btn then
                self.diff_btn:setText(self:_diffLabel(), self.diff_btn.width)
            end
            self:onNewGame()
        end,
    }
end

function LightUpScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.won then
        status = _("All cells illuminated! Puzzle solved!")
    else
        -- Count lit vs total white cells
        local n = self.board.n
        local lit_cnt, white_cnt, bulb_cnt = 0, 0, 0
        for r = 1, n do
            for c = 1, n do
                if self.board.grid[r][c] == LightUpBoard.TYPE_WHITE then
                    white_cnt = white_cnt + 1
                    if self.board.lit and self.board.lit[r][c] then lit_cnt = lit_cnt + 1 end
                    if self.board.marks[r][c] == LightUpBoard.MARK_BULB then bulb_cnt = bulb_cnt + 1 end
                end
            end
        end
        status = T(_("Lit: %1/%2  Bulbs: %3  Tap=cycle  Hold=dot"),
            lit_cnt, white_cnt, bulb_cnt)
    end
    ScreenBase.updateStatus(self, status)
end

function LightUpScreen:_sizeLabel()
    local n = self.plugin:getSetting("grid_n", LightUpBoard.DEFAULT_N)
    return string.format("%d\xC3\x97%d", n, n)
end

function LightUpScreen:_diffLabel()
    local diff = self.plugin:getSetting("difficulty", "medium")
    local labels = { easy = _("Easy"), medium = _("Medium"), hard = _("Hard") }
    return labels[diff] or diff
end

return LightUpScreen
