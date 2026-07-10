local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

local gwb      = require("grid_widget_base")
local drawLine = gwb.drawLine

local LightUpBoard = require("board")

local C_BG      = Blitbuffer.COLOR_WHITE
local C_FG      = Blitbuffer.COLOR_BLACK
local C_GRID    = Blitbuffer.COLOR_GRAY_9
local C_BLACK   = Blitbuffer.COLOR_GRAY_3
local C_LIT     = Blitbuffer.COLOR_GRAY_E
local C_BULB    = Blitbuffer.COLOR_GRAY_6
local C_DOT     = Blitbuffer.COLOR_GRAY_C
local C_WRONG   = Blitbuffer.COLOR_GRAY_2
local C_WHITE_NUM = Blitbuffer.COLOR_WHITE

-- ---------------------------------------------------------------------------
-- LightUpBoardWidget
-- ---------------------------------------------------------------------------

local LightUpBoardWidget = InputContainer:extend{
    board      = nil,
    max_width  = 0,
    max_height = 0,
    cellTapCallback  = nil,
    cellHoldCallback = nil,
}

function LightUpBoardWidget:init()
    local n    = self.board.n
    local cell = math.floor(math.min(self.max_width / n, self.max_height / n))
    cell = math.max(cell, 10)
    self.cell = cell
    self.w    = cell * n
    self.h    = cell * n
    self.dimen = Geom:new{ w = self.w, h = self.h }

    local fs = math.max(7, math.floor(cell * 0.5))
    self.num_face = Font:getFace("cfont", fs)
    self.sym_face = Font:getFace("cfont", math.max(6, math.floor(cell * 0.55)))

    self.paint_rect = nil

    self.ges_events = {
        CellTap  = { GestureRange:new{ ges = "tap",          range = function() return self.paint_rect end } },
        CellHold = { GestureRange:new{ ges = "hold_release", range = function() return self.paint_rect end } },
    }
end

local function centeredText(bb, text, face, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, cx * 2, face, text, true, false)
    local tx = cx - math.floor(m.x / 2)
    local ty = cy - math.floor((m.y_bottom - m.y_top) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color or Blitbuffer.COLOR_BLACK)
end

function LightUpBoardWidget:_hitTest(gx, gy)
    if not self.paint_rect then return nil end
    local lx = gx - self.paint_rect.x
    local ly = gy - self.paint_rect.y
    if lx < 0 or ly < 0 or lx >= self.w or ly >= self.h then return nil end
    local c = math.floor(lx / self.cell) + 1
    local r = math.floor(ly / self.cell) + 1
    local n = self.board.n
    if r >= 1 and r <= n and c >= 1 and c <= n then return r, c end
    return nil
end

function LightUpBoardWidget:onCellTap(ges)
    local r, c = self:_hitTest(ges.pos.x, ges.pos.y)
    if r and self.cellTapCallback then self.cellTapCallback(r, c) end
    return true
end

function LightUpBoardWidget:onCellHold(ges)
    local r, c = self:_hitTest(ges.pos.x, ges.pos.y)
    if r and self.cellHoldCallback then self.cellHoldCallback(r, c) end
    return true
end

function LightUpBoardWidget:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.paint_rect or self.dimen
    end)
end

function LightUpBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local board = self.board
    local n     = board.n
    local cell  = self.cell
    local thin  = 1

    bb:paintRect(x, y, self.w, self.h, C_BG)

    local TYPE_WHITE   = LightUpBoard.TYPE_WHITE
    local TYPE_BLACK   = LightUpBoard.TYPE_BLACK
    local TYPE_BLACK_0 = LightUpBoard.TYPE_BLACK_0
    local TYPE_BLACK_4 = LightUpBoard.TYPE_BLACK_4
    local MARK_BULB    = LightUpBoard.MARK_BULB
    local MARK_DOT     = LightUpBoard.MARK_DOT

    for r = 1, n do
        for c = 1, n do
            local cx = x + (c - 1) * cell
            local cy = y + (r - 1) * cell
            local ct    = board.grid[r][c]
            local mark  = board.marks[r][c]
            local is_lit = board.lit and board.lit[r][c]
            local is_wrong = board.wrong_cells and board.wrong_cells[r][c]

            local pad = math.max(1, math.floor(cell * 0.04))

            if ct > TYPE_WHITE then
                -- Black cell
                bb:paintRect(cx, cy, cell, cell, C_BLACK)
                if ct >= TYPE_BLACK_0 and ct <= TYPE_BLACK_4 then
                    centeredText(bb, tostring(ct - TYPE_BLACK_0), self.num_face,
                        cx + cell//2, cy + cell//2, C_WHITE_NUM)
                end
            else
                -- White cell
                local bg = is_wrong and C_WRONG
                        or (is_lit and C_LIT)
                        or C_BG
                bb:paintRect(cx + pad, cy + pad, cell - 2*pad, cell - 2*pad, bg)

                if mark == MARK_BULB then
                    -- Draw bulb: filled circle
                    local r2 = math.max(2, math.floor(cell * 0.3))
                    bb:paintCircle(cx + cell//2, cy + cell//2, r2, C_BULB)
                    -- Inner highlight
                    if r2 > 3 then
                        bb:paintCircle(cx + cell//2, cy + cell//2, r2 - 2, C_FG, true)
                        bb:paintCircle(cx + cell//2, cy + cell//2, r2 - 2, C_BG, false)
                    end
                elseif mark == MARK_DOT then
                    centeredText(bb, "\xC2\xB7", self.sym_face,
                        cx + cell//2, cy + cell//2, C_FG)
                end
            end
        end
    end

    -- Grid lines
    for i = 0, n do
        drawLine(bb, x + i*cell, y,          thin, self.h, C_GRID)
        drawLine(bb, x,          y + i*cell, self.w, thin, C_GRID)
    end

    -- Border
    local bw = math.max(2, thin)
    drawLine(bb, x,              y,              self.w, bw, C_FG)
    drawLine(bb, x,              y + self.h - bw, self.w, bw, C_FG)
    drawLine(bb, x,              y,              bw, self.h, C_FG)
    drawLine(bb, x + self.w - bw, y,             bw, self.h, C_FG)
end

return LightUpBoardWidget
