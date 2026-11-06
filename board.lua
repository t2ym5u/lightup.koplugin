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

-- What each level asks for (1.6.0; see logicSolve and generate). Up to
-- 1.5, wall density was the only knob, and backwards: Easy's sparse walls
-- made the hardest grids (half of 7x7 Easy needed trial and error).
--   density        share of black cells in the layout
--   tier           the hardest reasoning the puzzle may need
--   keep           share of wall numbers never removed (Easy keeps more)
--   min_t2/max_t2  how many tier-2 deductions the solution needs
-- Easy: the basic rules all the way, with plenty of numbers.
-- Medium: one or two named patterns (three at 14x14), few numbers.
-- Hard: at least three of them (four at 14x14), few numbers.
-- Never trial and error, at any level.
local LEVELS = {
    easy   = function(n) return { density = 0.30, tier = 1, keep = 0.6, min_t2 = 0, max_t2 = 0 } end,
    medium = function(n) return { density = 0.28, tier = 2, keep = 0, min_t2 = 1,
                                  max_t2 = n <= 10 and 2 or 3 } end,
    hard   = function(n) return { density = 0.26, tier = 2, keep = 0,
                                  min_t2 = n <= 10 and 3 or 4, max_t2 = math.huge } end,
}

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

-- Reveals a wall's bulb-adjacency count on a share (reveal_ratio) of the
-- black cells. Since 1.6.0 the generator numbers them all (1.0), then
-- removes the numbers the solver can do without.
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
-- Uniqueness counter (since 1.6.0 only the specs use it, to cross-check
-- logicSolve: the generator relies on the solver alone). The win-check is
-- genuinely rule-based (not a literal
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
-- ---------------------------------------------------------------------------
-- Human-style solver (1.6.0). Grades a puzzle by the reasoning it needs,
-- and never tries a bulb to see what breaks ("assume X, find a
-- contradiction" is guessing, and no level may ask for it).
--
--   tier 1  the rules read straight off the grid:
--           - a bulb's row and column (up to the walls) hold no other bulb;
--           - a numbered wall that already has its count rules out its
--             other neighbours; one whose open neighbours are exactly the
--             bulbs it still needs takes them all (0 and 4 are the
--             simplest cases);
--           - a cell that is not lit yet and can only be lit from one cell
--             left (itself or one cell it sees) gets a bulb there.
--   tier 2  two named patterns, each a fact about what one cell sees,
--           read off the grid without playing on:
--           - "corner of a wall": a numbered wall that can spare only one
--             of its open neighbours: the cell diagonal to it, between two
--             of them, sees both, so it can't hold a bulb (the classic
--             diagonal of a 3, of a 2 with three open sides, of a 1 with
--             two);
--           - "blocked view": a dark cell Y, ruled out itself, that only
--             two cells can light, one in its row and one in its column:
--             the cell at the fourth corner of that rectangle sees both,
--             so a bulb there would leave Y dark for good.
--
-- Tier 2 is only used when tier 1 is stuck. Whatever the solver finishes
-- has exactly one solution (every step is forced), so it doubles as the
-- uniqueness proof.
--
-- logicSolve(grid, n, max_tier) -> solved, t1, t2, bulbs, used, open
--   t1/t2: deductions of each tier (a "step" is one cell decided by one
--   rule application); bulbs: the solution as a bool grid when solved;
--   used: the numbered walls some deduction read, keyed (r - 1) * n + c
--   (a number no deduction read can go: the same steps still work);
--   open: when stuck, the undecided cells as { r, c } pairs.
-- The generator calls it hundreds of times on one layout while it only
-- removes numbers, so the layout's structure (white cells, segments,
-- walls) is built once by prepareLayout and the numbers are read from the
-- grid at each solve.
-- ---------------------------------------------------------------------------

local function prepareLayout(grid, n)
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
    for pass = 1, 2 do
        for a = 1, n do
            local b = 1
            while b <= n do
                local r, c = a, b
                if pass == 2 then r, c = b, a end
                if idx[r][c] then
                    S = S + 1
                    local list = {}
                    while b <= n do
                        r, c = a, b
                        if pass == 2 then r, c = b, a end
                        local i = idx[r][c]
                        if not i then break end
                        if pass == 1 then rseg[i] = S else cseg[i] = S end
                        list[#list + 1] = i
                        b = b + 1
                    end
                    seg_cells[S] = list
                else
                    b = b + 1
                end
            end
        end
    end
    -- Every black cell with a white neighbour (its number, if any, is read
    -- at solve time).
    local walls, wr, wc = {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            if grid[r][c] > TYPE_WHITE then
                local nb = {}
                for _, d in ipairs(DIR4) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and idx[nr][nc] then
                        nb[#nb + 1] = idx[nr][nc]
                    end
                end
                walls[#walls + 1] = nb
                wr[#walls], wc[#walls] = r, c
            end
        end
    end
    local cell_walls = {}   -- white cell -> the black cells next to it
    for i = 1, W do cell_walls[i] = {} end
    for w = 1, #walls do
        for _, i in ipairs(walls[w]) do
            local list = cell_walls[i]
            list[#list + 1] = w
        end
    end
    return { n = n, W = W, cr = cr, cc = cc, rseg = rseg, cseg = cseg,
             seg_cells = seg_cells, S = S, walls = walls, wr = wr, wc = wc,
             cell_walls = cell_walls, idx = idx }
end

local function solveLayout(P, grid, max_tier)
    local n, W, rseg, cseg, seg_cells = P.n, P.W, P.rseg, P.cseg, P.seg_cells
    -- The numbered walls of this grid.
    local walls, wall_need, wall_key = {}, {}, {}
    local num_of = {}       -- P's wall index -> index in walls, if numbered
    local wall_r, wall_c = {}, {}
    local idx = P.idx
    for w = 1, #P.walls do
        local t = grid[P.wr[w]][P.wc[w]]
        if t >= TYPE_BLACK_0 and t <= TYPE_BLACK_4 then
            local k = #walls + 1
            walls[k], wall_need[k] = P.walls[w], t - TYPE_BLACK_0
            wall_key[k] = (P.wr[w] - 1) * n + P.wc[w]
            num_of[w] = k
            wall_r[k], wall_c[k] = P.wr[w], P.wc[w]
        end
    end
    local used = {}
    local cell_walls = P.cell_walls

    -- Work lists: segments and numbered walls whose cells changed since
    -- they were last looked at (all of them at the start).
    local segq, segin, wallq, wallin = {}, {}, {}, {}
    for s = 1, P.S do segq[s], segin[s] = s, true end
    for w = 1, #walls do wallq[w], wallin[w] = w, true end
    local function touched(i)
        local s = rseg[i]
        if not segin[s] then segin[s] = true; segq[#segq + 1] = s end
        s = cseg[i]
        if not segin[s] then segin[s] = true; segq[#segq + 1] = s end
        local cw = cell_walls[i]
        for t = 1, #cw do
            local k = num_of[cw[t]]
            if k and not wallin[k] then wallin[k] = true; wallq[#wallq + 1] = k end
        end
    end

    local val = {}          -- nil undecided / true bulb / false no bulb
    local lit = {}          -- segment -> true once it holds a bulb
    local und = {}          -- segment -> undecided cells left in it
    for s = 1, P.S do lit[s], und[s] = false, #seg_cells[s] end
    local bad = false

    local function isLit(i)
        return lit[rseg[i]] or lit[cseg[i]]
    end
    -- How many cells could still light cell i (i itself counted once).
    local function lighterCount(i)
        local k = und[rseg[i]] + und[cseg[i]]
        if val[i] == nil then k = k - 1 end
        return k
    end
    local function firstLighter(i)
        if val[i] == nil then return i end
        local a, b = seg_cells[rseg[i]], seg_cells[cseg[i]]
        for t = 1, #a do if val[a[t]] == nil then return a[t] end end
        for t = 1, #b do if val[b[t]] == nil then return b[t] end end
    end
    local function setNo(i)
        if val[i] == nil then
            val[i] = false
            und[rseg[i]] = und[rseg[i]] - 1
            und[cseg[i]] = und[cseg[i]] - 1
            touched(i)
        end
    end
    -- A bulb also settles every other cell of its row and column segments
    -- (no bulb there): that is part of the same step.
    local function setBulb(i)
        if val[i] ~= nil then
            if val[i] == false then bad = true end
            return
        end
        if isLit(i) then bad = true; return end
        val[i] = true
        und[rseg[i]] = und[rseg[i]] - 1
        und[cseg[i]] = und[cseg[i]] - 1
        lit[rseg[i]], lit[cseg[i]] = true, true
        touched(i)
        local a, b = seg_cells[rseg[i]], seg_cells[cseg[i]]
        for t = 1, #a do setNo(a[t]) end
        for t = 1, #b do setNo(b[t]) end
    end

    local t1, t2 = 0, 0

    -- Drains the work lists: walls first, then the cells of changed
    -- segments, until nothing changes.
    local function tier1()
        while true do
            local w = wallq[#wallq]
            if w then
                wallq[#wallq] = nil
                wallin[w] = false
                local nb = walls[w]
                local have, open = 0, 0
                for t = 1, #nb do
                    local v = val[nb[t]]
                    if v then have = have + 1 elseif v == nil then open = open + 1 end
                end
                local need = wall_need[w]
                if have > need or have + open < need then bad = true; return end
                if open > 0 and (have == need or have + open == need) then
                    used[wall_key[w]] = true
                    local to = have < need
                    for t = 1, #nb do
                        local j = nb[t]
                        if val[j] == nil then
                            if to then setBulb(j) else setNo(j) end
                            t1 = t1 + 1
                        end
                    end
                    if bad then return end
                end
            else
                local s = segq[#segq]
                if not s then return end
                segq[#segq] = nil
                segin[s] = false
                local list = seg_cells[s]
                for t = 1, #list do
                    local i = list[t]
                    if not isLit(i) then
                        local k = lighterCount(i)
                        if k <= 0 then bad = true; return end
                        if k == 1 then
                            setBulb(firstLighter(i))
                            t1 = t1 + 1
                            if bad then return end
                        end
                    end
                end
            end
        end
    end

    -- The white cell at (r, c), if any.
    local function at(r, c)
        local row = idx[r]
        return row and row[c]
    end

    -- One tier-2 deduction (the first found), or false.
    local function tier2()
        -- Corner of a wall: a wall that can spare only one of its open
        -- neighbours can't lose two, so the cell diagonal to it between
        -- two open neighbours (it sees both) holds no bulb.
        for w = 1, #walls do
            local nb = walls[w]
            local have, open = 0, 0
            for t = 1, #nb do
                local v = val[nb[t]]
                if v then have = have + 1 elseif v == nil then open = open + 1 end
            end
            if open >= 2 and have + open - wall_need[w] == 1 then
                local r, c = wall_r[w], wall_c[w]
                for dr = -1, 1, 2 do
                    for dc = -1, 1, 2 do
                        local a, b, x = at(r + dr, c), at(r, c + dc), at(r + dr, c + dc)
                        if a and b and x and val[a] == nil and val[b] == nil and val[x] == nil then
                            used[wall_key[w]] = true
                            setNo(x)
                            return true
                        end
                    end
                end
            end
        end
        -- Blocked view: a dark cell Y (no bulb itself) that only two cells
        -- can light, one in its row and one in its column: the cell at the
        -- fourth corner of that rectangle sees both, so a bulb there would
        -- leave Y dark for good.
        for y = 1, W do
            if val[y] == false and not isLit(y) and lighterCount(y) == 2 then
                local l_row, l_col
                local a, b = seg_cells[rseg[y]], seg_cells[cseg[y]]
                for t = 1, #a do if val[a[t]] == nil then l_row = a[t] end end
                for t = 1, #b do if val[b[t]] == nil then l_col = b[t] end end
                if l_row and l_col then
                    local x = at(P.cr[l_col], P.cc[l_row])
                    if x and val[x] == nil and cseg[x] == cseg[l_row] and rseg[x] == rseg[l_col] then
                        setNo(x)
                        return true
                    end
                end
            end
        end
        return false
    end

    while true do
        tier1()
        if bad then return false, t1, t2 end
        local done = true
        for i = 1, W do
            if not isLit(i) then done = false; break end
        end
        if done then
            -- Every cell lit, so every cell is decided (a bulb rules out its
            -- segments); the walls must all be met.
            for w = 1, #walls do
                local have = 0
                for t = 1, #walls[w] do
                    if val[walls[w][t]] then have = have + 1 end
                end
                if have ~= wall_need[w] then return false, t1, t2 end
            end
            local bulbs = emptyBoolGrid(n, n)
            for i = 1, W do
                if val[i] then bulbs[P.cr[i]][P.cc[i]] = true end
            end
            return true, t1, t2, bulbs, used
        end
        if max_tier < 2 or not tier2() then
            local open = {}
            for i = 1, W do
                if val[i] == nil then open[#open + 1] = { P.cr[i], P.cc[i] } end
            end
            return false, t1, t2, nil, used, open
        end
        t2 = t2 + 1
    end
end

local function logicSolve(grid, n, max_tier)
    return solveLayout(prepareLayout(grid, n), grid, max_tier)
end

local function wallCount(bulbs, r, c, n)
    local adj = 0
    for _, d in ipairs(DIR4) do
        local nr, nc = r + d[1], c + d[2]
        if inBounds(nr, nc, n) and bulbs[nr][nc] then adj = adj + 1 end
    end
    return TYPE_BLACK_0 + adj
end

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

-- Makes a layout the solver at max_tier finishes. While it is stuck, a
-- cell it left open gets help: first the hidden numbers of the walls
-- around it are shown, and when it has none left, the cell itself (if not
-- a solution bulb, and if every white cell stays lit) becomes a numbered
-- wall. Always ends: once every non-bulb cell is a numbered wall, each
-- bulb is alone in its row and column and tier 1 places it. Returns the
-- solved layout's structure, or nil if no open cell could take help.
local function completeUntilSolved(grid, bulbs, n, max_tier)
    local P = prepareLayout(grid, n)
    while true do
        local ok, _, _, _, _, open = solveLayout(P, grid, max_tier)
        if ok then return P end
        if not open then return nil end
        shuffle(open)
        local helped = false
        for _, cell in ipairs(open) do
            local r, c = cell[1], cell[2]
            for _, d in ipairs(DIR4) do
                local nr, nc = r + d[1], c + d[2]
                if inBounds(nr, nc, n) and grid[nr][nc] == TYPE_BLACK then
                    grid[nr][nc] = wallCount(bulbs, nr, nc, n)
                    helped = true
                end
            end
            if helped then break end
        end
        if not helped then
            for _, cell in ipairs(open) do
                local r, c = cell[1], cell[2]
                if not bulbs[r][c] then
                    grid[r][c] = TYPE_BLACK
                    if stillLit(grid, bulbs, n) then
                        grid[r][c] = wallCount(bulbs, r, c, n)
                        P = prepareLayout(grid, n)
                        helped = true
                        break
                    end
                    grid[r][c] = TYPE_WHITE
                end
            end
        end
        if not helped then return nil end
    end
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

-- Layouts are drawn at the level's wall density, every wall gets its
-- number, then numbers are removed one by one, in random order, as long
-- as the solver limited to the level's tier still finishes (and, for a
-- level with a tier-2 cap, within that cap). A candidate is kept when its
-- tier-2 count lands in the level's window; otherwise the next layout is
-- tried, and after ATTEMPTS layouts the closest one is used. Every grid
-- that leaves here was finished by the solver: one solution, no guessing.
-- All work is bounded by counts (same seed, same puzzle on every device).
function LightUpBoard:generate(diff, on_progress)
    self.difficulty = diff or self.difficulty
    local n = self.n
    local level = (LEVELS[self.difficulty] or LEVELS.medium)(n)
    local ATTEMPTS = LightUpBoard.ATTEMPTS[n] or 12

    local best_grid, best_sol, best_score
    for attempt = 1, ATTEMPTS do
        if on_progress then on_progress((attempt - 1) / ATTEMPTS) end
        local base_grid, bulbs = generateBaseSolution(n, level.density)
        if base_grid then
            local grid = assignWallNumbers(base_grid, bulbs, n, 1.0)
            local P = completeUntilSolved(grid, bulbs, n, level.tier)
            if P then
                local numbered = {}
                for r = 1, n do
                    for c = 1, n do
                        if grid[r][c] >= TYPE_BLACK_0 then numbered[#numbered + 1] = { r, c } end
                    end
                end
                shuffle(numbered)
                local keep = math.floor(#numbered * level.keep + 0.5)
                local left = #numbered
                -- A number the last solve never read goes without a new
                -- solve (the same steps still work); one it read costs a
                -- solve to try.
                local _, _, _, _, used = solveLayout(P, grid, level.tier)
                for _, cell in ipairs(numbered) do
                    if left <= keep then break end
                    local r, c = cell[1], cell[2]
                    local was = grid[r][c]
                    grid[r][c] = TYPE_BLACK
                    if not used[(r - 1) * n + c] then
                        left = left - 1
                    else
                        local ok, _, t2, _, u = solveLayout(P, grid, level.tier)
                        if ok and t2 <= level.max_t2 then
                            left, used = left - 1, u
                        else
                            grid[r][c] = was
                        end
                    end
                end
                local ok, _, t2, sol = solveLayout(P, grid, level.tier)
                if ok then
                    if t2 >= level.min_t2 and t2 <= level.max_t2 then
                        best_grid, best_sol = grid, sol
                        break
                    end
                    -- Off the window: keep the closest, in case no layout
                    -- lands in it.
                    local score = t2 < level.min_t2 and level.min_t2 - t2 or t2 - level.max_t2
                    if not best_score or score < best_score then
                        best_grid, best_sol, best_score = grid, sol, score
                    end
                end
            end
        end
    end

    local grid, sol = best_grid, best_sol
    if not grid then
        -- Unreachable in practice (completeUntilSolved always ends with a
        -- solved grid); a single lit cell keeps the game playable.
        grid = emptyGrid(n, n, TYPE_BLACK)
        grid[1][1] = TYPE_WHITE
        sol  = emptyBoolGrid(n, n)
        sol[1][1] = true
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
    -- Every numbered wall has exactly its count of adjacent bulbs (up to
    -- 1.5 this rule was not checked, so a grid could win with a wrong
    -- count).
    for r = 1, n do
        for c = 1, n do
            local ct = self.grid[r][c]
            if ct >= TYPE_BLACK_0 and ct <= TYPE_BLACK_4 then
                local adj = 0
                for _, d in ipairs(DIR4) do
                    local nr, nc = r + d[1], c + d[2]
                    if inBounds(nr, nc, n) and bulbs[nr][nc] then adj = adj + 1 end
                end
                if adj ~= ct - TYPE_BLACK_0 then
                    self.won = false; return
                end
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

LightUpBoard.LEVELS       = LEVELS
-- Layouts tried per puzzle, by size: small layouts are cheap but miss
-- the Hard window more often.
LightUpBoard.ATTEMPTS     = { [7] = 60, [10] = 30, [14] = 12 }

-- for the specs
LightUpBoard._logicSolve           = logicSolve
LightUpBoard._countSolutions       = countSolutions
LightUpBoard._generateBaseSolution = generateBaseSolution
LightUpBoard._assignWallNumbers    = assignWallNumbers

return LightUpBoard
