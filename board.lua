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
-- classic Akari deduction rules -- a bulb rules out the rest of its row and
-- column segments, wall forcing (a numbered wall's remaining undecided
-- neighbors get forced to bulb/not-bulb once there's only one way left to
-- satisfy its count) and illumination forcing (a not-yet-lit cell with
-- exactly one remaining candidate across its row+col segments must be a
-- bulb) -- then branching on a candidate bulb of the unlit cell with the
-- fewest candidates. Returns (count, exhausted, first, second) with the
-- first two solutions found as bulb grids.
--
-- 1.5.0: cells and segments are plain integer-indexed arrays and the
-- search keeps one undo trail; the old version (string segment keys, fresh
-- tables at every step, branching on the first unlit cell) ran out of its
-- node budget on most 14x14 layouts and took up to 6 s per 10x10 Easy
-- puzzle on a desktop. Same counts, checked against it on random layouts.
-- ---------------------------------------------------------------------------

local function countSolutions(grid, n, limit, node_budget)
    -- White cells 1..W, their row/column segments, the numbered walls.
    local idx, cr, cc = {}, {}, {}
    local W = 0
    for r = 1, n do
        idx[r] = {}
        for c = 1, n do
            if grid[r][c] == TYPE_WHITE then
                W = W + 1
                idx[r][c], cr[W], cc[W] = W, r, c
            end
        end
    end
    local rseg, cseg, seg_cells, S = {}, {}, {}, 0
    for r = 1, n do
        local c = 1
        while c <= n do
            if idx[r][c] then
                S = S + 1
                local list = {}
                while c <= n and idx[r][c] do
                    rseg[idx[r][c]] = S
                    list[#list + 1] = idx[r][c]
                    c = c + 1
                end
                seg_cells[S] = list
            else
                c = c + 1
            end
        end
    end
    for c = 1, n do
        local r = 1
        while r <= n do
            if idx[r][c] then
                S = S + 1
                local list = {}
                while r <= n and idx[r][c] do
                    cseg[idx[r][c]] = S
                    list[#list + 1] = idx[r][c]
                    r = r + 1
                end
                seg_cells[S] = list
            else
                r = r + 1
            end
        end
    end
    local walls, wall_need = {}, {}
    for r = 1, n do
        for c = 1, n do
            local t = grid[r][c]
            if t >= TYPE_BLACK_0 and t <= TYPE_BLACK_4 then
                local nb = {}
                for _, d in ipairs(DIR4) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and idx[nr][nc] then
                        nb[#nb + 1] = idx[nr][nc]
                    end
                end
                walls[#walls + 1] = nb
                wall_need[#walls] = t - TYPE_BLACK_0
            end
        end
    end

    local val = {}          -- nil undecided / true bulb / false no bulb
    local seg_bulb = {}     -- segment -> true when it holds a bulb
    for s = 1, S do seg_bulb[s] = false end
    local trail, top = {}, 0

    local function set(i, v)
        local cur = val[i]
        if cur ~= nil then return cur == v end
        if v and (seg_bulb[rseg[i]] or seg_bulb[cseg[i]]) then return false end
        val[i] = v
        top = top + 1
        trail[top] = i
        if v then
            seg_bulb[rseg[i]] = true
            seg_bulb[cseg[i]] = true
        end
        return true
    end
    local function undoTo(mark)
        while top > mark do
            local i = trail[top]
            if val[i] then
                seg_bulb[rseg[i]] = false
                seg_bulb[cseg[i]] = false
            end
            val[i] = nil
            trail[top] = nil
            top = top - 1
        end
    end

    -- Fixed point of: a bulb rules out the rest of its two segments; a wall
    -- with its count reached rules out its other neighbours, one that needs
    -- all its undecided neighbours takes them; an unlit cell with a single
    -- possible bulb (in its row or column segment) takes it. Returns false
    -- on a contradiction.
    local function propagate()
        local progressed = true
        while progressed do
            progressed = false
            for i = 1, W do
                if val[i] then
                    for pass = 1, 2 do
                        local list = seg_cells[pass == 1 and rseg[i] or cseg[i]]
                        for t = 1, #list do
                            local j = list[t]
                            if val[j] == nil then
                                if not set(j, false) then return false end
                                progressed = true
                            end
                        end
                    end
                end
            end
            for w = 1, #walls do
                local have, und = 0, 0
                local nb = walls[w]
                for t = 1, #nb do
                    local v = val[nb[t]]
                    if v then have = have + 1 elseif v == nil then und = und + 1 end
                end
                local need = wall_need[w]
                if have > need or have + und < need then return false end
                if und > 0 and (have == need or have + und == need) then
                    local to = have < need
                    for t = 1, #nb do
                        if val[nb[t]] == nil then
                            if not set(nb[t], to) then return false end
                        end
                    end
                    progressed = true
                end
            end
            for i = 1, W do
                if not seg_bulb[rseg[i]] and not seg_bulb[cseg[i]] then
                    -- i itself sits in both segments: count it once
                    local cand, count = nil, val[i] == nil and 1 or 0
                    if count == 1 then cand = i end
                    for pass = 1, 2 do
                        local list = seg_cells[pass == 1 and rseg[i] or cseg[i]]
                        for t = 1, #list do
                            local j = list[t]
                            if j ~= i and val[j] == nil then
                                count = count + 1
                                cand = j
                                if count > 1 then break end
                            end
                        end
                        if count > 1 then break end
                    end
                    if count == 0 then return false end
                    if count == 1 then
                        if not set(cand, true) then return false end
                        progressed = true
                    end
                end
            end
        end
        return true
    end

    local solutions, nodes, exhausted = 0, 0, false
    local found = {}

    local function search()
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        local mark = top
        if not propagate() then undoTo(mark); return end
        -- Branch on a candidate bulb of the unlit cell with the fewest.
        local best_i, best_count = nil, math.huge
        for i = 1, W do
            if not seg_bulb[rseg[i]] and not seg_bulb[cseg[i]] then
                local count, first = 0, nil
                if val[i] == nil then count, first = 1, i end
                for pass = 1, 2 do
                    local list = seg_cells[pass == 1 and rseg[i] or cseg[i]]
                    for t = 1, #list do
                        local j = list[t]
                        if j ~= i and val[j] == nil then count = count + 1; first = first or j end
                    end
                end
                if count < best_count then best_count, best_i = count, first end
            end
        end
        if not best_i then
            -- Everything lit; propagation has ruled out every other cell
            -- (each sits in a lit segment) and the walls are consistent:
            -- all undecided cells are forced false already.
            for i = 1, W do
                if val[i] == nil then best_i = i; break end
            end
            if not best_i then
                solutions = solutions + 1
                if solutions <= 2 then
                    local sol = {}
                    for r = 1, n do
                        sol[r] = {}
                        for c = 1, n do sol[r][c] = (idx[r][c] and val[idx[r][c]]) == true end
                    end
                    found[solutions] = sol
                end
                undoTo(mark)
                return
            end
        end
        for _, v in ipairs({ true, false }) do
            local m2 = top
            if set(best_i, v) then search() end
            undoTo(m2)
            if solutions >= limit or exhausted then break end
        end
        undoTo(mark)
    end
    search()
    return solutions, exhausted, found[1], found[2]
end
-- Node counts, not time, so a seed gives the same puzzle on any device;
-- the counter concludes well within this on every layout measured.
local NODE_BUDGET = 100000

-- Escalating reveal ratios: the nominal ~60% reveal (matching the genre's
-- usual difficulty feel) is frequently ambiguous, especially at low black-
-- cell density ("easy"), but more revealed wall numbers can only ADD
-- constraints, never remove any -- so if the nominal ratio keeps coming
-- back ambiguous, try progressively denser reveals before tweaking the
-- layout. Same escalation shape as hitori's fix.
local REVEAL_LEVELS = { 0.6, 0.8, 1.0 }

-- Still ambiguous with every wall numbered: pick a cell where a rival
-- solution has a bulb and ours doesn't (or, failing that, one whose count
-- of adjacent bulbs differs between the two), and turn it into a numbered
-- wall (its count of our bulbs). Our solution stays valid as long as every
-- white cell is still lit (the new wall only blocks light); the rival is
-- gone. Repeat until unique, or give up on this layout.
local MAX_WALL_TWEAKS = 16

local function stillLit(grid, bulbs, n)
    local lit = emptyBoolGrid(n, n)
    for r = 1, n do
        for c = 1, n do
            if bulbs[r][c] then markLit(lit, nil, grid, r, c, n) end
        end
    end
    for r = 1, n do
        for c = 1, n do
            if grid[r][c] == TYPE_WHITE and not lit[r][c] then return false end
        end
    end
    return true
end

local function tweakUntilUnique(grid, bulbs, n, rival)
    for step = 1, MAX_WALL_TWEAKS do
        -- A rival bulb's cell first; else any cell whose wall number would
        -- tell the two apart (a different count of adjacent bulbs).
        local cands, others = {}, {}
        for r = 1, n do
            for c = 1, n do
                if grid[r][c] == TYPE_WHITE and not bulbs[r][c] then
                    if rival[r][c] then
                        cands[#cands + 1] = { r, c }
                    else
                        local diff = 0
                        for _, d in ipairs(DIR4) do
                            local nr, nc = r + d[1], c + d[2]
                            if inBounds(nr, nc, n) then
                                if bulbs[nr][nc] then diff = diff + 1 end
                                if rival[nr][nc] then diff = diff - 1 end
                            end
                        end
                        if diff ~= 0 then others[#others + 1] = { r, c } end
                    end
                end
            end
        end
        shuffle(cands)
        shuffle(others)
        for _, cell in ipairs(others) do cands[#cands + 1] = cell end
        local placed = false
        for _, cell in ipairs(cands) do
            local r, c = cell[1], cell[2]
            grid[r][c] = TYPE_BLACK
            if stillLit(grid, bulbs, n) then
                local adj = 0
                for _, d in ipairs(DIR4) do
                    local nr, nc = r + d[1], c + d[2]
                    if inBounds(nr, nc, n) and bulbs[nr][nc] then adj = adj + 1 end
                end
                grid[r][c] = TYPE_BLACK_0 + adj
                placed = true
                break
            end
            grid[r][c] = TYPE_WHITE
        end
        if not placed then return false, step - 1 end
        local solutions, exhausted, first, second = countSolutions(grid, n, 2, NODE_BUDGET)
        if exhausted or solutions == 0 then return false, step end
        if solutions == 1 then return true, step end
        rival = second
        for r = 1, n do
            for c = 1, n do
                if first[r][c] ~= bulbs[r][c] then rival = first; break end
            end
            if rival == first then break end
        end
    end
    return false, MAX_WALL_TWEAKS
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
    -- opts.empty: the caller loads a save or generates right after (with
    -- the progress bar), so skip the throwaway puzzle.
    if not opts.empty then obj:generate() end
    return obj
end

-- The win-check is genuinely rule-based (see countSolutions' header) --
-- there's no "given" mask to dig, so like hitori/nurikabe/starbattle this
-- generates+verifies whole candidates instead. Measured pre-fix: severe,
-- real ambiguity (0% unique at easy/medium across every size, ~13% even
-- at hard). Repicking which black cells reveal their wall number (for the
-- SAME base black-cell+bulb layout) is much cheaper than regenerating that
-- layout from scratch, and more revealed numbers can only add constraints
-- -- same lever as shikaku's clue-cell repositioning: the reveal ratio
-- escalates in bounded steps (0.6 -> 0.8 -> 1.0), same shape as hitori's
-- density escalation.
--
-- Up to 1.4, low black-cell density ("easy") often stayed ambiguous even
-- with every wall numbered: 10x10 Easy shipped an unproven layout ~80% of
-- the time and 14x14 Easy nearly always, after up to 6 s of retries on a
-- desktop (minutes on a Kobo). Now a layout still ambiguous at full reveal
-- gets a few extra numbered walls (tweakUntilUnique) until it is unique.
function LightUpBoard:generate(diff, on_progress)
    self.difficulty = diff or self.difficulty
    local n = self.n
    local density = BLACK_DENSITY[self.difficulty] or 0.28
    local base_attempts = 8

    local best_grid, best_sol

    for base_attempt = 1, base_attempts do
        if on_progress then on_progress((base_attempt - 1) / base_attempts) end
        local base_grid, bulbs = generateBaseSolution(n, density)
        if base_grid then
            local grid, rival
            for _, reveal_ratio in ipairs(REVEAL_LEVELS) do
                grid = assignWallNumbers(base_grid, bulbs, n, reveal_ratio)

                if not best_grid then
                    best_grid, best_sol = grid, bulbs
                end

                local solutions, exhausted, first, second = countSolutions(grid, n, 2, NODE_BUDGET)
                local unique = solutions == 1 and not exhausted
                if not unique and not exhausted and solutions >= 2 then
                    rival = second
                    for r = 1, n do
                        for c = 1, n do
                            if first[r][c] ~= bulbs[r][c] then rival = first; break end
                        end
                        if rival == first then break end
                    end
                else
                    rival = nil
                end
                if not unique and rival and reveal_ratio == REVEAL_LEVELS[#REVEAL_LEVELS] then
                    unique = tweakUntilUnique(grid, bulbs, n, rival)
                end
                if unique then
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

-- for the specs
LightUpBoard._countSolutions       = countSolutions
LightUpBoard._generateBaseSolution = generateBaseSolution
LightUpBoard._assignWallNumbers    = assignWallNumbers

return LightUpBoard
