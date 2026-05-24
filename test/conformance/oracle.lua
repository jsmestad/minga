local scenario_path = arg and arg[1]
vim.o.report = 999999

local function json_encode(value)
  return vim.json.encode(value)
end

local function json_decode(value)
  return vim.json.decode(value)
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local function split_lines(content)
  if content == "" then
    return { "" }
  end

  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  return lines
end

local function set_buffer_content(content)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, split_lines(content))
end

local function set_cursor(cursor)
  local line = math.max((cursor.line or 0) + 1, 1)
  local col = math.max(cursor.col or 0, 0)
  vim.api.nvim_win_set_cursor(0, { line, col })
end

local function capture_content()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return table.concat(lines, "\n")
end

local function capture_window_state(scenario)
  local wins = vim.api.nvim_list_wins()
  local current = vim.api.nvim_get_current_win()
  local window_list = {}

  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
    local first_line = (lines[1] or "")
    local pos = vim.api.nvim_win_get_position(win)

    table.insert(window_list, {
      buffer_first_line = first_line,
      line = cursor[1] - 1,
      col = cursor[2],
      active = (win == current),
      row_pos = pos[1],
      col_pos = pos[2],
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
    })
  end

  table.sort(window_list, function(a, b)
    if a.row_pos ~= b.row_pos then return a.row_pos < b.row_pos end
    return a.col_pos < b.col_pos
  end)

  return {
    name = scenario.name,
    ok = true,
    window_count = #wins,
    windows = window_list,
  }
end

local function run_window_commands(scenario)
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  vim.cmd("setlocal buftype=")
  vim.cmd("setlocal modifiable")
  set_buffer_content(scenario.content or "")
  set_cursor(scenario.cursor or { line = 0, col = 0 })

  for _, cmd in ipairs(scenario.commands or {}) do
    local cmd_ok, cmd_err = pcall(vim.cmd, cmd)
    if not cmd_ok then
      if tostring(cmd_err):find("E444") then
        -- last-window-close rejection is expected behavior, not an error
      else
        error(cmd_err)
      end
    end
  end

  return capture_window_state(scenario)
end

local function keys_exit_insert(keys)
  return keys:find("<Esc>", 1, true) ~= nil or keys:find("<C%-c>") ~= nil or keys:find("<C%-[>") ~= nil
end

local function capture_state(scenario, reported_mode)
  local cursor = vim.api.nvim_win_get_cursor(0)
  return {
    name = scenario.name,
    ok = true,
    line = cursor[1] - 1,
    col = cursor[2],
    content = capture_content(),
    mode = reported_mode or vim.api.nvim_get_mode().mode,
    register = vim.fn.getreg('"'),
    register_type = vim.fn.getregtype('"'),
  }
end

local function run_keys(keys)
  local saw_insert = false
  local group = vim.api.nvim_create_augroup("minga_conformance_mode", { clear = true })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      if vim.v.event.new_mode:sub(1, 1) == "i" then
        saw_insert = true
      end
    end,
  })

  local termcoded = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcoded, "nx", false)
  vim.api.nvim_del_augroup_by_id(group)

  if saw_insert and not keys_exit_insert(keys) then
    return "i"
  end

  return vim.api.nvim_get_mode().mode
end

-- feedkeys with "nx" does not open the search command-line; normal! drives the full /{pattern}<CR> flow.
local function run_search(keys)
  vim.o.wrapscan = true
  local termcoded = vim.api.nvim_replace_termcodes(keys, true, false, true)
  pcall(vim.cmd, "silent! normal! " .. termcoded)
  return vim.api.nvim_get_mode().mode
end

local runners = {
  motion = run_keys,
  operator = run_keys,
  text_object = run_keys,
  search = run_search,
}

local function run_scenario(scenario)
  local ok, result = pcall(function()
    if scenario.type == "window" then
      return run_window_commands(scenario)
    end

    vim.cmd("enew!")
    vim.cmd("setlocal buftype=")
    vim.cmd("setlocal modifiable")
    vim.fn.setreg('"', "")
    set_buffer_content(scenario.content or "")
    set_cursor(scenario.cursor or { line = 0, col = 0 })
    local runner = runners[scenario.type or "motion"] or run_keys
    local reported_mode = runner(scenario.keys or "")
    return capture_state(scenario, reported_mode)
  end)

  if ok then
    return result
  end

  return {
    name = scenario.name,
    ok = false,
    error = tostring(result),
  }
end

if not scenario_path then
  io.stderr:write("usage: nvim --headless --clean -l test/conformance/oracle.lua scenarios.json\n")
  os.exit(2)
end

local scenarios = json_decode(read_file(scenario_path))
for _, scenario in ipairs(scenarios) do
  io.write(json_encode(run_scenario(scenario)) .. "\n")
end

vim.cmd("qa!")
