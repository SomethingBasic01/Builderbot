-- builder_worker.lua
-- Turtle worker for multi-turtle schematic builds (broadcast protocol)

if not turtle then
    error("This program must be run on a turtle.")
end

local modem = peripheral.find("modem")
if not modem then
    error("No modem found on this turtle – attach a wireless modem.")
end
rednet.open(peripheral.getName(modem))

local function split(msg)
    local t = {}
    for w in msg:gmatch("[^|]+") do
        t[#t+1] = w
    end
    return t
end

term.clear()
term.setCursorPos(1,1)
print("=== Builder Worker ===")
print("Enter Job PIN:")
local pin = read()

local myID = os.getComputerID()
print("My ID: " .. myID)
print("Announcing presence to host...")

-- Let host know we exist
rednet.broadcast(("JOIN|%s|%d"):format(pin, myID))

----------------------------------------------------
-- Simple 3D movement helpers (local coordinates)
----------------------------------------------------
-- Turtle starts at build origin (0,0,0) facing +Z

local posX, posY, posZ = 0, 0, 0
local rot = 0 -- 0=+Z, 1=+X, 2=-Z, 3=-X

local function turnRight()
    turtle.turnRight()
    rot = (rot + 1) % 4
end

local function face(dir)
    while rot ~= dir do turnRight() end
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

local function goTo(x, y, z)
    -- Vertical
    while posY < y do safeUp() end
    while posY > y do safeDown() end

    -- X
    if posX < x then
        face(1)
        while posX < x do safeForward() end
    elseif posX > x then
        face(3)
        while posX > x do safeForward() end
    end

    -- Z
    if posZ < z then
        face(0)
        while posZ < z do safeForward() end
    elseif posZ > z then
        face(2)
        while posZ > z do safeForward() end
    end
end

----------------------------------------------------
-- Main work loop
----------------------------------------------------
print("Starting work loop...")

while true do
    -- Request work
    rednet.broadcast(("REQ|%s|%d"):format(pin, myID))
    print("Sent REQ|"..pin.."|"..myID..", waiting for task...")

    local senderID, msg = rednet.receive(5)

    if msg then
        print("Got message: "..msg.." (from "..senderID..")")
        local p = split(msg)
        local cmd      = p[1]
        local respPin  = p[2]
        local targetID = tonumber(p[3])

        -- Only process messages for this job AND this turtle
        if respPin == pin and targetID == myID then
            if cmd == "TASK" then
                -- TASK|PIN|id|idx|name|x|y|z
                local idx  = tonumber(p[4])
                local name = p[5]
                local x    = tonumber(p[6])
                local y    = tonumber(p[7])
                local z    = tonumber(p[8])

                print(string.format("Task %d: %s at (%d,%d,%d)", idx, name, x, y, z))

                goTo(x, y, z)

                -- Find the block and place it
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
                    print("Placed "..name.." at ("..x..","..y..","..z..")")
                    rednet.broadcast(("COMPLETE|%s|%d|%d"):format(pin, myID, idx))
                else
                    print("Missing "..name.." – waiting for restock.")
                    rednet.broadcast(("STATE|%s|%d|restocking"):format(pin, myID))
                    sleep(5)
                end

            elseif cmd == "IDLE" then
                print("Host reports no more tasks. Worker shutting down.")
                break
            else
                print("Unknown command "..tostring(cmd).." for me; ignoring.")
            end
        else
            print("Message not for me (pin="..tostring(respPin)..", id="..tostring(targetID).."); ignoring.")
        end
    else
        print("No message, retrying REQ...")
    end
end

print("Worker finished.")
