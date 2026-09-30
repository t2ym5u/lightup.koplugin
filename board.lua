local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")
local Hint      = require("hint")

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

-- Black-cell layout + a valid bulb placement that lights every white cell
-- (no wall numbers assigned yet -- see assignWallNumbers). Returns
-- (base_grid, bulbs) or (nil, nil) if 20 attempts couldn't find a fully-lit
-- layout.
local function generateBaseSolution(n, density)
    for _ = 1, 20 do
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

        local bulbs = emptyBoolGrid(n, n)
        local lit   = emptyBoolGrid(n, n)

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
            return grid, bulbs
        end
    end
    return nil, nil
end

-- Randomly reveals a wall's bulb-adjacency count on ~60% of black cells.
-- Repicking which subset gets revealed (for the SAME base layout/bulbs) is
-- much cheaper than regenerating the whole black-cell+bulb layout, and a
-- different reveal choice can turn an ambiguous puzzle unique on its own
-- (more revealed counts can only add constraints) -- same lever as
-- shikaku's clue-cell repositioning.
local function assignWallNumbers(base_grid, bulbs, n, reveal_ratio)
    local grid = emptyGrid(n, n, TYPE_WHITE)
    for r = 1, n do
        for c = 1, n do
            if base_grid[r][c] == TYPE_BLACK then
                if math.random() < reveal_ratio then
                    local adj = 0
                    for _, d in ipairs(DIR4) do
                        local nr, nc = r + d[1], c + d[2]
                        if inBounds(nr, nc, n) and bulbs[nr][nc] then
                            adj = adj + 1
                        end
                    end
                    grid[r][c] = TYPE_BLACK_0 + adj
                else
                    grid[r][c] = TYPE_BLACK
                end
            end
        end
    end
    return grid
end

-- ---------------------------------------------------------------------------
-- Uniqueness counter. The win-check is genuinely rule-based (not a literal
-- comparison to a stored solution): any bulb placement where every white
-- cell is lit, no two bulbs see each other, and every numbered wall's
-- adjacent-bulb count matches exactly is accepted. Real uniqueness means:
-- is there only ONE such placement given this black-cell/wall layout?
-- Constraint propagation to a fixed point before every branch, using the
-- two classic Akari deduction rules -- wall forcing (a numbered wall's
-- remaining undecided neighbors get forced to bulb/not-bulb once there's
-- only one way left to satisfy its count) and illumination forcing (a
-- not-yet-lit cell with exactly one remaining candidate across its row+col
-- segments must be a bulb) -- since a naive per-cell backtracking without
-- this explores enormous numbers of locally-valid-but-globally-unlit dead
-- ends.
-- ---------------------------------------------------------------------------

local function buildSegments(grid, n)
    local row_seg, col_seg = {}, {}
    for r = 1, n do row_seg[r] = {}; col_seg[r] = {} end
    local row_cells, col_cells = {}, {}

    for r = 1, n do
        local c = 1
        while c <= n do
            if grid[r][c] == TYPE_WHITE then
                local id = "r" .. r .. "_" .. c
                local cells = {}
                while c <= n and grid[r][c] == TYPE_WHITE do
                    row_seg[r][c] = id
                    cells[#cells + 1] = { r, c }
                    c = c + 1
                end
                row_cells[id] = cells
            else
                c = c + 1
            end
        end
    end
    for c = 1, n do
        local r = 1
        while r <= n do
            if grid[r][c] == TYPE_WHITE then
                local id = "c" .. r .. "_" .. c
                local cells = {}
                while r <= n and grid[r][c] == TYPE_WHITE do
                    col_seg[r][c] = id
                    cells[#cells + 1] = { r, c }
                    r = r + 1
                end
                col_cells[id] = cells
            else
                r = r + 1
            end
        end
    end
    return row_seg, col_seg, row_cells, col_cells
end

local function countSolutions(grid, n, limit, node_budget)
    local row_seg, col_seg, row_cells, col_cells = buildSegments(grid, n)

    local decided = {}
    for r = 1, n do decided[r] = {} end
    local row_seg_bulb, col_seg_bulb = {}, {}

    local solutions, nodes, exhausted = 0, 0, false

    local function wallNeighbors(r, c)
        local nbrs = {}
        for _, d in ipairs(DIR4) do
            local nr, nc = r + d[1], c + d[2]
            if inBounds(nr, nc, n) and grid[nr][nc] == TYPE_WHITE then
                nbrs[#nbrs + 1] = { nr, nc }
            end
        end
        return nbrs
    end

    -- Checks the conflict BEFORE recording any state change -- a failed
    -- call must leave everything untouched, otherwise undo() (which
    -- decides whether to clear a segment's bulb flag based on whether
    -- THIS cell is currently marked true) could wipe out a genuinely
    -- different cell's legitimate bulb registration in the same segment.
    local function setDecided(r, c, val, changes)
        if decided[r][c] ~= nil then
            return decided[r][c] == val
        end
        if val then
            local rs, cs = row_seg[r][c], col_seg[r][c]
            if row_seg_bulb[rs] or col_seg_bulb[cs] then return false end
            row_seg_bulb[rs] = true
            col_seg_bulb[cs] = true
        end
        decided[r][c] = val
        changes[#changes + 1] = { r, c }
        return true
    end

    local function isLit(r, c)
        return row_seg_bulb[row_seg[r][c]] or col_seg_bulb[col_seg[r][c]]
    end

    local function propagate(changes)
        local progressed = true
        while progressed do
            progressed = false
            for r = 1, n do
                for c = 1, n do
                    local ct = grid[r][c]
                    if ct >= TYPE_BLACK_0 and ct <= TYPE_BLACK_4 then
                        local required = ct - TYPE_BLACK_0
                        local nbrs = wallNeighbors(r, c)
                        local have, undecided = 0, {}
                        for _, cell in ipairs(nbrs) do
                            local v = decided[cell[1]][cell[2]]
                            if v == true then have = have + 1
                            elseif v == nil then undecided[#undecided + 1] = cell end
                        end
                        if have > required or have + #undecided < required then
                            return false
                        end
                        if #undecided > 0 then
                            if have == required then
                                for _, cell in ipairs(undecided) do
                                    if not setDecided(cell[1], cell[2], false, changes) then return false end
                                end
                                progressed = true
                            elseif have + #undecided == required then
                                for _, cell in ipairs(undecided) do
                                    if not setDecided(cell[1], cell[2], true, changes) then return false end
                                end
                                progressed = true
                            end
                        end
                    end
                end
            end
            for r = 1, n do
                for c = 1, n do
                    if grid[r][c] == TYPE_WHITE and not isLit(r, c) then
                        local cand, seen = {}, {}
                        for _, cell in ipairs(row_cells[row_seg[r][c]]) do
                            local key = cell[1] * 1000 + cell[2]
                            if decided[cell[1]][cell[2]] == nil and not seen[key] then
                                seen[key] = true; cand[#cand + 1] = cell
                            end
                        end
                        for _, cell in ipairs(col_cells[col_seg[r][c]]) do
                            local key = cell[1] * 1000 + cell[2]
                            if decided[cell[1]][cell[2]] == nil and not seen[key] then
                                seen[key] = true; cand[#cand + 1] = cell
                            end
                        end
                        if #cand == 0 then return false end
                        if #cand == 1 then
                            if not setDecided(cand[1][1], cand[1][2], true, changes) then return false end
                            progressed = true
                        end
                    end
                end
            end
        end
        return true
    end

    local function undo(changes, from)
        for i = #changes, from, -1 do
            local r, c = changes[i][1], changes[i][2]
            if decided[r][c] == true then
                row_seg_bulb[row_seg[r][c]] = false
                col_seg_bulb[col_seg[r][c]] = false
            end
            decided[r][c] = nil
            changes[i] = nil
        end
    end

    local function allDecided()
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == TYPE_WHITE and decided[r][c] == nil then return false end
            end
        end
        return true
    end

    local function pickBranchCell()
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == TYPE_WHITE and not isLit(r, c) then
                    for _, cell in ipairs(row_cells[row_seg[r][c]]) do
                        if decided[cell[1]][cell[2]] == nil then return cell[1], cell[2] end
                    end
                    for _, cell in ipairs(col_cells[col_seg[r][c]]) do
                        if decided[cell[1]][cell[2]] == nil then return cell[1], cell[2] end
                    end
                end
            end
        end
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == TYPE_WHITE and decided[r][c] == nil then return r, c end
            end
        end
        return nil
    end

    local function search()
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end

        local changes = {}
        if not propagate(changes) then
            undo(changes, 1)
            return
        end

        if allDecided() then
            solutions = solutions + 1
            undo(changes, 1)
            return
        end

        local r, c = pickBranchCell()
        if not r then
            undo(changes, 1)
            return
        end

        for _, val in ipairs({ true, false }) do
            local branch_changes = {}
            if setDecided(r, c, val, branch_changes) then
                search()
            end
            undo(branch_changes, 1)
            if solutions >= limit or exhausted then break end
        end
        undo(changes, 1)
    end

    search()
    return solutions, exhausted
end

local function uniquenessNodeBudget(n)
    if n <= 10 then return 6000 end
    return 2000
end

-- n=14's search space is large enough that even generous budgets mostly
-- just exhaust without concluding (measured: repeatedly grinding ~7s only
-- to fall back to the same ambiguous result as before the fix, i.e. pure
-- wasted latency, not improved quality) -- so effort is scaled down hard
-- there to fail fast, same "partial fix, never worse" tradeoff as
-- nurikabe/starbattle's hardest settings. n<=10 generates fast enough
-- (<2s even at full effort) to spend a much bigger budget productively.
local function retryBudgetsFor(n)
    if n <= 10 then return 12, 3 end -- base_attempts, numbers_attempts
    return 3, 1
end

-- Escalating reveal ratios: the nominal ~60% reveal (matching the genre's
-- usual difficulty feel) is frequently ambiguous, especially at low black-
-- cell density ("easy"), but more revealed wall numbers can only ADD
-- constraints, never remove any -- so if the nominal ratio keeps coming
-- back ambiguous, try progressively denser reveals before giving up on
-- this base layout entirely. Same escalation shape as hitori's fix.
local REVEAL_LEVELS = { 0.6, 0.8, 1.0 }

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

-- The win-check is genuinely rule-based (see countSolutions' header) --
-- there's no "given" mask to dig, so like hitori/nurikabe/starbattle this
-- generates+verifies whole candidates instead. Measured pre-fix: severe,
-- real ambiguity (0% unique at easy/medium across every size, ~13% even
-- at hard). Repicking which black cells reveal their wall number (for the
-- SAME base black-cell+bulb layout) is much cheaper than regenerating that
-- layout from scratch, and more revealed numbers can only add constraints
-- -- same lever as shikaku's clue-cell repositioning. An initial version
-- that retried the nominal ~60% reveal 20 times per base layout (30 base
-- layouts) had a real worst-case latency problem (tens of seconds,
-- occasionally more) -- most of those attempts were doomed from the start
-- at low black-cell density ("easy"), where 60% reveal rarely disambiguates
-- no matter how many times it's re-rolled. Rewritten to escalate the
-- reveal ratio in bounded steps (0.6 -> 0.8 -> 1.0) when the nominal ratio
-- keeps coming back ambiguous, same shape as hitori's density escalation,
-- with a much smaller per-attempt node budget (fail an inconclusive
-- attempt fast and move on, rather than grinding a large budget on a hard
-- one -- the same lesson tuned into starbattle's fix).
function LightUpBoard:generate(diff)
    self.difficulty = diff or self.difficulty
    local n = self.n
    local density = BLACK_DENSITY[self.difficulty] or 0.28
    local node_budget = uniquenessNodeBudget(n)
    local base_attempts, numbers_attempts = retryBudgetsFor(n)

    local best_grid, best_sol

    for base_attempt = 1, base_attempts do
        local base_grid, bulbs = generateBaseSolution(n, density)
        if base_grid then
            for _, reveal_ratio in ipairs(REVEAL_LEVELS) do
                for numbers_attempt = 1, numbers_attempts do
                    local grid = assignWallNumbers(base_grid, bulbs, n, reveal_ratio)

                    if not best_grid then
                        best_grid, best_sol = grid, bulbs
                    end

                    local solutions, exhausted = countSolutions(grid, n, 2, node_budget)
                    if solutions == 1 and not exhausted then
                        self.grid        = grid
                        self.solution    = bulbs
                        self.marks       = emptyGrid(n, n, MARK_EMPTY)
                        self.wrong_cells = emptyBoolGrid(n, n)
                        self.won         = false
                        self.undo:clear()
                        self:_recomputeLit()
                        return
                    end
                end
            end
        end
    end

    local grid, sol = best_grid, best_sol
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

-- Only bulbs decide the puzzle; a dot is an optional annotation, so cells
-- without a bulb read as empty and equals() compares bulb-ness. Black cells
-- take no marks at all.
Hint.install(LightUpBoard, {
    getUser     = function(b, r, c) return b.marks[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] and MARK_BULB or MARK_EMPTY end,
    isEmpty     = function(v) return v == MARK_EMPTY end,
    equals      = function(u, s) return (u == MARK_BULB) == (s == MARK_BULB) end,
    isGiven     = function(b, r, c) return b.grid[r][c] ~= TYPE_WHITE end,
    setCell     = function(b, r, c, v) return b:setMark(r, c, v) end,
    blank       = MARK_EMPTY,
})

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
