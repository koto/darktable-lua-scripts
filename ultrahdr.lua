--[[

  UltraHDR image generation for darktable

  copyright (c) 2024  Krzysztof Kotowicz

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

]] --[[

ULTRAHDR
Generate UltraHDR JPEG images from various combinations of source files (SDR, HDR, gain map).

https://developer.android.com/media/platform/hdr-image-format

The images are merged using libultrahdr example application (ultrahdr_app).

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
* ultrahdr_app (built using https://github.com/google/libultrahdr/blob/main/docs/building.md instructions)
* exiftool
* ffmpeg

USAGE
* require this file from your main luarc config file
* set binary tool paths
* Use UltraHDR module to generate UltraHDR images from selection

]] local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local log = require "lib/dtutils.log"
local dtsys = require "lib/dtutils.system"
local dd = require "lib/dtutils.debug"
local gettext = dt.gettext.gettext

local namespace = "module_ultrahdr"

-- works with darktable API version from 4.8.0 on
du.check_min_api_version("9.3.0", "ultrahdr")

dt.gettext.bindtextdomain(namespace, dt.configuration.config_dir .. "/lua/locale/")

local function _(msgid)
    return gettext(msgid)
end

local job

local GUI = {
    optionwidgets = {
        settings_label = {},
        encoding_variant_combo = {},
        selection_type_combo = {},
        encoding_settings_box = {},
        output_settings_label = {},
        output_settings_box = {},
        use_original_directory = {},
        output_directory_widget = {},
        copy_exif = {},
        import_to_darktable = {},
        min_content_boost = {},
        max_content_boost = {},
        hdr_capacity_min = {},
        hdr_capacity_max = {},
        metadata_label = {},
        metadata_box = {},
        edit_executables_button = {},
        executable_path_widget = {},
        quality_widget = {},
        gainmap_downsampling_widget = {},
    },
    options = {},
    run = {}
}

local flags = {}
flags.event_registered = false -- keep track of whether we've added an event callback or not
flags.module_installed = false -- keep track of whether the module is module_installed

local script_data = {}

script_data.metadata = {
    name = "ultrahdr",
    purpose = _("generate UltraHDR images"),
    author = "Krzysztof Kotowicz"
}

local PS = dt.configuration.running_os == "windows" and "\\" or "/"
local ENCODING_VARIANT_SDR_AND_GAINMAP = 1
local ENCODING_VARIANT_SDR_AND_HDR = 2
local ENCODING_VARIANT_SDR_AUTO_GAINMAP = 3

local SELECTION_TYPE_ONE_STACK = 1
local SELECTION_TYPE_GROUP_BY_FNAME = 2

-- Values are defined in darktable/src/common/colorspaces.h
local DT_COLORSPACE_PQ_P3 = 24
local DT_COLORSPACE_DISPLAY_P3 = 26

local function generate_metadata_file(settings)
    local metadata_file_fmt = [[--maxContentBoost %f
--minContentBoost %f
--gamma 1.0
--offsetSdr 0.0
--offsetHdr 0.0
--hdrCapacityMin %f
--hdrCapacityMax %f]]

    local filename = df.create_unique_filename(settings.tmpdir .. PS .. "metadata.cfg")
    local f, err = io.open(filename, "w+")
    if not f then
        dt.print(err)
        return nil
    end
    local content = string.format(metadata_file_fmt, settings.metadata.max_content_boost,
        settings.metadata.min_content_boost, settings.metadata.hdr_capacity_min, settings.metadata.hdr_capacity_max)
    f:write(content)
    f:close()
    return filename
end

local function save_preferences()
    dt.preferences.write(namespace, "encoding_variant", "integer", GUI.optionwidgets.encoding_variant_combo.selected)
    dt.preferences.write(namespace, "selection_type", "integer", GUI.optionwidgets.selection_type_combo.selected)
    dt.preferences.write(namespace, "use_original_directory", "bool", GUI.optionwidgets.use_original_directory.value)
    if GUI.optionwidgets.output_directory_widget.value then
        dt.preferences.write(namespace, "output_directory", "string", GUI.optionwidgets.output_directory_widget.value)
    end
    dt.preferences.write(namespace, "import_to_darktable", "bool", GUI.optionwidgets.import_to_darktable.value)
    dt.preferences.write(namespace, "copy_exif", "bool", GUI.optionwidgets.copy_exif.value)
    if GUI.optionwidgets.min_content_boost.value then
        dt.preferences.write(namespace, "min_content_boost", "float", GUI.optionwidgets.min_content_boost.value)
        dt.preferences.write(namespace, "max_content_boost", "float", GUI.optionwidgets.max_content_boost.value)
        dt.preferences.write(namespace, "hdr_capacity_min", "float", GUI.optionwidgets.hdr_capacity_min.value)
        dt.preferences.write(namespace, "hdr_capacity_max", "float", GUI.optionwidgets.hdr_capacity_max.value)
    end
    dt.preferences.write(namespace, "quality", "integer", GUI.optionwidgets.quality_widget.value)
    dt.preferences.write(namespace, "gainmap_downsampling", "integer", GUI.optionwidgets.gainmap_downsampling_widget.value)
end

local function default_to(value, default)
    if value == 0 then
        return default
    end
    return value
end

local function load_preferences()
    -- Since the option #1 is the default, and empty numeric prefs are 0, we can use math.max
    GUI.optionwidgets.encoding_variant_combo.selected = math.max(
        dt.preferences.read(namespace, "encoding_variant", "integer"), ENCODING_VARIANT_SDR_AND_GAINMAP)
    GUI.optionwidgets.selection_type_combo.selected = math.max(
        dt.preferences.read(namespace, "selection_type", "integer"), SELECTION_TYPE_ONE_STACK)

    GUI.optionwidgets.output_directory_widget.value = dt.preferences.read(namespace, "output_directory", "string")
    GUI.optionwidgets.use_original_directory.value = dt.preferences.read(namespace, "use_original_directory", "bool")
    if not GUI.optionwidgets.output_directory_widget.value then
        GUI.optionwidgets.use_original_directory.value = true
    end
    GUI.optionwidgets.import_to_darktable.value = dt.preferences.read(namespace, "import_to_darktable", "bool")
    GUI.optionwidgets.copy_exif.value = dt.preferences.read(namespace, "copy_exif", "bool")
    GUI.optionwidgets.min_content_boost.value = default_to(dt.preferences.read(namespace, "min_content_boost", "float"),
        1.0)
    GUI.optionwidgets.max_content_boost.value = default_to(dt.preferences.read(namespace, "max_content_boost", "float"),
        6.0)
    GUI.optionwidgets.hdr_capacity_min.value = default_to(dt.preferences.read(namespace, "hdr_capacity_min", "float"),
        1.0)
    GUI.optionwidgets.hdr_capacity_max.value = default_to(dt.preferences.read(namespace, "hdr_capacity_max", "float"),
        6.0)
    GUI.optionwidgets.quality_widget.value = default_to(dt.preferences.read(namespace, "quality", "integer"), 95)
    GUI.optionwidgets.gainmap_downsampling_widget.value = default_to(dt.preferences.read(namespace, "gainmap_downsampling", "integer"), 0)
end

-- Changes the combobox selection blindly until a paired config value is set.
-- Workaround for https://github.com/darktable-org/lua-scripts/issues/522
local function set_combobox(path, instance, config_name, new_config_value)

    local pref = dt.preferences.read("darktable", config_name, "integer")
    if pref == new_config_value then
        return new_config_value
    end

    dt.gui.action(path, 0, "selection", "first", 1.0)
    local limit, i = 30, 0 -- in case there is no matching config value in the first n entries of a combobox.
    while i < limit do
        i = i + 1
        dt.gui.action(path, 0, "selection", "next", 1.0)
        dt.control.sleep(10)
        if dt.preferences.read("darktable", config_name, "integer") == new_config_value then
            log.msg(log.debug, string.format(_("Changed %s from %d to %d"), config_name, pref, new_config_value))
            return pref
        end
    end
    log.msg(log.error, string.format(_("Could not change %s from %d to %d"), config_name, pref, new_config_value))
end

local function assert_settings_correct(encoding_variant)
    local errors = {}
    local settings = {
        bin = {
            ultrahdr_app = df.check_if_bin_exists("ultrahdr_app"),
            exiftool = df.check_if_bin_exists("exiftool"),
            ffmpeg = df.check_if_bin_exists("ffmpeg")
        },
        output = GUI.optionwidgets.output_directory_widget.value,
        use_original_dir = GUI.optionwidgets.use_original_directory.value,
        import_to_darktable = GUI.optionwidgets.import_to_darktable.value,
        copy_exif = GUI.optionwidgets.copy_exif.value,
        metadata = {
            min_content_boost = GUI.optionwidgets.min_content_boost.value,
            max_content_boost = GUI.optionwidgets.max_content_boost.value,
            hdr_capacity_min = GUI.optionwidgets.hdr_capacity_min.value,
            hdr_capacity_max = GUI.optionwidgets.hdr_capacity_max.value
        },
        quality = GUI.optionwidgets.quality_widget.value,
        downsample = 2^GUI.optionwidgets.gainmap_downsampling_widget.value,
        tmpdir = dt.configuration.tmp_dir,
        skip_cleanup = false -- keep temporary files around, for debugging.
    }

    if not settings.use_original_dir and (not settings.output or not df.check_if_file_exists(settings.output)) then
        table.insert(errors, string.format(_("output directory (%s) not found"), settings.output))
    end

    for k, v in pairs(settings.bin) do
        if not v then
            table.insert(errors, string.format(_("%s binary not found"), k))
        end
    end

    if encoding_variant == ENCODING_VARIANT_SDR_AND_GAINMAP or encoding_variant == ENCODING_VARIANT_SDR_AUTO_GAINMAP then
        if settings.metadata.min_content_boost >= settings.metadata.max_content_boost then
            table.insert(errors, _("min_content_boost should not be greater than max_content_boost"))
        end
        if settings.metadata.hdr_capacity_min >= settings.metadata.hdr_capacity_max then
            table.insert(errors, _("hdr_capacity_min should not be greater than hdr_capacity_max"))
        end
    end

    if #errors > 0 then
        return nil, errors
    end
    return settings, nil
end

local function get_dimensions(image)
    if image.final_width > 0 then
        return image.final_width, image.final_height
    end
    return image.width, image.height
end

local function get_stacks(images, encoding_variant, selection_type)
    local stacks = {}
    local extra_image_content_type
    if encoding_variant == ENCODING_VARIANT_SDR_AND_GAINMAP then
        extra_image_content_type = "gainmap"
    elseif encoding_variant == ENCODING_VARIANT_SDR_AND_HDR then
        extra_image_content_type = "hdr"
    elseif encoding_variant == ENCODING_VARIANT_SDR_AUTO_GAINMAP then
        extra_image_content_type = nil
    end

    local tags = nil
    -- Group images into (sdr [,extra]) stacks
    -- Assume that the first encountered image from each stack is an sdr one, unless it has a tag matching the expected extra_image_type, or has the expected extension
    for k, v in pairs(images) do
        local is_extra = false
        tags = dt.tags.get_tags(v)
        for ignore, tag in pairs(tags) do
            if extra_image_content_type and tag.name == extra_image_content_type then
                is_extra = true
            end
        end
        if extra_image_extension and df.get_filetype(v.filename) == extra_image_extension then
            is_extra = true
        end
        -- We assume every image in the stack is generated from the same source image file
        local key
        if selection_type == SELECTION_TYPE_GROUP_BY_FNAME then
            key = df.chop_filetype(v.path .. PS .. v.filename)
        elseif selection_type == SELECTION_TYPE_ONE_STACK then
            key = "the_one_and_only"
        end
        if stacks[key] == nil then
            stacks[key] = {}
        end
        if extra_image_content_type and (is_extra or stacks[key]["sdr"]) then
            -- Don't overwrite existing entries
            if not stacks[key][extra_image_content_type] then
                stacks[key][extra_image_content_type] = v
            end
        elseif not is_extra then
            -- Don't overwrite existing entries
            if not stacks[key]["sdr"] then
                stacks[key]["sdr"] = v
            end
        end
    end
    -- remove invalid stacks
    local count = 0
    for k, v in pairs(stacks) do
        if extra_image_content_type then
            if not v["sdr"] or not v[extra_image_content_type] then
                stacks[k] = nil
            else
                local sdr_w, sdr_h = get_dimensions(v["sdr"])
                local extra_w, extra_h = get_dimensions(v[extra_image_content_type])
                if (sdr_w ~= extra_w) or (sdr_h ~= extra_h) then
                    stacks[k] = nil
                end
            end
        end
        if stacks[k] then
            count = count + 1
        end
    end
    return stacks, count
end

local function stop_job(job)
    job.valid = false
end

local function file_size(path)
    local f, err = io.open(path, "r")
    if not f then
        return 0
    end
    local size = f:seek("end")
    f:close()
    return size
end

local function generate_ultrahdr(encoding_variant, images, settings, step, total_steps)
    local total_substeps
    local substep = 0
    local uhdr
    local errors = {}
    local remove_files = {}
    local ok
    local cmd

    local function execute_cmd(cmd, errormsg)
        log.msg(log.debug, cmd)
        local code = dtsys.external_command(cmd)
        if errormsg and code > 0 then
            table.insert(errors, errormsg)
        end
        return code == 0
    end

    function update_job_progress()
        substep = substep + 1
        if substep > total_substeps then
            log.msg(log.debug,
                string.format("total_substeps count is too low for encoding_variant %d", encoding_variant))
        end
        job.percent = (total_substeps * step + substep) / (total_steps * total_substeps)
    end

    function copy_or_export(src_image, dest, format, colorspace, props)
        if df.get_filetype(src_image.filename) == df.get_filetype(dest) and not src_image.is_altered then
            return df.file_copy(src_image.path .. PS .. src_image.filename, dest)
        else
            local prev = set_combobox("lib/export/profile", 0, "plugins/lighttable/export/icctype", colorspace)
            if not prev then
                return false
            end
            local exporter = dt.new_format(format)
            for k, v in pairs(props) do
                exporter[k] = v
            end
            local ok = exporter:write_image(src_image, dest)
            if dt.configuration.api_version_string == "9.3.0" then
                -- Workaround for https://github.com/darktable-org/darktable/issues/17528
                ok = not ok
            end

            if prev then
                set_combobox("lib/export/profile", 0, "plugins/lighttable/export/icctype", prev)
            end
            return ok
        end
        return true
    end

    function cleanup()
        if settings.skip_cleanup then
            return false
        end
        for _, v in pairs(remove_files) do
            os.remove(v)
        end
        return false
    end

    if encoding_variant == ENCODING_VARIANT_SDR_AND_GAINMAP or encoding_variant == ENCODING_VARIANT_SDR_AUTO_GAINMAP then
        total_substeps = 5
        -- Export/copy both SDR and gainmap to JPEGs
        local sdr = df.create_unique_filename(settings.tmpdir .. PS .. df.chop_filetype(images["sdr"].filename) ..
                                                  ".jpg")
        table.insert(remove_files, sdr)
        ok = copy_or_export(images["sdr"], sdr, "jpeg", DT_COLORSPACE_DISPLAY_P3, {
            quality = settings.quality
        })
        if not ok then
            table.insert(errors, string.format(_("Error exporting %s to %s"), images["sdr"].filename, "jpeg"))
            return cleanup(), errors
        end

        local gainmap
        if encoding_variant == ENCODING_VARIANT_SDR_AUTO_GAINMAP then -- SDR is also a gainmap
            gainmap = sdr
        else
            gainmap = df.create_unique_filename(settings.tmpdir .. PS .. images["gainmap"].filename .. "_gainmap.jpg")
            table.insert(remove_files, gainmap)
            ok = copy_or_export(images["gainmap"], gainmap, "jpeg", DT_COLORSPACE_DISPLAY_P3, {
                quality = settings.quality
            })
            if not ok then
                table.insert(errors, string.format(_("Error exporting %s to %s"), images["gainmap"].filename, "jpeg"))
                return cleanup(), errors
            end
        end
        log.msg(log.debug, string.format(_("Exported files: %s, %s"), sdr, gainmap))
        update_job_progress()
        -- Strip EXIFs
        table.insert(remove_files, sdr .. ".noexif")
        cmd = settings.bin.exiftool .. " -all= " .. df.sanitize_filename(sdr) .. " -o " ..
                  df.sanitize_filename(sdr .. ".noexif")
        if not execute_cmd(cmd, string.format(_("Error stripping EXIF from %s"), sdr)) then
            return cleanup(), errors
        end
        if sdr ~= gainmap then
            if not execute_cmd(settings.bin.exiftool .. " -all= " .. df.sanitize_filename(gainmap) ..
                                   " -overwrite_original", string.format(_("Error stripping EXIF from %s"), gainmap)) then
                return cleanup(), errors
            end
        end
        update_job_progress()
        -- Generate metadata.cfg file
        local metadata_file = generate_metadata_file(settings)
        table.insert(remove_files, metadata_file)
        -- Merge files
        uhdr = df.chop_filetype(sdr) .. "_ultrahdr.jpg"
        table.insert(remove_files, uhdr)
        cmd = settings.bin.ultrahdr_app .. " -m 0 -i " .. df.sanitize_filename(sdr .. ".noexif") .. " -g " ..
                  df.sanitize_filename(gainmap) .. " -f " .. df.sanitize_filename(metadata_file) .. " -z " ..
                  df.sanitize_filename(uhdr)
        if not execute_cmd(cmd, string.format(_("Error merging UltraHDR to %s"), uhdr)) then
            return cleanup(), errors
        end
        update_job_progress()
        -- Copy SDR's EXIF to UltraHDR file
        if settings.copy_exif then
            -- Restricting tags to EXIF only, to make sure we won't mess up XMP tags (-all>all).
            -- This might hapen e.g. when the source files are Adobe gainmap HDRs.
            cmd = settings.bin.exiftool .. " -tagsfromfile " .. df.sanitize_filename(sdr) .. " -exif " ..
                      df.sanitize_filename(uhdr) .. " -overwrite_original -preserve"
            if not execute_cmd(cmd, string.format(_("Error adding EXIF to %s"), uhdr)) then
                return cleanup(), errors
            end
        end
        update_job_progress()
    elseif encoding_variant == ENCODING_VARIANT_SDR_AND_HDR then
        total_substeps = 6
        -- https://discuss.pixls.us/t/manual-creation-of-ultrahdr-images/45004/20
        -- Step 1: Export HDR to JPEG-XL with DT_COLORSPACE_PQ_P3
        local hdr = df.create_unique_filename(settings.tmpdir .. PS .. df.chop_filetype(images["hdr"].filename) ..
                                                  ".jxl")
        table.insert(remove_files, hdr)
        ok = copy_or_export(images["hdr"], hdr, "jpegxl", DT_COLORSPACE_PQ_P3, {
            bpp = 10,
            quality = 100, -- lossless
            effort = 1 -- we don't care about the size, the file is temporary.
        })
        if not ok then
            table.insert(errors, string.format(_("Error exporting %s to %s"), images["hdr"].filename, "jxl"))
            return cleanup(), errors
        end
        update_job_progress()
        -- Step 2: Export SDR to PNG
        local sdr = df.create_unique_filename(settings.tmpdir .. PS .. df.chop_filetype(images["sdr"].filename) ..
                                                  ".png")
        table.insert(remove_files, sdr)
        ok = copy_or_export(images["sdr"], sdr, "png", DT_COLORSPACE_DISPLAY_P3, {
            bpp = 8
        })
        if not ok then
            table.insert(errors, string.format(_("Error exporting %s to %s"), images["sdr"].filename, "png"))
            return cleanup(), errors
        end
        uhdr = df.chop_filetype(sdr) .. "_ultrahdr.jpg"
        table.insert(remove_files, uhdr)
        update_job_progress()
        -- Step 3: Generate libultrahdr RAW images
        local sdr_raw, hdr_raw = sdr .. ".raw", hdr .. ".raw"
        table.insert(remove_files, sdr_raw)
        table.insert(remove_files, hdr_raw)
        local sdr_w, sdr_h = get_dimensions(images["sdr"])
        local resize_cmd = ""
        if sdr_h % 2 + sdr_w % 2 > 0 then -- needs resizing to even dimensions.
            resize_cmd = string.format(" -vf 'crop=%d:%d:0:0' ", sdr_w - sdr_w % 2, sdr_h - sdr_h % 2)
        end
        local size_in_px = (sdr_w - sdr_w % 2) * (sdr_h - sdr_h % 2)
        cmd =
            settings.bin.ffmpeg .. " -i " .. df.sanitize_filename(sdr) .. resize_cmd .. " -pix_fmt rgba -f rawvideo " ..
                df.sanitize_filename(sdr_raw)
        if not execute_cmd(cmd, string.format(_("Error generating %s"), sdr_raw)) then
            return cleanup(), errors
        end
        cmd = settings.bin.ffmpeg .. " -i " .. df.sanitize_filename(hdr) .. resize_cmd ..
                  " -pix_fmt p010le -f rawvideo " .. df.sanitize_filename(hdr_raw)
        if not execute_cmd(cmd, string.format(_("Error generating %s"), hdr_raw)) then
            return cleanup(), errors
        end
        -- sanity check for file sizes (sometimes dt exports different size images if the files were never opened in darktable view)
        if file_size(sdr_raw) ~= size_in_px * 4 or file_size(hdr_raw) ~= size_in_px * 3 then
            table.insert(errors, string.format(_("Wrong raw image resolution: %s, expected %dx%d. Try opening the image in darktable mode first."), images["sdr"].filename, sdr_w, sdr_h))
            return cleanup(), errors
        end
        update_job_progress()
        cmd = settings.bin.ultrahdr_app .. " -m 0 -y " .. df.sanitize_filename(sdr_raw) .. " -p " ..
                  df.sanitize_filename(hdr_raw) ..
                  string.format(" -a 0 -b 3 -c 1 -C 1 -t 2 -M 0 -s 1 -q %d -Q %d -D 1 ", settings.quality,
                settings.quality) .. string.format(" -s %d ", settings.downsample) .. " -w " .. tostring(sdr_w - sdr_w % 2) .. " -h " .. tostring(sdr_h - sdr_h % 2) ..
                  " -z " .. df.sanitize_filename(uhdr)
        if not execute_cmd(cmd, string.format(_("Error merging %s"), uhdr)) then
            return cleanup(), errors
        end
        update_job_progress()
        if settings.copy_exif then
            -- Restricting tags to EXIF only, to make sure we won't mess up XMP tags (-all>all).
            -- This might hapen e.g. when the source files are Adobe gainmap HDRs.
            cmd = settings.bin.exiftool .. " -tagsfromfile " .. df.sanitize_filename(sdr) .. " -exif " ..
                      df.sanitize_filename(uhdr) .. " -overwrite_original -preserve"
            if not execute_cmd(cmd, string.format(_("Error adding EXIF to %s"), uhdr)) then
                return cleanup(), errors
            end
        end
        update_job_progress()
    end

    local output_dir = settings.use_original_dir and images["sdr"].path or settings.output
    local output_file = df.create_unique_filename(output_dir .. PS .. df.get_filename(uhdr))
    ok = df.file_move(uhdr, output_file)
    if not ok then
        table.insert(errors, string.format(_("Error generating UltraHDR for %s"), images["sdr"].filename))
        return cleanup(), errors
    end
    if settings.import_to_darktable then
        local img = dt.database.import(output_file)
        -- Add "ultrahdr" tag to the imported image
        local tagnr = dt.tags.find("ultrahdr")
        if tagnr == nil then
            dt.tags.create("ultrahdr")
            tagnr = dt.tags.find("ultrahdr")
        end
        dt.tags.attach(tagnr, img)
    end
    cleanup()
    update_job_progress()
    local msg = string.format(_("Generated %s."), df.get_filename(output_file))
    log.msg(log.info, msg)
    dt.print(msg)
    return true, nil
end

local function main()
    save_preferences()

    local selection_type = GUI.optionwidgets.selection_type_combo.selected
    local encoding_variant = GUI.optionwidgets.encoding_variant_combo.selected
    log.msg(log.info, string.format("using selection type %d, encoding variant %d", selection_type, encoding_variant))

    local settings, errors = assert_settings_correct(encoding_variant)
    if not settings then
        dt.print(string.format(_("Export settings are incorrect, exiting:\n\n- %s"), table.concat(errors, "\n- ")))
        return
    end

    local stacks, stack_count = get_stacks(dt.gui.selection(), encoding_variant, selection_type)
    if stack_count == 0 then
        dt.print(string.format(_("No image stacks detected.\n\nMake sure that the image pairs have the same widths and heights."), stack_count))
        return
    end
    dt.print(string.format(_("Detected %d image stack(s)"), stack_count))
    job = dt.gui.create_job(_("Generating UltraHDR images"), true, stop_job)
    local count = 0
    local msg
    for i, v in pairs(stacks) do
        local ok, errors = generate_ultrahdr(encoding_variant, v, settings, count, stack_count)
        if not ok then
            dt.print(string.format(_("Generating UltraHDR images failed:\n\n- %s"), table.concat(errors, "\n- ")))
            job.valid = false
            return
        end
        count = count + 1
        -- sleep for a short moment to give stop_job callback function a chance to run
        dt.control.sleep(10)
    end
    -- stop job and remove progress_bar from ui, but only if not alreay canceled
    if (job.valid) then
        job.valid = false
    end

    msg = string.format(_("Generated %d UltraHDR image(s)."), count)
    log.msg(log.info, msg)
    dt.print(msg)
end

GUI.optionwidgets.settings_label = dt.new_widget("section_label") {
    label = _("UltraHDR settings")
}

GUI.optionwidgets.output_settings_label = dt.new_widget("section_label") {
    label = _("output")
}

GUI.optionwidgets.output_directory_widget = dt.new_widget("file_chooser_button") {
    title = _("select directory to write UltraHDR image files to"),
    is_directory = true
}

GUI.optionwidgets.use_original_directory = dt.new_widget("check_button") {
    label = _("export to original directory"),
    tooltip = _("Write UltraHDR images to the same directory as their original images"),
    clicked_callback = function(self)
        GUI.optionwidgets.output_directory_widget.sensitive = not self.value
    end
}

GUI.optionwidgets.import_to_darktable = dt.new_widget("check_button") {
    label = _("import UltraHDRs to library"),
    tooltip = _("Import UltraHDR images to darktable library after generating, with an 'ultrahdr' tag attached.")
}

GUI.optionwidgets.copy_exif = dt.new_widget("check_button") {
    label = _("copy EXIF data"),
    tooltip = _("Copy EXIF data into UltraHDR file(s) from their SDR sources.")
}

GUI.optionwidgets.output_settings_box = dt.new_widget("box") {
    orientation = "vertical",
    GUI.optionwidgets.output_settings_label,
    GUI.optionwidgets.use_original_directory,
    GUI.optionwidgets.output_directory_widget,
    GUI.optionwidgets.import_to_darktable,
    GUI.optionwidgets.copy_exif
}

GUI.optionwidgets.metadata_label = dt.new_widget("label") {
    label = _("gain map metadata")
}

GUI.optionwidgets.min_content_boost = dt.new_widget("slider") {
    label = _('min content boost'),
    tooltip = _(
        'How much darker an image can get, when shown on an HDR display, relative to the SDR rendition (linear, SDR = 1.0). Also called "GainMapMin". '),
    hard_min = 0.9,
    hard_max = 10,
    soft_min = 0.9,
    soft_max = 2,
    step = 1,
    digits = 1,
    reset_callback = function(self)
        self.value = 1.0
    end
}
GUI.optionwidgets.max_content_boost = dt.new_widget("slider") {
    label = _('max content boost'),
    tooltip = _(
        'How much brighter an image can get, when shown on an HDR display, relative to the SDR rendition (linear, SDR = 1.0). Also called "GainMapMax". \n\nMust not be lower than Min content boost'),
    hard_min = 1,
    hard_max = 10,
    soft_min = 2,
    soft_max = 10,
    step = 1,
    digits = 1,
    reset_callback = function(self)
        self.value = 6.0
    end
}
GUI.optionwidgets.hdr_capacity_min = dt.new_widget("slider") {
    label = _('min HDR capacity'),
    tooltip = _('Minimum display boost value for which the gain map is applied at all (linear, SDR = 1.0).'),
    hard_min = 0.9,
    hard_max = 10,
    soft_min = 1,
    soft_max = 2,
    step = 1,
    digits = 1,
    reset_callback = function(self)
        self.value = 1.0
    end
}
GUI.optionwidgets.hdr_capacity_max = dt.new_widget("slider") {
    label = _('max HDR capacity'),
    tooltip = _('Maximum display boost value for which the gain map is applied completely (linear, SDR = 1.0).'),
    hard_min = 1,
    hard_max = 10,
    soft_min = 2,
    soft_max = 10,
    digits = 1,
    step = 1,
    reset_callback = function(self)
        self.value = 6.0
    end
}

GUI.optionwidgets.metadata_box = dt.new_widget("box") {
    orientation = "vertical",
    GUI.optionwidgets.metadata_label,
    GUI.optionwidgets.min_content_boost,
    GUI.optionwidgets.max_content_boost,
    GUI.optionwidgets.hdr_capacity_min,
    GUI.optionwidgets.hdr_capacity_max
}

GUI.optionwidgets.encoding_variant_combo = dt.new_widget("combobox") {
    label = _("each stack contains"),
    tooltip = string.format(_([[Select the types of images in each stack.
This will determine the method used to generate UltraHDR.

- %s: SDR image paired with a gain map image.
- %s: SDR image paired with an HDR image.
- %s: Each stack consists of a single SDR image. Gain maps will be copies of SDR images.

By default, the first image in a stack is treated as SDR, and the second one is a gain map/HDR.
You can force the image into a specific stack slot by attaching "hdr" / "gainmap" tags to it.
]]), _("SDR + gain map"), _("SDR + HDR"), _("SDR only")),
    selected = 0,
    changed_callback = function(self)
        GUI.run.sensitive = self.selected and self.selected > 0
        if self.selected == ENCODING_VARIANT_SDR_AND_GAINMAP or self.selected == ENCODING_VARIANT_SDR_AUTO_GAINMAP then
            GUI.optionwidgets.metadata_box.visible = true
            GUI.optionwidgets.gainmap_downsampling_widget.visible = false
        else
            GUI.optionwidgets.metadata_box.visible = false
            GUI.optionwidgets.gainmap_downsampling_widget.visible = true
        end
    end,
    _("SDR + gain map"), -- ENCODING_VARIANT_SDR_AND_GAINMAP
    _("SDR + HDR"), -- ENCODING_VARIANT_SDR_AND_HDR
    _("SDR only") -- ENCODING_VARIANT_SDR_AUTO_GAINMAP
}

GUI.optionwidgets.selection_type_combo = dt.new_widget("combobox") {
    label = _("selection contains"),
    tooltip = string.format(_([[Select types of images selected in darktable.
This determines how the plugin groups images into separate stacks (each stack will produce a single UltraHDR image).

- %s: All selected image(s) belong to one stack. There will be 1 output UltraHDR image.
- %s: Group images into stacks, using the source image path + filename (ignoring extension).
  Use this method if the source images for a given stack are darktable duplicates.

As an added precaution, each image in a stack needs to have the same resolution.
]]), _("one stack"), _("multiple stacks (use filename)")),
    selected = 0,
    _("one stack"), -- SELECTION_TYPE_ONE_STACK
    _("multiple stacks (use filename)") -- SELECTION_TYPE_GROUP_BY_FNAME
}

GUI.optionwidgets.quality_widget = dt.new_widget("slider") {
    label = _('quality'),
    tooltip = _('Quality of the output UltraHDR JPEG file'),
    hard_min = 0,
    hard_max = 100,
    soft_min = 0,
    soft_max = 100,
    step = 1,
    digits = 0,
    reset_callback = function(self)
        self.value = 95
    end
}

GUI.optionwidgets.gainmap_downsampling_widget = dt.new_widget("slider") {
    label = _('gain map downsampling steps'),
    tooltip = _('Exponent (2^x) of the gain map downsampling factor.\nDownsampling reduces the gain map resolution.\n\n0 = don\'t downsample the gain map, 7 = maximum downsampling (128x)'),
    hard_min = 0,
    hard_max = 7,
    soft_min = 0,
    soft_max = 7,
    step = 1,
    digits = 0,
    reset_callback = function(self)
        self.value = 0
    end
}

GUI.optionwidgets.encoding_settings_box = dt.new_widget("box") {
    orientation = "vertical",
    GUI.optionwidgets.selection_type_combo,
    GUI.optionwidgets.encoding_variant_combo,
    GUI.optionwidgets.quality_widget,
    GUI.optionwidgets.gainmap_downsampling_widget,
    GUI.optionwidgets.metadata_box
}

GUI.optionwidgets.executable_path_widget = df.executable_path_widget({"ultrahdr_app", "exiftool", "ffmpeg"})
GUI.optionwidgets.executable_path_widget.visible = false

GUI.optionwidgets.edit_executables_button = dt.new_widget("button") {
    label = _("show / hide executables"),
    tooltip = _("Show / hide settings for executable files required for the plugin functionality"),
    clicked_callback = function()
        GUI.optionwidgets.executable_path_widget.visible = not GUI.optionwidgets.executable_path_widget.visible
    end
}

GUI.options = dt.new_widget("box") {
    orientation = "vertical",
    GUI.optionwidgets.settings_label,
    GUI.optionwidgets.encoding_settings_box,
    GUI.optionwidgets.edit_executables_button,
    GUI.optionwidgets.executable_path_widget,
    GUI.optionwidgets.output_settings_box
}

GUI.run = dt.new_widget("button") {
    label = _("generate UltraHDR"),
    tooltip = _("Generate UltraHDR image(s) from selection"),
    clicked_callback = main
}

load_preferences()

local function install_module()
    if flags.module_installed then
        return
    end
    dt.register_lib( -- register module
    namespace, -- Module name
    _("UltraHDR"), -- name
    true, -- expandable
    true, -- resetable
    {
        [dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 99}
    }, -- containers
    dt.new_widget("box") {
        orientation = "vertical",
        GUI.options,
        GUI.run
    }, nil, -- view_enter
    nil -- view_leave
    )
end

local function destroy()
    dt.gui.libs[namespace].visible = false
end

local function restart()
    dt.gui.libs[namespace].visible = true
end

if dt.gui.current_view().id == "lighttable" then -- make sure we are in lighttable view
    install_module() -- register the lib
else
    if not flags.event_registered then -- if we are not in lighttable view then register an event to signal when we might be
        -- https://www.darktable.org/lua-api/index.html#darktable_register_event
        dt.register_event(namespace, "view-changed", -- we want to be informed when the view changes
        function(event, old_view, new_view)
            if new_view.name == "lighttable" and old_view.name == "darkroom" then -- if the view changes from darkroom to lighttable
                install_module() -- register the lib
            end
        end)
        flags.event_registered = true --  keep track of whether we have an event handler installed
    end
end

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart

return script_data
