-- build_host.lua  (or builder.lua if that's what you're using)
-- Main job host and scheduler

local json = textutils
local JOBS_DIR = "jobs"
if not fs.exists(JOBS_DIR) then fs.makeDir(JOBS_DIR) end

-- Seed RNG for PIN generation
pcall(function() math.randomseed(os.epoch("utc")) end)

-- Generate a 6-char PIN like "A1B2C3"
local function genPIN()
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local pin = ""
    for i = 1, 6 do
        local idx = math.random(#chars)
        pin = pin .. chars:sub(idx, idx)
    end
    return pin
end

-- Normalise schematic file return value
-- Works with:
--   local blocks = {...} ; return blocks
--   return { meta=..., blocks={...} }
local function loadSchematic(path)
    -- Strip ".lua" for require
    local moduleName = path:gsub("%.lua$", "")
    local ok, data = pcall(require, moduleName)
    if not ok then
        error("Failed to load schematic '" .. path .. "': " .. tostring(data))
    end

    local blocks
    local meta

    if type(data) == "table" and data.blocks then
        -- New style: {meta=..., blocks={...}}
        blocks = data.blocks
        meta   = data.meta or {}
    else
        -- Old/simple style: return blocks
        blocks = data
        meta   = {}
    end

    if type(blocks) ~= "table" then
        error("Schematic file '" .. path .. "' did not return a table of blocks")
    end

    -- Optionally clean up block names ("minecraft:stone, None" -> "minecraft:stone")
    for _, b in ipairs(blocks) do
        if type(b.name) == "string" then
            local clean = b.name:match("([^,]+)")
            b.name = clean or b.name
        end
    end

    return { meta = meta, blocks = blocks }
end

-- === MAIN ===
print("=== Build Host ===")
print("Enter schematic file (e.g. sugar_data.lua):")
local file = read()

local sch = loadSchematic(file)
local blocks = sch.blocks   -- guaranteed by loadSchematic

print("Loaded schematic with " .. #blocks .. " blocks.")

local jobPIN = genPIN()
print("Job PIN: " .. jobPIN)

local job = {
    id        = jobPIN,
    schematic = sch,
    status    = {},
    turtles   = {},
    stats     = { total = #blocks, placed = 0, start = os.clock() }
}

for i = 1, #blocks do
    job.status[i] = "todo"
end

local jobFile = JOBS_DIR .. "/job_" .. jobPIN .. ".json"

local modem = peripheral.find("modem")
if not modem then
    error("No modem found on this computer/turtle – attach a wireless modem.")
end
rednet.open(peripheral.getName(modem))

print("Waiting for turtles to join on PIN " .. jobPIN .. "...")

local function saveJob()
    local f = fs.open(jobFile, "w")
    f.write(json.serialize(job))
    f.close()
end

-- Return next unclaimed block index and data
local function getNextTask()
    for i, state in ipairs(job.status) do
        if state == "todo" then
            job.status[i] = "inprogress"
            return i, job.schematic.blocks[i]
        end
    end
    return nil, nil
end

while true do
    local senderID, msg = rednet.receive()
    local parts = {}
    for w in msg:gmatch("[^|]+") do
        table.insert(parts, w)
    end

    local cmd = parts[1]
    local pin = parts[2]

    if pin ~= jobPIN then
        -- Not our job, ignore
        goto continue
    end

    if cmd == "JOIN" then
        job.turtles[senderID] = { name = "T" .. tostring(senderID), state = "idle" }
        rednet.send(senderID, "JOINED|" .. jobPIN)
        print("Turtle " .. senderID .. " joined job.")
        saveJob()

    elseif cmd == "REQ" then
        local idx, block = getNextTask()
        if idx then
            job.turtles[senderID].state = "working"
            -- Send TASK|PIN|idx|name|x|y|z
            local payload = ("TASK|%s|%d|%s|%d|%d|%d")
                :format(jobPIN, idx, block.name, block.x, block.y, block.z)
            rednet.send(senderID, payload)
        else
            -- No more tasks
            rednet.send(senderID, "DONE|" .. jobPIN)
        end

    elseif cmd == "DONE" then
        local idx = tonumber(parts[3])
        if job.status[idx] == "inprogress" then
            job.status[idx] = "done"
            job.stats.placed = job.stats.placed + 1
            saveJob()
        end

    elseif cmd == "STATE" then
        local state = parts[3]
        if job.turtles[senderID] then
            job.turtles[senderID].state = state
            saveJob()
        end
    end

    ::continue::
end
