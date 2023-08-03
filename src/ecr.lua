local bit32 = require("bit")
local INITIAL_ENTITY_VERSION = 1
local MAX_ENTITIES = 1048575

table.find = function(t, i, k)
	if not k then
		k = i
		i = 1
	end
	
	for i = i, #t do
		if t[i] == k then
			return i
		end
	end
end
table.clone = function(t)
	local r = {}
	for key, value in pairs(t) do
		r[key] = value
	end
	return r
end

local ERROR = function(msg)
	local stack = 1

	while debug.info(stack, "s") == debug.info(1, "s") do
		stack = stack + 1
	end

	error(msg, stack)
end

local ASSERT = function(v, msg)
	if v then
		return v
	end
	ERROR(msg)
	return nil
end

local function debug_arg(i)
	return "component (arg #" .. i .. ")"
end

ASSERT(
	bit32.band(MAX_ENTITIES + 1, MAX_ENTITIES) == 0 and MAX_ENTITIES <= 1048575 and MAX_ENTITIES > 0,
	"invalid max entities limit"
)

local ID_INVALID_KEY = 0
local ID_MAX_INT = 9007199254740991
local ID_MASK_KEY = MAX_ENTITIES
local ID_MASK_VER = ID_MAX_INT - ID_MASK_KEY

local ID_LSHIFT = ID_MASK_KEY + 1
local ID_RSHIFT = 1 / ID_LSHIFT

local ID_MAX_KEY = ID_MASK_KEY
local ID_MAX_VERSION = ID_MASK_VER * ID_RSHIFT

local function ID_CREATE(key, ver)
	return ver * ID_LSHIFT + key
end

local function ID_KEY(ID)
	return bit32.band(ID, ID_MASK_KEY)
end

local function ID_KEY_VER(ID)
	local key = ID_KEY(ID)
	local ver = (ID - key) * ID_RSHIFT
	return key, ver
end

local function ID_VER(ID)
	return (ID - ID_KEY(ID)) * ID_RSHIFT
end

local function ID_SWAPKEY(ID, key)
	return ID - ID_KEY(ID) + key
end

local ID_NULL = ID_CREATE(0, ID_MAX_VERSION)

local function pool_create(size)
	local n = size or 1
	return {
		size = 0,
		map = {},
		entities = {},
		values = {},
	}
end

local function pool_add(self, key, id, v)
	local n = self.size + 1
	self.size = n
	self.map[key] = ID_SWAPKEY(id, n)
	self.entities[n] = id
	self.values[n] = v
end

local function pool_remove(self, idx, key)
	local n = self.size
	self.size = n - 1
	local map = self.map
	local entities = self.entities
	local values = self.values

	local lastid = entities[n]
	map[ID_KEY(lastid)] = ID_SWAPKEY(lastid, idx)
	map[key] = nil
	entities[idx] = lastid
	entities[n] = nil
	values[idx] = values[n]
	values[n] = nil
end

local function pool_add_id(self, id)
	local map = self.map

	local key = ID_KEY(id)
	local idx_ver = map[key]

	if idx_ver == nil then
		local n = self.size + 1
		self.size = n
		map[key] = ID_SWAPKEY(id, n)
		self.entities[n] = id
	end
end

local function pool_remove_id(self, id)
	local map = self.map
	local entities = self.entities

	local key = ID_KEY(id)
	local idx_ver = map[key]

	if idx_ver then
		local n = self.size
		self.size = n - 1
		local idx = ID_KEY(idx_ver)
		local lastid = entities[n]
		map[ID_KEY(lastid)] = ID_SWAPKEY(lastid, idx)
		map[key] = nil
		entities[idx] = lastid
		entities[n] = nil
	end
end

local function pool_swap(self, idx, key, id, target_idx)
	local map = self.map
	local entities = self.entities
	local values = self.values

	local id_swap = entities[target_idx]

	entities[target_idx], entities[idx] = id, id_swap
	values[target_idx], values[idx] = values[idx], values[target_idx]
	map[key] = ID_SWAPKEY(id, target_idx)
	map[ID_KEY(id_swap)] = ID_SWAPKEY(id_swap, idx)
end

local function pool_clear(self)
	self.size = 0
	self.map = {}
	self.entities = {}
	self.values = {}
end

local function pool_clone(self)
	return {
		size = self.size,
		map = table.clone(self.map),
		entities = table.clone(self.entities),
		values = table.clone(self.values),
	}
end

local ctype_n = 0
local ctype_constructors = {}

local function ctype_create(constructors)
	ctype_n = ctype_n + 1
	ASSERT(constructors == nil or type(constructors) == "function", "constructor must be a function")
	ctype_constructors[ctype_n] = constructors
	return ctype_n
end

local function ctype_valid(v)
	return type(v) == "number" and math.floor(v) == v and v > 0 and v <= ctype_n
end

local View, Observer, Group
do
	local WEAK_VALUES = { __mode = "v" }

	local function has_any(pools, key)
		for _, pool in next, pools do
			if pool.map[key] then
				return true
			end
		end
		return false
	end

	local function smallest(pools)
		local s
		for _, pool in next, pools do
			if s == nil or pool.size < s.size then
				s = pool
			else
				s = s
			end
		end
		return assert(s, "no pools given")
	end

	local function get_pools(registry, ctypes)
		local pools = {}
		for i, ctype in next, ctypes do
			pools[i] = registry:storage(ctype)
		end
		return pools
	end

	local function disconnect_all(connections)
		for _, connection in next, connections do
			connection:disconnect()
		end
	end

	View = {}
	View.__index = View

	function View.new(reg, ...)
		assert(select("#", ...) > 0, "no components given")

		local self = setmetatable({
			registry = reg,
			includes = {},
			excludes = nil,
			lead = nil,
		}, View)

		local includes = self.includes

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			ASSERT(ctype_valid(ctype), "invalid " .. debug_arg(i))
			ASSERT(not table.find(includes, ctype), "duplicate " .. debug_arg(i) .. "included")
			table.insert(includes, ctype)
		end

		return self
	end

	function View.exclude(self, ...)
		local includes = self.includes
		local excludes = self.excludes or (function()
			local t = {}
			self.excludes = t
			return t
		end)()

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			ASSERT(ctype_valid(ctype), "invalid " .. debug_arg(i))
			ASSERT(
				not table.find(includes, ctype),
				"cannot exclude " .. debug_arg(i) .. "component is a part of the view"
			)
			if table.find(excludes, ctype) then
				::continue::
			end
			table.insert(excludes, ctype)
		end

		return self
	end

	function View.use(self, ctype)
		ASSERT(ctype_valid(ctype), "invalid component type")
		ASSERT(table.find(self.includes, ctype), "cannot lead with component; component is not a part of the view")
		self.lead = ctype
		return self
	end

	function View.__call(self)
		local function single(pool)
			local n = pool.size
			local entities = pool.entities
			local values = pool.values

			return function()
				local i = n
				n = i - 1
				return entities[i], values[i]
			end
		end

		local function double(a, b)
			local na, nb = a.size, b.size

			if na <= nb then
				local n = na
				local entities = a.entities
				local values = a.values

				return function()
					for i = n, 1, -1 do
						local entity = entities[i]
						local idx_ver = b.map[ID_KEY(entity)]
						if idx_ver == nil then
							::continue::
						else
							local vb = b.values[ID_KEY(idx_ver)]
							if vb == nil then
								::continue::
							else
								n = i - 1
								return entity, values[i], vb
							end
						end
						
					end
					return nil, nil, nil
				end
			else
				local n = nb
				local entities = b.entities
				local values = b.values

				return function()
					for i = n, 1, -1 do
						local entity = entities[i]
						local idx_ver = a.map[ID_KEY(entity)]
						if idx_ver == nil then
							::continue::
						end
						local va = a.values[ID_KEY(idx_ver)]
						if va == nil then
							::continue::
						end
						n = i - 1
						return entity, va, values[i]
					end
					return nil, nil, nil
				end
			end
		end

		local function multi(includes, excludes, lead)
			local source = lead or smallest(includes)

			local n = source.size
			local entities = source.entities
			local tuple = {}

			return function()
				for i = n, 1, -1 do
					local entity = entities[i]
					local key = ID_KEY(entity)

					if excludes and has_any(excludes, key) then
						::continue::
					end

					local has_all = true
					for ii, pool in next, includes do
						local idx_ver = pool.map[key]
						if idx_ver == nil then
							has_all = false
							break
						end
						tuple[ii] = pool.values[ID_KEY(idx_ver)]
					end
					if has_all == false then
						::continue::
					end

					n = i - 1
					return entity, unpack(tuple)
				end
				return nil
			end
		end

		local includes = get_pools(self.registry, self.includes)
		local excludes = self.excludes and get_pools(self.registry, self.excludes)
		local lead = self.lead and self.registry:storage(self.lead)

		if #includes == 1
				and not excludes
				and not lead
			then return single(includes[1])
			elseif #includes == 2 and not excludes and not lead then return double(includes[1], includes[2])
			else return multi(includes, excludes, lead) end
	end

	function View.__len(self)
		return smallest(get_pools(self.registry, self.includes)).size
	end

	View.each = View.__call
	
	Observer = {}
	Observer.__index = Observer

	function Observer.new(reg, ...)
		local ctype_first = select(1, ...)

		local self = setmetatable({
			registry = reg,
			pool = pool_clone(reg:storage(ctype_first)),
			includes = {},
			excludes = nil,
			connections = nil,
			flags = {},
		}, Observer)

		local includes = self.includes

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			ASSERT(ctype_valid(ctype), "invalid " .. debug_arg(i))
			ASSERT(not table.find(includes, ctype), "duplicate " .. debug_arg(i) .. " included")
			table.insert(includes, ctype)
		end

		local connections = {}
		local pool = self.pool
		local weakref = setmetatable({ self = self }, WEAK_VALUES)
		local function try_remove(id)
			if weakref.self == nil then
				disconnect_all(connections)
			end
			pool_remove_id(pool, id)
		end

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			table.insert(connections, reg:removing(ctype):connect(try_remove))
		end

		return self:reconnect()
	end

	function Observer.disconnect(self)
		if not self.connections then
			return self
		end
		disconnect_all(self.connections)
		self.connections = nil
		return self
	end

	function Observer.reconnect(self)
		if self.connections then
			return self
		end

		local reg = self.registry
		local pool = self.pool
		local includes = self.includes

		local connections = {}

		for i, ctype in next, includes do
			local function listener(id)
				pool_add_id(pool, id)
			end

			table.insert(connections, reg:added(ctype):connect(listener))
			table.insert(connections, reg:changed(ctype):connect(listener))
		end

		self.connections = connections

		return self
	end

	function Observer.clear(self)
		pool_clear(self.pool)
		return self
	end

	function Observer.__call(self)
		local pool = self.pool
		local reg = self.registry
		local includes = get_pools(reg, self.includes)
		local excludes = self.excludes and get_pools(reg, self.excludes)

		local n = pool.size
		local entities = pool.entities

		local reg_pool = includes[1]
		local reg_map = reg_pool.map
		local reg_values = reg_pool.values

		local tuple = {}

		if #includes == 1 and not excludes
			then return function()
				local i = n
				n = i - 1
				local id = entities[i]
				if id == nil then
					return nil
				end
				local key = ID_KEY(id)
				local value = reg_values[ID_KEY(reg_map[key])]
				return id, value
			end
			else return function()
				for i = n, 1, -1 do
					local id = entities[i]
					local key = ID_KEY(id)

					if excludes and has_any(excludes, key) then
						::continue::
					end

					local has_all = true
					for ii, pool in next, includes do
						local idx_ver = pool.map[key]
						if idx_ver == nil then
							has_all = false
							break
						end
						tuple[ii] = pool.values[ID_KEY(idx_ver)]
					end
					if has_all == false then
						::continue::
					end

					n = i - 1
					return id, unpack(tuple)
				end
				return nil, nil
			end
		end
	end

	function Observer.exclude(self, ...)
		local excludes = self.excludes or (function()
			local t = {}
			self.excludes = t
			return t
		end)()

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			ASSERT(ctype_valid(ctype), "invalid" .. debug_arg(i))
			ASSERT(
				not table.find(self.includes, ctype),
				"cannot exclude" .. debug_arg(i) .. "component is being tracked"
			)
			if table.find(excludes, ctype) then
				::continue::
			end
			table.insert(excludes, ctype)
		end

		return self
	end

	function Observer.__len(self)
		return self.pool.size
	end

	Observer.each = Observer.__call
	
	Group = {}
	Group.__index = Group

	function Group.new(reg, data, ...)
		local self = setmetatable({
			data = data,
			pools = {},
		}, Group)

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			local pool = reg:storage(ctype)
			assert(table.find(data, pool), "component type is not in group")
			self.pools[i] = pool
		end

		return self
	end

	function Group.__call(self)
		local pools = self.pools
		local n = self.data.size
		local entities = pools[1].entities

		local values = {}
		for i, pool in next, pools do
			values[i] = pool.values
		end

		if #pools == 1 then
			local a = unpack(values)
			return function()
				local i = n
				n = i - 1
				return entities[i], a[i]
			end
		elseif #pools == 2 then
			local a, b = unpack(values)
			return function()
				local i = n
				n = i - 1
				return entities[i], a[i], b[i]
			end
		elseif #pools == 3 then
			local a, b, c = unpack(values)
			return function()
				local i = n
				n = i - 1
				return entities[i], a[i], b[i], c[i]
			end
		elseif #pools == 4 then
			local a, b, c, d = unpack(values)
			return function()
				local i = n
				n = i - 1
				return entities[i], a[i], b[i], c[i], d[i]
			end
		else
			local tuple = {}
			return function()
				local i = n
				n = i - 1
				for ii, v in next, values do
					tuple[ii] = v[i]
				end
				return entities[i], unpack(tuple)
			end
		end
	end

	Group.each = Group.__call
	
	function Group.__len(self)
		return self.data.size
	end
end

local signal_create
do
	local Connection = {}
	Connection.__index = Connection

	function Connection.disconnect(self)
		local pool = self.signal.pool
		local idx_ver = pool.map[self.id]
		if idx_ver then
			pool_remove(self.signal.pool, ID_KEY(idx_ver), self.id)
		end
	end

	local Signal = {}
	Signal.__index = Signal

	function Signal.connect(self, listener)
		local n = self.count + 1
		self.count = n
		pool_add(self.pool, n, n, listener)
		return setmetatable({ signal = self, id = n }, Connection)
	end

	function signal_create()
		local pool = pool_create(1)
		local signal = setmetatable({ pool = pool, count = 0 }, Signal)
		return signal, pool.values
	end
end

local function registry_create()
	local registry = {}

	local size = 0
	local free = ID_INVALID_KEY
	local ids = {}

	local pools = {}
	local groups = {}

	local signals = {
		added = {},
		changed = {},
		removing = {},
	}

	local added_listeners = {}
	local changed_listeners = {}
	local removing_listeners = {}

	setmetatable(pools, {
		__index = function(self, v)
			ASSERT(ctype_valid(v), "invalid component type")
			local pool = pool_create(1)
			self[v] = pool
			return pool
		end,
	})

	local function group_try_add(group, key, id)
		for _, pool in ipairs(group) do
			if pool.map[key] == nil then
				return
			end
		end

		local n = group.size + 1
		group.size = n

		for _, pool in ipairs(group) do
			pool_swap(pool, ID_KEY(pool.map[key]), key, id, n)
		end
	end

	local function group_try_remove(group, index, key, id)
		local n = group.size
		if index <= n then
			group.size = n - 1
			for _, pool in ipairs(group) do
				pool_swap(pool, index, key, id, n)
			end
			return n
		else
			return index
		end
	end

	local function group_init(...)
		local group = { size = 0 }

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			group[i] = pools[ctype]
			groups[ctype] = group
		end

		local entities = pools[...].entities

		for _, id in next, entities do
			group_try_add(group, ID_KEY(id), id)
		end

		return group
	end

	local function add(ctype, pool, key, id, value)
		pool_add(pool, key, id, value)
		local group = groups[ctype]
		if group then
			group_try_add(group, key, id)
		end
	end

	local function remove(ctype, pool, index, key, id)
		local group = groups[ctype]
		if group then
			index = group_try_remove(group, index, key, id)
		end
		pool_remove(pool, index, key)
	end

	local function fire(listeners, id, value)
		for i = #listeners, 1, -1 do
			listeners[i](id, value)
		end
	end

	local function fire_added(ctype, id, value)
		local listeners = added_listeners[ctype]
		if listeners then
			fire(listeners, id, value)
		end
	end

	local function fire_changed(ctype, id, value)
		local listeners = changed_listeners[ctype]
		if listeners then
			fire(listeners, id, value)
		end
	end

	local function fire_removing(ctype, id)
		local listeners = removing_listeners[ctype]
		if listeners then
			fire(listeners, id)
		end
	end

	local function release(id)
		local key, ver = ID_KEY_VER(id)
		size = size - 1

		if ver < ID_MAX_VERSION then
			ids[key] = ID_CREATE(free, ver + 1)
			free = key
		else
			ids[key] = ID_NULL
		end
	end

	local function release_all()
		for i = #ids, 1, -1 do
			local id = ids[i]
			if ID_KEY(id) == i then
				release(id)
			end
		end
	end

	local function clear(ctype)
		local pool = pools[ctype]

		local listeners = removing_listeners[ctype]
		if listeners then
			for _, id in next, pool.entities do
				fire(listeners, id)
			end
		end

		local group = groups[ctype]
		if group then
			group.size = 0
		end

		pool_clear(pool)
	end

	local function create()
		size = size + 1
		if free ~= ID_INVALID_KEY then
			local next = ID_KEY(ids[free])
			local newid = ID_SWAPKEY(ids[free], free)
			ids[free] = newid
			free = next
			return newid
		else
			local key = #ids + 1
			local newid = ID_CREATE(key, INITIAL_ENTITY_VERSION)
			ids[key] = newid
			return newid
		end
	end

	local function create_using(id)
		local key, ver = ID_KEY_VER(id)
		ASSERT(key >= 1 and ver >= 1 and key <= ID_MAX_KEY and ver <= ID_MAX_VERSION, "malformed id")

		local n = #ids
		if key > n + 1 then
			for i = n + 1, key - 2 do
				ids[i] = ID_CREATE(i + 1, INITIAL_ENTITY_VERSION)
			end
			ids[key - 1] = ID_CREATE(free, INITIAL_ENTITY_VERSION)
			free = n + 1
		elseif key <= n then
			if ids[key] == ID_NULL then
				ids[key] = id
			else
				ASSERT(free ~= ID_INVALID_KEY and ID_KEY(ids[key]) ~= key, "key is already in use")
				if free == key then
					local next = ID_KEY(ids[free])
					free = next
				else
					local previous = free
					while true do
						local next = ID_KEY(ids[previous])
						if next == key then
							break
						end
						previous = next
					end
					ids[previous] = ID_SWAPKEY(ids[previous], ID_KEY(ids[key]))
				end
			end
		end
		size = size + 1
		ids[key] = id
		return id
	end

	local function check_versions_equal(idx, idx_ver, key, id)
		return idx_ver - idx + key == id
	end

	local function ASSERT_VERSIONS_EQUAL(idx, idx_ver, key, id)
		if idx_ver - idx + key ~= id then
			ASSERT(false, "invalid entity")
		end
	end

	local function ASSERT_VALID_ENTITY(key, id)
		if ids[key] ~= id then
			ASSERT(false, "invalid entity")
		end
	end

	function registry.create(self, id)
		if size >= ID_MAX_KEY then
			error("cannot create entity; registry is at max entities", 2)
		end
		return id and create_using(id) or create()
	end

	function registry.release(self, id)
		ASSERT_VALID_ENTITY(ID_KEY(id), id)
		release(id)
	end

	function registry.destroy(self, id)
		local key = ID_KEY(id)
		ASSERT_VALID_ENTITY(key, id)

		for ctype, pool in next, pools do
			local idx_ver = pool.map[key]
			if idx_ver then
				fire_removing(ctype, id)
				remove(ctype, pool, ID_KEY(idx_ver), key, id)
			end
		end

		release(id)
	end

	function registry.contains(self, id)
		return ids[ID_KEY(id)] == id
	end

	function registry.version(self, id)
		return ID_VER(id)
	end

	function registry.current(self, id)
		return ID_VER(ids[ID_KEY(id)])
	end

	function registry.orphaned(self, id)
		local key = ID_KEY(id)
		for _, pool in next, pools do
			if pool.map[key] then
				return false
			end
		end
		return true
	end

	function registry.add(self, id, ...)
		local key = ID_KEY(id)
		ASSERT_VALID_ENTITY(key, id)

		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			local pool = pools[ctype]
			if pool.map[key] then
				::continue::
			end

			local constructor = ctype_constructors[ctype] or ERROR("no constructor defined for" .. debug_arg(i))
			local value = constructor()
			if value == nil then
				ERROR(debug_arg(i) .. "constructor did not return a value")
			end

			add(ctype, pool, key, id, value)
			fire_added(ctype, id, value)
		end
	end

	function registry.set(self, id, ctype, value)
		local pool = pools[ctype]
		local key = ID_KEY(id)
		local idx_ver = pool.map[key]

		if value ~= nil then
			if idx_ver then
				local idx = ID_KEY(idx_ver)
				ASSERT_VERSIONS_EQUAL(idx, idx_ver, key, id)
				pool.values[idx] = value
				fire_changed(ctype, id, value)
			else
				ASSERT_VALID_ENTITY(key, id)
				add(ctype, pool, key, id, value)
				fire_added(ctype, id, value)
			end
		elseif idx_ver then
			local idx = ID_KEY(idx_ver)
			ASSERT_VERSIONS_EQUAL(idx, idx_ver, key, id)
			fire_removing(ctype, id)
			remove(ctype, pool, idx, key, id)
		end
	end

	function registry.patch(self, id, ctype, patcher)
		local pool = pools[ctype]
		local key = ID_KEY(id)
		local idx_ver = pool.map[key]
		if idx_ver == nil then
			error("entity does not have component", 2)
		end
		local idx = ID_KEY(idx_ver)

		ASSERT_VERSIONS_EQUAL(idx, idx_ver, key, id)

		local values = pool.values
		local value = patcher(values[idx])
		if value == nil then
			error("patcher cannot return nil", 2)
		end

		values[idx] = value
		fire_changed(ctype, id, value)
	end

	registry.has = function(self, id, ...)
		local a, b = ...
		local key = ID_KEY(id)
		if b == nil then
			local idx_ver = pools[a].map[key]
			return idx_ver ~= nil and check_versions_equal(ID_KEY(idx_ver), idx_ver, key, id)
		else
			for i = 1, select("#", ...) do
				local idx_ver = pools[select(i, ...)].map[key]
				if idx_ver == nil or not check_versions_equal(ID_KEY(idx_ver), idx_ver, key, id) then
					return false
				end
			end
			return true
		end
	end

	local function pool_get(self, key, id)
		local idx_ver = self.map[key]
		if idx_ver == nil or not check_versions_equal(ID_KEY(idx_ver), idx_ver, key, id) then
			return nil
		end
		return self.values[ID_KEY(idx_ver)]
	end

	registry.get = function(self, id, ...)
		local a, b, c, d, e = ...
		local key = ID_KEY(id)
		if b == nil then
			return pool_get(pools[a], key, id)
		elseif c == nil then
			return pool_get(pools[a], key, id), pool_get(pools[b], key, id)
		elseif d == nil then
			return pool_get(pools[a], key, id), pool_get(pools[b], key, id), pool_get(pools[c], key, id)
		elseif e == nil then
			return pool_get(pools[a], key, id),
				pool_get(pools[b], key, id),
				pool_get(pools[c], key, id),
				pool_get(pools[d], key, id)
		else
			local tuple = { ... }
			for i, v in next, tuple do
				tuple[i] = pool_get(pools[v], key, id)
			end
			return unpack(tuple)
		end
	end

	function registry.remove(self, id, ...)
		local key = ID_KEY(id)
		for i = 1, select("#", ...) do
			local ctype = select(i, ...)
			local pool = pools[ctype]
			local idx_ver = pool.map[key]
			if idx_ver == nil then
				::continue::
			else
				local idx = ID_KEY(idx_ver)
			ASSERT_VERSIONS_EQUAL(idx, idx_ver, key, id)

			fire_removing(ctype, id)
			remove(ctype, pool, idx, key, id)
			end
		end
	end

	function registry.size(self)
		return size
	end

	function registry.clear(self, ...)
		local argn = select("#", ...)
		if argn > 0 then
			for i = 1, argn do
				clear(select(i, ...))
			end
		else
			for ctype in next, pools do
				clear(ctype)
			end
			release_all()
		end
	end

	function registry.view(self, ...)
		return View.new(registry, ...)
	end

	function registry.track(self, ...)
		return Observer.new(registry, ...)
	end

	function registry.group(self, ...)
		local argn = select("#", ...)
		ASSERT(argn > 1, "groups must contain at least 2 components")
		local group = groups[select(1, ...)]

		for i = 1, argn do
			local ctype = select(i, ...)
			ASSERT(ctype_valid(ctype), "invalid" .. debug_arg(i))
			ASSERT(
				groups[ctype] == group,
				"cannot create group;" .. debug_arg(i) .. "is not owned by the same group as previous args"
			)
		end

		return Group.new(registry, group or group_init(...), ...)
	end

	function registry.entities(self)
		local entities = {}

		for i, id in next, ids do
			if ID_KEY(id) == i then
				table.insert(entities, id)
			end
		end

		return entities
	end

	function registry.storage(self, ctype)
		return pools[ctype]
	end

	function registry.added(self, ctype)
		return (
			signals.added[ctype]
			or (function()
				local signal, listeners = signal_create()
				signals.added[ctype] = signal
				added_listeners[ctype] = listeners
				return signal
			end)()
		)
	end

	function registry.changed(self, ctype)
		return (
			signals.changed[ctype]
			or (function()
				local signal, listeners = signal_create()
				signals.changed[ctype] = signal
				changed_listeners[ctype] = listeners
				return signal
			end)()
		)
	end

	function registry.removing(self, ctype)
		return signals.removing[ctype]
			or (function()
				local signal, listeners = signal_create()
				signals.removing[ctype] = signal
				removing_listeners[ctype] = listeners
				return signal
			end)()
	end

	(registry).set_entity_version = function(_, key, ver)
		ids[key] = ID_CREATE(ID_KEY(ids[key]), ver)
	end

	setmetatable(registry, {
		__index = function(_, index)
			error(tostring(index) .. " is not a valid member of Registry", 2)
		end,
	})

	return registry
end

local ecr = {
	component = ctype_create,
	registry = registry_create,
	null = ID_NULL,
};

(ecr).id = ID_CREATE

return ecr
