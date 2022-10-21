local parse_struct_tag = function(raw_struct_tag)
  assert(type(raw_struct_tag) == "string", "error expecting a string")

  local elems = {}
  for raw_tag in raw_struct_tag:gmatch("[^` ]+") do
    local elem = Elem:new_from_raw(raw_tag)
    elems[elem.key] = elem
  end

  return elems
end

local StructTag = {}
function StructTag:new(raw_struct_tag)
  local o = parse_struct_tag(raw_struct_tag)
  setmetatable(o, self)
  self.__index = self
  return o
end

function StructTag:get(key)
  return self[key]
end

function StructTag:add(key, value)
  if not self[key] then
    local elem = Elem:new(key, { value })
    self[key] = elem
    return self
  end

  self[key]:add(value)

  return self
end

function StructTag:remove(key)
  if not self[key] then
    return self
  end

  self[key] = nil

  return self
end

function StructTag:raw()
  local raw_elem = {}
  for _, elem in pairs(self) do
    table.insert(raw_elem, elem:raw())
  end

  local inner = table.concat(raw_elem, " ")
  if not inner or inner == "" then
    return ""
  end

  return "`" .. inner .. "`"
end

Elem = {
  key = "",
  -- options is a list of string values
  options = {},
}

function Elem:new(key, options)
  local o = {
    key = key,
    options = options,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

function Elem:new_from_raw(raw)
  assert(type(raw) == "string", "error expecting a string")

  local key = raw:match("[^\\:]+")
  if not key then
    key = ""
  end

  local raw_options = raw:match("[^\\\"]+", key:len() + 2)
  if not raw_options then
    raw_options = ""
  end

  local options = {}
  for opt in raw_options:gmatch("[^,]+") do
    table.insert(options, opt)
  end

  local o = {
    key = key,
    options = options,
  }
  setmetatable(o, self)
  self.__index = self

  return o
end

function Elem:add(option)
  table.insert(self.options, option)
end

function Elem:raw()
  if not self.options then
    return self.key
  end

  return self.key .. ":\"" .. table.concat(self.options, ",") .. "\""
end

local st = {
  StructTag = StructTag,
  Elem = Elem,
}

local tsutils = require('nvim-treesitter.ts_utils')
local api = vim.api

-- Gets the treesitter root node of a buffer.
local function get_root(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "go", {})
  local tree = parser:parse()[1]

  return tree:root()
end

local structs_query = vim.treesitter.parse_query('go', [[ (struct_type) @struct ]])
local fields_query = vim.treesitter.parse_query('go', [[ 
  (field_declaration_list
    (field_declaration) @field
  )
  ]])

local field_name_query = vim.treesitter.parse_query('go', [[ 
  (field_declaration
    name: (field_identifier) @name
  )
  ]])

local field_tag_query = vim.treesitter.parse_query('go', [[ 
  (field_declaration
    tag: (raw_string_literal) @tag
  )
  ]])

local function get_current_struct(bufnr)
  local cursor = api.nvim_win_get_cursor(0)
  local root = get_root(bufnr)

  -- select the struct under the cursor, if there is one
  local curr_struct = nil
  for _, node in structs_query:iter_captures(root, bufnr, 0, -1) do
    if tsutils.is_in_node_range(node, cursor[1] - 1, cursor[2]) then
      curr_struct = node
      break
    end
  end

  return curr_struct
end

local function get_current_field()
  local curr_node = tsutils.get_node_at_cursor(0)

  local find_field_declaration
  find_field_declaration = function(node)
    local parent = node:parent()
    if not parent then
      return nil
    end

    if parent:type() == "field_declaration" then
      return parent
    end

    return find_field_declaration(parent)
  end

  return find_field_declaration(curr_node)
end

local function get_field_name(node --[[tsnode]] , bufnr)
  for _, name in field_name_query:iter_captures(node, bufnr) do
    return vim.treesitter.get_node_text(name, bufnr)
  end
end

local function remove_tag_from_field(bufnr, node, tag_name)
  local tag_nodes = node:field("tag")
  -- if there is a tag in the field.
  if tag_nodes[1] then
    local n = tag_nodes[1]
    local start_row, start_col, end_row, end_col = n:range()

    -- if there is not tag_name, remove all tags.
    if not tag_name then
      api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, {})
      return
    end

    local raw_tag = vim.treesitter.get_node_text(n, bufnr)
    local parsedTag = st.StructTag:new(raw_tag)

    local new_raw = parsedTag:remove(tag_name):raw()
    api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, { new_raw })

    return
  end
end

local function add_tag_to_field_declaration(bufnr, node, tag_name, tag_value_callback)
  local tag_value = tag_value_callback(get_field_name(node, bufnr))

  local tag_nodes = node:field("tag")
  -- if there is a tag in the field
  if tag_nodes[1] then
    local n = tag_nodes[1]
    local start_row, start_col, end_row, end_col = n:range()

    local raw_tag = vim.treesitter.get_node_text(n, bufnr)
    local parsed = st.StructTag:new(raw_tag)

    local new_raw = parsed:add(tag_name, tag_value):raw()
    api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, { new_raw })

    return
  end

  local row, col = node:end_()
  local tag = ' `' .. tag_name .. ':"' .. tag_value .. '"' .. '`'
  api.nvim_buf_set_text(bufnr, row, col, row, col, { tag })
end

-- Adds an element to all field tags in the struct.
-- elem_name  - name of the tag element.
-- elem_value - (string | function(field_name) string)
--            - string -> sets directy the element value
--              function(field_name) string -> sets the element tag value as
--                the value returned by the callback function. The callback function
--                recives the current field name as the first parameter.
local function add_elem_tag_to_field(elem_name, elem_value)
  local bufnr = api.nvim_get_current_buf()
  local curr_struct = get_current_struct(bufnr)

  -- not inside a struct...
  if not curr_struct then
    print("sorry, not inside a struct declaration...")
    return
  end

  local curr_field = get_current_field()
  if not curr_field then
    print("sorry, not inside a struct field declaration...")
    return
  end

  add_tag_to_field_declaration(bufnr, curr_field, elem_name, elem_value)
end

-- Adds an element to all field tags in the struct.
-- elem_name  - name of the tag element.
-- elem_value - (string | function(field_name) string)
--              string -> sets directy the element value
--              function(field_name) string -> sets the element tag value as
--                the value returned by the callback function. The callback function
--                recives the field name as the first parameter.
local function add_elem_tag_to_struct(elem_name, elem_value)
  local bufnr = api.nvim_get_current_buf()
  local curr_struct = get_current_struct(bufnr)

  -- not inside a struct...
  if curr_struct == nil then
    print("sorry, not inside a struct declaration...")
    return
  end

  local callback = elem_value
  if type(elem_value) == "string" then
    callback = function() return elem_value end
  end

  for _, field_line in fields_query:iter_captures(curr_struct, bufnr) do
    add_tag_to_field_declaration(bufnr, field_line, elem_name, callback)
  end
end

-- Removes a tag elem from a struct tag.
-- bufnr     - buffer number.
-- node      - root ts node of the struct.
-- elem_name - optional - tag element name that should be removed from the tag. If name is not passed all elements are removed.
local function remove_tag_elem_from_struct(bufnr, node, elem_name)
  for _, tag_node in field_tag_query:iter_captures(node, bufnr) do
    local start_row, start_col, end_row, end_col = tag_node:range()

    if not elem_name then
      api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, {})
      goto continue
    end

    local raw_tag = vim.treesitter.get_node_text(tag_node, bufnr)
    local parsedTag = st.StructTag:new(raw_tag)

    local new_raw = parsedTag:remove(elem_name):raw()
    api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, { new_raw })

    ::continue::
  end
end

-- Removes elements (or the whole tag) of the struct under the cursor.
-- elem_name - optional - If name is not passed all elements are removed.
local function remove_from_struct_tag(elem_name)
  local bufnr = api.nvim_get_current_buf()
  local curr_struct = get_current_struct(bufnr)

  -- not inside a struct...
  if curr_struct == nil then
    print("sorry, not inside a struct declaration...")
    return
  end

  remove_tag_elem_from_struct(bufnr, curr_struct, elem_name)
end

-- Remove elements (or the whole tag) fo the field under the cursor.
-- elem_name - optional - If name is not passed all elements are removed.
local function remove_from_field_tag(elem_name)
  local bufnr = api.nvim_get_current_buf()
  local curr_struct = get_current_struct(bufnr)

  -- not inside a struct...
  if not curr_struct then
    print("sorry, not inside a struct declaration...")
    return
  end

  local curr_field = get_current_field()
  if not curr_field then
    print("sorry, not inside a struct field declaration...")
    return
  end

  remove_tag_from_field(bufnr, curr_field, elem_name)
end

local M = {
  remove_from_field_tag = remove_from_field_tag,
  remove_from_struct_tag = remove_from_struct_tag,
  add_to_field_tag = add_elem_tag_to_field,
  add_to_struct_tag = add_elem_tag_to_struct,
}

return M
