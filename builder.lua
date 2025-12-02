--[[
    builder.lua
    One-file multi-turtle schematic builder for CC:Tweaked

    Modes:
      - Host   (computer or turtle): loads schematic, hands out work
      - Worker (turtle only)       : joins job and places blocks
      - Monitor (computer/turtle)  : shows progress & ETA

    Simplifications in this version:
      - NO automatic chest restocking or fuel chest logic.
      - You must keep each worker turtle fueled & stocked manually.
      - All coordinates are relative to a single build origin.
        Each worker can have an offset from that origin.

    This is the "make it actually work" base version.
]]

--------------------------------------------------------
-- Helpers
--------------------------------------------------------
local isTurtle = turtle ~= nil

local function split(str)
    local t = {}
    for part in string.gmatch(str, "[^|]+") do
        t[#t+1] = part
    end
    return t
end

local function trim_block_name(name)
    if type(name) ~= "string" then return name end
    local clean = name:match("([^,]+)")
    return clean or name
end

--------------------------------------------------------
-- Schematic loading
--------------------------------------------------------
local function load_schematic(module_name)
    local ok, data = pcall(require, module_name)
    if not ok then
        error("Failed to load schematic '" .. module_name .. "': " .. tostring(data))
    end

    local blocks
    if type(data) == "table" and data.blocks then
        blocks = data.blocks
    else
        blocks = data
    end

    if type(blocks) ~= "table" then
        error("Schematic module did not return a table of blocks")
    end

    -- normalise block names
    for _, b in ipairs(blocks) do
        b.name = trim_block_name(b.name)
    end

    -- sort blocks: layer-by-layer (y), then z, then x
    table.sort(blocks, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.z ~= b.z then return a.z < b.z end
        return a.x < b.x
    end)

    return blocks
end

--------------------------------------------------------
-- Fuel & inventory helpers (worker)
--------------------------------------------------------
local function ensure_fuel(min_level)
    if not isTurtle then return end
    min_level = min_level or 20

    while true do
        local lvl = turtle.getFuelLevel()
        if lvl == "unlimited" or lvl == nil or lvl >= min_level then
            return
        end

        -- try to refuel from inventory
        for slot = 1, 16 do
            local item = turtle.getItemDetail(slot)
            if item then
                turtle.select(slot)
                if turtle.refuel(0) then
                    turtle.refuel()
                    print("Refueled from slot "..slot..". Fuel now "..tostring(turtle.getFuelLevel()))
                    return
                end
            end
        end

        print("OUT OF FUEL. Put fuel into any slot. Checking again in 5s...")
        sleep(5)
    end
end

local function ensure_block(name)
    if not isTurtle then return end
    name = trim_block_name(name)

    while true do
        for slot = 1, 16 do
            local item = turtle.getItemDetail(slot)
            if item then
                if trim_block_name(item.name) == name then
                    turtle.select(slot)
                    return true
                end
            end
        end

        print("Missing block "..name..". Put it in any slot. Checking again in 5s...")
        sleep(5)
    end
end

--------------------------------------------------------
-- Movement helpers (worker)
--------------------------------------------------------
local function make_mover(worker_offset)
    -- worker_offset = {dx, dy, dz} from ORIGIN -> TURTLE_START
    local posX, posY, posZ = 0, 0, 0 -- turtle's local coords (start = 0,0,0)
    local rot = 0 -- 0=+Z, 1=+X, 2=-Z, 3=-X

    local function turnRight()
        turtle.turnRight()
        rot = (rot + 1) % 4
    end

    local function turnLeft()
        turtle.turnLeft()
        rot = (rot + 3) % 4
    end

    local function face(dir)
        while rot ~= dir do turnRight() end
    end

    local function forward_raw()
        while not turtle.forward() do
            turtle.dig()
            sleep(0.1)
        end
        if rot == 0 then
            posZ = posZ + 1
        elseif rot == 1 then
            posX = posX + 1
        elseif rot == 2 then
            posZ = posZ - 1
        elseif rot == 3 then
            posX = posX - 1
        end
    end

    local function up_raw()
        while not turtle.up() do
            turtle.digUp()
            sleep(0.1)
        end
        posY = posY + 1
    end

    local function down_raw()
        while not turtle.down() do
            turtle.digDown()
            sleep(0.1)
        end
        posY = posY - 1
    end

    local function safe_forward() ensure_fuel(); forward_raw() end
    local function safe_up() ensure_fuel(); up_raw() end
    local function safe_down() ensure_fuel(); down_raw() end

    -- Move to *global* schematic position (gx,gy,gz),
    -- considering worker offset (origin -> turtle start).
    local function go_to_global(gx, gy, gz)
        -- convert to local coords (target relative to turtle start)
        local tx = gx - worker_offset.dx
        local ty = gy - worker_offset.dy
        local tz = gz - worker_offset.dz

        -- Y
        while posY < ty do safe_up() end
        while posY > ty do safe_down() end

        -- X
        if posX < tx then
            face(1)
            while posX < tx do safe_forward() end
        elseif posX > tx then
            face(3)
            while posX > tx do safe_forward() end
        end

        -- Z
        if posZ < tz then
            face(0)
            while posZ < tz do safe_forward() end
        elseif posZ > tz then
            face(2)
            while posZ > tz do safe_forward() end
        end
    end

    return {
        go_to_global = go_to_global,
        get_pos = function() return posX, posY, posZ, rot end
    }
end

--------------------------------------------------------
-- Network protocol constants
--------------------------------------------------------
-- Messages (all via rednet.broadcast):
--   Worker -> Host:
--     JOIN|PIN|workerID
--     REQ|PIN|workerID
--     DONE|PIN|workerID|blockIndex
--     STATE|PIN|workerID|status
--
--   Host -> Workers & Monitors:
--     TASK|PIN|workerID|blockIndex|blockName|x|y|z
--     NO_TASK|PIN|workerID
--     STAT|PIN|total|placed|turtlesJson

local function open_modem()
    local modem = peripheral.find("modem")
    if not modem then
        error("No modem attached. Place a wireless modem on the side of this computer/turtle.")
    end
    rednet.open(peripheral.getName(modem))
end

--------------------------------------------------------
-- Host mode
--------------------------------------------------------
local function host_mode()
    open_modem()

    term.clear()
    term.setCursorPos(1,1)
    print("=== Builder :: HOST MODE ===")
    print("Enter schematic lua file name (e.g. sugar_data.lua):")
    local fname = read()
    local module_name = fname:gsub("%.lua$", "")

    local blocks = load_schematic(module_name)
    print("Loaded schematic with "..#blocks.." blocks.")

    -- generate PIN
    math.randomseed(os.epoch and os.epoch("utc") or os.time())
    local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    local pin = ""
    for i = 1, 6 do
        local idx = math.random(#chars)
        pin = pin .. chars:sub(idx, idx)
    end

    print("Job PIN: "..pin)
    print("Share this PIN with worker turtles and monitors.")
    print()

    local job = {
        pin = pin,
        blocks = blocks,
        status = {},
        total = #blocks,
        placed = 0,
        turtles = {}, -- [id] = {state="idle", placed=0, lastSeen=os.clock()}
        start_time = os.clock()
    }

    for i = 1, #blocks do
        job.status[i] = "todo"
    end

    local function next_task()
        for i, st in ipairs(job.status) do
            if st == "todo" then
                job.status[i] = "inprogress"
                return i, job.blocks[i]
            end
        end
        return nil, nil
    end

    local last_stat_time = 0

    while true do
        local timeout = 1
        local sender, msg = rednet.receive(timeout)

        if msg then
            local parts = split(msg)
            local cmd   = parts[1]
            local mpin  = parts[2]
            local wid   = tonumber(parts[3])

            if mpin == pin and cmd and wid then
                if cmd == "JOIN" then
                    job.turtles[wid] = job.turtles[wid] or {state="idle", placed=0, lastSeen=os.clock()}
                    print("Worker "..wid.." joined job.")
                elseif cmd == "REQ" then
                    job.turtles[wid] = job.turtles[wid] or {state="idle", placed=0, lastSeen=os.clock()}
                    job.turtles[wid].state = "requesting"
                    job.turtles[wid].lastSeen = os.clock()

                    local idx, blk = next_task()
                    if idx then
                        local payload = ("TASK|%s|%d|%d|%s|%d|%d|%d"):format(
                            pin, wid, idx, blk.name, blk.x, blk.y, blk.z)
                        rednet.broadcast(payload)
                        print(("Assigned block %d to worker %d"):format(idx, wid))
                    else
                        local payload = ("NO_TASK|%s|%d"):format(pin, wid)
                        rednet.broadcast(payload)
                    end
                elseif cmd == "DONE" then
                    local idx = tonumber(parts[4])
                    if idx and job.status[idx] == "inprogress" then
                        job.status[idx] = "done"
                        job.placed = job.placed + 1
                        job.turtles[wid] = job.turtles[wid] or {state="idle", placed=0, lastSeen=os.clock()}
                        job.turtles[wid].placed = job.turtles[wid].placed + 1
                        job.turtles[wid].state = "idle"
                        job.turtles[wid].lastSeen = os.clock()
                        print(("Worker %d completed block %d (%d/%d)"):format(
                            wid, idx, job.placed, job.total))
                    end
                elseif cmd == "STATE" then
                    local st = parts[4] or "unknown"
                    job.turtles[wid] = job.turtles[wid] or {state="idle", placed=0, lastSeen=os.clock()}
                    job.turtles[wid].state = st
                    job.turtles[wid].lastSeen = os.clock()
                end
            end
        end

        -- send STAT broadcast every second
        local now = os.clock()
        if now - last_stat_time >= 1 then
            last_stat_time = now
            local turtlesJson = textutils.serialize(job.turtles)
            local payload = ("STAT|%s|%d|%d|%s"):format(pin, job.total, job.placed, turtlesJson)
            rednet.broadcast(payload)
        end
    end
end

--------------------------------------------------------
-- Worker mode
--------------------------------------------------------
local function worker_mode()
    if not isTurtle then
        print("Worker mode only works on turtles.")
        return
    end

    open_modem()

    term.clear()
    term.setCursorPos(1,1)
    print("=== Builder :: WORKER MODE ===")
    print("Enter job PIN:")
    local pin = read()

    local myID = os.getComputerID()
    print("My ID: "..myID)

    print("Enter your offset from BUILD ORIGIN.")
    print("Think: standing ON the origin, facing the same way as the structure faces.")
    print("Dx (origin -> turtle, +X to the right):")
    local dx = tonumber(read()) or 0
    print("Dy (origin -> turtle, +Y up):")
    local dy = tonumber(read()) or 0
    print("Dz (origin -> turtle, +Z forward):")
    local dz = tonumber(read()) or 0

    local offset = {dx=dx, dy=dy, dz=dz}
    local mover = make_mover(offset)

    rednet.broadcast(("JOIN|%s|%d"):format(pin, myID))

    print("Joining job "..pin.." as worker "..myID.."...")
    print("Offset from origin: ("..dx..","..dy..","..dz..")")
    print("Keep this turtle fueled & stocked. It will ask when it needs stuff.")

    while true do
        -- request work
        rednet.broadcast(("REQ|%s|%d"):format(pin, myID))
        print("Requested task from host...")

        local sender, msg = rednet.receive(5)
        if not msg then
            print("No reply from host yet, retrying...")
        else
            local parts = split(msg)
            local cmd      = parts[1]
            local mpin     = parts[2]
            local targetID = tonumber(parts[3])

            if mpin == pin and targetID == myID then
                if cmd == "TASK" then
                    -- TASK|PIN|id|idx|name|x|y|z
                    local idx  = tonumber(parts[4])
                    local name = parts[5]
                    local x    = tonumber(parts[6])
                    local y    = tonumber(parts[7])
                    local z    = tonumber(parts[8])

                    print(string.format(
                        "Task %d: place %s at global (%d,%d,%d)",
                        idx, name, x, y, z))

                    mover.go_to_global(x, y, z)
                    ensure_block(name)

                    local placed = turtle.placeDown()
                    if not placed then
                        turtle.digDown()
                        sleep(0.1)
                        placed = turtle.placeDown()
                    end

                    if placed then
                        print("Placed "..name..".")
                        rednet.broadcast(("DONE|%s|%d|%d"):format(pin, myID, idx))
                    else
                        print("Failed to place "..name..". Telling host I'm stuck.")
                        rednet.broadcast(("STATE|%s|%d|placement_failed"):format(pin, myID))
                        sleep(5)
                    end

                elseif cmd == "NO_TASK" then
                    print("Host says there is no more work for me. Shutting down.")
                    break
                end
            end
        end
    end
end

--------------------------------------------------------
-- Monitor mode
--------------------------------------------------------
local function monitor_mode()
    open_modem()

    term.clear()
    term.setCursorPos(1,1)
    print("=== Builder :: MONITOR MODE ===")
    print("Enter job PIN to monitor:")
    local pin = read()

    local function draw(total, placed, turtles, elapsed)
        term.clear()
        term.setCursorPos(1,1)
        print("=== Job "..pin.." :: Monitor ===")
        print("Total blocks: "..total)
        print("Placed blocks: "..placed)

        local pct = 0
        if total > 0 then
            pct = math.floor(placed * 100 / total + 0.5)
        end
        print("Progress: "..pct.."%")

        -- progress bar
        local barW = 30
        local filled = math.floor(barW * pct / 100 + 0.5)
        local bar = "["..string.rep("#", filled)..string.rep(" ", barW - filled).."]"
        print(bar)

        -- ETA
        local etaStr = "N/A"
        if placed > 0 then
            local rate = placed / elapsed -- blocks per second
            local remaining = total - placed
            local seconds = remaining / rate
            local mins = math.floor(seconds / 60)
            local secs = math.floor(seconds % 60)
            etaStr = string.format("%dm %ds", mins, secs)
        end
        print("Elapsed: "..math.floor(elapsed).."s   ETA: "..etaStr)
        print()
        print("Workers:")

        for id, info in pairs(turtles) do
            local line = string.format(
                "  #%d  placed=%d  state=%s",
                id, info.placed or 0, info.state or "unknown")
            print(line)
        end
    end

    local start_time = os.clock()

    while true do
        local sender, msg = rednet.receive()
        if msg then
            local parts = split(msg)
            local cmd  = parts[1]
            local mpin = parts[2]

            if cmd == "STAT" and mpin == pin then
                local total  = tonumber(parts[3]) or 0
                local placed = tonumber(parts[4]) or 0
                local turtlesJson = parts[5] or "{}"
                local turtles = textutils.unserialize(turtlesJson) or {}

                local elapsed = os.clock() - start_time
                draw(total, placed, turtles, elapsed)
            end
        end
    end
end

--------------------------------------------------------
-- Main menu
--------------------------------------------------------
local function main()
    while true do
        term.clear()
        term.setCursorPos(1,1)
        print("=== Builder :: Unified ===")
        print("Running on: "..(isTurtle and "Turtle" or "Computer"))
        print()
        print("1) Host new build job")
        if isTurtle then
            print("2) Join as worker (turtle)")
            print("3) Monitor job")
            print("4) Exit")
        else
            print("2) Monitor job")
            print("3) Exit")
        end
        print()
        write("Select option: ")
        local choice = read()

        if isTurtle then
            if choice == "1" then host_mode()
            elseif choice == "2" then worker_mode()
            elseif choice == "3" then monitor_mode()
            elseif choice == "4" then return
            end
        else
            if choice == "1" then host_mode()
            elseif choice == "2" then monitor_mode()
            elseif choice == "3" then return
            end
        end
    end
end

main()
