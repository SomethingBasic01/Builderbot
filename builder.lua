-- ** FILE: builder.lua (Robust Builder) **

-- === 1. Configuration: YOU MUST SET THESE ===
local FUEL_SIDE = "bottom"       -- Side where the chest containing fuel (coal, charcoal, etc.) is located
local MATERIAL_SIDE = "right"    -- Side where the chest containing all building blocks is located
local STATUS_FILE = "build_status.txt" -- File to save crash recovery data
-- ==============================================

-- Global Position Variables (Used for crash recovery)
local posX, posY, posZ = 0, 0, 0
local rotation = 0 -- 0:North (+Y), 1:East (+X), 2:South (-Y), 3:West (-X)
local currentBlockIndex = 1

-- Coordinate Mapping: Schematic X, Z (horizontal), Y (vertical/height)
local BLOCKS

-- Inventory/Peripheral References
local fuelChest, materialChest
local blockInventory = {} -- Stores which turtle slot has which block name

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

-- Initializes the peripheral chests
local function setupPeripherals()
    fuelChest = peripheral.wrap(FUEL_SIDE)
    materialChest = peripheral.wrap(MATERIAL_SIDE)
    if not fuelChest or not materialChest then
        error(string.format("Failed to find chests! Check side names: Fuel on %s, Materials on %s.", FUEL_SIDE, MATERIAL_SIDE))
    end
    print("Chests connected successfully.")
end

-- Refuel logic
local function checkAndRefuel()
    if turtle.getFuelLevel() < 1000 then -- Refuel if low
        print("⛽ Low fuel. Refueling...")
        turtle.select(16) -- Use a dedicated fuel slot (slot 16 is a good choice)
        
        -- Pull up to 64 items (e.g., coal) from the fuel chest into slot 16
        local itemsPulled = fuelChest.pullItems(FUEL_SIDE, 1, 64, 16)
        if itemsPulled > 0 then
            turtle.refuel()
            print("⛽ Refueled successfully.")
        else
            error("🛑 OUT OF FUEL! Fuel chest is empty or cannot be accessed.")
        end
    end
end

-- Tries to find the block in the turtle's inventory or pull it from the chest
local function getBlock(blockName)
    local slot = blockInventory[blockName]
    
    -- 1. Check turtle inventory
    if slot then
        local details = turtle.getItemDetail(slot)
        if details and details.name:match("^([^,]+)") == blockName then
            return slot
        end
    end
    
    -- 2. If slot is empty or block is wrong, search and pull from material chest
    print("🔍 Block " .. blockName .. " missing. Restocking...")
    
    -- Find the required item in the Material Chest
    local itemsList = materialChest.list()
    local sourceSlot, targetSlot
    
    -- Find the block in the material chest
    for s, item in pairs(itemsList) do
        if item.name:match("^([^,]+)") == blockName then
            sourceSlot = s
            break
        end
    end
    
    if not sourceSlot then
        error("🛑 CRITICAL: Block " .. blockName .. " NOT found in the material chest.")
    end
    
    -- Find an empty slot in the turtle's inventory (1-15, keep 16 for fuel)
    for i = 1, 15 do
        if not turtle.getItemDetail(i) then
            targetSlot = i
            break
        end
    end

    if not targetSlot then
        error("🛑 CRITICAL: Turtle inventory is full! Cannot restock " .. blockName)
    end
    
    -- Pull 64 items into the empty slot
    local pulled = materialChest.pullItems(MATERIAL_SIDE, sourceSlot, 64, targetSlot)
    if pulled > 0 then
        blockInventory[blockName] = targetSlot
        return targetSlot
    else
        error("Failed to pull block " .. blockName .. " from chest.")
    end
end

-- === 4. Movement Functions (Updated) ===

-- Executes a movement command and updates coordinates/saves state
local function move(command)
    local success, reason = command()
    
    if not success then
        checkAndRefuel() -- Always try refueling if movement fails
        
        if reason == "Movement blocked" then
            if command == turtle.forward then turtle.dig() end
            if command == turtle.up then turtle.digUp() end
            if command == turtle.down then turtle.digDown() end
            
            -- Try the move again after digging
            local s, r = command()
            if s then success = s else error("Movement failed after digging: " .. (r or "Unknown")) end
        else
            error("Movement failed: " .. (reason or "Unknown reason"))
        end
    end
    
    -- Update internal coordinates on success
    if command == turtle.forward then
        if rotation == 0 then posY = posY + 1
        elseif rotation == 1 then posX = posX + 1
        elseif rotation == 2 then posY = posY - 1
        elseif rotation == 3 then posX = posX - 1
        end
    -- Turtle does not have turtle.back(), but is included for completeness in case it's added.
    -- elseif command == turtle.back then
    --     if rotation == 0 then posY = posY - 1
    --     ...
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
    
    -- Optional: Orient North after movement for a predictable final state
    orient(0) 
end

-- Selects the block and places it down.
local function placeBlock(blockName)
    local slot = getBlock(blockName)
    
    turtle.select(slot)
    
    -- Place the block *down* (as the turtle is standing where the next layer starts)
    local success, reason = turtle.placeDown()
    if not success then
        -- Attempt to dig the block below and try again
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
    -- 1. File Selection and Loading (Fix 1)
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
    
    BLOCKS = require(selectedFile:match("(.+)%.lua$")) -- Load the file
    print("Loaded " .. selectedFile .. " with " .. #BLOCKS .. " blocks.")
    
    -- 2. Setup Peripherals (Fix 2)
    setupPeripherals()
    
    -- 3. Load State (Fix 3)
    loadState()
    
    -- 4. Main Loop
    print("\n--- Starting Construction (Press Ctrl+T to Stop) ---")
    for i = currentBlockIndex, #BLOCKS do
        local block = BLOCKS[i]
        
        -- Get the clean name, stripping the ", None" part
        local blockName = block.name:match("^([^,]+)") 

        checkAndRefuel()
        
        -- a. Move to the next block's position
        moveTo(block.x, block.z, block.y) 
        
        -- b. Place the block (Fix 4)
        placeBlock(blockName)
        
        -- c. Save state for crash recovery (Fix 3)
        currentBlockIndex = i + 1
        saveState()
    end

    print("\n--- CONSTRUCTION COMPLETE! ---")
    fs.delete(STATUS_FILE) -- Clean up status file on successful completion
end

runBuild()
