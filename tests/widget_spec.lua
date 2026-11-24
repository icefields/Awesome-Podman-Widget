local widgetPath = WIDGET_PATH or "docker.lua"
local failures = {}
local testsRun = 0

local function assertEqual(expected, actual, message)
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message or "values differ",
            tostring(expected), tostring(actual)), 2)
    end
end

local function assertCommand(expected, actual, message)
    assertEqual("table", type(actual), message .. " (command type)")
    assertEqual(#expected, #actual, message .. " (argument count)")
    for index = 1, #expected do
        assertEqual(expected[index], actual[index], message .. " (argument " .. index .. ")")
    end
end

local function containsValue(values, expected)
    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end
    return false
end

local function makeHarness(listOutput)
    local harness = {
        commands = {},
        notifications = {},
        listOutput = listOutput or "",
    }

    local function newWidget(spec)
        local widget = spec or {}
        widget.signals = {}
        widget.buttonSpecs = {}

        function widget:connect_signal(name, callback)
            self.signals[name] = callback
        end

        function widget:buttons(buttonSpecs)
            self.buttonSpecs = buttonSpecs
        end

        function widget:set_bg(color)
            self.bg = color
        end

        function widget:set_opacity(opacity)
            self.opacity = opacity
        end

        function widget:emit_signal()
        end

        function widget:get_children_by_id(id)
            local matches = {}
            local visited = {}
            local function visit(node)
                if type(node) ~= "table" or visited[node] then
                    return
                end
                visited[node] = true
                if node.id == id then
                    table.insert(matches, node)
                end
                for key, value in pairs(node) do
                    if key ~= "signals" and key ~= "buttonSpecs" then
                        visit(value)
                    end
                end
            end
            visit(self)
            return matches
        end

        return widget
    end

    local wibox = {
        widget = setmetatable({
            textbox = { widgetType = "textbox" },
            imagebox = { widgetType = "imagebox" },
        }, {
            __call = function(_, spec)
                return newWidget(spec)
            end,
        }),
        container = {
            margin = { widgetType = "margin" },
            background = { widgetType = "background" },
            place = { widgetType = "place" },
        },
        layout = {
            fixed = {
                vertical = { layoutType = "fixed.vertical" },
                horizontal = { layoutType = "fixed.horizontal" },
            },
            align = {
                horizontal = { layoutType = "align.horizontal" },
            },
        },
    }

    local spawn = {}
    function spawn.easy_async(command, callback)
        table.insert(harness.commands, command)
        local isList = type(command) == "table" and command[2] == "container" and command[3] == "ls"
        if type(command) == "string" then
            isList = command:find("container ls", 1, true) ~= nil
        end

        if isList then
            callback(harness.listOutput, "", "exit", 0)
        else
            callback("", "", "exit", 0)
        end
    end

    local awful = {
        spawn = spawn,
        button = function(_, button, callback)
            return {{ button = button, callback = callback }}
        end,
        popup = function(spec)
            local popup = newWidget(spec)
            popup.visible = false
            function popup:setup(rows)
                self.setupRows = rows
            end
            function popup:move_next_to()
            end
            harness.popup = popup
            return popup
        end,
    }

    local gears = {
        shape = {
            rounded_rect = function() end,
            circle = function() end,
        },
        table = {
            join = function(...)
                local joined = {}
                for _, value in ipairs({...}) do
                    for key, item in pairs(value) do
                        if type(key) == "number" then
                            table.insert(joined, item)
                        else
                            joined[key] = item
                        end
                    end
                end
                return joined
            end,
        },
    }

    local naughty = {
        config = { presets = { critical = {} } },
        notify = function(notification)
            table.insert(harness.notifications, notification)
        end,
    }

    for _, moduleName in ipairs({ "awful", "awful.spawn", "wibox", "naughty", "gears", "beautiful" }) do
        package.loaded[moduleName] = nil
    end

    package.preload["awful"] = function() return awful end
    package.preload["awful.spawn"] = function() return spawn end
    package.preload["wibox"] = function() return wibox end
    package.preload["naughty"] = function() return naughty end
    package.preload["gears"] = function() return gears end
    package.preload["beautiful"] = function()
        return { bg_focus = "focus", bg_normal = "normal" }
    end

    mouse = { current_wibox = nil, current_widget_geometry = nil }

    local widget = dofile(widgetPath)
    harness.widget = widget({})
    harness.openPopup = function()
        harness.widget.signals["button::press"](harness.widget, 0, 0, 1)
    end

    return harness
end

local function collectRowData(row)
    local buttons = {}
    local texts = {}
    local images = {}
    local visited = {}

    local function visit(node)
        if type(node) ~= "table" or visited[node] then
            return
        end
        visited[node] = true
        if node.buttonSpecs and #node.buttonSpecs > 0 then
            for _, button in ipairs(node.buttonSpecs) do
                table.insert(buttons, button)
            end
        end
        if type(node.markup) == "string" then
            table.insert(texts, (node.markup:gsub("<[^>]+>", "")))
        end
        if type(node.text) == "string" then
            table.insert(texts, node.text)
        end
        if type(node.image) == "string" then
            table.insert(images, node.image)
        end
        for key, value in pairs(node) do
            if key ~= "signals" and key ~= "buttonSpecs" then
                visit(value)
            end
        end
    end

    visit(row)
    return { buttons = buttons, texts = texts, images = images }
end

local function findRow(harness, name)
    local rows = harness.popup.setupRows
    for index = 1, #rows do
        local data = collectRowData(rows[index])
        if containsValue(data.texts, name) then
            return data
        end
    end
    error("No row found for container " .. name)
end

local function lastCommand(harness)
    return harness.commands[#harness.commands]
end

local function test(name, callback)
    testsRun = testsRun + 1
    local ok, err = pcall(callback)
    if ok then
        print("PASS: " .. name)
    else
        table.insert(failures, name .. ": " .. tostring(err))
        print("FAIL: " .. failures[#failures])
    end
end

local listFormat = "{{.Names}}::{{.ID}}::{{.Image}}::{{.Status}}::{{.Size}}"

test("lists all containers through Podman without a shell", function()
    local harness = makeHarness()
    harness.openPopup()
    assertCommand({
        "podman", "container", "ls", "--all", "--size", "--last", "-1",
        "--format", listFormat,
    }, harness.commands[1], "default list command")
end)

test("honors executable and container count overrides", function()
    local harness = makeHarness()
    harness.widget = harness.widget({ executable_name = "podman-remote", number_of_containers = 5 })
    harness.openPopup()
    assertCommand({
        "podman-remote", "container", "ls", "--all", "--size", "--last", "5",
        "--format", listFormat,
    }, lastCommand(harness), "customized list command")
end)

test("maps Podman states to the correct lifecycle commands", function()
    local output = table.concat({
        "running::aaa::localhost/running:latest::Up 2 hours (healthy)::1kB (virtual 2kB)",
        "paused::bbb::localhost/paused:latest::Up 3 hours (Paused)::1kB (virtual 2kB)",
        "exited::ccc::localhost/exited:latest::Exited (0) 4 hours ago::1kB (virtual 2kB)",
        "created::ddd::localhost/created:latest::Created::0B (virtual 2kB)",
    }, "\n")
    local harness = makeHarness(output)
    harness.openPopup()

    assertEqual(4, #harness.popup.setupRows, "container row count")
    local running = findRow(harness, "running")
    local paused = findRow(harness, "paused")
    local exited = findRow(harness, "exited")
    local created = findRow(harness, "created")

    assertEqual(2, #running.buttons, "running controls")
    assertEqual(2, #paused.buttons, "paused controls")
    assertEqual(2, #exited.buttons, "exited controls")
    assertEqual(2, #created.buttons, "created controls")
    assert(containsValue(running.texts, "2 hours"), "running duration should omit health status")
    assert(containsValue(paused.texts, "3 hours"), "paused duration should omit pause annotation")
    assert(containsValue(exited.texts, "4 hours ago"), "exited duration should omit exit code")
    assert(containsValue(created.texts, "Never started"), "created duration")

    running.buttons[1].callback()
    assertCommand({ "podman", "stop", "running" }, harness.commands[#harness.commands - 1],
        "running stop command")
    running.buttons[2].callback()
    assertCommand({ "podman", "pause", "running" }, harness.commands[#harness.commands - 1],
        "running pause command")
    paused.buttons[2].callback()
    assertCommand({ "podman", "unpause", "paused" }, harness.commands[#harness.commands - 1],
        "paused unpause command")
    exited.buttons[1].callback()
    assertCommand({ "podman", "start", "exited" }, harness.commands[#harness.commands - 1],
        "exited start command")
    created.buttons[1].callback()
    assertCommand({ "podman", "start", "created" }, harness.commands[#harness.commands - 1],
        "created start command")
    exited.buttons[2].callback()
    assertCommand({ "podman", "rm", "exited" }, harness.commands[#harness.commands - 1],
        "exited remove command")
end)

test("uses Podman branding for the default icon", function()
    local harness = makeHarness()
    local icons = harness.widget:get_children_by_id("icon")
    assertEqual(1, #icons, "main icon count")
    assert(icons[1].image:sub(-10) == "podman.svg", "default icon should be podman.svg")
end)

if #failures > 0 then
    error(string.format("%d of %d tests failed", #failures, testsRun))
end
print(string.format("All %d tests passed", testsRun))
