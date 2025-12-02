 -- build_host.lua
-- Main job host and scheduler
local json = textutils
local JOBS_DIR = "jobs"
if not fs.exists(JOBS_DIR) then fs.makeDir(JOBS_DIR) end

local function genPIN()
  local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local pin=""
  for i=1,6 do pin=pin..chars:sub(math.random(#chars),math.random(#chars)) end
  return pin
end

local function loadSchematic(path)
  local ok,data = pcall(require, path:match("(.+)%.lua$"))
  if not ok then error("Failed to load schematic: "..data) end
  return data
end

print("=== Build Host ===")
print("Enter schematic file (e.g. sugar_data.lua):")
local file = read()
local sch = loadSchematic(file)
print("Loaded schematic with "..#sch.blocks.." blocks.")

local jobPIN = genPIN()
local job = {
  id = jobPIN,
  schematic = sch,
  status = {},
  turtles = {},
  stats = {total=#sch.blocks, placed=0, start=os.clock()}
}
for i=1,#sch.blocks do job.status[i]="todo" end

local jobFile = JOBS_DIR.."/job_"..jobPIN..".json"
local modem = peripheral.find("modem")
if not modem then error("No modem found") end
rednet.open(peripheral.getName(modem))
print("Job PIN: "..jobPIN.." - waiting for turtles...")

-- assign next unclaimed block
local function getNextTask()
  for i,s in ipairs(job.status) do
    if s=="todo" then
      job.status[i]="inprogress"
      return i, job.schematic.blocks[i]
    end
  end
  return nil,nil
end

local function saveJob()
  local f = fs.open(jobFile,"w")
  f.write(json.serialize(job))
  f.close()
end

while true do
  local id,msg = rednet.receive()
  local parts = {}
  for w in msg:gmatch("[^|]+") do table.insert(parts,w) end
  if parts[1]=="JOIN" and parts[2]==jobPIN then
    job.turtles[id]={name="T"..tostring(id),state="idle"}
    rednet.send(id,"JOINED|"..jobPIN)
    print("Turtle "..id.." joined.")
  elseif parts[1]=="REQ" and parts[2]==jobPIN then
    local taskID,block=getNextTask()
    if taskID then
      job.turtles[id].state="working"
      rednet.send(id,("TASK|%s|%d|%s|%d|%d|%d"):format(jobPIN,taskID,block.name,block.x,block.y,block.z))
    else
      rednet.send(id,"DONE|"..jobPIN)
    end
  elseif parts[1]=="DONE" and parts[2]==jobPIN then
    local idx=tonumber(parts[3])
    if job.status[idx]=="inprogress" then
      job.status[idx]="done"
      job.stats.placed=job.stats.placed+1
      saveJob()
    end
  elseif parts[1]=="STATE" and parts[2]==jobPIN then
    job.turtles[id].state=parts[3]
  end
end
