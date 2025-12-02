-- ** FILE: builder.lua **

-- 1. Load the data using 'require'
-- This relies on sugar_data.lua being in the same directory/disk.
local blocks = require("sugar_data") 
if not blocks or #blocks == 0 then
    error("Failed to load block data from sugar_data.lua or data is empty!")
end

-- 2. Coordinate Tracking Setup
-- The turtle always starts facing North (rotation 0) on the block below the schematic origin (0, 0, 0).
-- In ComputerCraft: Y is usually the vertical axis, X/Z are horizontal.
-- We will use the schematic's X, Y(height), Z relative to the starting position.
local posX, posY, posZ = 0, 0, 0
local rotation = 0 -- 0:North (+Z), 1:East (+X), 2:South (-Z), 3:West (-X)

-- Map of block names to inventory slot numbers (1-16)
-- YOU MUST POPULATE THIS MANUALLY based on where you put the materials!
local INVENTORY_MAP = {
    ["minecraft:white_wool"] = 1,
    ["minecraft:gray_wool"] = 2,
    ["minecraft:light_gray_wool"] = 3,
    ["minecraft:white_concrete_powder"] = 4,
    -- Add all other block names and their respective slot numbers here!
}

-- 3. Helper Functions

-- Utility to refuel if needed
local function checkFuel()
    if turtle.getFuelLevel() == 0 or turtle.getFuelLevel() < #blocks then
        print("!! WARNING: LOW FUEL. Attempting refuel...")
        turtle.refuel(64) -- Try to use one stack of fuel
        if turtle.getFuelLevel() == 0 then
            error("OUT OF FUEL! Please add fuel to the turtle's inventory.")
        end
    end
end

-- Function to execute a movement command and update coordinates
local function move(command)
    local success, reason = command()
    
    if not success then
        -- Handle common movement issues (e.g., blocking block)
        if reason == "Out of fuel" then
            checkFuel()
            return move(command) -- Retry movement
        elseif reason == "Movement blocked" then
            -- Attempt to dig the obstruction
            if command == turtle.forward then
                if turtle.dig() then return move(command) end
            elseif command == turtle.up then
                if turtle.digUp() then return move(command) end
            elseif command == turtle.down then
                if turtle.digDown() then return move(command) end
            end
        end
        error("Movement failed: " .. (reason or "Unknown reason"))
    end
    
    -- Update internal coordinates based on successful movement
    if command == turtle.forward then
        if rotation == 0 then posY = posY + 1 -- North
        elseif rotation == 1 then posX = posX + 1 -- East
        elseif rotation == 2 then posY = posY - 1 -- South
        elseif rotation == 3 then posX = posX - 1 -- West
        end
    elseif command == turtle.back then
        if rotation == 0 then posY = posY - 1
        elseif rotation == 1 then posX = posX - 1
        elseif rotation == 2 then posY = posY + 1
        elseif rotation == 3 then posX = posX + 1
        end
    elseif command == turtle.up then
        posZ = posZ + 1
    elseif command == turtle.down then
        posZ = posZ - 1
    elseif command == turtle.turnLeft then
        rotation = (rotation - 1) % 4
    elseif command == turtle.turnRight then
        rotation = (rotation + 1) % 4
    end
end

-- Turns the turtle until it faces the target direction (0, 1, 2, or 3)
local function orient(targetRotation)
    while rotation ~= targetRotation do
        move(turtle.turnRight)
    end
end

-- The core movement function: navigates the turtle to the relative coordinates (tx, ty, tz)
local function moveTo(tx, ty, tz)
    print(string.format("Moving to (%d, %d, %d)", tx, ty, tz))
    
    -- 1. Handle Vertical (Z-axis / Minecraft Y-axis) movement first
    while posZ < tz do move(turtle.up) end
    while posZ > tz do move(turtle.down) end

    -- 2. Handle X-axis movement
    if posX < tx then 
        orient(1) -- Face East (+X)
        while posX < tx do move(turtle.forward) end
    elseif posX > tx then 
        orient(3) -- Face West (-X)
        while posX > tx do move(turtle.forward) end
    end
    
    -- 3. Handle Y-axis movement (Schematic Z-axis)
    if posY < ty then
        orient(0) -- Face North (+Y / Schematic Z)
        while posY < ty do move(turtle.forward) end
    elseif posY > ty then
        orient(2) -- Face South (-Y / Schematic Z)
        while posY > ty do move(turtle.forward) end
    end
end

-- Selects the block and places it down.
local function placeBlock(name)
    local slot = INVENTORY_MAP[name]
    if not slot then
        error("Block name '" .. name .. "' not found in INVENTORY_MAP!")
    end
    
    -- Select the correct slot
    turtle.select(slot)
    
    -- Place the block *down* (as the turtle is standing where the next layer starts)
    local success, reason = turtle.placeDown()
    if not success then
        print("Placement failed: " .. (reason or "Unknown reason"))
        -- A common failure is a block already being there. Try to dig and re-place.
        turtle.digDown()
        os.sleep(0.1)
        success, reason = turtle.placeDown()
        if not success then
             error("Placement failed again at " .. string.format("(%d, %d, %d)", posX, posY, posZ) .. ": " .. (reason or "Unknown reason"))
        end
    end
    
    print("Placed " .. name)
end

-- 4. Main Program Loop
print("--- Starting Schematic Build ---")
print("Target: " .. #blocks .. " blocks.")

checkFuel()

for i, block in ipairs(blocks) do
    local blockName = block.name:match("^([^,]+)") -- Get just the 'minecraft:name' part
    
    -- a. Move the turtle to the target position *above* where the block needs to be placed.
    -- The coordinates are: X, Z, Y (Schematic Y is Turtle Z)
    moveTo(block.x, block.z, block.y) 
    
    -- b. Place the block at the current location + 1 block below (using placeDown)
    placeBlock(blockName)
    
    -- Optional: sleep to prevent network/server lag
    os.sleep(0.05) 
end

print("--- CONSTRUCTION COMPLETE! ---")
