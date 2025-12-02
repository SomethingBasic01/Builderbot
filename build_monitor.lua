-- build_monitor.lua
-- Monitoring UI
local modem = peripheral.find("modem")
if not modem then error("No modem found") end
rednet.open(peripheral.getName(modem))

print("Enter Job PIN:")
local pin = read()
local lastPlaced,total=0,0

while true do
  local id,msg = rednet.receive(1)
  if msg and msg:find(pin) then
    if msg:find("JOB") then
      local job = textutils.unserialize(msg)
      total=job.stats.total
      lastPlaced=job.stats.placed
    end
  end
  term.clear()
  term.setCursorPos(1,1)
  local pct=(lastPlaced/total)*100
  local bar=math.floor(pct/5)
  write("Job "..pin.."  "..string.format("%.1f%% complete\n",pct))
  write("["..string.rep("█",bar)..string.rep("░",20-bar).."]\n")
  sleep(1)
end
