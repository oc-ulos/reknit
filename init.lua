--!lua
-- System V-style init

--- Perform a system call
---@param call string
---@vararg any
local function syscall(call, ...)
  local result, err = coroutine.yield("syscall", call, ...)
  if type(err) == "string" then error(err) end
  return result, err
end

---@param fmt string
---@vararg any
local function printf(fmt, ...)
  syscall("write", 1, string.format(fmt, ...))
end

--- Execute a command
---@param cmd string
---@return integer
local function exec(cmd)
  local pid, errno = syscall("fork", function()
    local _, errno = syscall("execve", "/bin/sh.lua", {
      "/bin/sh.lua",
      "-c",
      cmd
    })
    if errno then
      printf("execve failed: %d\n", errno)
      syscall("exit", 1)
    end
  end)
  if not pid then
    printf("fork failed: %d\n", errno)
    return nil, errno
  else
    return pid
  end
end

-- Load a script and execute it with Reknit's environment.
-- Only used internally, mostly for security reasons.
local function exec_script(file)
  local okay, emsg
  if dofile then
    pcall(dofile, file)
  else
    local fd, err = syscall("open", file, "r")
    if not fd then
      printf("open '%s' failed: %d\n", file, err)
      return nil, err
    end

    local data = syscall("read", fd, "a")
    syscall("close", fd)

    local ok, lerr = load(data, "="..file, "t", _G)
    if not ok then
      printf("Load failed - %s\n", lerr)
      return
    else
      okay, emsg = pcall(ok)
    end
  end

  if not okay and emsg then
    printf("Execution failed - %s\n", emsg)
    return
  end

  return true
end

-- Load /lib/package.lua - because where else do you do it?
-- Environments propagate to process children in certain
-- Cynosure configurations, and this is the only real way to
-- ensure that every process has access to the 'package' library.
--
-- This may change in the future.
assert(exec_script("/lib/package.lua"))

---@class InitEntry
---@field id string
---@field runlevels boolean[]
---@field action string
---@field command string

---@type InitEntry[]
local init_table = {}

--- Load `/etc/inittab`
local function load_inittab()
  local fd, errno = syscall("open", "/etc/inittab", "r")
  if not fd then
    printf("Could not open /etc/inittab: %s\n", (
      (errno == 2 and "No such file or directory") or
      tostring(errno)
    ))
    return
  end
  local inittab = syscall("read", fd, "a")
  syscall("close", fd)

  init_table = {}

  for line in inittab:gmatch("[^\r\n]+") do
    if line:sub(1,1) == ":" then
      -- Comment
    elseif line == "" then
      -- Empty line
    else
      local id, runlevels, action, command = line:match("^([^:]+):([^:]+):([^:]+):(.+)$")
      if not id then
        printf("Bad init entry on line %d\n", line)
      else
        local entry = {
          id = id,
          runlevels = {},
          action = action,
          command = command,
        }
        for runlevel in runlevels:gmatch("%d") do
          entry.runlevels[tonumber(runlevel)] = true
        end
        entry.index = #init_table + 1
        init_table[#init_table + 1] = entry
        init_table[entry.id] = entry -- for 'start' and 'stop'
      end
    end
  end
end

load_inittab()

--- List of active init entries with their PID as key
---@type InitEntry[]
local active_entries = {}
--- List of init entries to watch for respawn
---@type InitEntry[]
local respawn_entries = {}
--- A buffer of IPC entries, in case a lot of them get sent at once.
---@type integer[]
local telinit = {}

local Runlevel = -1

--- Start a service described by that entry
---@param entry InitEntry
local function start_service(entry)
  local pid, errno = exec(entry.command)

  if not pid then
    printf("Could not fork for entry %s: %d\n", entry.id, errno)
    return nil, errno
  elseif entry.action == "once" then
    active_entries[pid] = entry
  elseif entry.action == "wait" then
    syscall("wait", pid)
  elseif entry.action == "respawn" then
    respawn_entries[pid] = entry
  end

  -- for 'stop'
  active_entries[entry.id] = pid

  return true
end

--- Stop a service described by that entry
---@param entry InitEntry
local function stop_service(entry)
  local pid = active_entries[entry.id]
  if pid then
    if syscall("kill", pid, "SIGTERM") then
      active_entries[pid] = nil
      respawn_entries[pid] = nil
      active_entries[entry.id] = nil
      return true
    end
  end
end

--- Switch to a new runlevel
---@param runlevel integer
local function switch_runlevel(runlevel)
  Runlevel = runlevel
  for id, entry in pairs(active_entries) do
    if type(id) == "string" then
      if not entry.runlevels[runlevel] then
        stop_service(entry)
      end
    end
  end

  for i, entry in pairs(init_table) do
    if entry.runlevels[runlevel] then
      start_service(entry)
    end
  end
end

switch_runlevel(1) -- Single user mode

local valid_actions = {
  runlevel = true,
  start = true,
  stop = true,
  status = true,
}

local evt, err = syscall("open", "/proc/events", "rw")
if not evt then
  -- The weird formatting here is so it'll fit into 80 character lines.
  printf("init: \27[91mWARNING: Failed to open /proc/events (%d) - %s",
    err, "telinit responses will not work\27[m\n")
end

while true do
  local sig, id, req, a = coroutine.yield()

  if sig == "process_exit" and respawn_entries[id] then
    local entry = respawn_entries[id]

    respawn_entries[id] = nil
    active_entries[id] = nil

    local pid, errno = exec(entry.command)
    if not pid then
      printf("init: Could not fork for entry %s: %d\n", entry.id, errno)
    else
      active_entries[pid] = entry
      respawn_entries[pid] = entry
    end
  elseif sig == "telinit" then
    if type(id) ~= "number" then
      printf("init: Cannot respond to non-numeric PID %s\n", tostring(id))
    elseif not syscall("kill", id, "SIGEXIST") then
      printf("init: Cannot respond to nonexistent process %d\n", id)
    elseif type(req) ~= "string" or not valid_actions[req] then
      printf("init: Got bad telinit %s\n", tostring(req))
    else
      if req == "runlevel" and arg and type(arg) ~= "number" then
        printf("init: Got bad runlevel argument %s\n", tostring(arg))
      elseif req ~= "runlevel" and type(arg) ~= "string" then
        printf("init: Got bad %s argument %s\n", req, tostring(arg))
      else
        telinit[#telinit+1] = {req = req, from = id, arg = a}
      end
    end
  end

  if #telinit > 0 then
    local request = table.remove(telinit, 1)
    if request == "runlevel" then
      if not request.arg then
        syscall("ioctl", evt, "send", request.from, "response", "runlevel",
          Runlevel)
      elseif request.arg ~= Runlevel then
        switch_runlevel(request.arg)
        syscall("ioctl", evt, "send", request.from, "response", "runlevel",
          true)
      end
    elseif request == "start" then
      if active_entries[request.arg] then
        syscall("ioctl", evt, "send", request.from, "response", "start",
          start_service(active_entries[request.arg]))
      end
    elseif request == "stop" then
      if active_entries[request.arg] then
        syscall("ioctl", evt, "send", request.from, "response", "stop",
          stop_service(active_entries[request.arg]))
      end
    end
  end
end
