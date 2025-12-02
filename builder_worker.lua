-- build_worker.lua
-- Turtle worker node
local modem = peripheral.find("modem")
if not modem then error("No modem found") end
rednet.open(peripheral.getName(modem))

print("Enter Job PIN:")
local pin = read()
print("Joining job "..pin.."...")
rednet.broadcast("JOIN|"..pin)

local function goTo(x,y,z)
  -- Basic Manhattan movement (replace with proper pathing)
  local cx,cy,cz=0,0,0
  while cz<z do if not turtle.up() then turtle.digUp() end cz=cz+1 end
  while cz>z do if not turtle.down() then turtle.digDown() end cz=cz-1 end
  while cy<y do if not turtle.forward() then turtle.dig() end cy=cy+1 end
  while cy>y do turtle.back() cy=cy-1 end
end

while true do
  rednet.broadcast("REQ|"..pin)
  local id,msg = rednet.receive(2)
  if not msg then sleep(1) goto continue end

  local parts={} for w in msg:gmatch("[^|]+") do table.insert(parts,w) end
  if parts[1]=="TASK" and parts[2]==pin then
    local idx=tonumber(parts[3])
    local name=parts[4]
    local x,y,z=tonumber(parts[5]),tonumber(parts[6]),tonumber(parts[7])
    print("Building "..name.." at ("..x..","..y..","..z..")")

    goTo(x,y,z)
    local placed=false
    for i=1,16 do
      local item=turtle.getItemDetail(i)
      if item and item.name==name then
        turtle.select(i)
        placed=turtle.placeDown()
        break
      end
    end
    if placed then
      rednet.broadcast(("DONE|%s|%d"):format(pin,idx))
    else
      print("Missing block "..name)
      rednet.broadcast(("STATE|%s|restock"):format(pin))
      sleep(5)
    end
  elseif parts[1]=="DONE" and parts[2]==pin then
    print("All tasks complete.")
    break
  end
  ::continue::
end
