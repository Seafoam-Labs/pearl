local a = {fg="{{colors.on_primary.default.hex}}", bg="{{colors.primary.default.hex}}", gui="bold"}
local b = {fg="{{colors.on_surface.default.hex}}", bg="{{colors.surface_container.default.hex}}"}
return { normal={a=a,b=b,c=b}, insert={a=a,b=b,c=b}, visual={a=a,b=b,c=b}, replace={a=a,b=b,c=b}, command={a=a,b=b,c=b}, inactive={a=b,b=b,c=b} }
