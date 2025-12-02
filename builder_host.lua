-- builder_host.lua
-- Main job host and scheduler for multi-turtle builds (with WHOIS handshake)

local json = textutils
local JOBS_DIR = "jobs"
if not fs.exists(JOBS_DIR) then fs.makeDir(JOBS_DIR) end

-- Seed RNG
pcall(function() math.randomseed(os.epoch("utc")) end)

local function genPIN()
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local pin = ""
    for i = 1, 6 do
        local idx = math.random(#chars)
        pin = pin .. chars:sub(idx, idx)
    end
    return pin
end

-- Load schematic and normalise format
local function loadSchematic(path)
    local moduleName = path:gsub("%.lua$", "")
    local ok, data = pcall(require, moduleName)
    if not ok then
        error("Failed to load schematic '" .. path .. "': " .. tostring(data))
    end

    local blocks
    local meta

    if type(data) == "table" and data.blocks then
        blocks = data.blocks
        meta   = data.meta or {}
    else
        blocks = data
        meta   = {}
    end

    if type(blocks) ~= "table" then
        error("Schematic file '" .. path .. "' did not return a table of blocks")
    end

    -- Clean up names "minecraft:foo, None" -> "minecraft:foo"
    for _, b in ipairs(blocks) do
        if type(b.name) == "string" then
            local clean = b.name:match("([^,]+)")
            b.name = clean or b.name
        end
    end

    return { meta = meta, blocks = blocks }
end

-- === MAIN ===
term.clear()
term.setCursorPos(1,1)
print("=== Build Host ===")
print("Enter schematic file (e.g. sugar_data.lua):")
local file = read()

local sch = loadSchematic(file)
local blocks = sch.blocks

print("Loaded schematic with " .. #blocks .. " blocks.")

local jobPIN = genPIN()
local hostID = os.getComputerID()
print("Job PIN: " .. jobPIN .. " (Host ID: " .. hostID .. ")")

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
    if type(msg) == "string" then
        local parts = {}
        for w in msg:gmatch("[^|]+") do
            table.insert(parts, w)
        end

        local cmd = parts[1]
        local pin = parts[2]

        -- Ignore messages for other jobs
        if pin == jobPIN and cmd then
            ------------------------------------------------
            -- WHOIS: worker asking for host for this PIN
            ------------------------------------------------
            if cmd == "WHOIS" then
                -- Respond with HOST|PIN|hostID
                local payload = ("HOST|%s|%d"):format(jobPIN, hostID)
                rednet.send(senderID, payload)

            ------------------------------------------------
            -- JOIN: worker joining job
            ------------------------------------------------
            elseif cmd == "JOIN" then
                job.turtles[senderID] = { name = "T" .. tostring(senderID), state = "idle" }
                rednet.send(senderID, "JOINED|" .. jobPIN)
                print("Turtle " .. senderID .. " joined job.")
                saveJob()

            ------------------------------------------------
            -- REQ: worker requesting next task
            ------------------------------------------------
            elseif cmd == "REQ" then
                local idx, block = getNextTask()
                if idx then
                    job.turtles[senderID].state = "working"
                    local payload = ("TASK|%s|%d|%s|%d|%d|%d")
                        :format(jobPIN, idx, block.name, block.x, block.y, block.z)
                    rednet.send(senderID, payload)
                else
                    rednet.send(senderID, "DONE|" .. jobPIN)
                end

            ------------------------------------------------
            -- DONE: worker finished placing a block
            ------------------------------------------------
            elseif cmd == "DONE" then
                local idx = tonumber(parts[3])
                if idx and job.status[idx] == "inprogress" then
                    job.status[idx] = "done"
                    job.stats.placed = job.stats.placed + 1
                    saveJob()
                end

            ------------------------------------------------
            -- STATE: status update from worker
            ------------------------------------------------
            elseif cmd == "STATE" then
                local state = parts[3]
                if job.turtles[senderID] then
                    job.turtles[senderID].state = state or "unknown"
                    saveJob()
                end
            end
        end
    end
end
