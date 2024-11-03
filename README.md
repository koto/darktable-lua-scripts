# darktable_lua_scripts
Additional Lua scripts for darktable that won't be included in the official repository or only tailored for my own personal needs.

## UltraHDR

Generate UltraHDR JPEG images from various combinations of source files (SDR, HDR, gain map).

https://developer.android.com/media/platform/hdr-image-format

The images are merged using libultrahdr example application (ultrahdr_app).

## group_leader_by_extension

Make images with a chosen extension group leaders

For all selected images, check for image groups where there 
and make the image with the selected extension the group leader.  

Based on `jpg_group_leader` script by Bill Ferguson <wpferguson@gmail.com>

## Ext_editor_multi

Edit current selection with external editors

This script provides helpers to edit selection with programs external to darktable. It adds:

- a new module "edit selection externally", visible in lightable, to select a program from a list 
- of up to 9 external editors and run it on a selected image (adjust this limit by changing MAX_EDITORS)
- a set of lua preferences in order to configure name and path of up to 9 external editors
    
Based on ext_editor script by Marco Carrarini <marco.carrarini@gmail.com>
