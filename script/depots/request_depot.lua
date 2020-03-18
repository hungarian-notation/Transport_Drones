local transport_drone = require("script/transport_drone")
local road_network = require("script/road_network")
local transport_technologies = require("script/transport_technologies")

local request_spawn_timeout = 60

local script_data = 
{
  request_depots = {}
}

local request_depot = {}
local depot_metatable = {__index = request_depot}

local corpse_offsets = 
{
  [0] = {0, -2},
  [2] = {2, 0},
  [4] = {0, 2},
  [6] = {-2, 0},
}

local get_corpse_position = function(entity)

  local position = entity.position
  local direction = entity.direction
  local offset = corpse_offsets[direction]
  return {position.x + offset[1], position.y + offset[2]}

end

function request_depot.new(entity)

  local force = entity.force
  local surface = entity.surface

  entity.active = false

  local corpse_position = get_corpse_position(entity)
  local corpse = surface.create_entity{name = "transport-caution-corpse", position = corpse_position}
  corpse.corpse_expires = false
  
  local depot =
  {
    entity = entity,
    corpse = corpse,
    index = tostring(entity.unit_number),
    node_position = {math.floor(corpse_position[1]), math.floor(corpse_position[2])},
    item = false,
    drones = {},
    next_spawn_tick = 0
  }
  setmetatable(depot, depot_metatable)

  depot:add_to_node()

  return depot

end

function request_depot:check_drone_validity()
  local index, drone = next(self.drones)
  if not index then return end

  if not drone.entity.valid then
    drone:clear_drone_data()
    self:remove_drone(drone)
  end
end

function request_depot:update()
  self:check_request_change()
  self:check_drone_validity()
  self:update_sticker()
end

function request_depot:suicide_all_drones()
  for k, drone in pairs (self.drones) do
    drone:suicide()
  end
end

function request_depot:check_request_change()
  local requested_item = self:get_requested_item()
  if self.item == requested_item then return end

  if self.item then
    self:remove_from_network()
    self:suicide_all_drones()
  end

  self.item = requested_item
  
  if not self.item then return end
  
  self:add_to_network()

end

function request_depot:get_requested_item()
  local recipe = self.entity.get_recipe()
  if not recipe then return end
  return recipe.products[1].name
end

function request_depot:get_stack_size()
  return game.item_prototypes[self.item].stack_size
end

function request_depot:get_request_size()
  return self:get_stack_size() * (1 + transport_technologies.get_transport_capacity_bonus(self.entity.force.index))
end

function request_depot:get_output_inventory()
  return self.entity.get_output_inventory()
end

function request_depot:get_drone_inventory()
  return self.entity.get_inventory(defines.inventory.assembling_machine_input)
end

function request_depot:get_active_drone_count()
  return table_size(self.drones)
end

function request_depot:can_spawn_drone()
  if game.tick < (self.next_spawn_tick or 0) then return end
  return self:get_drone_item_count() > self:get_active_drone_count()
end

function request_depot:get_drone_item_count()
  return self.entity.get_item_count("transport-drone")
end

function request_depot:get_minimum_request_size()
  return math.ceil(self:get_stack_size() / 2)
end

function request_depot:should_order(plus_one)
  local stack_size = self:get_request_size()
  local current_count = self:get_output_inventory().get_item_count(self.item)
  local max_count = self:get_drone_item_count()
  local drone_spawn_count = max_count - math.floor(current_count / stack_size)
  return drone_spawn_count + (plus_one and 1 or 0) > self:get_active_drone_count()
end

function request_depot:handle_offer(supply_depot, name, count)

  if count < self:get_minimum_request_size() then return end

  if not self:can_spawn_drone() then return end

  if not self:should_order() then return end


  local needed_count = math.min(self:get_request_size(), count)

  local drone = transport_drone.new(self, supply_depot, needed_count)
  self.drones[drone.index] = drone
  self.next_spawn_tick = game.tick + request_spawn_timeout
  self:update_sticker()

end

function request_depot:take_item(name, count)
  self.entity.get_output_inventory().insert({name = name, count = count})
end

function request_depot:remove_drone(drone, remove_item)
  self.drones[drone.index] = nil
  if remove_item then
    self:get_drone_inventory().remove{name = "transport-drone", count = 1}
  end
  self:update_sticker()
end

function request_depot:update_sticker()

  if self.rendering and rendering.is_valid(self.rendering) then
    rendering.set_text(self.rendering, self:get_active_drone_count().."/"..self:get_drone_item_count())
    return
  end

  if not self.item then return end

  self.rendering = rendering.draw_text
  {
    surface = self.entity.surface.index,
    target = self.entity,
    text = self:get_active_drone_count().."/"..self:get_drone_item_count(),
    only_in_alt_mode = true,
    forces = {self.entity.force},
    color = {r = 1, g = 1, b = 1},
    alignment = "center",
    scale = 1.5
  }

end


function request_depot:say(string)
  self.entity.surface.create_entity{name = "flying-text", position = self.entity.position, text = string}
end

function request_depot:add_to_node()
  local node = road_network.get_node(self.entity.surface.index, self.node_position[1], self.node_position[2])
  node.depots = node.depots or {}
  node.depots[self.index] = self
end

function request_depot:remove_from_node()
  local surface = self.entity.surface.index
  local node = road_network.get_node(surface, self.node_position[1], self.node_position[2])
  node.depots[self.index] = nil
  road_network.check_clear_lonely_node(surface, self.node_position[1], self.node_position[2])
end

function request_depot:add_to_network()
  if not self.item then return end
  --self:say("Adding to network")
  self.network_id = road_network.add_request_depot(self, self.item)
end

function request_depot:remove_from_network()
  if not self.item then return end
  local network = road_network.get_network_by_id(self.network_id)
  if not network then return end

  local requesters = network.requesters
  requesters[self.item][self.index] = nil

  self.network_id = nil

end

function request_depot:on_removed()
  self:remove_from_network()
  self:remove_from_node()
  self:suicide_all_drones()
  self.corpse.destroy()
  script_data.request_depots[self.index] = nil
end


local update_next_depot = function()
  local index = script_data.last_update_index
  local depots = script_data.request_depots
  if index and not depots[index] then
    index = nil
  end
  local update_depot
  index, update_depot = next(depots, index)
  script_data.last_update_index = index
  if not index then
    return
  end
  update_depot:update()
  --update_depot:say("U")
end

local on_tick = function(event)
  if event.tick % 2 == 1 then return end
  update_next_depot()
end

local lib = {}

lib.load = function(depot)
  setmetatable(depot, depot_metatable)
end

lib.new = request_depot.new

return lib