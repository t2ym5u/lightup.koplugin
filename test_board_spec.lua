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
