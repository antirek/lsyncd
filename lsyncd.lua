--============================================================================
-- lsyncd.lua   Live (Mirror) Syncing Demon
--
-- License: GPLv2 (see COPYING) or any later version
--
-- Authors: Axel Kittenberger <axkibe@gmail.com>
--
-- This is the "runner" part of Lsyncd. It containts all its high-level logic.
-- It works closely together with the Lsyncd core in lsyncd.c. This means it
-- cannot be runned directly from the standard lua interpreter.
--============================================================================

-----
-- A security measurement.
-- Core will exit if version ids mismatch.
--
if lsyncd_version then
	-- checks if the runner is being loaded twice 
	lsyncd.log("Error",
		"You cannot use the lsyncd runner as configuration file!")
	lsyncd.terminate(-1) -- ERRNO
end
lsyncd_version = "2.0beta3"

-----
-- Hides the core interface from user scripts
--
local _l = lsyncd
lsyncd = nil
local lsyncd = _l
_l = nil

-----
-- Shortcuts (which user is supposed to be able to use them as well)
--
log  = lsyncd.log
terminate = lsyncd.terminate

--============================================================================
-- Lsyncd Prototypes 
--============================================================================

-----
-- The array objects are tables that error if accessed with a non-number.
--
local Array = (function()
	-- Metatable
	local mt = {}

	-- on accessing a nil index.
	mt.__index = function(t, k) 
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for Array", 2)
		end
		return rawget(t, k)
	end

	-- on assigning a new index.
	mt.__newindex = function(t, k, v)
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for Array", 2)
		end
		rawset(t, k, v)
	end

	-- creates a new object
	local function new()
		local o = {}
		setmetatable(o, mt)
		return o
	end

	-- objects public interface
	return {new = new}
end)()


-----
-- The count array objects are tables that error if accessed with a non-number.
-- Additionally they maintain their length as "size" attribute.
-- Lua's # operator does not work on tables which key values are not 
-- strictly linear.
--
local CountArray = (function()
	-- Metatable
	local mt = {}

	-----
	-- key to native table
	local k_nt = {}
	
	-----
	-- on accessing a nil index.
	mt.__index = function(t, k) 
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for CountArray", 2)
		end
		return t[k_nt][k]
	end

	-----
	-- on assigning a new index.
	mt.__newindex = function(t, k, v)
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for CountArray", 2)
		end
		-- value before
		local vb = t[k_nt][k]
		if v and not vb then
			t._size = t._size + 1
		elseif not v and vb then
			t._size = t._size - 1
		end
		t[k_nt][k] = v
	end

	-----
	-- Walks through all entries in any order.
	--
	local function walk(self)
		return pairs(self[k_nt])
	end

	-----
	-- returns the count
	--
	local function size(self)
		return self._size
	end

	-----
	-- creates a new count array
	--
	local function new()
		-- k_nt is native table, private for this object.
		local o = {_size = 0, walk = walk, size = size, [k_nt] = {} }
		setmetatable(o, mt)
		return o
	end

	-----
	-- public interface
	--
	return {new = new}
end)()

----
-- Locks globals,
-- no more globals can be created
--
local function lockGlobals()
	local t = _G
	local mt = getmetatable(t) or {}
	mt.__index = function(t, k) 
		if (k~="_" and string.sub(k, 1, 2) ~= "__") then
			error("Access of non-existing global '"..k.."'", 2)
		else
			rawget(t, k)
		end
	end
	mt.__newindex = function(t, k, v) 
		if (k~="_" and string.sub(k, 1, 2) ~= "__") then
			error("Lsyncd does not allow GLOBALS to be created on the fly. " ..
			      "Declare '" ..k.."' local or declare global on load.", 2)
		else
			rawset(t, k, v)
		end
	end
	setmetatable(t, mt)
end

-----
-- Holds information about a delayed event of one Sync.
--
local Delay = (function()
	-----
	-- Creates a new delay.
	-- 
	-- @params see below
	--
	local function new(etype, alarm, path, path2)
		local o = {
			-----
			-- Type of event.
			-- Can be 'Create', 'Modify', 'Attrib', 'Delete' and 'Move'
			etype = etype,

			-----
			-- Latest point in time this should be catered for.
			-- This value is in kernel ticks, return of the C's 
			-- times(NULL) call.
			alarm = alarm,

			-----
			-- path and filename or dirname of the delay relative 
			-- to the syncs root.
			-- for the directories it contains a trailing slash
			--
			path  = path,

			------
			-- only not nil for 'Move's.
			-- path and file/dirname of a move destination.
			--
			path2  = path2,
		
			------
			-- Status of the event. Valid stati are: 
			-- 'wait'    ... the event is ready to be handled.
			-- 'active'  ... there is process running catering for this event.
			-- 'blocked' ... this event waits for another to be handled first.
			-- 'done'    ... event has been collected. This should never be 
			--               visible as all references should be droped on
			--               collection, nevertheless seperat status for 
			--               insurrance.
			--
			status = "wait",
		}
		return o
	end

	return {new = new}
end)()

-----
-- User interface to grap events
--
-- InletControl is the runners part to control the interface
-- hidden from the user.
--
local getInlet
local Inlet, InletControl = (function()
	-- lua runner controlled variables
	local sync 

	-----
	-- table to receive the delay of an event.
	local e2d = {}
	-- doesnt stop the garbage collect to remove entries.
	setmetatable(e2d, { __mode = 'kv' })
	
	-- table to receive the delay list of an event list.
	local el2dl = {}
	-- doesnt stop the garbage collect to remove entries.
	setmetatable(el2dl, { __mode = 'kv' })

	-----
	-- removes the trailing slash from a path
	local function cutSlash(path) 
		if string.byte(path, -1) == 47 then
			return string.sub(path, 1, -2)
		else
			return path
		end
	end

	local function getPath(event)
		if event.move ~= "To" then
			return e2d[event].path
		else
			return e2d[event].path2
		end
	end

	-----
	-- Interface for user scripts to get event fields.
	--
	local eventFields = {
		-----
		-- Returns a copy of the configuration as called by sync.
		-- But including all inherited data and default values.
		--
		-- TODO give user a readonly version.
		--
		config = function(event)
			return sync.config
		end,

		inlet = function(event)
			return getInlet()
		end,

		-----
		-- Returns the type of the event.
		-- Can be:
		--    "Attrib",
		--    "Create",
		--    "Delete",
		--    "Modify",
		--    "Move",
		--
		etype = function(event)
			return e2d[event].etype
		end,

		-----
		-- Tells script this isnt a list.
		--
		isList = function()
			return false
		end,

		-----
		-- Returns 'Fr'/'To' for events of moves.
		move = function(event)
			local d = e2d[event]
			if d.move then
				return d.move
			else 
				return ""
			end
		end,
	
		-----
		-- Status
		status = function(event)
			return e2d[event].status
		end,

		-----
		-- Returns true if event relates to a directory.
		--
		isdir = function(event) 
			return string.byte(getPath(event), -1) == 47
		end,

		-----
		-- Returns the name of the file/dir.
		-- Includes a trailing slash for dirs.
		--
		name = function(event)
			return string.match(getPath(event), "[^/]+/?$")
		end,
		
		-----
		-- Returns the name of the file/dir.
		-- Excludes a trailing slash for dirs.
		--
		basename = function(event)
			return string.match(getPath(event), "([^/]+)/?$")
		end,

		-----
		-- Returns the file/dir relative to watch root
		-- Includes a trailing slash for dirs.
		--
		path = function(event)
			return getPath(event)
		end,
		
		-----
		-- Returns the directory of the file/dir relative to watch root
		-- Always includes a trailing slash.
		--
		pathdir = function(event)
			return string.match(getPath(event), "^(.*/)[^/]+/?") or ""
		end,

		-----
		-- Returns the file/dir relativ to watch root
		-- Excludes a trailing slash for dirs.
		--
		pathname = function(event)
			return cutSlash(getPath(event))
		end,
		
		------
		-- Returns the absolute path of the watch root.
		-- All symlinks will have been resolved.
		--
		source = function(event)
			return sync.source
		end,

		------
		-- Returns the absolute path of the file/dir.
		-- Includes a trailing slash for dirs.
		--
		sourcePath = function(event)
			return sync.source .. getPath(event)
		end,
		
		------
		-- Returns the absolute path of the file/dir.
		-- Excludes a trailing slash for dirs.
		--
		sourcePathname = function(event)
			return sync.source .. cutSlash(getPath(event))
		end,
		
		------
		-- Returns the target. 
		-- Just for user comfort, for most case
		-- (Actually except of here, the lsyncd.runner itself 
		--  does not care event about the existance of "target",
		--  this is completly up to the action scripts.)
		--
		target = function(event)
			return sync.config.target
		end,

		------
		-- Returns the relative dir/file appended to the target.
		-- Includes a trailing slash for dirs.
		--
		targetPath = function(event)
			return sync.config.target .. getPath(event)
		end,
		
		------
		-- Returns the relative dir/file appended to the target.
		-- Excludes a trailing slash for dirs.
		--
		targetPathname = function(event)
			return sync.config.target .. cutSlash(getPath(event))
		end,
	}
	
	-----
	-- Retrievs event fields for the user script.
	--
	local eventMeta = {
		__index = function(t, k)
			local f = eventFields[k]
			if not f then
				if k == 'move' then
					-- possibly undefined
					return nil
				end
				error("event does not have field '"..k.."'", 2)
			end
			return f(t)
		end
	}

	-----
	-- adds an exclude.
	--
	local function addExclude(pattern)
		sync:addExclude(pattern)
	end
	
	-----
	-- removes an exclude.
	--
	local function rmExclude(pattern)
		sync:rmExclude(pattern)
	end

	-----
	-- Interface for user scripts to get event fields.
	--
	local eventListFuncs = {
		-----
		-- Returns a list of file/dirnames of all events in list.
		--
		--getNames = function(elist)
		--	local dlist = el2dl[elist]
		--	if not dlist then
		--		error("cannot find delay list from event list.")
		--	end
		--	local pl = {}
		--	local i = 1
		--	for k, d in pairs(dlist) do
		--		if type(k) == "number" then
		--			pl[i] = string.match(d.path, "[^/]+/?$") 
		--			i = i + 1
		--			if d.path2 then
		--				pl[i] = string.match(d.path2, "[^/]+/?$") 
		--				i = i + 1
		--			end
		--		end
		--	end
		--	return pl
		--end,

		-----
		-- Returns a list of paths of all events in list.
		-- 
		-- @param elist -- handle returned by getevents()
		-- @param mutator -- if not nil called with (etype, path, path2)
		--                   returns one or two strings to add.
		--
		getPaths = function(elist, mutator)
			local dlist = el2dl[elist]
			if not dlist then
				error("cannot find delay list from event list.")
			end
			local result = {}
			for k, d in pairs(dlist) do
				if type(k) == "number" then
					local s1, s2
					if mutator then
						s1, s2 = mutator(d.etype, d.path, d.path2)
					else
						s1, s2 = d.path, d.path2
					end
					table.insert(result, s1)
					if s2 then
						table.insert(result, s2)
					end
				end
			end
			return result
		end,
		
		-----
		-- Returns a list of absolutes local paths in list.
		--
		--getSourcePaths = function(elist)
		--	local dlist = el2dl[elist]
		--	if not dlist then
		--		error("cannot find delay list from event list.")
		--	end
		--	local pl = {}
		--	local i = 1
		--	for k, d in pairs(dlist) do
		--		if type(k) == "number" then
		--			pl[i] = sync.source .. d.path
		--			i = i + 1
		--			if d.path2 then
		--				pl[i] = sync.source .. d.path2
		--				i = i + 1
		--			end
		--		end
		--	end
		--	return pl
		--end,
	}


	-----
	-- Retrievs event list fields for the user script.
	--
	local eventListMeta = {
		__index = function(t, k)
			if k == "isList" then
				return true
			end
			
			if k == "config" then
				return sync.config
			end

			local f = eventListFuncs[k]
			if not f then
				error("event list does not have function '"..k.."'", 2)
			end
			
			return function(...)
				return f(t, ...)
			end
		end
	}
	
	-----
	-- Encapsulates a delay into an event for the user script.
	--
	local function d2e(delay)
		if delay.etype ~= "Move" then
			if not delay.event then
				local event = {}
				delay.event = event
				setmetatable(event, eventMeta)
				e2d[event] = delay
			end
			return delay.event
		else
			-- moves have 2 events - origin and destination
			if not delay.event then
				local event  = {}
				local event2 = {}
				delay.event  = event
				delay.event2 = event2

				setmetatable(event, eventMeta)
				setmetatable(event2, eventMeta)
				e2d[delay.event] = delay
				e2d[delay.event2] = delay
				
				-- move events have a field 'event'
				event.move  = "Fr"
				event2.move = "To"
			end
			return delay.event, delay.event2
		end
	end
	
	-----
	-- Encapsulates a delay list into an event list for the user script.
	--
	local function dl2el(dlist)
		if not dlist.elist then
			local elist = {}
			dlist.elist = elist
			setmetatable(elist, eventListMeta)
			el2dl[elist] = dlist
		end
		return dlist.elist
	end

	
	-----
	-- Creates a blanketEvent that blocks everything
	-- and is blocked by everything.
	--
	local function createBlanketEvent()
		return d2e(sync:addBlanketDelay())
	end

	-----
	-- Discards a waiting event.
	--
	local function discardEvent(event)
		local delay = e2d[event]
		if delay.status ~= "wait" then
			log("Error", "Ignored try to cancel a non-waiting event of type ",
				event.etype)
			return
		end
		sync:removeDelay(delay)
	end

	-----
	-- Gets the next not blocked event from queue.
	--
	local function getEvent()
		return d2e(sync:getNextDelay(lysncd.now()))
	end
	
	-----
	-- Gets all events that are not blocked by active events.
	--
	-- @param if not nil a function to test each delay
	--
	local function getEvents(test)
		local dlist = sync:getDelays(test)
		return dl2el(dlist)
	end

	-----
	-- Returns the configuration table specified by sync{}
	--
	local function getConfig()
		-- TODO give a readonly handler only.
		return sync.config
	end

	-----
	-- Interface for lsyncd runner to control what
	-- the inlet will present the user.
	--
	local function setSync(setSync)
		sync = setSync
	end

	-----
	-- Returns the delay from a event.
	--    not to be called from user script.
	local function getDelay(event)
		return e2d[event]
	end
	
	-----
	-- Returns the delay list from a event list.
	--    not to be called from user script.
	local function getDelayList(elist)
		return el2dl[elist]
	end
	
	-----
	-- Return the currentsync 
	--    not to be called from user script.
	local function getSync()
		return sync
	end

	-----
	-- public interface.
	-- this one is split, one for user one for runner.
	return {
			addExclude         = addExclude,
			createBlanketEvent = createBlanketEvent,
			discardEvent       = discardEvent,
			getEvent           = getEvent, 
			getEvents          = getEvents, 
			getConfig          = getConfig, 
			rmExclude          = rmExclude,
		}, {
			d2e = d2e,
			dl2el = dl2el,
			getDelay = getDelay,
			getDelayList = getDelayList, 
			getSync = getSync,
			setSync = setSync, 
		}
end)()

-----
-- Little dirty workaround to retrieve the Inlet from events in Inlet
getInlet = function()
	return Inlet
end


-----
-- A set of exclude patterns
--
local Excludes = (function()
	
	-----
	-- Turns a rsync like file pattern to a lua pattern.
	-- 
	-- 
	local function toLuaPattern(p)
		local o = p
		p = string.gsub(p, "%%", "%%")
		p = string.gsub(p, "%^", "%^")
		p = string.gsub(p, "%$", "%$")
		p = string.gsub(p, "%(", "%(")
		p = string.gsub(p, "%)", "%)")
		p = string.gsub(p, "%.", "%.")
		p = string.gsub(p, "%[", "%[")
		p = string.gsub(p, "%]", "%]")
		p = string.gsub(p, "%+", "%+")
		p = string.gsub(p, "%-", "%-")
		p = string.gsub(p, "%?", "[^/]")
		p = string.gsub(p, "%*", "[^/]*")
		-- this was a ** before v
		p = string.gsub(p, "%[%^/%]%*%[%^/%]%*", ".*") 
		p = string.gsub(p, "^/", "^") 
		p = string.gsub(p, "/$", ".*/$") 
		log("Exclude", "toLuaPattern '",o,"' = '",p,'"')
		return p
	end

	-----
	-- Adds a pattern to exclude.
	--
	local function add(self, pattern)
		if self.list[pattern] then
			-- already in the list
			return
		end
		local lp = toLuaPattern(pattern)
		self.list[pattern] = lp
	end
	
	-----
	-- Removes a pattern to exclude.
	--
	local function remove(self, pattern)
		if not self.list[pattern] then
			-- already in the list
			log("Normal", "Removing not excluded exclude '"..pattern.."'")
			return
		end
		self.list[pattern] = nil
	end


	-----
	-- Adds a list of patterns to exclude.
	--
	local function addList(self, plist)
		for _, v in plist do
			add(self, v)
		end
	end

	-----
	-- loads excludes from a file
	--
	local function loadFile(self, file)
		f, err = io.open(file)
		if not f then
			log("Error", "Cannot open exclude file '",file,"': ", err)
			terminate(-1) -- ERRNO
		end
	    for line in f:lines() do 
			-- lsyncd 2.0 does not support includes
			if not string.match(line, "%s*+") then
				local p = string.match(line, "%s*-?%s*(.*)")
				if p then
					add(self, p)
				end
			end
		end
		f:close()
	end

	-----
	-- Tests if 'file' is excluded.
	--
	local function test(self, file)
		for _, p in pairs(self.list) do
			if (string.match(file, p)) then
				return true
			end
		end
		return false
	end

	-----
	-- Cretes a new exclude set
	--
	local function new() 
		return { 
			list = {},

			-- functions
			add      = add,
			adList   = addList,
			loadFile = loadFile,
			remove   = remove,
			test     = test,
		}
	end

	-----
	-- Public interface
	return { new = new }
end)()

-----
-- Holds information about one observed directory inclusively subdirs.
--
local Sync = (function()

	-----
	-- Syncs that have no name specified by the user script 
	-- get an incremental default name 'Sync[X]'
	--
	local nextDefaultName = 1

	-----
	-- Adds an exclude.
	--
	local function addExclude(self, pattern)
		return self.excludes:add(pattern)
	end

	-----
	-- Removes an exclude.
	--
	local function rmExclude(self, pattern)
		return self.excludes:remove(pattern)
	end

	-----
	-- Removes a delay.
	--
	local function removeDelay(self, delay) 
		local found
		for i, d in ipairs(self.delays) do
			if d == delay then
				found = true
				table.remove(self.delays, i)
				break
			end
		end
		
		if not found then
			error("Did not find a delay to be removed!")
		end

		-- free all delays blocked by this one. 
		if delay.blocks then
			for i, vd in pairs(delay.blocks) do
				vd.status = "wait"
			end
		end
	end

	-----
	-- Collects a child process 
	--
	local function collect(self, pid, exitcode)
		local delay = self.processes[pid]
		if not delay then
			-- not a child of this sync.
			return
		end

		if delay.status then
			-- collected an event
			if delay.status ~= "active" then
				error("internal fail, collecting a non-active process")
			end
			InletControl.setSync(self)
			local rc = self.config.collect(InletControl.d2e(delay), exitcode)
			if rc == "die" then
				log("Error", "Critical exitcode.");
				terminate(-1) --ERRNO
			end
			if rc ~= "again" then
				-- if its active again the collecter restarted the event
				removeDelay(self, delay)
				log("Delay", "Finish of ",delay.etype," on ",
					self.source,delay.path," = ",exitcode)
			else 
				-- sets the delay on wait again
				delay.status = "wait"
				local alarm = self.config.delay 
				-- delays at least 1 second
				if alarm < 1 then
					alarm = 1 
				end
				delay.alarm = lsyncd.addtoclock(lsyncd.now(), alarm)
			end
		else
			log("Delay", "collected a list")
			InletControl.setSync(self)
			local rc = self.config.collect(InletControl.dl2el(delay), exitcode)
			if rc == "die" then
				log("Error", "Critical exitcode.");
				terminate(-1) --ERRNO
			end
			if rc == "again" then
				-- sets the delay on wait again
				delay.status = "wait"
				local alarm = self.config.delay 
				-- delays at least 1 second
				if alarm < 1 then
					alarm = 1 
				end
				alarm = lsyncd.addtoclock(lsyncd.now(), alarm)
				for k, d in pairs(delay) do
					if type(k) == "number" then
						d.alarm = alarm
						d.status = "wait"
					end
				end

			end
			for k, d in pairs(delay) do
				if type(k) == "number" then
					if rc ~= "again" then
						removeDelay(self, d)
					else
						d.status = "wait"
					end
				end
			end
			log("Delay","Finished list = ",exitcode)
		end
		self.processes[pid] = nil
	end

	-----
	-- Stacks a newDelay on the oldDelay, 
	-- the oldDelay blocks the new Delay.
	--
	-- A delay can block 'n' other delays, 
	-- but is blocked at most by one, the latest delay.
	-- 
	local function stack(oldDelay, newDelay)
		newDelay.status = "block"
		if not oldDelay.blocks then
			oldDelay.blocks = {}
		end
		table.insert(oldDelay.blocks, newDelay)
	end

	-----
	-- Puts an action on the delay stack.
	--
	local function delay(self, etype, time, path, path2)
		log("Function", "delay(",self.config.name,", ",
			etype,", ",path,", ",path2,")")

		-- exclusion tests
		if not path2 then
			-- simple test for 1 path events
			if self.excludes:test(path) then
				log("Exclude", "excluded ",etype," on '",path,"'")
				return
			end
		else
			-- for 2 paths (move) it might result into a split
			local ex1 = self.excludes:test(path)
			local ex2 = self.excludes:test(path2)
			if ex1 and ex2 then
				log("Exclude", "excluded '",etype," on '",path,
					"' -> '",path2,"'")
				return
			elseif not ex1 and ex2 then
				-- splits the move if only partly excluded
				log("Exclude", "excluded destination transformed ",etype,
					" to Delete ",path)
				delay(self, "Delete", time, path, nil)
				return
			elseif ex1 and not ex2 then
				-- splits the move if only partly excluded
				log("Exclude", "excluded origin transformed ",etype,
					" to Create.",path2)
				delay(self, "Create", time, path2, nil)
				return
			end
		end

		if etype == "Move" and not self.config.onMove then
			-- if there is no move action defined, 
			-- split a move as delete/create
			-- layer 1 scripts which want moves events have to
			-- set onMove simply to "true"
			log("Delay", "splitting Move into Delete & Create")
			delay(self, "Delete", time, path,  nil)
			delay(self, "Create", time, path2, nil)
			return
		end

		-- creates the new action
		local alarm 
		if time and self.config.delay then
			alarm = lsyncd.addtoclock(time, self.config.delay)
		else
			alarm = lsyncd.now()
		end
		-- new delay
		local nd = Delay.new(etype, alarm, path, path2)
		if nd.etype == "Blanket" then
			-- always stack blanket events on the last event
			log("Delay", "Stacking blanket event.")
			if #self.delays > 0 then
				stack(self.delays[#self.delays], nd)
			end
			addDelayPath("", nd)
			table.insert(self.delays, nd)
			return
		end

		-- detects blocks and collapses by working from back until 
		-- front through the fifo

		InletControl.setSync(self)
		local ne, ne2 = InletControl.d2e(nd)
		local il = #self.delays -- last delay
		while il > 0 do
			-- get 'old' delay
			local od = self.delays[il]
			local oe, oe2 = InletControl.d2e(od)

			if oe.etype == "Blanket" then
				-- everything is blocked by a blanket event.
				log("Delay", "Stacking ",nd.etype," upon blanket event.")
				stack(od, nd)
				table.insert(self.delays, nd)
				return
			end

			-- this mini loop repeats the collapse a second 
			-- time for move events
			local oel = oe
			local nel = ne

			while oel and nel do
				local c = self.config.collapse(oel, nel, self.config)
				if c == 0 then
					-- events nullificate each ether
					log("Delay",nd.etype," and ",od.etype," on ",path,
						" nullified each other.")
					od.etype = "None"
					table.remove(self.delays, il)
					return
				elseif c == 1 then
					log("Delay",nd.etype," is absored by event ",
						od.etype," on ",path)
					return
				elseif c == 2 then
					if od.etype ~= "Move" then
						log("Delay",nd.etype," replaces event ",
							od.etype," on ",path)
						od.etype = nd.etype
						if od.path ~= nd.path then
							error("Cannot replace events with different paths")
						end
					else
						log("Delay",nd.etype," turns a Move into delete of ",
							od.path)
						od.etype = "Delete"
						od.path2 = nil
						table.insert(self.delays, nd)
					end
					return
				elseif c == 3 then
					log("Delay", "Stacking ",nd.etype," upon ",
						od.etype," on ",path)
					stack(od, nd)
					table.insert(self.delays, nd)
					return
				end
				
				-- loops over all oe, oe2, ne, ne2 combos.
				if oel == oe and oe2 then
					-- do another time for oe2 if present
					oel = oe2
				elseif nel == ne then
					-- do another time for ne2 if present
					-- start with first oe
					nel = ne2
					oel = oe
				else 
					oel = false
				end
			end
			il = il - 1
		end
		log("Delay", "Registering ",nd.etype," on ",path)
		-- there was no hit on collapse or it decided to stack.
		table.insert(self.delays, nd)
	end
	

	-----
	-- Returns the nearest alarm for this Sync.
	--
	local function getAlarm(self)
		-- first checks if more processses could be spawned 
		if self.processes:size() >= self.config.maxProcesses then
			return nil
		end

		-- finds the nearest delay waiting to be spawned
		for _, d in ipairs(self.delays) do
			if d.status == "wait" then
				return d.alarm
			end
		end

		-- nothing to spawn.
		return nil
	end
		
	
	-----
	-- Gets all delays that are not blocked by active delays.
	--
	-- @param test   function to test each delay
	--
	local function getDelays(self, test)
		local dlist = {}
		local blocks = {}

		----
		-- inheritly transfers all blocks from delay
		--
		local function getBlocks(delay) 
			blocks[delay] = true
			if delay.blocks then
				for i, d in ipairs(delay.blocks) do
					getBlocks(d)
				end
			end
		end

		for i, d in ipairs(self.delays) do
			if d.status == "active" or
				(test and not test(InletControl.d2e(d))) 
			then
				getBlocks(d)
			elseif not blocks[d] then
				dlist[i] = d
			end
		end
		
		--- TODO: make incremental indexes in dlist,
		--        and replace pairs with ipairs.

		return dlist
	end

	-----
	-- Creates new actions
	--
	local function invokeActions(self, now)
		log("Function", "invokeActions('",self.config.name,"',",now,")")
		if self.processes:size() >= self.config.maxProcesses then
			-- no new processes
			return
		end
		for _, d in ipairs(self.delays) do
			if #self.delays < self.config.maxDelays then
				-- time constrains only are only a concern if not maxed 
				-- the delay FIFO already.
				if d.alarm ~= true and lsyncd.clockbefore(now, d.alarm) then
					-- reached point in stack where delays are in future
					return
				end
			end
			if d.status == "wait" then
				-- found a waiting delay
				InletControl.setSync(self)
				self.config.action(Inlet)
				if self.processes:size() >= self.config.maxProcesses then
					-- no further processes
					return
				end
			end
		end
	end
	
	-----
	-- Gets the next event to be processed.
	--
	local function getNextDelay(self, now)
		for i, d in ipairs(self.delays) do
			if #self.delays < self.config.maxDelays then
				-- time constrains only are only a concern if not maxed 
				-- the delay FIFO already.
				if d.alarm ~= true and lsyncd.clockbefore(now, d.alarm) then
					-- reached point in stack where delays are in future
					return nil
				end
			end
			if d.status == "wait" then
				-- found a waiting delay
				return d
			end
		end
	end


	------
	-- adds and returns a blanket delay thats blocks all 
	-- (used in startup)
	--
	local function addBlanketDelay(self)
		local newd = Delay.new("Blanket", true, "")
		table.insert(self.delays, newd)
		return newd 
	end
	
	-----
	-- Writes a status report about delays in this sync.
	--
	local function statusReport(self, f)
		local spaces = "                    "
		f:write(self.config.name," source=",self.source,"\n")
		f:write("There are ",#self.delays, " delays\n")
		for i, vd in ipairs(self.delays) do
			local st = vd.status
			f:write(st, string.sub(spaces, 1, 7 - #st))
			f:write(vd.etype," ")
			-- TODO spaces
			f:write(vd.path)
			if (vd.path2) then
				f:write(" -> ",vd.path2)
			end
			f:write("\n")
		end
		f:write("Excluding:\n")
		local nothing = true
		for t, p in pairs(self.excludes.list) do
			nothing = false
			f:write(t,"\n")
		end
		if nothing then
			f:write("  nothing.\n")
		end
		f:write("\n")
	end

	--[[--
	-- DEBUG delays
	local _delay = delay
	delay = function(self, ...) 
		_delay(self, ...)
		statusReport(self, io.stdout)
	end
	--]]

	-----
	-- Creates a new Sync
	--
	local function new(config) 
		local s = {
			-- fields
			config = config,
			delays = CountArray.new(),
			source = config.source,
			processes = CountArray.new(),
			excludes = Excludes.new(),

			-- functions

			addBlanketDelay = addBlanketDelay,
			addExclude      = addExclude,
			collect         = collect,
			delay           = delay,
			getAlarm        = getAlarm,
			getDelays       = getDelays,
			getNextDelay    = getNextDelay,
			invokeActions   = invokeActions,
			removeDelay     = removeDelay,
			rmExclude       = rmExclude,
			statusReport    = statusReport,
		}
		-- provides a default name if needed
		if not config.name then
			config.name = "Sync" .. nextDefaultName
		end
		-- increments default nevertheless to cause less confusion
		-- so name will be the n-th call to sync{}
		nextDefaultName = nextDefaultName + 1

		-- loads exclusions
		if config.exclude then
			s.excludes:addList(config.exclude)
		end
		if config.excludeFrom then
			s.excludes:loadFile(config.excludeFrom)
		end

		return s
	end

	-----
	-- public interface
	--
	return {new = new}
end)()


-----
-- Syncs - a singleton
-- 
-- It maintains all configured directories to be synced.
--
local Syncs = (function()
	-----
	-- the list of all syncs
	--
	local list = Array.new()
	
	-----
	-- inheritly copies all non integer keys from
	-- @cd copy destination
	-- to
	-- @cs copy source
	-- all integer keys are treated as new copy sources
	--
	local function inherit(cd, cs)
		-- first copies from source all 
		-- non-defined non-integer keyed values 
		for k, v in pairs(cs) do
			if type(k) ~= "number" and not cd[k] then
				cd[k] = v
			end
		end
		-- first recurses into all integer keyed tables
		for i, v in ipairs(cs) do
			if type(v) == "table" then
				inherit(cd, v)
			end
		end
	end
	
	-----
	-- Adds a new directory to observe.
	--
	local function add(config)
		-----
		-- Creates a new config table and inherit all keys/values
		-- from integer keyed tables
		--
		local uconfig = config
		config = {}
		inherit(config, uconfig)
		
		-- at very first let the userscript 'prepare' function 
		-- fill out more values.
		if type(config.prepare) == "function" then
			-- give explicitly a writeable copy of config.
			config.prepare(config)
		end 

		if not config["source"] then
			local info = debug.getinfo(3, "Sl")
			log("Error", info.short_src, ":", info.currentline,
				": source missing from sync.")
			terminate(-1) -- ERRNO
		end
		
		-- absolute path of source
		local realsrc = lsyncd.realdir(config.source)
		if not realsrc then
			log("Error", "Cannot access source directory: ",config.source)
			terminate(-1) -- ERRNO
		end
		config._source = config.source
		config.source = realsrc

		if not config.action   and not config.onAttrib and
		   not config.onCreate and not config.onModify and
		   not config.onDelete and not config.onMove
		then
			local info = debug.getinfo(3, "Sl")
			log("Error", info.short_src, ":", info.currentline,
				": no actions specified, use e.g. 'config=default.rsync'.")
			terminate(-1) -- ERRNO
		end

		-- loads a default value for an option if not existent
		if not settings then
			settings = {}
		end
		local defaultValues = {
			'action',  
			'collapse', 
			'collapseTable', 
			'collect', 
			'init', 
			'maxDelays', 
			'maxProcesses', 
		}
		for _, dn in pairs(defaultValues) do
			if config[dn] == nil then
				config[dn] = settings[dn] or default[dn]
			end
		end

		--- creates the new sync
		local s = Sync.new(config)
		table.insert(list, s)
	end

	-----
	-- allows to walk through all syncs
	--
	local function iwalk()
		return ipairs(list)
	end

	-----
	-- returns the number of syncs
	--
	local size = function()
		return #list
	end

	-- public interface
	return {add = add, iwalk = iwalk, size = size}
end)()


-----
-- Utility function, returns the relative part of absolute path if it 
-- begins with root
--
local function splitPath(path, root)
	local rl = #root
	local sp = string.sub(path, 1, rl)

	if sp == root then
		return string.sub(path, rl, -1)
	else
		return nil
	end
end

-----
-- Interface to inotify, watches recursively subdirs and 
-- sends events.
--
-- All inotify specific implementation should be enclosed here.
-- So lsyncd can work with other notifications mechanisms just
-- by changing this.
--
local Inotify = (function()

	-----
	-- A list indexed by inotifies watch descriptor yielding the 
	-- directories absolute paths.
	--
	local wdpaths = CountArray.new()

	-----
	-- The same vice versa, all watch descriptors by its
	-- absolute path.
	--
	local pathwds = {}

	-----
	-- A list indexed by sync's containing the root path this
	-- sync is interested in.
	--
	local syncRoots = {}
	
	-----
	-- Stops watching a directory
	--
	-- @param path    absolute path to unwatch
	-- @param core    if false not actually send the unwatch to the kernel
	--                (used in moves which reuse the watch)
	--
	local function removeWatch(path, core)
		local wd = pathwds[path]
		if not wd then
			return 
		end
		if core then
			lsyncd.inotify.rmwatch(wd)
		end
		wdpaths[wd] = nil
		pathwds[path] = nil
	end

	-----
	-- Adds watches for a directory (optionally) including all subdirectories.
	--
	-- @param path       absolute path of directory to observe
	-- @param recurse    true if recursing into subdirs 
	-- @param raiseSync  --X --
	--        raiseTime  if not nil sends create Events for all files/dirs
	--                   to this sync.
	--
	local function addWatch(path, recurse, raiseSync, raiseTime)
		log("Function", 
			"Inotify.addWatch(",path,", ",recurse,", ",
			raiseSync,", ",raiseTime,")")

		-- lets the core registers watch with the kernel
		local wd = lsyncd.inotify.addwatch(path);
		if wd < 0 then
			log("Inotify","Unable to add watch '",path,"'")
			return
		end

		do
			-- If this wd is registered already the kernel
			-- reused it for a new dir for a reason - old 
			-- dir is gone.
			local op = wdpaths[wd]
			if op and op ~= path then
				pathwds[op] = nil
			end
		end
		pathwds[path] = wd
		wdpaths[wd] = path

		-- registers and adds watches for all subdirectories 
		-- and/or raises create events for all entries
		if not recurse and not raise then 
			return
		end

		local entries = lsyncd.readdir(path)
		if not entries then
			return
		end
		for dirname, isdir in pairs(entries) do
			local pd = path .. dirname
			if isdir then
				pd = pd .. "/"
			end
			
			-- creates a Create event for entry.
			if raiseSync then
				local relative  = splitPath(pd, syncRoots[raiseSync])
				if relative then
					raiseSync:delay("Create", raiseTime, relative)
				end
			end
			-- adds syncs for subdirs
			if isdir and recurse then
				addWatch(pd, true, raiseSync, raiseTime)
			end
		end
	end

	-----
	-- adds a Sync to receive events
	--
	-- @param root   root dir to watch
	-- @param sync   Object to receive events
	--
	local function addSync(sync, root)
		if syncRoots[sync] then
			error("internal fail, duplicate sync in Inotify.addSync()")
		end
		syncRoots[sync] = root
		addWatch(root, true)
	end

	-----
	-- Called when an event has occured.
	--
	-- @param etype     "Attrib", "Mofify", "Create", "Delete", "Move")
	-- @param wd        watch descriptor (matches lsyncd.inotifyadd())
	-- @param isdir     true if filename is a directory
	-- @param time      time of event
	-- @param filename  string filename without path
	-- @param filename2 
	--
	local function event(etype, wd, isdir, time, filename, wd2, filename2)
		local ftype;

		if isdir then
			ftype = "directory"
			filename = filename .. "/"
			if filename2 then
				filename2 = filename2 .. "/"
			end
		end

		if filename2 then
			log("Inotify", "got event ",etype," ",filename, 
				"(",wd,") to ",filename2,"(",wd2,")") 
		else 
			log("Inotify","got event ",etype," ",filename,"(",wd,")")
		end

		-- looks up the watch descriptor id
		local path = wdpaths[wd]
		if path then
			path = path..filename
		end
		
		local path2 = wd2 and wdpaths[wd2]
		if path2 and filename2 then
			path2 = path2..filename2
		end
		
		if not path and path2 and etype =="Move" then
			log("Inotify", "Move from deleted directory ",path2,
				" becomes Create.")
			path = path2
			path2 = nil
			etype = "Create"
		end

		if not path then
			-- this is normal in case of deleted subdirs
			log("Inotify", "event belongs to unknown watch descriptor.")
			return
		end

		for sync, root in pairs(syncRoots) do repeat
			local relative  = splitPath(path, root)
			local relative2 
			if path2 then
				relative2 = splitPath(path2, root)
			end
			if not relative and not relative2 then
				-- sync is not interested in this dir
				break -- continue
			end
		
			-- makes a copy of etype to possibly change it
			local etyped = etype 
			if etyped == 'Move' then
				if not relative2 then
					log("Normal", "Transformed Move to Create for ",
						sync.config.name)
					etyped = 'Create'
				elseif not relative then
					relative = relative2
					relative2 = nil
					log("Normal", "Transformed Move to Delete for ",
						sync.config.name)
					etyped = 'Delete'
				end
			end
			sync:delay(etyped, time, relative, relative2)
			
			if isdir and 
				(sync.config.subdirs or sync.config.subdirs == nil) 
			then
				if etyped == "Create" then
					addWatch(path, true, sync, time)
				elseif etyped == "Delete" then
					removeWatch(path, true)
				elseif etyped == "Move" then
					removeWatch(path, false)
					addWatch(path2, true, sync, time)
				end
			end
		until true end
	end

	-----
	-- Writes a status report about inotifies to a filedescriptor
	--
	local function statusReport(f)
		f:write("Watching ",wdpaths:size()," directories\n")
		for wd, path in wdpaths:walk() do
			f:write("  ",wd,": ",path,"\n")
		end
	end

	-- public interface
	return { 
		addSync = addSync, 
		event = event, 
		statusReport = statusReport 
	}
end)()

-----
-- Holds information about the event monitor capabilities
-- of the core.
--
local Monitors = (function()
	-----
	-- The cores monitor list
	local list = {}

	-----
	-- initializes with info received from core
	--
	local function initialize(clist)
		for k, v in ipairs(clist) do
			list[k] = v
		end
	end

	-- public interface
	return { list = list,
	         initialize = initialize 
	}
end)()

------
-- Writes functions for the user for layer 3 configuration.
--
local functionWriter = (function()

	-----
	-- all variables for layer 3
	transVars = {
		{ "%^pathname",          "event.pathname"        , 1, },
		{ "%^pathdir",           "event.pathdir"         , 1, },
		{ "%^path",              "event.path"            , 1, },
		{ "%^sourcePathname",    "event.sourcePathname"  , 1, },
		{ "%^sourcePath",        "event.sourcePath"      , 1, },
		{ "%^source",            "event.source"          , 1, },
		{ "%^targetPathname",    "event.targetPathname"  , 1, },
		{ "%^targetPath",        "event.targetPath"      , 1, },
		{ "%^target",            "event.target"          , 1, },
		{ "%^o%.pathname",       "event.pathname"        , 1, },
		{ "%^o%.path",           "event.path"            , 1, },
		{ "%^o%.sourcePathname", "event.sourcePathname"  , 1, },
		{ "%^o%.sourcePath",     "event.sourcePath"      , 1, },
		{ "%^o%.targetPathname", "event.targetPathname"  , 1, },
		{ "%^o%.targetPath",     "event.targetPath"      , 1, },
		{ "%^d%.pathname",       "event2.pathname"       , 2, },
		{ "%^d%.path",           "event2.path"           , 2, },
		{ "%^d%.sourcePathname", "event2.sourcePathname" , 2, },
		{ "%^d%.sourcePath",     "event2.sourcePath"     , 2, },
		{ "%^d%.targetPathname", "event2.targetPathname" , 2, },
		{ "%^d%.targetPath",     "event2.targetPath"     , 2, },
	}

	-----
	-- Splits a user string into its arguments
	-- 
	-- @param a string where parameters are seperated by spaces.
	--
	-- @return a table of arguments
	--
	local function splitStr(str)
		local args = {}
		while str ~= "" do
			-- break where argument stops
			local bp = #str
			-- in a quote
			local inQuote = false
			-- tests characters to be space and not within quotes
			for i=1,#str do
				local c = string.sub(str, i, i)
				if c == '"' then
					inQuote = not inQuote
				elseif c == ' ' and not inQuote then
					bp = i - 1
					break
				end
			end
			local arg = string.sub(str, 1, bp)
			arg = string.gsub(arg, '"', '\\"')
			table.insert(args, arg)
			str = string.sub(str, bp + 1, -1)
			str = string.match(str, "^%s*(.-)%s*$")
		end
		return args
	end

	-----
	-- Translates a call to a binary to a lua function.
	--
	-- TODO this has a little too much coding blocks.
	--
	local function translateBinary(str)
		-- splits the string
		local args = splitStr(str)
	
		-- true if there is a second event
		local haveEvent2 = false
	
		for ia, iv in ipairs(args) do
			-- a list of arguments this arg is being split into
			local a = {{true, iv}}
			-- goes through all translates
			for _, v in ipairs(transVars) do
				local ai = 1 
				while ai <= #a do
					if a[ai][1] then
						local pre, post = 
							string.match(a[ai][2], "(.*)"..v[1].."(.*)")
						if pre then
							if v[3] > 1 then
								haveEvent2 = true
							end
							if pre ~= "" then
								table.insert(a, ai, {true, pre})
								ai = ai + 1
							end
							a[ai] = {false, v[2]}
							if post ~= "" then
								table.insert(a, ai + 1, {true, post})
							end
						end
					end
					ai = ai + 1
				end
			end

			-- concats the argument pieces into a string.
			local as = ""
			local first = true
			for _, v in ipairs(a) do
				if not first then
					as = as.." .. "
				end
				if v[1] then
					as = as..'"'..v[2]..'"'
				else 
					as = as..v[2]
				end
				first = false
			end
			args[ia] = as
		end

		local ft
		if not haveEvent2 then
			ft = "function(event)\n"
		else
			ft = "function(event, event2)\n"
		end
		ft = ft .. '    log("Normal", "Event " .. event.etype ..\n'
		ft = ft .. "        [[ spawns action '" .. str .. '\']])\n'
		ft = ft .. "    spawn(event"
		for _, v in ipairs(args) do
			ft = ft .. ",\n         " .. v 
		end
		ft = ft .. ")\nend"	
		return ft
	end

	-----
	-- Translates a call using a shell to a lua function
	--
	local function translateShell(str)
		local argn = 1
		local args = {}
		local cmd = str
		local lc = str
		-- true if there is a second event
		local haveEvent2 = false

		for _, v in ipairs(transVars) do
			local occur = false
			cmd = string.gsub(cmd, v[1], 
				function() 
					occur = true
					return '"$'..argn..'"' 
				end)
			lc = string.gsub(lc, v[1], ']]..'..v[2]..'..[[')
			if occur then
				argn = argn + 1
				table.insert(args, v[2])
				if v[3] > 1 then
					haveEvent2 = true
				end
			end
		end
		local ft
		if not haveEvent2 then
			ft = "function(event)\n"
		else
			ft = "function(event, event2)\n"
		end
		ft = ft .. '    log("Normal", "Event " .. event.etype ..\n'
		ft = ft .. "        [[ spawns shell '" .. lc .. '\']])\n'
		ft = ft .. "    spawnShell(event, [[" .. cmd .. "]]"
		for _, v in ipairs(args) do
			ft = ft .. ",\n         " .. v 
		end
		ft = ft .. ")\nend"
		return ft
	end

	-----
	-- writes a lua function for a layer 3 user script.
	local function translate(str)
		-- trim spaces 
		str = string.match(str, "^%s*(.-)%s*$")

		local ft
		if string.byte(str, 1, 1) == 47 then
			 ft = translateBinary(str)
		else
			 ft = translateShell(str)
		end
		log("FWrite","translated [[",str,"]] to \n",ft)
		return ft
	end

	-----
	-- public interface
	--
	return {translate = translate}
end)()


----
-- Writes a status report file at most every [statusintervall] seconds.
--
--
local StatusFile = (function() 
	-----
	-- Timestamp when the status file has been written.
	local lastWritten = false

	-----
	-- Timestamp when a status file should be written
	local alarm = false

	-----
	-- Returns when the status file should be written
	--
	local function getAlarm()
		return alarm
	end

	-----
	-- Called to check if to write a status file.
	--
	local function write(now)
		log("Function", "write(", now, ")")

		-- some logic to not write too often
		if settings.statusIntervall > 0 then
			-- already waiting
			if alarm and lsyncd.clockbefore(now, alarm) then
				log("Statusfile", "waiting(",now," < ",alarm,")")
				return
			end
			-- determines when a next write will be possible
			if not alarm then
				local nextWrite = lastWritten and
					lsyncd.addtoclock(now, settings.statusIntervall)
				if nextWrite and lsyncd.clockbefore(now, nextWrite) then
					log("Statusfile", "setting alarm: ", nextWrite)
					alarm = nextWrite
					return
				end
			end
			lastWritten = now
			alarm = false
		end

		log("Statusfile", "writing now")
		local f, err = io.open(settings.statusFile, "w")
		if not f then
			log("Error", "Cannot open status file '"..settings.statusFile..
				"' :"..err)
			return
		end
		f:write("Lsyncd status report at ", os.date(), "\n\n")
		for i, s in Syncs.iwalk() do
			s:statusReport(f)
			f:write("\n")
		end
		
		Inotify.statusReport(f)
		f:close()
	end

	-- public interface
	return {write = write, getAlarm = getAlarm}
end)()

--============================================================================
-- lsyncd runner plugs. These functions will be called from core. 
--============================================================================

-----
-- Current status of lsyncd.
--
-- "init"  ... on (re)init
-- "run"   ... normal operation
-- "fade"  ... waits for remaining processes
--
local lsyncdStatus = "init"

----
-- the cores interface to the runner
local runner = {}

-----
-- Called from core whenever lua code failed.
-- Logs a backtrace
--
function runner.callError(message)
	log("Error", "IN LUA: ", message)
	-- prints backtrace
	local level = 2
	while true do
		local info = debug.getinfo(level, "Sl")
		if not info then
			terminate(-1) -- ERRNO
		end
		log("Error", "Backtrace ", level - 1, " :", 
			info.short_src, ":", info.currentline)
		level = level + 1
	end
end

-----
-- Called from code whenever a child process finished and 
-- zombie process was collected by core.
--
function runner.collectProcess(pid, exitcode) 
	for _, s in Syncs.iwalk() do
		if s:collect(pid, exitcode) then
			return
		end
	end
end

----
-- Called from core everytime a masterloop cycle runs through.
-- This happens in case of 
--   * an expired alarm.
--   * a returned child process.
--   * received inotify events.
--   * received a HUP or TERM signal.
--
-- @param now   the current kernel time (in jiffies)
--
function runner.cycle(now)
	-- goes through all syncs and spawns more actions
	-- if possible
	if lsyncdStatus == "fade" then
		local np = 0
		for _, s in Syncs.iwalk() do
			np = np + s.processes:size()
		end
		if np > 0 then
			log("Normal", "waiting for ",np," more child processes.")
			return true
		else
			return false
		end
	end
	if lsyncdStatus ~= "run" then
		error("cycle called in not run?!")
	end

	for _, s in Syncs.iwalk() do
		s:invokeActions(now)
	end

	if settings.statusFile then
		StatusFile.write(now)
	end

	return true
end

-----
-- Called by core before anything is "-help" or "--help" is in
-- the arguments.
--
function runner.help()
	io.stdout:write(
[[

USAGE: 
  runs a config file:
    lsyncd [OPTIONS] [CONFIG-FILE]

  default rsync behaviour:
    lsyncd [OPTIONS] -rsync [SOURCE] [TARGET]  
  
  default rsync with mv's through ssh:
    lsyncd [OPTIONS] -rsyncssh [SOURCE] [HOST] [TARGETDIR]

OPTIONS:
  -help               Shows this
  -log    all         Logs everything (debug)
  -log    scarce      Logs errors only
  -log    [Category]  Turns on logging for a debug category
  -logfile FILE       Writes log to FILE (DEFAULT: uses syslog)
  -monitor NAME       Uses operating systems event montior NAME 
                      (inotify/fanotify/fsevents)
  -nodaemon           Does not detach and logs to stdout/stderr
  -pidfile FILE       Writes Lsyncds PID into FILE
  -runner FILE        Loads Lsyncds lua part from FILE 
  -version            Prints versions and exits

LICENSE:
  GPLv2 or any later version.

SEE:
  `man lsyncd` for further information.

]])
	os.exit(-1) -- ERRNO
end


-----
-- settings specified by command line.
--
local clSettings = {}

-----
-- Called from core to parse the command line arguments
-- @returns a string as user script to load.
--          or simply 'true' if running with rsync bevaiour
-- terminates on invalid arguments
--
function runner.configure(args, monitors)
	Monitors.initialize(monitors)

	-- a list of all valid --options
	-- first paramter is number of options
	--       if < 0 the function checks existance
	-- second paramter is function to call when in args 
	--
	local options = {
		-- log is handled by core already.
		log      = 
			{1, nil},
		logfile   = 
			{1, function(file)
				clSettings.logfile=file
			end},
		monitor = 
			{-1, function(monitor)
				if not monitor then
					io.stdout:write("This Lsyncd supports these monitors:\n")
					for _, v in ipairs(Monitors.list) do
						io.stdout:write("   ",v,"\n")
					end
					io.stdout:write("\n");
					lsyncd.terminate(-1); -- ERRNO
				else
					clSettings.monitor=monitor
				end
			end},
		nodaemon = 
			{0, function() 
				clSettings.nodaemon=true 
			end},
		pidfile   = 
			{1, function(file)
				clSettings.pidfile=file
			end},
		rsync    = 
			{2, function(src, trg) 
				clSettings.syncs = clSettings.syncs or {}
				table.insert(clSettings.syncs, {"rsync", src, trg})
			end},
		rsyncssh = 
			{3, function(src, host, tdir) 
				clSettings.syncs = clSettings.syncs or {}
				table.insert(clSettings.syncs, {"rsyncssh", src, host, tdir})
			end},
		version  =
			{0, function()
				io.stdout:write("Version: ", lsyncd_version,"\n")
				os.exit(0)
			end}
	}
	-- nonopts is filled with all args that were no part dash options
	local nonopts = {}
	local i = 1
	while i <= #args do
		local a = args[i]
		if a:sub(1, 1) ~= "-" then
			table.insert(nonopts, args[i])
		else
			if a:sub(1, 2) == "--" then
				a = a:sub(3)
			else
				a = a:sub(2)
			end
			local o = options[a]
			if o then
				if o[1] >= 0 and i + o[1] > #args then
					log("Error",a," needs ",o[1]," arguments")
					os.exit(-1) -- ERRNO
				else
					o[1] = -o[1]
				end
				if o[2] then
					if o[1] == 0 then
						o[2]()
					elseif o[1] == 1 then
						o[2](args[i + 1])
					elseif o[1] == 2 then
						o[2](args[i + 1], args[i + 2])
					elseif o[1] == 3 then
						o[2](args[i + 1], args[i + 2], args[i + 3])
					end
				end
				i = i + o[1]
			else
				log("Error","unknown option command line option ", args[i])
				os.exit(-1) -- ERRNO
			end
		end
		i = i + 1
	end

	if clSettings.syncs then
		if #nonopts ~= 0 then
			log("Error", 
			"There cannot be command line default syncs with a config file.")
			os.exit(-1) -- ERRNO
		end
	else
		if #nonopts == 0 then
			runner.help(args[0])
		elseif #nonopts == 1 then
			return nonopts[1]
		else 
			log("Error", "There can only be one config file in command line.")
			os.exit(-1) -- ERRNO
		end
	end
end


----
-- Called from core on init or restart after user configuration.
-- 
function runner.initialize()
	-- creates settings if user didnt
	settings = settings or {}

	-- From this point on, no globals may be created anymore
	lockGlobals()

	-- copies simple settings with numeric keys to "key=true" settings.
	for k, v in pairs(settings) do
		if settings[v] then
			log("Error", "Double setting '"..v.."'")
			os.exit(-1) -- ERRNO
		end
		settings[v]=true
	end
	
	-- all command line settings overwrite config file settings
	for k, v in pairs(clSettings) do
		if k ~= "syncs" then
			settings[k]=v 
		end
	end

	-- adds syncs specified by command line.
	if clSettings.syncs then
		for _, s in ipairs(clSettings.syncs) do
			if s[1] == "rsync" then
				sync{default.rsync, source=s[2], target=s[3]}
			elseif s[1] == "rsyncssh" then
				sync{default.rsyncssh, source=s[2], host=s[3], targetdir=s[4]}
			end
		end
	end

	if settings.nodaemon then
		lsyncd.configure("nodaemon")
	end
	if settings.logfile then
		lsyncd.configure("logfile", settings.logfile)
	end
	if settings.pidfile then
		lsyncd.configure("pidfile", settings.pidfile)
	end
	-----
	-- transfers some defaults to settings 
	if settings.statusIntervall == nil then
		settings.statusIntervall = default.statusIntervall
	end

	-- makes sure the user gave Lsyncd anything to do 
	if Syncs.size() == 0 then
		log("Error", "Nothing to watch!")
		log("Error", "Use sync(SOURCE, TARGET, BEHAVIOR) in your config file.");
		os.exit(-1) -- ERRNO
	end

	-- from now on use logging as configured instead of stdout/err.
	lsyncdStatus = "run";
	lsyncd.configure("running");
	
	local ufuncs = {
		"onAttrib", "onCreate", "onDelete",
		"onModify", "onMove",   "onStartup"
	}
		
	-- translates layer 3 scripts
	for _, s in Syncs.iwalk() do
		-- checks if any user functions is a layer 3 string.
		local config = s.config
		for _, fn in ipairs(ufuncs) do
			if type(config[fn]) == 'string' then
				local ft = functionWriter.translate(config[fn])
				config[fn] = assert(loadstring("return " .. ft))()
			end
		end
	end

	-- runs through the Syncs created by users
	for _, s in Syncs.iwalk() do
		Inotify.addSync(s, s.source)
		if s.config.init then
			InletControl.setSync(s)
			s.config.init(Inlet)
		end
	end
end

----
-- Called by core to query soonest alarm.
--
-- @return false ... no alarm, core can in untimed sleep, or
--         true  ... immediate action
--         times ... the alarm time (only read if number is 1)
--
function runner.getAlarm()
	local alarm = false

	----
	-- checks if current nearest alarm or a is earlier
	--
	local function checkAlarm(a) 
		if alarm == true or not a then
			-- already immediate or no new alarm
			return
		end
		if not alarm then
			alarm = a
		else
			alarm = lsyncd.earlier(alarm, a)
		end
	end

	-- checks all syncs for their earliest alarm
	for _, s in Syncs.iwalk() do
		checkAlarm(s:getAlarm())
	end
	-- checks if a statusfile write has been delayed
	checkAlarm(StatusFile.getAlarm())

	log("Debug", "getAlarm returns: ",alarm)
	return alarm
end


-----
-- Called when an inotify event arrived.
-- Simply forwards it directly to the object.
--
runner.inotifyEvent = Inotify.event

-----
-- Collector for every child process that finished in startup phase
--
-- Parameters are pid and exitcode of child process
--
-- Can return either a new pid if one other child process 
-- has been spawned as replacement (e.g. retry) or 0 if
-- finished/ok.
--
function runner.collector(pid, exitcode)
	if exitcode ~= 0 then
		log("Error", "Startup process", pid, " failed")
		terminate(-1) -- ERRNO
	end
	return 0
end

----
-- Called by core when an overflow happened.
--
function runner.overflow()
	log("Normal", "--- OVERFLOW on inotify event queue ---")
	lsyncdStatus = "fade"
end

----
-- Called by core on a hup signal.
--
function runner.hup()
	log("Normal", "--- HUP signal, resetting ---")
	lsyncdStatus = "fade"
end

----
-- Called by core on a term signal.
--
function runner.term()
	log("Normal", "--- TERM signal, fading ---")
	lsyncdStatus = "fade"
end

--============================================================================
-- Lsyncd user interface
--============================================================================

-----
-- Main utility to create new observations.
--
function sync(opts)
	if lsyncdStatus ~= "init" then
		error("Sync can only be created on initialization.", 2)
	end
	Syncs.add(opts)
end


-----
-- Spawn a new child process
--
-- @param agent   the reason why a process is spawned.
--                normally this is a delay/event of a sync.
--                it will mark the related files as blocked.
--                or it is a string saying "all", that this 
--                process blocks all events and is blocked by all
--                this is used on startup.
-- @param collect a table of exitvalues and the action that shall taken.
-- @param binary  binary to call
-- @param ...     arguments
--
function spawn(agent, binary, ...)
	if agent == nil or type(agent) ~= "table" then
		error("spawning with an invalid agent", 2)
	end
	if lsyncdStatus == "fade" then
		log("Normal", "ignored spawn processs since status fading")
	end
	local pid = lsyncd.exec(binary, ...)
	if pid and pid > 0 then
		local sync = InletControl.getSync()
		local delay = InletControl.getDelay(agent)
		if delay then
			delay.status = "active"
			sync.processes[pid] = delay
		else 
			local dlist = InletControl.getDelayList(agent)
			if not dlist then
				error("spawning with an unknown agent", 2)
			end
			for k, d in pairs(dlist) do
				if type(k) == "number" then
					d.status = "active"
				end
			end
			sync.processes[pid] = dlist
		end
	end
end

-----
-- Spawns a child process using bash.
--
function spawnShell(agent, command, ...)
	return spawn(agent, "/bin/sh", "-c", command, "/bin/sh", ...)
end


-----
-- Comfort routine also for user.
-- Returns true if 'String' starts with 'Start'
--
function string.starts(String,Start)
	return string.sub(String,1,string.len(Start))==Start
end

-----
-- Comfort routine also for user.
-- Returns true if 'String' ends with 'End'
--
function string.ends(String,End)
	return End=='' or string.sub(String,-string.len(End))==End
end


--============================================================================
-- Lsyncd default settings
--============================================================================

-----
-- Exitcodes to retry on network failures of rsync.
--
local rsync_exitcodes = {
	[  1] = "die",
	[  2] = "die",
	[  3] = "again",
	[  4] = "die",
	[  5] = "again",
	[  6] = "again",
	[ 10] = "again", 
	[ 11] = "again",
--	[ 12] = "again", -- dont consistent failure, if e.g. target dir not there.
	[ 14] = "again",
	[ 20] = "again",
	[ 21] = "again",
	[ 22] = "again",
	[ 25] = "die",
	[ 30] = "again",
	[ 35] = "again",
	[255] = "again",
}

-----
-- Exitcodes to retry on network failures of rsync.
--
local ssh_exitcodes = {
	[255] = "again",
}


-----
-- Lsyncd classic - sync with rsync
--
local default_rsync = {
	-----
	-- Spawns rsync for a list of events
	--
	action = function(inlet) 
		-- gets all events ready for syncing
		local elist = inlet.getEvents()
		local paths = elist.getPaths(
			function(etype, path1, path2) 
				if etype == "Delete" and string.byte(path1, -1) == 47 then
					return path1 .. "***", path2
				else
					return path1, path2
				end
			end)
		-- stores all filters with integer index	
		local filterI = {} 
		-- stores all filters with path index	
		local filterP = {}

		-- adds one entry into the filter
		-- @param path ... path to add
		-- @param leaf ... true if this the orinal path
		--                 false if its a parent
		local function addToFilter(path) 
			if filterP[path] then
				return
			end
			filterP[path]=true
			table.insert(filterI, path)
		end

		-- adds a path to the filter, for rsync this needs
		-- to have entries for all steps in the path, so the file
		-- d1/d2/d3/f1 needs filters 
		-- "d1/", "d1/d2/", "d1/d2/d3/" and "d1/d2/d3/f1"
		for _, path in ipairs(paths) do
			if path and path ~="" then
				addToFilter(path)
				local pp = string.match(path, "^(.*/)[^/]+/?")
				while pp do
					addToFilter(pp)
					pp = string.match(pp, "^(.*/)[^/]+/?")
				end
			end
		end
		
		local filterS = table.concat(filterI, "\n")
		log("Normal", 
			"Calling rsync with filter-list of new/modified files/dirs\n", 
			filterS)
		local config = inlet.getConfig()
		spawn(elist, "/usr/bin/rsync", 
			"<", filterS, 
			config.rsyncOps,
			"-r",
			"--delete",
			"--force",
			"--include-from=-",
			"--exclude=*",
			config.source, 
			config.target)
		
	end,

	-----
	-- Spawns the recursive startup sync
	-- 
	init = function(inlet)
		local config = inlet.getConfig()
		local event = inlet.createBlanketEvent()
		if string.sub(config.target, -1) ~= "/" then
			config.target = config.target .. "/"
		end
		log("Normal", "recursive startup rsync: ", config.source,
			" -> ", config.target)
		spawn(event, "/usr/bin/rsync", 
			"--delete",
			config.rsyncOps, "-r", 
			config.source, config.target)
	end,

	-----
	-- Calls rsync with this options.
	--
	rsyncOps = "-lts",

	-----
	-- exit codes for rsync.
	--
	exitcodes = rsync_exitcodes,
	
	-----
	-- Default delay
	--
	delay = 15,
}


-----
-- Lsyncd 2 improved rsync - sync with rsync but move over ssh.
--
local default_rsyncssh = {
	-----
	-- Spawns rsync for a list of events
	--
	action = function(inlet) 
		local event, event2 = inlet.getEvent()
		local config = inlet.getConfig()
		
		-- makes move local on host
		if event.etype == 'Move' then
			log("Normal", "Moving ",event.path," -> ",event2.path)
			spawn(event, "/usr/bin/ssh", 
				config.host, "mv",
				config.targetdir .. event.path, 
				config.targetdir .. event2.path)
			return
		end
		
		-- uses ssh to delete files on remote host
		-- instead of constructing rsync filters
		if event.etype == 'Delete' then
			local elist = inlet.getEvents(
				function(e)
					return e.etype == "Delete"
				end)

			local paths = elist.getPaths(
				function(etype, path1, path2) 
					if path2 then
						return config.targetdir..path1, config.targetdir..path2
					else
						return config.targetdir..path1
					end
				end)

			for _, v in pairs(paths) do
				if string.match(v, "^%s*/+%s*$") then
					log("Error", "refusing to `rm -rf /` the target!")
					terminate(-1) -- ERRNO
				end
			end

			local sPaths = table.concat(paths, "\n")
			log("Normal", "Deleting list\n", sPaths)
			spawn(elist, "/usr/bin/ssh", 
				"<", sPaths,
				config.host, "xargs", "rm -rf")
			return
		end

		-- for everything else spawn a rsync
		local elist = inlet.getEvents(
			function(e) 
				return e.etype ~= "Move" and e.etype ~= "Delete"
			end)
		local paths = elist.getPaths()
		
		-- removes trailing slashes from dirs.
		for k, v in ipairs(paths) do
			if string.byte(v, -1) == 47 then
				paths[k] = string.sub(v, 1, -2)
			end
		end
		local sPaths = table.concat(paths, "\n") -- TODO 0 delimiter
		log("Normal", "Rsyncing list\n", sPaths)
		spawn(elist, "/usr/bin/rsync", 
			"<", sPaths, 
			config.rsyncOps,
			"--files-from=-",
			config.source, 
			config.host .. ":" .. config.targetdir)
	end,
	
	-----
	-- Called when collecting a finished child process
	--
	collect = function(agent, exitcode)
		if not agent.isList and agent.etype == "Blanket" then
			if exitcode == 0 then
				log("Normal", "Startup of '",agent.source,"' finished.")
			elseif rsync_exitcodes[exitcode] == "again" then
				log("Normal", 
					"Retrying startup of '",agent.source,"'.")
				return "again"
			else
				log("Error", "Failure on startup of '",agent.source,"'.")
				terminate(-1) -- ERRNO
			end
		end

		if agent.isList then
			local rc = rsync_exitcodes[exitcode] 
			if rc == "die" then
				return rc
			end
			if rc == "again" then
				log("Normal", "Retrying a list on exitcode = ",exitcode)
			else
				log("Normal", "Finished a list = ",exitcode)
			end
			return rc
		else
			local rc = ssh_exitcodes[exitcode] 
			if rc == "die" then
				return rc
			end
			if rc == "again" then
				log("Normal", "Retrying ",agent.etype,
					" on ",agent.sourcePath," = ",exitcode)
			else
				log("Normal", "Finished ",agent.etype,
					" on ",agent.sourcePath," = ",exitcode)
			end
		end
	end,

	-----
	-- Spawns the recursive startup sync
	-- 
	init = function(inlet)
		local config = inlet.getConfig()
		local event = inlet.createBlanketEvent()
		if string.sub(config.targetdir, -1) ~= "/" then
			config.targetdir = config.targetdir .. "/"
		end
		log("Normal", "recursive startup rsync: ", config.source,
			" -> ", config.host .. ":" .. config.targetdir)
		spawn(event, "/usr/bin/rsync", 
			"--delete",
			config.rsyncOps .. "r", 
			config.source, 
			config.host .. ":" .. config.targetdir)
	end,

	-----
	-- Calls rsync with this options
	--
	rsyncOps = "-lts",

	-----
	-- allow several processes
	--
	maxProcesses = 3,
	
	------
	-- Let the core not split move event.
	--
	onMove = true,
	
	-----
	-- Default delay. 
	--
	delay = 15,
}

-----
-- The default table for the user to accesss.
-- Provides all the default layer 1 functions.
-- 
--   TODO make readonly
-- 
default = {

	-----
	-- Default action calls user scripts on**** functions.
	--
	action = function(inlet)
		-- in case of moves getEvent returns the origin and dest of the move
		local event, event2 = inlet.getEvent()
		local config = inlet.getConfig()
		local func = config["on".. event.etype]
		if func then
			func(event, event2)
		end
		-- if function didnt change the wait status its not interested
		-- in this event -> drop it.
		if event.status == "wait" then
			inlet.discardEvent(event)
		end
	end,

	-----
	-- Called to see if two events can be collapsed.
	--
	-- Default function uses the collapseTable.
	--
	-- @param event1    first event
	-- @param event2    second event
	-- @return -1  ... no interconnection
	--          0  ... drop both events.
	--          1  ... keep first event only
	--          2  ... keep second event only
	--          3  ... events block.
	--
	collapse = function(event1, event2, config)
		if event1.path == event2.path then
			if event1.status == "active" then
				return 3
			end
			local e1 = event1.etype .. event1.move
			local e2 = event2.etype .. event2.move
			return config.collapseTable[e1][e2]
		end
	
		-----
		-- Block events if one is a parent directory of another
		--
		if event1.isdir and string.starts(event2.path, event1.path) then
			return 3
		end
		if event2.isdir and string.starts(event1.path, event2.path) then
			return 3
		end

		return -1
	end,
	
	-----
	-- Used by default collapse function.
	-- Specifies how two event should be collapsed when here 
	-- horizontal event meets upon a vertical event.
	-- values:
	-- 0 ... nullification of both events.
	-- 1 ... absorbtion of horizontal event.
	-- 2 ... replace of vertical event.
	-- 3 ... stack both events, vertical blocking horizonal.
	-- 9 ... combines two move events.
	--
	collapseTable = {
		Attrib = {Attrib=1, Modify=2, Create=2, Delete=2, MoveFr=3, MoveTo= 2},
		Modify = {Attrib=1, Modify=1, Create=2, Delete=2, MoveFr=3, MoveTo= 2},
		Create = {Attrib=1, Modify=1, Create=1, Delete=0, MoveFr=3, MoveTo= 2},
		Delete = {Attrib=1, Modify=1, Create=3, Delete=1, MoveFr=3, MoveTo= 2},
		MoveFr = {Attrib=3, Modify=3, Create=3, Delete=3, MoveFr=3, MoveTo= 3},
		--                                           TODO MoveFr=9
		MoveTo = {Attrib=3, Modify=3, Create=2, Delete=2, MoveFr=3, MoveTo= 2},
	},

	-----
	-- Called when collecting a finished child process
	--
	collect = function(agent, exitcode)
		local config = agent.config

		if not agent.isList and agent.etype == "Blanket" then
			if exitcode == 0 then
				log("Normal", "Startup of '",agent.source,"' finished.")
			elseif config.exitcodes and 
			       config.exitcodes[exitcode] == "again" 
			then
				log("Normal", 
					"Retrying startup of '",agent.source,"'.")
				return "again"
			else
				log("Error", "Failure on startup of '",agent.source,"'.")
				terminate(-1) -- ERRNO
			end
			return
		end

		local rc = config.exitcodes and config.exitcodes[exitcode] 
		if rc == "die" then
			return rc
		end

		if agent.isList then
			if rc == "again" then
				log("Normal", "Retrying a list on exitcode = ",exitcode)
			else
				log("Normal", "Finished a list = ",exitcode)
			end
		else
			if rc == "again" then
				log("Normal", "Retrying ",agent.etype,
					" on ",agent.sourcePath," = ",exitcode)
			else
				log("Normal", "Finished ",agent.etype,
					" on ",agent.sourcePath," = ",exitcode)
			end
		end
		return rc
	end,

	-----
	-- called on (re)initalizing of Lsyncd.
	--
	init = function(inlet)
		local config = inlet.getConfig()
		-- user functions

		-- calls a startup if given by user script.
		if type(config.onStartup) == "function" then
			local event = inlet.createBlanketEvent()
			local startup = config.onStartup(event)
			if event.status == "wait" then
				-- user script did not spawn anything
				-- thus the blanket event is deleted again.
				inlet.discardEvent(event)
			end
			-- TODO honor some return codes of startup like "warmstart".
		end
	end,

	-----
	-- The maximum number of processes Lsyncd will spawn simultanously for
	-- one sync.
	--
	maxProcesses = 1,

	-----
	-- Try not to have more than these delays.
	-- not too large, since total calculation for stacking 
	-- events is n*log(n) or so..
	--
	maxDelays = 1000,

	-----
	-- a default rsync configuration for easy usage.
	--
	rsync = default_rsync,
	
	-----
	-- a default rsync configuration with ssh'd move and rm actions
	--
	rsyncssh = default_rsyncssh,

	-----
	-- Minimum seconds between two writes of a status file.
	--
	statusIntervall = 10,
}

-----
-- Returns the core the runners function interface.
--
return runner
