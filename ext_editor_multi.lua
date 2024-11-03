--[[
  ext_editor_multi.lua - edit current selection with external editors

  darktable is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.
  
  darktable is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.
  
  You should have received a copy of the GNU General Public License
  along with darktable.  If not, see <http://www.gnu.org/licenses/>.
]]

--[[
ext_editor_multi.lua - edit current selection with external editors

This script provides helpers to edit selection with programs external to darktable. It adds:
  - a new module "edit selection externally", visible in lightable, to select a program from a list 
  - of up to 9 external editors and run it on a selected image (adjust this limit by changing MAX_EDITORS)
  - a set of lua preferences in order to configure name and path of up to 9 external editors

Based on ext_editor script by Marco Carrarini <marco.carrarini@gmail.com>
USAGE
* require this script from main lua file

-- setup --
  * in "preferences/lua options" configure name and path/command of external programs
  * note that if a program name is left empty, that and all following entries will be ignored

-- use --
  * in lighttable, select images for editing with en external program 
  * in external editors GUI, select program and press "edit"
  * edit the images with the external editor
  * if editors produce an output file, it is not automatically imported into the collection.

* warning: mouseover on lighttable/filmstrip will prevail on current image
* this is the default DT behavior, not a bug of this script

]]


local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local dtsys = require "lib/dtutils.system"


-- module name
local MODULE_NAME = "ext_editor_multi"
du.check_min_api_version("7.0.0", MODULE_NAME) 

-- translation
local gettext = dt.gettext.gettext

dt.gettext.bindtextdomain("ext_editor_multi", dt.configuration.config_dir .."/lua/locale/")

local function _(msgid)
  return gettext(msgid)
end

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = "ext_editor_multi",
  purpose = _("edit selection with external editors"),
  author = "Krzysztof Kotowicz <kkotowicz@gmail.com>",
}

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil -- only required for libs since the destroy_method only hides them

-- OS compatibility
local PS = dt.configuration.running_os == "windows" and  "\\"  or  "/"

-- namespace
local ee = {}
ee.module_installed = false
ee.event_registered = false
ee.widgets = {}


-- maximum number of external programs, can be increased to necessity
local MAX_EDITORS = 9

-- number of valid entries in the list of external programs
local n_entries

-- last used editor initialization
if not dt.preferences.read(MODULE_NAME, "initialized", "bool") then
  dt.preferences.write(MODULE_NAME, "lastchoice", "integer", 0)
  dt.preferences.write(MODULE_NAME, "initialized", "bool", true)
end 
local lastchoice = 0


-- update lists of program names and paths, as well as combobox ---------------
local function UpdateProgramList(combobox, button_edit, update_button_pressed) 

  -- initialize lists
  program_names = {}
  program_paths = {}

  -- build lists from preferences
  local name
  local last = false
  n_entries = 0
  for i = 1, MAX_EDITORS do
    name = dt.preferences.read(MODULE_NAME, "program_name_"..i, "string")
    if (name == "" or name == nil) then last = true end
    if last then 
      if combobox[n_entries + 1] then combobox[n_entries + 1] = nil end -- remove extra combobox entries
    else 
      combobox[i] = i..": "..name
      program_names[i] = name
      program_paths[i] = df.sanitize_filename(dt.preferences.read(MODULE_NAME, "program_path_"..i, "string"))
      n_entries = i
    end
  end 

  lastchoice = dt.preferences.read(MODULE_NAME, "lastchoice", "integer")
  if lastchoice == 0 and n_entries > 0 then lastchoice = 1 end
  if lastchoice > n_entries then lastchoice = n_entries end
  dt.preferences.write(MODULE_NAME, "lastchoice", "integer", lastchoice)

  -- widgets enabled if there is at least one program configured
  combobox.selected = lastchoice 
  local active = n_entries > 0
  combobox.sensitive = active
  button_edit.sensitive = active

  if update_button_pressed then dt.print(string.format(_("%d editors configured"), n_entries)) end
end


-- callback for buttons "edit"  ------------------------------
local function OpenWith(images, choice) 
    
  -- check choice is valid, return if not
  if choice > n_entries then
    dt.print(_("not a valid choice"))
    return
  end

  -- check if at least one image is selected, return if not
  if #images == 0 then
    dt.print(_("please make a selection"))
    return
  end
  
  local bin = program_paths[choice]
  local friendly_name = program_names[choice]

  -- On MacOS, support both application packages, and binaries.
  if dt.configuration.running_os == "macos" and df.get_filetype(bin) == "app" then bin = "open -a "..bin end

  -- images to be edited
  local run_cmd = bin
  for _, image in pairs(images) do
    local name = image.path..PS..image.filename
    -- launch the external editor, check result, return if error
    run_cmd = run_cmd.." "..df.sanitize_filename(name)
  end

  dt.print(string.format(_("launching %s..."), friendly_name))
  dt.print_log("cmd is " .. run_cmd)

  local result = dtsys.external_command(run_cmd)
  if result ~= 0 then
    dt.print(string.format(_("error launching %s"), friendly_name))
    return
  end
end

-- install the module in the UI -----------------------------------------------
local function install_module()
  
  local views = {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 90}}
  
  if not ee.module_installed then
    -- register new module "external editors" in lighttable --
    dt.register_lib(
      MODULE_NAME,          
      _("external editors (multi)"),
      true, -- expandable
      false,  -- resetable
      views,
      dt.new_widget("box") {
        orientation = "vertical",
        table.unpack(ee.widgets),
        },
      nil,  -- view_enter
      nil   -- view_leave
      )
    ee.module_installed = true
  end
end

local function destroy()
  dt.gui.libs[MODULE_NAME].visible = false
end

local function restart()
  dt.gui.libs[MODULE_NAME].visible = true
end

local function show()
  dt.gui.libs[MODULE_NAME].visible = true
end


-- combobox, with variable number of entries ----------------------------------
local combobox = dt.new_widget("combobox") {
  label = _("choose program"), 
  tooltip = _("select the external editor from the list"),
  changed_callback = function(self)
    dt.preferences.write(MODULE_NAME, "lastchoice", "integer", self.selected)
    end,
  ""
}


-- button edit ----------------------------------------------------------------
local button_edit = dt.new_widget("button") {
  label = _("edit selection"),
  tooltip = _("open the selection in external editor"),
  --sensitive = false,
  clicked_callback = function()
    OpenWith(dt.gui.action_images, combobox.selected, false)
  end
}


-- button update list ---------------------------------------------------------
local button_update_list = dt.new_widget("button") {
  label = _("update list"),
  tooltip = _("update list of programs if lua preferences are changed"),
  clicked_callback = function()
    UpdateProgramList(combobox, button_edit, true)
  end
}


-- box for the buttons --------------------------------------------------------
-- it doesn't seem there is a way to make the buttons equal in size
local box1 = dt.new_widget("box") {
  orientation = "horizontal",
  button_edit,
  button_update_list
}


-- table with all the widgets --------------------------------------------------
table.insert(ee.widgets, combobox)
table.insert(ee.widgets, box1)


-- register new module, but only when in lighttable ----------------------------
if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  if not ee.event_registered then
    dt.register_event(
      MODULE_NAME, "view-changed",
      function(event, old_view, new_view)
        if new_view.name == "lighttable" and old_view.name == "darkroom" then
          install_module()
         end
      end
    )
    ee.event_registered = true
  end
end


-- initialize list of programs and widgets ------------------------------------ 
UpdateProgramList(combobox, button_edit, false) 

-- register the new preferences -----------------------------------------------
for i = MAX_EDITORS, 1, -1 do
  dt.preferences.register(MODULE_NAME, "program_path_"..i, "file", 
  string.format(_("executable for external editor %d"), i), 
  _("select executable for external editor")  , _("(none)"))
  
  dt.preferences.register(MODULE_NAME, "program_name_"..i, "string", 
  string.format(_(MODULE_NAME..": name of external editor %d"), i), 
  _("friendly name of external editor"), "")
end

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = show

return script_data

-- end of script --------------------------------------------------------------

-- vim: shiftwidth=2 expandtab tabstop=2 cindent syntax=lua
-- kate: hl Lua;
