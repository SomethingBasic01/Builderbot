-- builder_host.lua
-- Simple multi-turtle build host using broadcast + worker IDs

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

local function split(msg)
    local t = {}
    for w in msg:gmatch("[^|]+") do
        t[#t+1] = w
    end
    return t
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

    -- Clean up names "minecraft:stone, None" -> "minecraft:stone"
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
print("Job PIN: " .. jobPIN)

local job = {
    id        = jobPIN,
    schematic = sch,
    status    = {},
    turtles   = {},   -- [id] = {state="...", placed=0}
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
        local p = split(msg)
        local cmd   = p[1]
        local pin   = p[2]
        local wID   = tonumber(p[3])

        if pin == jobPIN and cmd and wID then
            if cmd == "JOIN" then
                job.turtles[wID] = job.turtles[wID] or { state = "idle", placed = 0 }
                print("Worker " .. wID .. " joined job.")
                saveJob()

            elseif cmd == "REQ" then
                local idx, block = getNextTask()
                if idx then
                    job.turtles[wID] = job.turtles[wID] or { state = "idle", placed = 0 }
                    job.turtles[wID].state = "working"

                    local payload = ("TASK|%s|%d|%d|%s|%d|%d|%d")
                        :format(jobPIN, wID, idx, block.name, block.x, block.y, block.z)
                    rednet.broadcast(payload)
                    print(("Sent TASK %d to worker %d"):format(idx, wID))
                else
                    local payload = ("IDLE|%s|%d"):format(jobPIN, wID)
                    rednet.broadcast(payload)
                    print("No more tasks, told worker " .. wID .. " to idle.")
                end
                saveJob()

            elseif cmd == "COMPLETE" then
                local idx = tonumber(p[4])
                if idx and job.status[idx] == "inprogress" then
                    job.status[idx] = "done"
                    job.stats.placed = job.stats.placed + 1

                    job.turtles[wID] = job.turtles[wID] or { state = "idle", placed = 0 }
                    job.turtles[wID].state = "idle"
                    job.turtles[wID].placed = job.turtles[wID].placed + 1

                    print(("Worker %d completed block %d (%d/%d total)")
                        :format(wID, idx, job.stats.placed, job.stats.total))
                    saveJob()
                end

            elseif cmd == "STATE" then
                local state = p[4] or "unknown"
                job.turtles[wID] = job.turtles[wID] or { placed = 0 }
                job.turtles[wID].state = state
                saveJob()
            end
        end
    end
end
