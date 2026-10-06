# dmgbuild settings for build/spacebar.dmg, read by scripts/dmg.sh, which defines app, icon and background.
# Positions are icon centres in points from the window's top left; background.swift draws the arrow between them.
import os.path

app = defines["app"]  # noqa: F821
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821
hide = [".background.tiff", ".VolumeIcon.icns"]

window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
show_item_info = False
include_list_view_settings = False
arrange_by = None
label_pos = "bottom"
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (490, 190),
}
