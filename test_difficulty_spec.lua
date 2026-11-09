-- Difficulty guarantees for Light Up (see docs/dev/TESTING.md, "Difficulty
-- specs"): every size x level builds fast and is unique, the game's own
-- no-trial solver finishes it within the level's tier, Easy needs tier 1
-- only, Medium/Hard need named patterns and are ordered on average, a seed
-- gives the same puzzle, and generation never reads the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

local SEEDS = 12

describe("Light Up difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    it("the level table is ordered", function()
        for _, n in ipairs(Board.SIZES) do
            local e, m, h = Board.LEVELS.easy(n), Board.LEVELS.medium(n), Board.LEVELS.hard(n)
            assert.is_true(e.tier <= m.tier and m.tier <= h.tier)
            assert.is_true(e.max_t2 < m.min_t2 and m.max_t2 < h.min_t2)
            assert.is_true(e.density >= m.density and m.density >= h.density)
        end
    end)

    -- moved from test_board_spec.lua
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

    -- moved from test_board_spec.lua
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

    -- moved from test_board_spec.lua
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

    -- moved from test_board_spec.lua
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

    it("generation never reads the clock", function()
        for _, n in ipairs(Board.SIZES) do
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local reads = clockReads(function()
                    math.randomseed(99 + n)
                    Board:new{ n = n, difficulty = diff }
                end)
                assert.are.equal(0, reads, ("n=%d %s read the clock"):format(n, diff))
            end
        end
    end)
end)
