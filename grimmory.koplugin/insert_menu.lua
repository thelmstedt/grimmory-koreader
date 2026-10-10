local filemanager_order = require("ui/elements/filemanager_menu_order")

local pos = 1
for index, value in ipairs(filemanager_order.tools) do
    if value == "cloud_storage" then
        pos = index + 1
        break
    end
end
table.insert(filemanager_order.tools, pos, "grimmory")
