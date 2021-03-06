
-- module describing business system (company, money laundering)

local cfg = require("resources/vrp/cfg/business")
local htmlEntities = require("resources/vrp/lib/htmlEntities")

-- sql
local q_init = vRP.sql:prepare([[
CREATE TABLE IF NOT EXISTS vrp_user_business(
  user_id INTEGER,
  name VARCHAR(30),
  description TEXT,
  capital INTEGER,
  laundered INTEGER,
  reset_timestamp INTEGER,
  CONSTRAINT pk_user_business PRIMARY KEY(user_id),
  CONSTRAINT fk_user_business_users FOREIGN KEY(user_id) REFERENCES vrp_users(id) ON DELETE CASCADE
);
]])
q_init:execute()

local q_create_business = vRP.sql:prepare("INSERT IGNORE INTO vrp_user_business(user_id,name,description,capital,laundered,reset_timestamp) VALUES(@user_id,@name,'',@capital,0,@time)")
local q_delete_business = vRP.sql:prepare("DELETE FROM vrp_user_business WHERE user_id = @user_id")
local q_get_business = vRP.sql:prepare("SELECT name,description,capital,laundered,reset_timestamp FROM vrp_user_business WHERE user_id = @user_id")
local q_add_capital = vRP.sql:prepare("UPDATE vrp_user_business SET capital = capital + @capital WHERE user_id = @user_id")
local q_add_laundered = vRP.sql:prepare("UPDATE vrp_user_business SET laundered = laundered + @laundered WHERE user_id = @user_id")
local q_get_page = vRP.sql:prepare("SELECT user_id,name,description,capital FROM vrp_user_business ORDER BY capital DESC LIMIT @b,@n")
local q_reset_transfer = vRP.sql:prepare("UPDATE vrp_user_business SET laundered = 0, reset_timestamp = @time WHERE user_id = @user_id")

-- api

-- get user business data or nil
function vRP.getUserBusiness(user_id)
  local business = nil
  if user_id ~= nil then
    q_get_business:bind("@user_id",user_id)
    local r = q_get_business:query()
    if r:fetch() then
      business = r:getRow()
    end

    r:close()
  end

  -- when a business is fetched from the database, check for update of the laundered capital transfer capacity
  if business and os.time() >= business.reset_timestamp+cfg.transfer_reset_interval*60 then
    q_reset_transfer:bind("@user_id",user_id)
    q_reset_transfer:bind("@time",os.time())
    q_reset_transfer:execute()

    business.laundered = 0
  end

  return business
end

-- add dirty money item

local dm_choices = {}
vRP.defInventoryItem("dirty_money","Dirty money","Illegally earned money.",dm_choices)

-- business interaction

-- page start at 0
local function open_business_directory(player,page) -- open business directory with pagination system
  if page < 0 then page = 0 end

  local menu = {name="Business directory ("..page..")",css={top="75px",header_color="rgba(240,203,88,0.75)"}}

  q_get_page:bind("@b",page*10)
  q_get_page:bind("@n",10)
  local r = q_get_page:query()
  while r:fetch() do 
    local row = r:getRow()

    if row.user_id ~= nil then
      -- get owner identity
      local identity = vRP.getUserIdentity(row.user_id)

      if identity then
        menu[htmlEntities.encode(row.name)] = {function()end,"<em>capital: </em>"..row.capital.." $<br /><em>owner: </em>"..htmlEntities.encode(identity.name).." "..htmlEntities.encode(identity.firstname).."<br /><em>registration n°: </em>"..identity.registration}
      end
    end
  end

  r:close()

  menu["> Next"] = {function() open_business_directory(player,page+1) end}
  menu["> Prev"] = {function() open_business_directory(player,page-1) end}

  vRP.openMenu(player,menu)
end

local function business_enter()
  local user_id = vRP.getUserId(source)
  if user_id ~= nil then
    -- build business menu
    local menu = {name="Chamber of Commerce",css={top="75px",header_color="rgba(240,203,88,0.75)"}}

    local business = vRP.getUserBusiness(user_id)
    if business then -- have a business
      -- business info
      menu["Business info"] = {function(player,choice)
      end,"<em>name: </em>"..htmlEntities.encode(business.name).."<br /><em>capital: </em>"..business.capital.." $<br /><em>capital transfer: </em>"..business.laundered.." $<br /><br/>Capital transfer is the amount of money transfered for a business economic period, the maximum is the business capital."}

      -- add capital
      menu["Add capital"] = {function(player,choice)
        vRP.prompt(player,"Amount to add to the business capital: ","",function(player,amount)
          amount = tonumber(amount)
          if amount > 0 then
            if vRP.tryPayment(user_id,amount) then
              q_add_capital:bind("@user_id",user_id)
              q_add_capital:bind("@capital",amount)
              q_add_capital:execute()

              vRPclient.notify(player,{amount.." $ added to the business capital."})
            else
              vRPclient.notify(player,{"Not enough money."})
            end
          else
            vRPclient.notify(player,{"Invalid amount."})
          end
        end)
      end,"Add capital to your business."}

      -- money laundered
      menu["Money laundering"] = {function(player,choice)
        business = vRP.getUserBusiness(user_id) -- update business data
        local launder_left = math.min(business.capital-business.laundered,vRP.getInventoryItemAmount(user_id,"dirty_money")) -- compute launder capacity
        vRP.prompt(player,"Amount of dirty money to launder (max "..launder_left.." $): ",""..launder_left,function(player,amount)
          amount = tonumber(amount)
          if amount > 0 and amount <= launder_left then
            if vRP.tryGetInventoryItem(user_id,"dirty_money",amount) then
              -- add laundered amount
              q_add_laundered:bind("@user_id",user_id)
              q_add_laundered:bind("@laundered",amount)
              q_add_laundered:execute()

              -- give laundered money
              vRP.giveMoney(user_id,amount)
              vRPclient.notify(player,{amount.." $ laundered."})
            else
              vRPclient.notify(player,{"Not enough dirty money."})
            end
          else
            vRPclient.notify(player,{"Invalid amount."})
          end
        end)
      end,"Use your business to launder dirty money."}

    else -- doesn't have a business
      menu["Open business"] = {function(player,choice)
        vRP.prompt(player,"Business name (can't change after, max 30 chars): ","",function(player,name)
          if string.len(name) >= 2 and string.len(name) <= 30 then
            vRP.prompt(player,"Initial capital (min "..cfg.minimum_capital..")",""..cfg.minimum_capital,function(player,capital)
              capital = tonumber(capital)
              if capital >= cfg.minimum_capital then
                if vRP.tryPayment(user_id,capital) then
                  q_create_business:bind("@user_id",user_id)
                  q_create_business:bind("@name",name)
                  q_create_business:bind("@capital",capital)
                  q_create_business:bind("@time",os.time())
                  q_create_business:execute()
                  vRPclient.notify(player,{"Business created."})
                  vRP.closeMenu(player) -- close the menu to force update business info
                else
                  vRPclient.notify(player,{"Not enough money."})
                end
              else
                vRPclient.notify(player,{"Invalid capital."})
              end
            end)
          else
            vRPclient.notify(player,{"Invalid name."})
          end
        end)
      end,"Open your business, minimum capital is "..cfg.minimum_capital.." $."}
    end

    -- business list
    menu["Directory"] = {function(player,choice)
      open_business_directory(player,0)
    end,"Business directory."}

    -- open menu
    vRP.openMenu(source,menu) 
  end
end

local function business_leave()
  vRP.closeMenu(source)
end

local function build_client_business(source) -- build the city hall area/marker/blip
  local user_id = vRP.getUserId(source)
  if user_id ~= nil then
    for k,v in pairs(cfg.commerce_chambers) do
      local x,y,z = table.unpack(v)

      vRPclient.addBlip(source,{x,y,z,431,70,"Chamber of Commerce"})
      vRPclient.addMarker(source,{x,y,z-1,0.7,0.7,0.5,0,255,125,125,150})

      vRP.setArea(source,"vRP:business",x,y,z,1,1.5,business_enter,business_leave)
    end
  end
end


AddEventHandler("vRP:playerSpawned",function()
  local user_id = vRP.getUserId(source)
  if user_id ~= nil then
    -- first spawn, build business
    if vRP.isFirstSpawn(user_id) then
      build_client_business(source)
    end
  end
end)


