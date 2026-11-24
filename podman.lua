-------------------------------------------------
-- Podman Widget for Awesome Window Manager
-- Lists Podman containers and allows managing them
-- @author Icefields
-- https://github.com/Icefields
-- Forked from:
-- @author Pavel Makhov
-- https://github.com/streetturtle/awesome-wm-widgets/tree/master/docker-widget
-------------------------------------------------

local awful = require("awful")
local wibox = require("wibox")
local spawn = require("awful.spawn")
local naughty = require("naughty")
local gears = require("gears")
local beautiful = require("beautiful")

local HOME_DIR = os.getenv("HOME")
local WIDGET_DIR = HOME_DIR .. '/.config/awesome/podman-widget'
local ICONS_DIR = WIDGET_DIR .. '/icons/'

local FIELD_SEPARATOR = '\031'
local LIST_CONTAINERS_FORMAT = table.concat({
    '{{.Names}}', '{{.ID}}', '{{.Image}}', '{{.State}}', '{{.Status}}',
}, FIELD_SEPARATOR)
local LIST_CONTAINERS_SIZE_FORMAT = LIST_CONTAINERS_FORMAT .. FIELD_SEPARATOR .. '{{.Size}}'
local VALID_CONTAINER_STATES = {
    created = true,
    initialized = true,
    running = true,
    stopped = true,
    paused = true,
    exited = true,
    removing = true,
    stopping = true,
    unknown = true,
}

local function buildListCommand(executableName, numberOfContainers, showSize)
    local command = { executableName, 'container', 'ls', '--all' }
    if showSize then
        table.insert(command, '--size')
    end
    table.insert(command, '--last')
    table.insert(command, tostring(numberOfContainers))
    table.insert(command, '--format')
    table.insert(command, showSize and LIST_CONTAINERS_SIZE_FORMAT or LIST_CONTAINERS_FORMAT)
    return command
end

--- Utility function to show warning messages
local function show_warning(message)
    naughty.notify{
        preset = naughty.config.presets.critical,
        title = 'Podman Widget',
        text = message}
end

-- easy_async returns a PID on success or a string error without calling back.
local function spawnCommand(command, callback)
    local pidOrError = spawn.easy_async(command, callback)
    if type(pidOrError) == 'string' then
        show_warning(pidOrError)
        return nil
    end
    return pidOrError
end

local parseContainer = function(line, showSize)
    local fields = {}
    for field in (line .. FIELD_SEPARATOR):gmatch('(.-)' .. FIELD_SEPARATOR) do
        table.insert(fields, field)
    end

    local expectedFields = showSize and 6 or 5
    if #fields ~= expectedFields then
        return nil, string.format('expected %d fields, got %d', expectedFields, #fields)
    end

    local name, id, image, state, status = fields[1], fields[2], fields[3], fields[4], fields[5]
    local size = showSize and fields[6] or nil
    if name == '' or id == '' or image == '' or status == '' or not VALID_CONTAINER_STATES[state] then
        return nil, 'missing fields or unrecognized container state'
    end

    return {
        name = name,
        id = id,
        image = image,
        state = state,
        status = status,
        size = size,
        is_up = function() return state == 'running' end,
        is_paused = function() return state == 'paused' end,
        is_exited = function() return state == 'exited' or state == 'stopped' end,
        is_created = function() return state == 'created' or state == 'initialized' end,
    }
end

local statusToIconName = {
    running = ICONS_DIR .. 'play.svg',
    paused = ICONS_DIR .. 'pause.svg',
}

local function worker(user_args)

    local args = user_args or {}
    local max_widget_width = args.max_widget_width or 1026
    assert(type(max_widget_width) == 'number' and max_widget_width > 90 and max_widget_width < math.huge,
        'max_widget_width must be a number greater than 90')

    local popup = awful.popup{
        ontop = true,
        visible = false,
        shape = gears.shape.rounded_rect,
        border_width = 1,
        border_color = beautiful.bg_focus,
        maximum_width = max_widget_width,
        offset = { y = 5 },
        widget = {}
    }

    local podmanWidget = wibox.widget {
        {
            {
                {
                    id = 'icon',
                    widget = wibox.widget.imagebox
                },
                margins = 4,
                layout = wibox.container.margin
            },
            shape = function(cr, width, height)
                gears.shape.rounded_rect(cr, width, height, 4)
            end,
            widget = wibox.container.background
        },
        widget = wibox.container.background,
        set_icon = function(self, new_icon)
            self:get_children_by_id("icon")[1].image = new_icon
        end
    }


    local icon = args.icon or ICONS_DIR .. 'podman.svg'
    local number_of_containers = args.number_of_containers or -1
    local executableName = args.executable_name or 'podman'
    local showSize = args.show_size == true
    local listTimeout = args.list_timeout or 15
    assert(type(listTimeout) == 'number' and listTimeout >= 0 and listTimeout < math.huge,
        'list_timeout must be a nonnegative number of seconds')

    podmanWidget:set_icon(icon)

    local rows = {
        { text = 'Loading containers...', widget = wibox.widget.textbox },
        layout = wibox.layout.fixed.vertical,
    }

    local refreshContainers
    local runContainerAction
    local busyContainers = {}
    local actionsInFlight = 0

    local function replaceRowsWithMessage(message)
        rows = {
            { text = message, widget = wibox.widget.textbox },
            layout = wibox.layout.fixed.vertical,
        }
        if actionsInFlight == 0 then
            busyContainers = {}
        end
        popup:setup(rows)
    end

    local function failListing(message)
        show_warning(message)
        replaceRowsWithMessage('Failed to load containers. Reopen to retry.')
    end

    local function rebuildWidget(containers, errors, exitReason, exitCode)
        if exitReason ~= 'exit' or exitCode ~= 0 then
            local message = errors
            if message == '' then
                message = string.format('Podman listing failed: %s %s',
                    tostring(exitReason), tostring(exitCode))
            end
            failListing(message)
            return
        end
        if errors ~= '' then
            show_warning(errors)
        end

        local newRows = { layout = wibox.layout.fixed.vertical }

        for line in containers:gmatch("[^\r\n]+") do

            local container, parseError = parseContainer(line, showSize)
            if not container then
                failListing('Invalid Podman output: ' .. parseError)
                return
            end

            local status_icon = wibox.widget {
                image = (statusToIconName[container['state']] or ICONS_DIR .. 'square.svg'),
                resize = false,
                widget = wibox.widget.imagebox
            }


            local start_stop_button
            if container.is_up() or container.is_exited() or container.is_created() then
                start_stop_button = wibox.widget {
                    {
                        {
                            id = 'icon',
                            image = ICONS_DIR .. (container:is_up() and 'stop-btn.svg' or 'play-btn.svg'),
                            opacity = 0.4,
                            resize = false,
                            widget = wibox.widget.imagebox
                        },
                        left = 2,
                        right = 2,
                        layout = wibox.container.margin
                    },
                    shape = gears.shape.circle,
                    bg = '#00000000',
                    widget = wibox.container.background
                }
                local old_cursor, old_wibox
                start_stop_button:connect_signal("mouse::enter", function(c)
                    c:set_bg('#3B4252')

                    local wb = mouse.current_wibox
                    old_cursor, old_wibox = wb.cursor, wb
                    wb.cursor = "hand1"
                    c:get_children_by_id("icon")[1]:set_opacity(1)
                    c:get_children_by_id("icon")[1]:emit_signal('widget::redraw_needed')  end)
                start_stop_button:connect_signal("mouse::leave", function(c)
                    c:set_bg('#00000000')
                    if old_wibox then
                        old_wibox.cursor = old_cursor
                        old_wibox = nil
                    end
                    c:get_children_by_id("icon")[1]:set_opacity(0.4)
                    c:get_children_by_id("icon")[1]:emit_signal('widget::redraw_needed')
                end)

                start_stop_button:buttons(
                    gears.table.join( awful.button({}, 1, function()
                        local command
                        if container:is_up() then command = 'stop' else command = 'start' end

                        status_icon:set_opacity(0.2)
                        status_icon:emit_signal('widget::redraw_needed')

                        runContainerAction(container, command, status_icon)
                    end) )
                )
            else
                start_stop_button = nil
            end


            local pause_unpause_button
            if container.is_up() or container.is_paused() then
                pause_unpause_button = wibox.widget {
                    {
                        {
                            id = 'icon',
                            image = ICONS_DIR .. (container:is_paused() and 'unpause-btn.svg' or 'pause-btn.svg'),
                            opacity = 0.4,
                            resize = false,
                            widget = wibox.widget.imagebox
                        },
                        left = 2,
                        right = 2,
                        layout = wibox.container.margin
                    },
                    shape = gears.shape.circle,
                    bg = '#00000000',
                    widget = wibox.container.background
                }
                local old_cursor, old_wibox
                pause_unpause_button:connect_signal("mouse::enter", function(c)
                    c:set_bg('#3B4252')
                    local wb = mouse.current_wibox
                    old_cursor, old_wibox = wb.cursor, wb
                    wb.cursor = "hand1"
                    c:get_children_by_id("icon")[1]:set_opacity(1)
                    c:get_children_by_id("icon")[1]:emit_signal('widget::redraw_needed')
                end)
                pause_unpause_button:connect_signal("mouse::leave", function(c)
                    c:set_bg('#00000000')
                    if old_wibox then
                        old_wibox.cursor = old_cursor
                        old_wibox = nil
                    end
                    c:get_children_by_id("icon")[1]:set_opacity(0.4)
                    c:get_children_by_id("icon")[1]:emit_signal('widget::redraw_needed')
                end)

                pause_unpause_button:buttons(
                    gears.table.join( awful.button({}, 1, function()
                        local command
                        if container:is_paused() then command = 'unpause' else command = 'pause' end

                        status_icon:set_opacity(0.2)
                        status_icon:emit_signal('widget::redraw_needed')

                        runContainerAction(container, command, status_icon)
                    end) ) )
            else
                pause_unpause_button = nil
            end

            local delete_button
            if container.is_exited() or container.is_created() then
                delete_button = wibox.widget {
                    {
                        {
                            id = 'icon',
                            image = ICONS_DIR .. 'trash-btn.svg',
                            opacity = 0.4,
                            resize = false,
                            widget = wibox.widget.imagebox
                        },
                        margins = 4,
                        layout = wibox.container.margin
                    },
                    shape = gears.shape.circle,
                    bg = '#00000000',
                    widget = wibox.container.background
                }
                delete_button:buttons(
                        gears.table.join( awful.button({}, 1, function()
                            runContainerAction(container, 'rm', status_icon)
                        end)))

                local old_cursor, old_wibox
                delete_button:connect_signal("mouse::enter", function(c)
                    c:set_bg('#3B4252')
                    local wb = mouse.current_wibox
                    old_cursor, old_wibox = wb.cursor, wb
                    wb.cursor = "hand1"
                    c:get_children_by_id("icon")[1]:set_opacity(1)
                    c:get_children_by_id("icon")[1]:emit_signal('widget::redraw_needed')
                end)
                delete_button:connect_signal("mouse::leave", function(c)
                    c:set_bg('#00000000')
                    if old_wibox then
                        old_wibox.cursor = old_cursor
                        old_wibox = nil
                    end
                    c:get_children_by_id("icon")[1]:set_opacity(0.4)
                    c:get_children_by_id("icon")[1]:emit_signal('widget::redraw_needed')
                end)
            else
                delete_button = nil
            end


            local controls = { layout = wibox.layout.align.horizontal }
            if start_stop_button then table.insert(controls, start_stop_button) end
            if pause_unpause_button then table.insert(controls, pause_unpause_button) end
            if delete_button then table.insert(controls, delete_button) end

            local row = wibox.widget {
                {
                    {
                        {
                            {
                                status_icon,
                                margins = 8,
                                layout = wibox.container.margin
                            },
                            valign = 'center',
                            layout = wibox.container.place
                        },
                        {
                            {
                                {
                                    markup = '<b>' .. container['name'] .. '</b>',
                                    widget = wibox.widget.textbox
                                },
                                {
                                    text = container['size'] or container['image'],
                                    widget = wibox.widget.textbox
                                },
                                {
                                    text = container['status'],
                                    widget = wibox.widget.textbox
                                },
                                -- 90 is the reserved width of the control buttons
                                forced_width = max_widget_width - 90,
                                layout = wibox.layout.fixed.vertical
                            },
                            valign = 'center',
                            layout = wibox.container.place
                        },
                        {
                            controls,
                            forced_width = 90,
                            valign = 'center',
                            halign = 'center',
                            layout = wibox.container.place,
                        },
                        spacing = 8,
                        layout = wibox.layout.align.horizontal
                    },
                    margins = 8,
                    layout = wibox.container.margin
                },
                bg = beautiful.bg_normal,
                widget = wibox.container.background
            }


            row:connect_signal("mouse::enter", function(c) c:set_bg(beautiful.bg_focus) end)
            row:connect_signal("mouse::leave", function(c) c:set_bg(beautiful.bg_normal) end)

            table.insert(newRows, row)
        end

        if #newRows == 0 then
            table.insert(newRows, { text = 'No containers found', widget = wibox.widget.textbox })
        end
        rows = newRows
        if actionsInFlight == 0 then
            busyContainers = {}
        end
        popup:setup(rows)
    end

    local listInFlight = false
    local refreshQueued = false
    local listGeneration = 0

    -- Coalesce listing work. Container actions may request one trailing refresh;
    -- simply reopening while a request is pending reuses the active process.
    refreshContainers = function(queueIfBusy)
        if actionsInFlight > 0 then
            refreshQueued = true
            return
        end
        if listInFlight then
            if queueIfBusy then
                refreshQueued = true
            end
            return
        end
        if not popup.visible then
            return
        end

        listInFlight = true
        listGeneration = listGeneration + 1
        local generation = listGeneration
        local timedOut = false
        local timeoutTimer = nil

        local pid = spawnCommand(buildListCommand(executableName, number_of_containers, showSize),
            function(stdout, stderr, exitReason, exitCode)
                if generation ~= listGeneration then
                    return
                end
                listInFlight = false
                if timeoutTimer then
                    timeoutTimer:stop()
                    timeoutTimer = nil
                end
                if timedOut then
                    refreshQueued = false
                    return
                end
                if actionsInFlight > 0 then
                    refreshQueued = true
                    return
                end

                local runTrailingRefresh = refreshQueued
                refreshQueued = false
                if runTrailingRefresh then
                    if popup.visible then
                        refreshContainers(false)
                    end
                    return
                end
                if popup.visible then
                    rebuildWidget(stdout, stderr, exitReason, exitCode)
                end
            end)

        if not pid then
            listInFlight = false
            refreshQueued = false
            replaceRowsWithMessage('Failed to load containers. Reopen to retry.')
            return
        end

        -- A started AwesomeWM timer is strongly retained, so both normal
        -- completion and expiry must stop it. Only read-only listings use it.
        if listInFlight and listTimeout > 0 then
            timeoutTimer = gears.timer.start_new(listTimeout, function()
                if generation == listGeneration then
                    timedOut = true
                    listInFlight = false
                    refreshQueued = false
                    show_warning(string.format('Podman listing timed out after %s seconds', listTimeout))
                    replaceRowsWithMessage('Failed to load containers. Reopen to retry.')
                    local signal = awesome.unix_signal and awesome.unix_signal.SIGKILL or 9
                    awesome.kill(pid, signal)
                end
                timeoutTimer = nil
                return false
            end)
        end
    end

    runContainerAction = function(container, command, statusIcon)
        local containerId = container['id']
        if busyContainers[containerId] then
            return
        end

        busyContainers[containerId] = true
        actionsInFlight = actionsInFlight + 1
        local pid = spawnCommand({ executableName, command, container['id'] },
            function(_, stderr, exitReason, exitCode)
                actionsInFlight = actionsInFlight - 1
                local succeeded = exitReason == 'exit' and exitCode == 0
                if not succeeded then
                    busyContainers[containerId] = nil
                    local message = stderr
                    if message == '' then
                        message = string.format('Podman %s failed: %s %s', command,
                            tostring(exitReason), tostring(exitCode))
                    end
                    show_warning(message)
                    statusIcon:set_opacity(1)
                    statusIcon:emit_signal('widget::redraw_needed')
                    if refreshQueued then
                        refreshQueued = false
                        refreshContainers(true)
                    end
                    return
                end
                if stderr ~= '' then
                    show_warning(stderr)
                end
                refreshQueued = false
                refreshContainers(true)
            end)

        if not pid then
            actionsInFlight = actionsInFlight - 1
            busyContainers[containerId] = nil
            statusIcon:set_opacity(1)
            statusIcon:emit_signal('widget::redraw_needed')
            if refreshQueued then
                refreshQueued = false
                refreshContainers(true)
            end
        end
    end

    podmanWidget:connect_signal("button::press", function(self, lx, ly, button)
        if button == 1 then
            if popup.visible then
                podmanWidget:set_bg('#00000000')
                popup.visible = not popup.visible
            else
                podmanWidget:set_bg(beautiful.bg_focus)
                popup:setup(rows)
                popup.visible = true
                popup:move_next_to(mouse.current_widget_geometry)
                refreshContainers(false)
            end
        end
    end)

    return podmanWidget
end

return setmetatable({}, { __call = function(_, ...) return worker(...) end })
