local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("LightUpBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local function newBoard(diff)
        math.randomseed(42)
        return Board:new({ n = 7, difficulty = diff or "easy" })
    end

    describe("new / generate", function()
        it("creates a 7x7 board whose solution lights every white cell", function()
            local b = newBoard()
            assert.are.equal(7, b.n)
            local n = b.n
            local function isLit(r, c)
                if b.solution[r][c] then return true end
                for _, d in ipairs(Board.DIR4) do
                    local nr, nc = r + d[1], c + d[2]
                    while nr >= 1 and nr <= n and nc >= 1 and nc <= n
                        and b.grid[nr][nc] == Board.TYPE_WHITE do
                        if b.solution[nr][nc] then return true end
                        nr, nc = nr + d[1], nc + d[2]
                    end
                end
                return false
            end
            for r = 1, n do
                for c = 1, n do
                    if b.grid[r][c] == Board.TYPE_WHITE then
                        assert.is_true(isLit(r, c), ("white cell [%d][%d] not lit"):format(r, c))
                    end
                end
            end
        end)

        it("no two solution bulbs see each other", function()
            local b = newBoard()
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if b.solution[r][c] then
                        for dc = -1, 1, 2 do
                            local nc = c + dc
                            while nc >= 1 and nc <= n and b.grid[r][nc] == Board.TYPE_WHITE do
                                assert.is_false(b.solution[r][nc] and true or false)
                                nc = nc + dc
                            end
                        end
                    end
                end
            end
        end)
    end)

    -- 1.5.0: an array-based counter replaced the old one (same rules,
    -- same counts; the old one took up to 6 s per 10x10 Easy puzzle on a
    -- desktop and ran out of budget on most 14x14 layouts), and layouts
    -- still ambiguous at full reveal get extra numbered walls. Keep the old
    -- counter here and check the two agree, and that every size and
    -- difficulty now yields a uniquely solvable puzzle, quickly.
    describe("counter and generator", function()
        local TYPE_WHITE, TYPE_BLACK_0, TYPE_BLACK_4 = 0, 2, 6
        local DIR4 = { {-1,0},{1,0},{0,-1},{0,1} }
        local function inBounds(r, c, n)
            return r >= 1 and r <= n and c >= 1 and c <= n
        end

        -- The pre-1.5.0 counter, verbatim.
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

        local function oldCountSolutions(grid, n, limit, node_budget)
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
        it("counts the same solutions as the old counter on random layouts", function()
            local dens = { 0.2, 0.28, 0.35 }
            for _, n in ipairs({ 5, 7, 10 }) do
                for seed = 1, 30 do
                    math.randomseed(seed * 7177 + n)
                    local base, bulbs = Board._generateBaseSolution(n, dens[seed % 3 + 1])
                    if base then
                        local grid = Board._assignWallNumbers(base, bulbs, n, ({ 0.3, 0.6, 0.8, 1.0 })[seed % 4 + 1])
                        local so, eo = oldCountSolutions(grid, n, 3, 300000)
                        local sn, en = Board._countSolutions(grid, n, 3, 1000000)
                        if not eo then
                            assert.is_false(en)
                            assert.are.equal(so, sn, ("n=%d seed %d"):format(n, seed))
                        end
                    end
                end
            end
        end)

        it("builds uniquely solvable puzzles quickly at every size and difficulty", function()
            for _, n in ipairs(Board.SIZES) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, 8 do
                        math.randomseed(seed * 7919 + n)
                        local t0 = os.clock()
                        local b = Board:new{ n = n, difficulty = diff }
                        worst = math.max(worst, os.clock() - t0)
                        local count, exhausted, sol = Board._countSolutions(b.grid, n, 2, 10000000)
                        assert.is_false(exhausted)
                        assert.are.equal(1, count, ("n=%d %s seed %d not unique"):format(n, diff, seed))
                        assert.are.same(b.solution, sol)
                    end
                    -- generous: ~0.05 s on a desktop
                    assert.is_true(worst < 2.0, ("n=%d %s took %.2f s"):format(n, diff, worst))
                end
            end
        end)
    end)

    -- 1.6.0: a no-trial solver grades every puzzle. Up to 1.5 the levels
    -- were set by wall density alone and came out backwards (Easy's sparse
    -- walls made the hardest grids, half of 7x7 Easy needed trial and
    -- error).
    describe("logic solver and levels", function()
        local SEEDS = 12

        it("finishes only puzzles with exactly one solution, and finds it", function()
            local finished, checked = 0, 0
            for _, n in ipairs({ 5, 7, 10 }) do
                for seed = 1, 120 do
                    math.randomseed(seed * 131 + n)
                    local base, bulbs = Board._generateBaseSolution(n, ({ 0.2, 0.26, 0.32 })[seed % 3 + 1])
                    if base then
                        local grid = Board._assignWallNumbers(base, bulbs, n, ({ 0.3, 0.6, 0.8, 1.0 })[seed % 4 + 1])
                        local count, exhausted, sol = Board._countSolutions(grid, n, 2, 1000000)
                        assert.is_false(exhausted)
                        local ok, _, _, lsol = Board._logicSolve(grid, n, 2)
                        checked = checked + 1
                        if ok then
                            finished = finished + 1
                            assert.are.equal(1, count, ("n=%d seed %d"):format(n, seed))
                            assert.are.same(sol, lsol)
                        end
                    end
                end
            end
            -- both outcomes were exercised
            assert.is_true(finished > 20 and finished < checked, ("%d/%d"):format(finished, checked))
        end)

        it("needs no trial and error, at every size and level, and levels differ", function()
            for _, n in ipairs(Board.SIZES) do
                local mean = {}
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local level = Board.LEVELS[diff](n)
                    local sum, inside = 0, 0
                    for seed = 1, SEEDS do
                        math.randomseed(seed * 7919 + n)
                        local b = Board:new{ n = n, difficulty = diff }
                        local ok, _, t2, sol = Board._logicSolve(b.grid, n, level.tier)
                        assert.is_true(ok, ("n=%d %s seed %d"):format(n, diff, seed))
                        assert.are.same(b.solution, sol)
                        local ok1 = Board._logicSolve(b.grid, n, 1)
                        if diff == "easy" then
                            assert.is_true(ok1)
                        else
                            -- medium and hard need at least one named pattern
                            assert.is_false(ok1, ("n=%d %s seed %d"):format(n, diff, seed))
                        end
                        sum = sum + t2
                        if t2 >= level.min_t2 and t2 <= level.max_t2 then inside = inside + 1 end
                    end
                    mean[diff] = sum / SEEDS
                    assert.is_true(inside >= SEEDS - 1, ("n=%d %s: %d/%d in window"):format(n, diff, inside, SEEDS))
                end
                assert.are.equal(0, mean.easy)
                assert.is_true(mean.medium >= 1 and mean.hard > mean.medium + 1,
                    ("n=%d medium %.1f hard %.1f"):format(n, mean.medium, mean.hard))
            end
        end)

        it("is deterministic: same seed, same puzzle", function()
            for _, n in ipairs(Board.SIZES) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    math.randomseed(1234 + n)
                    local a = Board:new{ n = n, difficulty = diff }
                    math.randomseed(1234 + n)
                    local b = Board:new{ n = n, difficulty = diff }
                    assert.are.same(a.grid, b.grid)
                    assert.are.same(a.solution, b.solution)
                end
            end
        end)

        it("generates quickly (generous bound)", function()
            for _, n in ipairs(Board.SIZES) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, 10 do
                        math.randomseed(seed * 31 + n)
                        local b = Board:new{ n = n, difficulty = diff, empty = true }
                        local t0 = os.clock()
                        b:generate(diff)
                        worst = math.max(worst, os.clock() - t0)
                    end
                    -- measured worst ~0.07 s (14x14 Hard) on a desktop
                    assert.is_true(worst < 0.5, ("n=%d %s took %.2f s"):format(n, diff, worst))
                end
            end
        end)

        it("loads a save made by 1.5", function()
            local save = { n = 7, difficulty = "easy", won = false,
              grid = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 4, 4, 0, 0, 0, 0, 0, 0, 0, 3, 0, 4, 0, 2, 3, 0, 0, 0, 0, 0 },
              solution = { 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 },
              marks = { 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }
            local b = Board:new{ n = 10, empty = true }
            assert.is_true(b:load(save))
            assert.are.equal(7, b.n)
            assert.are.equal(Board.MARK_BULB, b.marks[1][5])
            assert.is_false(b.won)
            b:reveal()
            assert.is_true(b.won)
        end)
    end)

    describe("cycleCell", function()
        it("cycles a white cell empty -> bulb -> dot -> empty", function()
            local b = newBoard()
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.grid[rr][cc] == Board.TYPE_WHITE then r, c = rr, cc; break end
                end
                if r then break end
            end
            assert.are.equal(Board.MARK_EMPTY, b.marks[r][c])
            b:cycleCell(r, c)
            assert.are.equal(Board.MARK_BULB, b.marks[r][c])
            b:cycleCell(r, c)
            assert.are.equal(Board.MARK_DOT, b.marks[r][c])
            b:cycleCell(r, c)
            assert.are.equal(Board.MARK_EMPTY, b.marks[r][c])
        end)

        it("refuses to mark a black cell", function()
            local b = newBoard()
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.grid[rr][cc] ~= Board.TYPE_WHITE then r, c = rr, cc; break end
                end
                if r then break end
            end
            assert.is_false(b:cycleCell(r, c))
        end)
    end)

    describe("undoMove", function()
        it("restores the previous mark", function()
            local b = newBoard()
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.grid[rr][cc] == Board.TYPE_WHITE then r, c = rr, cc; break end
                end
                if r then break end
            end
            b:cycleCell(r, c)
            assert.is_true(b:undoMove())
            assert.are.equal(Board.MARK_EMPTY, b.marks[r][c])
        end)
    end)

    describe("reveal / _checkWin", function()
        it("reveal places the solution's bulbs and wins", function()
            local b = newBoard()
            b:reveal()
            assert.is_true(b.won)
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.grid[r][c] == Board.TYPE_WHITE then
                        local expected = b.solution[r][c] and Board.MARK_BULB or Board.MARK_EMPTY
                        assert.are.equal(expected, b.marks[r][c])
                    end
                end
            end
        end)
    end)

    describe("_checkWin rules", function()
        it("refuses a placement whose wall count is wrong", function()
            -- 2x2: two white cells on a diagonal, two walls. Each white
            -- cell can only light itself, so both take a bulb; each wall
            -- then touches two bulbs.
            local W = Board.TYPE_WHITE
            local function play(wall)
                local b = Board:new{ n = 2, empty = true }
                assert.is_true(b:load{ n = 2, difficulty = "easy",
                    grid = { W, wall, wall, W },
                    solution = { 1, 0, 0, 1 },
                    marks = { 0, 0, 0, 0 } })
                b:setMark(1, 1, Board.MARK_BULB)
                b:setMark(2, 2, Board.MARK_BULB)
                return b.won
            end
            assert.is_true(play(Board.TYPE_BLACK_2))
            assert.is_true(play(Board.TYPE_BLACK))
            assert.is_false(play(Board.TYPE_BLACK_1))
        end)
    end)

    describe("serialize / load", function()
        it("round-trips grid, solution and marks", function()
            local b = newBoard()
            b:reveal()
            local data = b:serialize()

            local b2 = Board:new({ n = 7 })
            assert.is_true(b2:load(data))
            assert.are.equal(b.n, b2.n)
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(b.grid[r][c], b2.grid[r][c])
                    assert.are.equal(b.marks[r][c], b2.marks[r][c])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = newBoard()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
