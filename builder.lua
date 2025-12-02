-- ** FILE: builder.lua (Fixed Robust Builder) **

-- === 1. Configuration: DO NOT CHANGE THESE SIDES! ===
-- We enforce UP/DOWN for safety to keep the horizontal build path clear.
local MATERIAL_SIDE = "up"       -- Material Chest MUST be placed directly on TOP.
local FUEL_SIDE = "down"         -- Fuel Chest MUST be placed directly on BOTTOM.
local STATUS_FILE = "build_status.txt" 
-- ======================================================

-- Global Position Variables (Used for crash recovery)
local posX, posY, posZ = 0, 0, 0 -- Relative coordinates (X, Schematic Z, Schematic Y)
local rotation = 0              -- 0:North (+Y), 1:East (+X), 2:South (-Y), 3:West (-X)
local currentBlockIndex = 1
local BLOCKS                    -- Loaded schematic data

-- Inventory/Peripheral References
local fuelChest, materialChest
local blockInventory = {}       -- Stores which turtle slot has which block name

-- === 2. Core I/O Functions (For Crash Recovery) ===

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

-- === 3. Utility Functions (Inventory & Fuel) ===

local function setupPeripherals()
    fuelChest = peripheral.wrap(FUEL_SIDE)
    materialChest = peripheral.wrap(MATERIAL_SIDE)
    if not fuelChest or not materialChest then
        error(string.format("🛑 FAILED: Cannot find chests! Ensure Material Chest is on %s and Fuel Chest is on %s.", MATERIAL_SIDE, FUEL_SIDE))
    end
    print("Chests connected successfully.")
end

-- Refuel logic: Uses suckDown to pull from the bottom chest.
local function checkAndRefuel()
    if turtle.getFuelLevel() < 1000 then -- Refuel if low
        print("⛽ Low fuel. Refueling...")
        
        -- Try to suck one slot of items from the fuel chest (down)
        local success = turtle.suckDown() 
        
        if success then
            -- Find the fuel in inventory and select it
            local fuel_slot = nil
            for i = 1, 16 do
                local detail = turtle.getItemDetail(i)
                if detail and (detail.name:find("coal") or detail.name:find("charcoal") or detail.name:find("lava_bucket")) then
                    fuel_slot = i
                    break
                end
            end
            
            if fuel_slot then
                turtle.select(fuel_slot)
                turtle.refuel()
                print("⛽ Refueled successfully.")
            else
                print("⚠️ Sucked items, but no valid fuel found in inventory. Continuing.")
            end
        else
            error("🛑 OUT OF FUEL! Fuel chest is empty or cannot be accessed by turtle.suckDown().")
        end
    end
end

-- Tries to find the block in the turtle's inventory or pull it from the chest (up).
local function getBlock(blockName)
    local slot = blockInventory[blockName]
    
    -- 1. Check turtle inventory
    if slot then
        local details = turtle.getItemDetail(slot)
        if details and details.name:match("^([^,]+)") == blockName then
            return slot
        end
    end
    
    -- 2. Search and pull from material chest (up)
    print("🔍 Block " .. blockName .. " missing. Restocking...")
    
    -- Find an empty slot in the turtle's inventory (1-15, keep 16 for utility/fuel)
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
        error("🛑 CRITICAL: Turtle inventory is full! Cannot restock " .. blockName)
    end
    
    -- Tell the chest (peripheral) to push the item to the turtle's current slot
    local success = materialChest.pullItems(MATERIAL_SIDE, 1, 64, targetSlot)

    -- If peripheral pull fails, try the simpler turtle suck approach (which is safer)
    if not success then
        print("Peripheral pull failed. Searching chest for " .. blockName .. " and attempting turtle.suckUp...")
        
        local itemsList = materialChest.list()
        local sourceSlot
        
        for s, item in pairs(itemsList) do
            if item.name:match("^([^,]+)") == blockName then
                sourceSlot = s
                break
            end
        end

        if not sourceSlot then
            error("🛑 CRITICAL: Block " .. blockName .. " NOT found in the material chest.")
        end

        -- Move item to the first slot of the chest (hack for turtle.suckUp)
        local count = materialChest.pushItems(MATERIAL_SIDE, sourceSlot, nil, 1)

        if count > 0 then
            -- Suck from the chest's first slot (which now contains the required block)
            turtle.suckUp(count)
        end
    end

    -- Re-check inventory for the item after the restock attempt
    local pulledDetails = turtle.getItemDetail(targetSlot)
    if pulledDetails and pulledDetails.name:match("^([^,]+)") == blockName then
        blockInventory[blockName] = targetSlot
        print("Restock successful. Block " .. blockName .. " in slot " .. targetSlot)
        return targetSlot
    else
        error("Restock failed. Could not retrieve " .. blockName)
    end
end

-- === 4. Movement Functions ===

-- Executes a movement command and updates coordinates/saves state
local function move(command)
    local success, reason = command()
    
    if not success then
        -- We're building, so if movement is blocked, dig the obstruction.
        if command == turtle.forward then turtle.dig() end
        if command == turtle.up then turtle.digUp() end
        if command == turtle.down then turtle.digDown() end
        
        -- Try the move again after digging
        local s, r = command()
        if not s then error("Movement failed after digging: " .. (r or "Unknown")) end
    end
    
    -- Update internal coordinates on success
    if command == turtle.forward then
        if rotation == 0 then posY = posY + 1
        elseif rotation == 1 then posX = posX + 1
        elseif rotation == 2 then posY = posY - 1
        elseif rotation == 3 then posX = posX - 1
        end
    elseif command == turtle.up then
        posZ = posZ + 1
    elseif command == turtle.down then
        posZ = posZ - 1
    elseif command == turtle.turnLeft then
        rotation = (rotation - 1 + 4) % 4 -- +4 for correct Lua modulo behavior
    elseif command == turtle.turnRight then
        rotation = (rotation + 1) % 4
    end
end

local function orient(targetRotation)
    while rotation ~= targetRotation do
        move(turtle.turnRight)
    end
end

-- Navigates the turtle to the relative coordinates (tx, ty, tz)
local function moveTo(tx, ty, tz)
    term.clear()
    print(string.format("Target: (%d, %d, %d)", tx, ty, tz))
    print(string.format("Current: (%d, %d, %d)", posX, posY, posZ))

    -- 1. Handle Vertical (Z-axis / Minecraft Y-axis) movement
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
    
    -- Ensure we always finish facing North (Home orientation)
    orient(0) 
end

local function placeBlock(blockName)
    local slot = getBlock(blockName)
    
    turtle.select(slot)
    
    -- Place the block *down* (as the turtle is standing where the next layer starts)
    local success, reason = turtle.placeDown()
    if not success then
        -- Try to dig the block below and try again (for a dirty schematic layer)
        turtle.digDown()
        os.sleep(0.1)
        success, reason = turtle.placeDown()
        
        if not success then
             error("Failed to place block " .. blockName .. ": " .. (reason or "Unknown"))
        end
    end
end

-- === 5. Initialization and Main Loop ===

local function runBuild()
    -- 1. File Selection and Loading
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
    
    -- The require() is correct assuming your data file returns the table
    BLOCKS = require(selectedFile:match("(.+)%.lua$")) 
    print("Loaded " .. selectedFile .. " with " .. #BLOCKS .. " blocks.")
    
    -- 2. Setup Peripherals
    setupPeripherals()
    
    -- 3. Load State
    loadState()
    
    -- 4. Main Loop
    print("\n--- Starting Construction (Press Ctrl+T to Stop) ---")
    for i = currentBlockIndex, #BLOCKS do
        local block = BLOCKS[i]
        
        local blockName = block.name:match("^([^,]+)") 

        -- Check fuel and restock if needed. This step is safe and causes no movement.
        checkAndRefuel()
        
        -- Get the block, potentially restocking. This is also safe and causes no movement.
        -- This ensures the block is in the inventory before moving.
        getBlock(blockName) 

        -- a. Move to the next block's position
        moveTo(block.x, block.z, block.y) 
        
        -- b. Place the block 
        placeBlock(blockName)
        
        -- c. Save state for crash recovery
        currentBlockIndex = i + 1
        saveState()
    end

    print("\n--- CONSTRUCTION COMPLETE! ---")
    fs.delete(STATUS_FILE) -- Clean up status file on successful completion
end

runBuild()
