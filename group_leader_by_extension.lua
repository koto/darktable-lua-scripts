--[[

    group_leader_by_extension.lua - Make images with chosen extension group leaders

    Copyright (C) 2024 Bill Ferguson <wpferguson@gmail.com>.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]
--[[
group_leader_by_extension - Make images with a chosen extension group leaders

For all selected images, check for image groups where there 
and make the image with the selected extension the group leader.  

Based on jpg_group_leader script by Bill Ferguson <wpferguson@gmail.com>

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
None

USAGE
Start script from script_manager
Assign keys to the shortcuts

BUGS, COMMENTS, SUGGESTIONS
Krzysztof Kotowicz <kkotowicz@gmail.com>
]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"


-- - - - - - - - - - - - - - - - - - - - - - - - 
-- C O N S T A N T S
-- - - - - - - - - - - - - - - - - - - - - - - - 

local MODULE = "group_leader_by_extension"

-- - - - - - - - - - - - - - - - - - - - - - - - 
-- A P I  C H E C K
-- - - - - - - - - - - - - - - - - - - - - - - - 

du.check_min_api_version("7.0.0", MODULE) 


-- - - - - - - - - - - - - - - - - - - - - - - - - -
-- I 1 8 N
-- - - - - - - - - - - - - - - - - - - - - - - - - -

local gettext = dt.gettext.gettext

dt.gettext.bindtextdomain(MODULE, dt.configuration.config_dir .."/lua/locale/")

local function _(msgid)
    return gettext(msgid)
end

-- - - - - - - - - - - - - - - - - - - - - - - - - -
-- S C R I P T  M A N A G E R  I N T E G R A T I O N
-- - - - - - - - - - - - - - - - - - - - - - - - - -

local script_data = {}

script_data.metadata = {
  name = MODULE,
  purpose = _("Make images with chosen extension group leaders"),
  author = "Krzysztof Kotowicz <kkotowicz@gmail.com>",
}

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil -- only required for libs since the destroy_method only hides them


-- - - - - - - - - - - - - - - - - - - - - - - - 
-- P R E F E R E N C E S
-- - - - - - - - - - - - - - - - - - - - - - - - 

dt.preferences.register(MODULE, "group_leader_extension", "string", MODULE .. ":" .. _("extension to make a group leader"), _("make this extension a group leader for grouped images in a selection"), "jpg")

-- - - - - - - - - - - - - - - - - - - - - - - - 
-- N A M E  S P A C E
-- - - - - - - - - - - - - - - - - - - - - - - - 

local jgloi = {}
jgloi.images = {}

-- - - - - - - - - - - - - - - - - - - - - - - - 
-- F U N C T I O N S
-- - - - - - - - - - - - - - - - - - - - - - - - 

local function toggle_global_toolbox_grouping()
  dt.gui.libs.global_toolbox.grouping = false
  dt.gui.libs.global_toolbox.grouping = true
end

-- - - - - - - - - - - - - - - - - - - - - - - - 
-- M A I N  P R O G R A M
-- - - - - - - - - - - - - - - - - - - - - - - - 

local function maybe_make_a_group_leader(image, extension)
  -- Only process images with a chosen extension that are not already group leaders.
  if string.lower(df.get_filetype(image.filename)) ~= extension then return end
  if #image:get_group_members() <= 1 then return end
  if image.group_leader.id == image.id then return end

  for _, member in ipairs(image:get_group_members()) do
    if member.id == image.id then goto continue end
    -- If a group already has another image with the same extension, skip
    if string.lower(df.get_filetype(member.filename)) == extension then
      dt.print_log("skipping " .. image.filename .. " as a group leader, as " .. member.filename .. " also has that file extension")
      return
    end
    ::continue::
  end
  dt.print_log("setting " ..image.filename .. " as a group leader")
  image:make_group_leader()
end

local function make_existing_extension_group_leader(images)
  local extension = dt.preferences.read(MODULE, "group_leader_extension", "string")
  for _, image in ipairs(images) do
    maybe_make_a_group_leader(image, extension)
  end
  if dt.gui.libs.global_toolbox.grouping then
    -- toggle the grouping to make the new leader show
    toggle_global_toolbox_grouping()
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - 
-- D A R K T A B L E  I N T E G R A T I O N 
-- - - - - - - - - - - - - - - - - - - - - - - - 

dt.gui.libs.image.register_action(
  MODULE, dt.preferences.read(MODULE, "group_leader_extension", "string") .. _(" to group leaders") ,
  function() make_existing_extension_group_leader(dt.gui.action_images) end,
  _("make files with this extension group leaders")
)

local function destroy()
    dt.gui.libs.image.destroy_action(MODULE)

end

script_data.destroy = destroy

-- - - - - - - - - - - - - - - - - - - - - - - - 
-- E V E N T S
-- - - - - - - - - - - - - - - - - - - - - - - - 

return script_data