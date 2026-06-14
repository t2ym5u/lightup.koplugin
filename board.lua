local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")

local shuffle    = grid_utils.shuffle
local emptyGrid  = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid

-- Cell types (fixed)
local TYPE_WHITE = 0
local TYPE_BLACK = 1   -- black cell, no constraint
-- Black cells with constraints: TYPE_BLACK_0 .. TYPE_BLACK_4
local TYPE_BLACK_0 = 2
local TYPE_BLACK_1 = 3
local TYPE_BLACK_2 = 4
local TYPE_BLACK_3 = 5
local TYPE_BLACK_4 = 6

-- Player marks
local MARK_EMPTY = 0
local MARK_BULB  = 1
local MARK_DOT   = 2   -- confirmed not a bulb

local SIZES     = { 7, 10, 14 }
local DEFAULT_N = 10
local DEFAULT_DIFF = "medium"

-- Black cell density per difficulty
local BLACK_DENSITY = { easy = 0.20, medium = 0.28, hard = 0.35 }

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

local DIR4 = { {-1,0},{1,0},{0,-1},{0,1} }

local function inBounds(r, c, n)
    return r >= 1 and r <= n and c >= 1 and c <= n
end

local function isBlack(grid, r, c, n)
    if not inBounds(r, c, n) then return true end  -- out of bounds = blocking
    return grid[r][c] > TYPE_WHITE
end

-- Check if placing bulb at (r,c) conflicts with any existing bulb
local function bulbConflict(bulbs, grid, r, c, n)
    -- Check along row (left and right) until black cell
    for dc = -1, 1, 2 do
        local nc = c + dc
        while inBounds(r, nc, n) and not isBlack(grid, r, nc, n) do
            if bulbs[r][nc] then return true end
            nc = nc + dc
        end
    end
    -- Check along column (up and down) until black cell
    for dr = -1, 1, 2 do
        local nr = r + dr
        while inBounds(nr, c, n) and not isBlack(grid, nr, c, n) do
            if bulbs[nr][c] then return true end
            nr = nr + dr
        end
    end
    return false
end

-- Mark cells lit by bulb at (r,c)
local function markLit(lit, bulbs, grid, r, c, n)
    lit[r][c] = true
    for _, d in ipairs(DIR4) do
        local nr, nc = r + d[1], c + d[2]
        while inBounds(nr, nc, n) and not isBlack(grid, nr, nc, n) do
            lit[nr][nc] = true
            nr = nr + d[1]
            nc = nc + d[2]
        end
    end
end

local function generateSolution(n, density)
    for _ = 1, 20 do
        -- Step 1: generate black cells
        local grid = emptyGrid(n, n, TYPE_WHITE)
        local cells = {}
        for r = 1, n do
            for c = 1, n do cells[#cells + 1] = {r, c} end
        end
        shuffle(cells)

        local num_black = math.floor(n * n * density)
        for i = 1, math.min(num_black, #cells) do
            grid[cells[i][1]][cells[i][2]] = TYPE_BLACK
        end

        -- Step 2: place bulbs greedily to illuminate all white cells
        local bulbs = emptyBoolGrid(n, n)
        local lit   = emptyBoolGrid(n, n)

        -- Pre-mark already-lit (none initially)
        -- Scan in random order; place bulb if cell not yet lit and no conflict
        local white_cells = {}
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == TYPE_WHITE then
                    white_cells[#white_cells + 1] = {r, c}
                end
            end
        end
        shuffle(white_cells)

        for _, pos in ipairs(white_cells) do
            local r, c = pos[1], pos[2]
            if not lit[r][c] and not bulbConflict(bulbs, grid, r, c, n) then
                bulbs[r][c] = true
                markLit(lit, bulbs, grid, r, c, n)
            end
        end

        -- Check all white cells are lit
        local all_lit = true
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == TYPE_WHITE and not lit[r][c] then
                    all_lit = false; break
                end
            end
            if not all_lit then break end
        end

        if all_lit then
            -- Step 3: assign constraint numbers to black cells
            for r = 1, n do
                for c = 1, n do
                    if grid[r][c] == TYPE_BLACK then
                        local adj = 0
                        for _, d in ipairs(DIR4) do
                            local nr, nc = r + d[1], c + d[2]
                            if inBounds(nr, nc, n) and bulbs[nr][nc] then
                                adj = adj + 1
                            end
                        end
                        -- Only assign number constraint with ~60% probability
                        if math.random() < 0.6 then
                            grid[r][c] = TYPE_BLACK_0 + adj
                        end
                    end
                end
            end
            return grid, bulbs
        end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- LightUpBoard
-- ---------------------------------------------------------------------------

local LightUpBoard = {}
LightUpBoard.__index = LightUpBoard

function LightUpBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({
        n          = opts.n          or DEFAULT_N,
        difficulty = opts.difficulty or DEFAULT_DIFF,
        grid       = nil,    -- fixed cell types
        solution   = nil,    -- solution bulbs
        marks      = nil,    -- player marks
        lit        = nil,    -- cells currently lit
        wrong_cells= nil,
        won        = false,
        undo       = UndoStack:new{ max_size = 500 },
    }, self)
    obj:generate()
    return obj
end

function LightUpBoard:generate(diff)
    self.difficulty = diff or self.difficulty
    local n = self.n
    local density = BLACK_DENSITY[self.difficulty] or 0.28

    local grid, sol = generateSolution(n, density)
    if not grid then
        -- minimal fallback
        grid = emptyGrid(n, n, TYPE_WHITE)
        sol  = emptyBoolGrid(n, n)
        if n >= 1 then sol[1][1] = true end
    end

    self.grid        = grid
    self.solution    = sol
    self.marks       = emptyGrid(n, n, MARK_EMPTY)
    self.wrong_cells = emptyBoolGrid(n, n)
    self.won         = false
    self.undo:clear()
    self:_recomputeLit()
end

function LightUpBoard:_recomputeLit()
    local n = self.n
    self.lit = emptyBoolGrid(n, n)
    for r = 1, n do
        for c = 1, n do
            if self.marks[r][c] == MARK_BULB then
                markLit(self.lit, nil, self.grid, r, c, n)
            end
        end
    end
end

function LightUpBoard:cycleCell(r, c)
    if self.grid[r][c] ~= TYPE_WHITE then return false end
    if self.won then return false end
    local cur = self.marks[r][c]
    local next_mark
    if     cur == MARK_EMPTY then next_mark = MARK_BULB
    elseif cur == MARK_BULB  then next_mark = MARK_DOT
    else                          next_mark = MARK_EMPTY
    end
    local old = self.marks[r][c]
    self.undo:push{ r = r, c = c, old = old }
    self.marks[r][c]        = next_mark
    self.wrong_cells[r][c]  = false
    self:_recomputeLit()
    self:_checkWin()
    return true
end

function LightUpBoard:setMark(r, c, mark)
    if self.grid[r][c] ~= TYPE_WHITE then return false end
    if self.won then return false end
    local old = self.marks[r][c]
    if old == mark then mark = MARK_EMPTY end
    self.undo:push{ r = r, c = c, old = old }
    self.marks[r][c]        = mark
    self.wrong_cells[r][c]  = false
    self:_recomputeLit()
    self:_checkWin()
    return true
end

function LightUpBoard:undoMove()
    local entry = self.undo:pop()
    if not entry then return false end
    self.marks[entry.r][entry.c]       = entry.old
    self.wrong_cells[entry.r][entry.c] = false
    self:_recomputeLit()
    self.won = false
    return true
end

function LightUpBoard:check()
    local n = self.n
    self.wrong_cells = emptyBoolGrid(n, n)

    -- Mark wrong if bulb conflicts with another bulb
    local bulbs = emptyBoolGrid(n, n)
    for r = 1, n do
        for c = 1, n do
            if self.marks[r][c] == MARK_BULB then bulbs[r][c] = true end
        end
    end

    for r = 1, n do
        for c = 1, n do
            if bulbs[r][c] then
                if bulbConflict(bulbs, self.grid, r, c, n) then
                    self.wrong_cells[r][c] = true
                end
            end
        end
    end

    -- Check black cell constraints
    for r = 1, n do
        for c = 1, n do
            local ct = self.grid[r][c]
            if ct >= TYPE_BLACK_0 and ct <= TYPE_BLACK_4 then
                local required = ct - TYPE_BLACK_0
                local actual   = 0
                for _, d in ipairs(DIR4) do
                    local nr, nc = r + d[1], c + d[2]
                    if inBounds(nr, nc, n) and bulbs[nr][nc] then actual = actual + 1 end
                end
                if actual ~= required then
                    -- Mark adjacent bulbs as wrong
                    for _, d in ipairs(DIR4) do
                        local nr, nc = r + d[1], c + d[2]
                        if inBounds(nr, nc, n) and bulbs[nr][nc] then
                            self.wrong_cells[nr][nc] = true
                        end
                    end
                end
            end
        end
    end
end

function LightUpBoard:reveal()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            if self.grid[r][c] == TYPE_WHITE then
                self.marks[r][c] = self.solution[r][c] and MARK_BULB or MARK_EMPTY
            end
        end
    end
    self:_recomputeLit()
    self.won = true
end

function LightUpBoard:_checkWin()
    local n = self.n
    -- All white cells lit, no conflicting bulbs, all constraints met
    for r = 1, n do
        for c = 1, n do
            if self.grid[r][c] == TYPE_WHITE and not self.lit[r][c] then
                self.won = false; return
            end
        end
    end
    -- Check no bulb conflicts
    local bulbs = emptyBoolGrid(n, n)
    for r = 1, n do
        for c = 1, n do
            if self.marks[r][c] == MARK_BULB then bulbs[r][c] = true end
        end
    end
    for r = 1, n do
        for c = 1, n do
            if bulbs[r][c] and bulbConflict(bulbs, self.grid, r, c, n) then
                self.won = false; return
            end
        end
    end
    self.won = true
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function LightUpBoard:serialize()
    local n = self.n
    local grid_flat, sol_flat, marks_flat = {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            grid_flat[#grid_flat + 1]  = self.grid[r][c]
            sol_flat[#sol_flat + 1]    = self.solution[r][c] and 1 or 0
            marks_flat[#marks_flat + 1] = self.marks[r][c]
        end
    end
    return {
        n          = n,
        difficulty = self.difficulty,
        grid       = grid_flat,
        solution   = sol_flat,
        marks      = marks_flat,
        won        = self.won,
    }
end

function LightUpBoard:load(data)
    if type(data) ~= "table" or not data.grid then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFF
    self.grid       = emptyGrid(n, n, TYPE_WHITE)
    self.solution   = emptyBoolGrid(n, n)
    self.marks      = emptyGrid(n, n, MARK_EMPTY)
    self.wrong_cells= emptyBoolGrid(n, n)
    local idx = 1
    for r = 1, n do
        for c = 1, n do
            self.grid[r][c]     = data.grid[idx]     or TYPE_WHITE
            self.solution[r][c] = (data.solution[idx] or 0) == 1
            self.marks[r][c]    = data.marks[idx]    or MARK_EMPTY
            idx = idx + 1
        end
    end
    self.won = data.won or false
    self.undo:clear()
    self:_recomputeLit()
    return true
end

LightUpBoard.TYPE_WHITE   = TYPE_WHITE
LightUpBoard.TYPE_BLACK   = TYPE_BLACK
LightUpBoard.TYPE_BLACK_0 = TYPE_BLACK_0
LightUpBoard.TYPE_BLACK_1 = TYPE_BLACK_1
LightUpBoard.TYPE_BLACK_2 = TYPE_BLACK_2
LightUpBoard.TYPE_BLACK_3 = TYPE_BLACK_3
LightUpBoard.TYPE_BLACK_4 = TYPE_BLACK_4
LightUpBoard.MARK_EMPTY   = MARK_EMPTY
LightUpBoard.MARK_BULB    = MARK_BULB
LightUpBoard.MARK_DOT     = MARK_DOT
LightUpBoard.SIZES        = SIZES
LightUpBoard.DEFAULT_N    = DEFAULT_N
LightUpBoard.DIR4         = DIR4

return LightUpBoard
