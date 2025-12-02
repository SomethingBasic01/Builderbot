-- ** FILE: builder.lua (Most Compatible Final Script) **

-- === 1. Configuration: YOU MUST SET THESE ===
local MATERIAL_SIDE = "back"     -- Material Chest MUST be placed directly behind the turtle.
local FUEL_SIDE = "right"        -- Fuel Chest MUST be placed to the right of the turtle.
local STATUS_FILE = "build_status.txt" 
-- ==============================================

-- Global Position Variables (Crash Recovery)
local posX, posY, posZ = 0, 0, 0 -- Relative coordinates (X, Schematic Z, Schematic Y)
local rotation = 0              -- 0:North (+Y), 1:East (+X), 2:South (-Y), 3:West (-X)
local currentBlockIndex = 1
local BLOCKS                    -- Loaded schematic data

-- Inventory Tracking
local blockInventory = {}       -- Stores which turtle slot has which block name

-- === 2. Core I/O Functions (Simplified as no peripherals needed) ===
-- (SaveState and LoadState logic remains the same)
local function saveState()
    local f = fs.open(STATUS_FILE, "w")
    f.write(tostring(currentBlockIndex) .. "\n")
    f.write(string.format("%d,%d,%d\n", posX, posY, posZ) .. "\n")
    f.write(tostring(rotation))
    f.close()
end

local function loadState()
    if not fs.exists(STATUS_FILE) then
        print("No save state found. Starting new build.")
        return false
    end
    -- ... (Loading logic remains the same)
    local f = fs.open(STATUS_FILE, "r")
    currentBlockIndex = tonumber(f.readLine()) or 1
    local pos_str = f.readLine()
    local rot_str = f.readLine()
    f.close()
    
    if pos_str then
        local parts = textutils.explode(",", pos_str)
        posX, posY, posZ = tonumber(parts[1]) or 0, tonumber(parts[2]) or 0, tonumber(parts[3]) or 0
    end
    rotation = tonumber(rot_str) or 0
    
    print(string.format("✅ Resuming from index %d at (%d, %d, %d), facing %d.", currentBlockIndex, posX, posY, posZ, rotation))
    return true
end

-- === 3. Movement Helpers (Same as previous version, ensures coordinate updates) ===

local function move(command)
    local success, reason = command()
    
    if not success then
        -- Digging logic for blocked movement remains (Fix 4)
        if command == turtle.forward then turtle.dig() end
        if command == turtle.up then turtle.digUp() end
        if command == turtle.down then turtle.digDown() end
        
        local s, r = command()
        if not s then error("Movement failed after digging: " .. (r or "Unknown")) end
    end
    
    -- Update internal coordinates on success (Same logic)
    if command == turtle.forward then
        if rotation == 0 then posY = posY + 1
        elseif rotation == 1 then posX = posX + 1
        elseif rotation == 2 then posY = posY - 1
        elseif rotation == 3 then posX = posX - 1
        end
    elseif command == turtle.up then posZ = posZ + 1
    elseif command == turtle.down then posZ = posZ - 1
    elseif command == turtle.turnLeft then rotation = (rotation - 1 + 4) % 4
    elseif command == turtle.turnRight then rotation = (rotation + 1) % 4
    end
end

local function orient(targetRotation)
    while rotation ~= targetRotation do
        move(turtle.turnRight)
    end
end

-- New function to return the turtle to its safe Home State (Fix 3)
local function returnHome()
    -- Move to the saved Z-position
    while posZ > 0 do move(turtle.down) end
    while posZ < 0 do move(turtle.up) end
    
    -- Face North (0)
    orient(0)
    
    -- Move in Y (Schematic Z)
    while posY > 0 do move(turtle.back) end
    while posY < 0 do move(turtle.forward) end

    -- Move in X
    if posX > 0 then orient(3) while posX > 0 do move(turtle.forward) end end
    if posX < 0 then orient(1) while posX < 0 do move(turtle.forward) end end
    
    -- Reset final orientation and coordinates (Should be 0, 0, 0)
    orient(0)
    posX, posY, posZ = 0, 0, 0
    print("🏠 Returned to Home (0, 0, 0, North)")
end

-- === 4. Inventory/Fuel Functions (FIXED to use Movement and SUCK) ===

-- Determines the rotation needed to face a side from North (0)
local function getRotationForSide(side)
    if side == "front" then return 0
    elseif side == "right" then return 1
    elseif side == "back" then return 2
    elseif side == "left" then return 3
    else error("Invalid side for chest: " .. side)
    end
end

-- Refuel logic: Turtle turns, moves, refuels, and returns (Fix 4 & Fuel Fix)
local function checkAndRefuel()
    if turtle.getFuelLevel() < 1000 then 
        print("⛽ Low fuel. Moving to refuel cycle...")
        local currentX, currentY, currentZ, currentRot = posX, posY, posZ, rotation
        
        -- 1. Move to the fuel chest
        orient(getRotationForSide(FUEL_SIDE))
        move(turtle.forward)
        
        -- 2. Suck fuel
        local fuel_sucked = turtle.suck(64)
        if fuel_sucked > 0 then
            -- Find the fuel in inventory and select it
            local fuel_slot = nil
            for i = 1, 16 do
                local detail = turtle.getItemDetail(i)
                if detail and (detail.name:find("coal") or detail.name:find("lava_bucket")) then
                    fuel_slot = i
                    break
                end
            end
            
            if fuel_slot then
                turtle.select(fuel_slot)
                turtle.refuel()
                print("⛽ Refueled successfully.")
            end
        else
            error("🛑 OUT OF FUEL! Fuel chest is empty or cannot be sucked.")
        end
        
        -- 3. Return to the starting point of the refuel cycle
        move(turtle.back)
        orient(currentRot)
        
        -- Restore coordinates (since the move/back was temporary)
        posX, posY, posZ, rotation = currentX, currentY, currentZ, currentRot
        
        turtle.select(1) -- Select build slot
    end
end

-- Restock logic: Turtle turns, moves, sucks materials, and returns (Fix 4 & Materials Fix)
local function restockMaterials(blockName)
    print("🔍 Block " .. blockName .. " missing. Restocking cycle...")
    local currentX, currentY, currentZ, currentRot = posX, posY, posZ, rotation

    -- 1. Find an empty slot and select it
    local targetSlot = 1
    for i = 1, 15 do
        if not turtle.getItemDetail(i) then
            targetSlot = i
            break
        end
    end
    if not turtle.getItemDetail(targetSlot) then
        turtle.select(targetSlot)
    else
        error("🛑 CRITICAL: Inventory is full! Cannot restock.")
    end

    -- 2. Move to the Material Chest
    orient(getRotationForSide(MATERIAL_SIDE))
    move(turtle.forward)
    
    -- 3. Suck materials (Assumes the chest is directly in front)
    turtle.suck(64)
    
    -- 4. Return to the starting point
    move(turtle.back)
    orient(currentRot)

    -- Restore coordinates
    posX, posY, posZ, rotation = currentX, currentY, currentZ, currentRot
    
    -- 5. Verify the item was sucked
    local pulledDetails = turtle.getItemDetail(targetSlot)
    if pulledDetails and pulledDetails.name:match("^([^,]+)") == blockName then
        blockInventory[blockName] = targetSlot
        print("Restock successful. Block " .. blockName .. " in slot " .. targetSlot)
        return targetSlot
    else
        error("Restock failed. Could not retrieve " .. blockName .. " from chest.")
    end
end

-- Finds/selects a block, triggering restock if needed
local function getBlock(blockName)
    local slot = blockInventory[blockName]
    
    if slot then
        local details = turtle.getItemDetail(slot)
        if details and details.name:match("^([^,]+)") == blockName and details.count > 0 then
            return slot -- Found in inventory
        end
    end
    
    -- If not found or empty, RESTOCK
    return restockMaterials(blockName)
end

-- === 5. Main Loop (Build Logic remains the same) ===

local function runBuild()
    -- ... (File selection and loading logic remains the same)
    local files = fs.list(".")
    local luaFiles = {}
    for _, file in ipairs(files) do
        if file:match("%.lua$") and file ~= "builder.lua" then
            table.insert(luaFiles, file)
        end
    end
    
    if #luaFiles == 0 then
        error("No .lua schematic files found on disk! Please transfer the data file.")
    end
    
    term.clear()
    print("--- Select Schematic File ---")
    for i, file in ipairs(luaFiles) do
        print(string.format("[%d] %s", i, file))
    end
    
    local selection = tonumber(read())
    local selectedFile = luaFiles[selection]
    
    if not selectedFile then
        error("Invalid selection.")
    end
    
    BLOCKS = require(selectedFile:match("(.+)%.lua$")) 
    print("Loaded " .. selectedFile .. " with " .. #BLOCKS .. " blocks.")
    
    -- New: Home logic to ensure safety (Fix 3)
    loadState()
    returnHome() -- Ensure starting coordinates are 0,0,0
    
    -- Main Loop
    print("\n--- Starting Construction (Press Ctrl+T to Stop) ---")
    for i = currentBlockIndex, #BLOCKS do
        local block = BLOCKS[i]
        local blockName = block.name:match("^([^,]+)") 

        checkAndRefuel()
        
        -- The crucial order: RESTOCK (via getBlock) before moving, then MOVE, then PLACE.
        local targetSlot = getBlock(blockName) 
        turtle.select(targetSlot)
        
        -- a. Move to the next block's position
        moveTo(block.x, block.z, block.y) 
        
        -- b. Place the block
        local success, reason = turtle.placeDown()
        if not success then
             turtle.digDown()
             os.sleep(0.1)
             success, reason = turtle.placeDown()
             if not success then
                 error("Placement failed: " .. (reason or "No items to place"))
             end
        end
        
        print(string.format("Placed %s at (%d, %d, %d)", blockName, block.x, block.z, block.y))

        -- c. Save state for crash recovery
        currentBlockIndex = i + 1
        saveState()
    end

    print("\n--- CONSTRUCTION COMPLETE! ---")
    fs.delete(STATUS_FILE) 
end

runBuild()
