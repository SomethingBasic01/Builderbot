-- builder_worker.lua
-- Turtle worker for multi-turtle schematic builds

if not turtle then
    error("This program must be run on a turtle.")
end

local modem = peripheral.find("modem")
if not modem then
    error("No modem found on this turtle – attach a wireless modem.")
end
rednet.open(peripheral.getName(modem))

term.clear()
term.setCursorPos(1,1)
print("=== Builder Worker ===")
print("Enter Job PIN:")
local pin = read()
print("Joining job "..pin.."...")

-- Tell host we want to join
rednet.broadcast("JOIN|"..pin)

----------------------------------------------------
-- Simple 3D movement helpers (relative coordinates)
----------------------------------------------------
-- We assume turtle starts at build origin (0,0,0) facing "north" (rot=0).

local posX, posY, posZ = 0, 0, 0
-- rot: 0 = +Z, 1 = +X, 2 = -Z, 3 = -X
local rot = 0

local function turnRight()
    turtle.turnRight()
    rot = (rot + 1) % 4
end

local function turnLeft()
    turtle.turnLeft()
    rot = (rot + 3) % 4
end

local function face(dir)
    -- rotate shortest way
    while rot ~= dir do
        turnRight()
    end
end

local function safeForward()
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

local function safeUp()
    while not turtle.up() do
        turtle.digUp()
        sleep(0.1)
    end
    posY = posY + 1
end

local function safeDown()
    while not turtle.down() do
        turtle.digDown()
        sleep(0.1)
    end
    posY = posY - 1
end

-- Move to local coordinates (x,y,z) in schematic space
local function goTo(x, y, z)
    -- Vertical first
    while posY < y do safeUp() end
    while posY > y do safeDown() end

    -- X axis
    if posX < x then
        face(1) -- +X
        while posX < x do safeForward() end
    elseif posX > x then
        face(3) -- -X
        while posX > x do safeForward() end
    end

    -- Z axis
    if posZ < z then
        face(0) -- +Z
        while posZ < z do safeForward() end
    elseif posZ > z then
        face(2) -- -Z
        while posZ > z do safeForward() end
    end
end

----------------------------------------------------
-- Main work loop
----------------------------------------------------

while true do
    -- Ask host for work
    rednet.broadcast("REQ|"..pin)

    -- Wait a short time for a response
    local senderID, msg = rednet.receive(2)

    if msg then
        local parts = {}
        for w in msg:gmatch("[^|]+") do
            table.insert(parts, w)
        end

        local cmd = parts[1]
        local respPin = parts[2]

        -- Ignore messages for other jobs
        if respPin == pin then
            if cmd == "TASK" then
                -- TASK|PIN|idx|name|x|y|z
                local idx = tonumber(parts[3])
                local name = parts[4]
                local x = tonumber(parts[5])
                local y = tonumber(parts[6])
                local z = tonumber(parts[7])

                print(string.format("Task %d: %s at (%d,%d,%d)", idx, name, x, y, z))

                -- Move to target
                goTo(x, y, z)

                -- Try to place the correct block
                local placed = false
                for slot = 1, 16 do
                    local item = turtle.getItemDetail(slot)
                    if item and item.name == name then
                        turtle.select(slot)
                        placed = turtle.placeDown()
                        if not placed then
                            turtle.digDown()
                            sleep(0.1)
                            placed = turtle.placeDown()
                        end
                        if placed then break end
                    end
                end

                if placed then
                    -- Inform host we finished this block
                    rednet.broadcast(string.format("DONE|%s|%d", pin, idx))
                else
                    print("Missing block "..name.." – waiting for restock.")
                    rednet.broadcast(string.format("STATE|%s|restocking", pin))
                    -- Give you time to refill the turtle manually
                    sleep(5)
                end

            elseif cmd == "DONE" then
                -- Host says there are no more tasks
                print("No more tasks for job "..pin..". Shutting down worker.")
                break
            end
        end
    else
        -- No message, idle briefly
        sleep(1)
    end
end

print("Worker finished.")
