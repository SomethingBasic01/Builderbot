-- builder_worker.lua
-- Turtle worker for multi-turtle schematic builds
-- Supports:
--   - broadcast host protocol
--   - fuel from inventory + simple fuel chest
--   - materials chest in front of origin
--   - verbose inventory debugging

if not turtle then
    error("This program must be run on a turtle.")
end

-- === CONFIG: chest positions relative to START ===
-- Turtle starts at (0,0,0), facing +Z (front).
local MATERIAL_SIDE = "front" -- material chest is 1 block in front of the turtle at origin
local FUEL_SIDE     = "right" -- fuel chest is 1 block to the right of the turtle at origin
-- ================================================

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
-- Position / orientation tracking
----------------------------------------------------
-- Turtle starts at origin (0,0,0) facing +Z

local posX, posY, posZ = 0, 0, 0
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
    while rot ~= dir do
        turnRight()
    end
end

local function rotationForSide(side)
    if side == "front" then return 0
    elseif side == "right" then return 1
    elseif side == "back" then return 2
    elseif side == "left" then return 3
    else
        return 0
    end
end

----------------------------------------------------
-- Fuel handling
----------------------------------------------------
local function tryRefuelFromInventory()
    local lvl = turtle.getFuelLevel()
    if lvl == "unlimited" or lvl == nil then return true end

    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item then
            turtle.select(slot)
            if turtle.refuel(0) then   -- is this fuel?
                turtle.refuel()
                print("Refueled from slot "..slot..". Fuel now: "..tostring(turtle.getFuelLevel()))
                return true
            end
        end
    end
    return false
end

local function refuelFromChest()
    print("Trying to refuel from fuel chest...")
    local sx, sy, sz, srot = posX, posY, posZ, rot

    -- go back to origin
    local function goToRaw(x,y,z)
        -- NOTE: this version does NOT call ensureFuel to avoid recursion
        while posY < y do
            while not turtle.up() do turtle.digUp(); sleep(0.1) end
            posY = posY + 1
        end
        while posY > y do
            while not turtle.down() do turtle.digDown(); sleep(0.1) end
            posY = posY - 1
        end

        if posX < x then
            face(1)
            while posX < x do
                while not turtle.forward() do turtle.dig(); sleep(0.1) end
                posX = posX + 1
            end
        elseif posX > x then
            face(3)
            while posX > x do
                while not turtle.forward() do turtle.dig(); sleep(0.1) end
                posX = posX - 1
            end
        end

        if posZ < z then
            face(0)
            while posZ < z do
                while not turtle.forward() do turtle.dig(); sleep(0.1) end
                posZ = posZ + 1
            end
        elseif posZ > z then
            face(2)
            while posZ > z do
                while not turtle.forward() do turtle.dig(); sleep(0.1) end
                posZ = posZ - 1
            end
        end
    end

    goToRaw(0,0,0)
    face(rotationForSide(FUEL_SIDE))

    -- fuel chest 1 block in front
    turtle.suck(64)

    if not tryRefuelFromInventory() then
        error("Could not refuel from fuel chest: add coal/charcoal etc.")
    end

    -- go back
    goToRaw(sx,sy,sz)
    while rot ~= srot do turnRight() end
end

local function ensureFuel()
    local lvl = turtle.getFuelLevel()
    if lvl == "unlimited" or lvl == nil then return end
    if lvl > 20 then return end

    if tryRefuelFromInventory() then return end

    -- If still low, try the chest
    refuelFromChest()
end

----------------------------------------------------
-- Movement helpers (use ensureFuel)
----------------------------------------------------
local function safeForward()
    ensureFuel()
    while not turtle.forward() do
        turtle.dig()
        sleep(0.1)
        ensureFuel()
    end
    if     rot == 0 then posZ = posZ + 1
    elseif rot == 1 then posX = posX + 1
    elseif rot == 2 then posZ = posZ - 1
    elseif rot == 3 then posX = posX - 1 end
end

local function safeUp()
    ensureFuel()
    while not turtle.up() do
        turtle.digUp()
        sleep(0.1)
        ensureFuel()
    end
    posY = posY + 1
end

local function safeDown()
    ensureFuel()
    while not turtle.down() do
        turtle.digDown()
        sleep(0.1)
        ensureFuel()
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
-- Material chest restock
----------------------------------------------------
local function restockFromMaterialChest()
    print("Restocking materials from chest...")
    local sx, sy, sz, srot = posX, posY, posZ, rot

    -- go back to origin
    goTo(0,0,0)
    face(rotationForSide(MATERIAL_SIDE))

    -- pull a stack from the chest in front
    turtle.suck(64)
    print("Pulled items from material chest.")

    -- go back
    goTo(sx,sy,sz)
    while rot ~= srot do turnRight() end
end

----------------------------------------------------
-- Helper: find block slot & debug inventory
----------------------------------------------------
local function findBlockSlot(targetName)
    print("Looking for block "..targetName.." in inventory:")
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item then
            print(("  slot %2d: %s x%d"):format(slot, item.name, item.count))
            if item.name == targetName then
                return slot
            end
        end
    end
    return nil
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

                -- Try to find block
                local slot = findBlockSlot(name)
                if not slot then
                    print("Don't have "..name.." in inventory, attempting restock.")
                    restockFromMaterialChest()
                    slot = findBlockSlot(name)
                end

                if slot then
                    turtle.select(slot)
                    local placed = turtle.placeDown()
                    if not placed then
                        turtle.digDown()
                        sleep(0.1)
                        placed = turtle.placeDown()
                    end

                    if placed then
                        print("Placed "..name.." at ("..x..","..y..","..z..")")
                        rednet.broadcast(("COMPLETE|%s|%d|%d"):format(pin, myID, idx))
                    else
                        print("Could not place "..name.." even after selecting slot "..slot..".")
                    end
                else
                    print("Still missing "..name.." after restock. Waiting...")
                    rednet.broadcast(("STATE|%s|%d|restocking"):format(pin, myID))
                    sleep(5)
                end

            elseif cmd == "IDLE" then
                print("Host reports no more tasks. Worker shutting down.")
                break
            else
                print("Unknown command "..tostring(cmd).." for me; ignoring.")
            end
        end
    else
        print("No message, retrying REQ...")
    end
end

print("Worker finished.")
