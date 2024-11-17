local tw, th = term.getSize()

local protocol = "pong"
local am_host = false
local current_user = {
    ["name"] = nil,
    ["record"] = nil,
    ["password"] = nil
}

local parse_record = function(rec_str)
    local rec = {}
    for k, v in string.gmatch(rec_str, "wins,(%-?%d+),losses,(%-?%d+)") do
        rec["wins"] =  tonumber(k)
        rec["losses"] = tonumber(v)
    end
    return rec
end

local open_modem = function()
    if not rednet.isOpen() then
        peripheral.find("modem", rednet.open)
    end
end
open_modem()

local round = function(x)
    return math.floor(x+0.5)
end

local clamp = function(x, min, max)
    if min > max then
        error("Min must be <= max", 0)
    end
    return math.max(min, math.min(x, max))
end

local plen
plen = round(th / 6)

local reset_state = function()
    return {
        [1] = {
            x = round(tw / 10),
            y = round((th / 2) - plen / 2),
            last_input = "none",
            color = colors.green,
            ms = 1,
            score = 0,
            name = nil,
            record = nil
        },
        [2] = {
            x = round(tw - (tw / 10)),
            y = round((th / 2) - plen / 2),
            last_input = "none",
            color = colors.red,
            ms = 1,
            score = 0,
            id = nil,
            name = nil,
            record = nil
        },
        [3] = {
            x = round(tw / 2),
            y = round(th / 2),
            color = colors.white,
            ms = 1,
            dir = math.random() > 0.5
                and vector.new(1, 0, 0)
                or vector.new(-1, 0, 0),
            max_bounce_angle = 5 * math.pi / 12 --radians=75 degrees
        }
    }
end

local intoint = {
    ["none"] = 0,
    ["up"] = -1,
    ["down"] = 1
}

local state
state = reset_state()
local game_state
game_state = "menu"

local you, notyou, ball = 1, 2, 3

local send_msg = function(msg, id_override)
    rednet.send(id_override or state[notyou].id, msg, protocol)
end

local parse_msg = function(msg)
    -- "evt|data"
    local evt_sep_idx = string.find(msg, "|")
    if evt_sep_idx == nil then error("Invalid message format") end
    local parsed = {
        ["evt"] = string.sub(msg, 1, evt_sep_idx),
        ["data"] = string.sub(msg, evt_sep_idx + 1),
    }
    return parsed
end

local join_evt, accept_evt,
    reject_evt, update_evt,
    input_evt, leave_evt,
    start_evt, ackstart_evt,
    name_evt, record_evt = 
        "join|", "accept|",
        "reject|", "update|",
        "input|", "leave|",
        "start|", "ackstart|",
        "name|", "record|"

local draw_btn = function(btn, color)
    paintutils.drawFilledBox(
        btn[1],
        btn[2],
        btn[3],
        btn[4],
        color
    )
    term.setCursorPos(
        btn[5],
        btn[6]
    )
    write(btn[7])   
end

local render = function()
    --erase screen
    paintutils.drawFilledBox(0, 0, tw, th, colors.black)
    --write scores
    term.setCursorPos(tw/2 - 2, 3)
    if state[you].x > tw / 2 then
        print(state[notyou].score .. "     " .. state[you].score)
    else
        print(state[you].score .. "     " .. state[notyou].score)
    end
    --draw score zones
    if am_host then
        paintutils.drawFilledBox(0, 0, 1, th, state[notyou].color)
        paintutils.drawFilledBox(tw, 0, tw+1, th, state[you].color)
    else
        paintutils.drawFilledBox(0, 0, 1, th, state[you].color)
        paintutils.drawFilledBox(tw, 0, tw+1, th, state[notyou].color)
    end
    paintutils.drawLine(
        state[you].x,
        state[you].y,
        state[you].x,
        state[you].y + plen,
        state[you].color
    )
    paintutils.drawLine(
        state[notyou].x,
        state[notyou].y,
        state[notyou].x,
        state[notyou].y + plen,
        state[notyou].color
    ) 
    paintutils.drawPixel(
        state[ball].x,
        state[ball].y,
        state[ball].color
    )
end

local half_plen
half_plen = round(plen / 2)

local bounce_paddle = function(paddle_y, ball_y, max_angle)
    local rel_int_y = (paddle_y + half_plen) - ball_y
    local norm_rel_int_y = rel_int_y / half_plen
    local bounce_angle = norm_rel_int_y * max_angle
    return math.cos(bounce_angle), math.sin(bounce_angle)
end

local update_state = function(delta)
    local update_players = function()
        local p1 = state[you]
        local p2 = state[notyou]
        --add 1 to y to account for the title
        p1.y = clamp(p1.y + intoint[p1.last_input] * p1.ms * (delta or 1), 1, th - plen)
        p2.y = clamp(p2.y + intoint[p2.last_input] * p2.ms * (delta or 1), 1, th - plen)                
        state[you].y = p1.y
        state[notyou].y = p2.y
        sleep(0.01)
    end
            
    local update_ball = function()
        if state[you].score == 5 or state[notyou].score == 5 then
            game_state = "end_game"
            return
        end

        local b = state[ball]
        b.x = clamp(b.x + b.dir.x * b.ms * (delta or 1), 0, tw)
        b.y = clamp(b.y + b.dir.y * b.ms * (delta or 1), 1, th)
        state[ball].x = b.x
        state[ball].y = b.y
        
        --reflect off paddles
        local rel_y_int
        if b.dir.x < 0 and b.x <= state[you].x + 1 and b.x >= state[you].x - 1 then
            if b.y >= state[you].y and b.y <= state[you].y + plen then
                local new_dir_x, new_dir_y = bounce_paddle(state[you].y, b.y, b.max_bounce_angle)   
                state[ball].dir.x = new_dir_x
                state[ball].dir.y = new_dir_y
            end
        elseif b.dir.x > 0 and b.x >= state[notyou].x - 1 and b.x <= state[notyou].x + 1 then
            if b.y >= state[notyou].y and b.y <= state[notyou].y + plen then
                local new_dir_x, new_dir_y = bounce_paddle(state[notyou].y, b.y, b.max_bounce_angle)
                state[ball].dir.x = -new_dir_x
                state[ball].dir.y = -new_dir_y
            end
        end
        
        --reflect off walls
        b = state[ball]
        if b.y <= 2 or b.y >= th then
            state[ball].dir.y = -b.dir.y
        end
        
        --detect score
        b = state[ball]
        if b.x <= 1 then
            if am_host then
                state[notyou].score = state[notyou].score + 1
            else
                state[you].score = state[you].score + 1
            end
            local t_state = reset_state()
            state[ball] = t_state[ball]
        elseif b.x >= tw then
            if am_host then
                state[you].score = state[you].score + 1
            else
                state[notyou].score = state[notyou].score + 1
            end
            local t_state = reset_state()
            state[ball] = t_state[ball]
        end
        if state[you].score == 5 or state[notyou].score == 5 then
            game_state = "end_game"
            return
        end
        sleep(0.01)
    end
    parallel.waitForAny(update_players, update_ball) 
end

local sync_state = function()
    local evt, timer
    if am_host then
        timer = os.startTimer(0.05)
    end
    while true do
        evt = {os.pullEvent()}
        if evt[1] == "rednet_message" then
            if evt[4] == protocol then
                local parsed = parse_msg(evt[3])
                if parsed.evt == update_evt then
                    parsed.data = textutils.unserialise(parsed.data)
                    local _you = parsed.data.notyou
                    local _notyou = parsed.data.you
                    local _ball = parsed.data.ball
                    state[you].x = _you.x
                    state[you].y = _you.y
                    state[you].score = _you.score
                    state[notyou].x = _notyou.x
                    state[notyou].y = _notyou.y
                    state[notyou].score = _notyou.score
                    state[ball].x = _ball.x
                    state[ball].y = _ball.y
                    state[ball].dir = _ball.dir
                elseif parsed.evt == input_evt then
                    state[notyou].last_input = parsed.data
                end
            end
        elseif am_host and evt[1] == "timer" then
            os.cancelTimer(timer)
            local msg = {
                ["you"] = {
                    x = state[you].x,
                    y = state[you].y,
                    score = state[you].score
                },
                -- if not host then notyou is you
                ["notyou"] = {
                    x = state[notyou].x,
                    y = state[notyou].y,
                    score = state[notyou].score
                },
                ["ball"] = {
                    x = state[ball].x,
                    y = state[ball].y,
                    dir = state[ball].dir
                }
            }
            send_msg(update_evt .. textutils.serialise(msg))
            timer = os.startTimer(0.05)
        end
    end
end

local process_input = function()
    local evt, key, is_held = os.pullEvent("key")
    if keys.getName(key) ~= "up" and keys.getName(key) ~= "down" then
        state[you].last_input = "none"
    else
        state[you].last_input = keys.getName(key)
    end
    send_msg(input_evt .. state[you].last_input)
end

local get_game_id = function()
    math.randomseed(os.clock()) 
    local template = "xxxxxx"
    return string.gsub(
        template,
        '[xy]',
        function(c)
            local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
            return string.format("%x", v)
        end
    )
end

local hosted_game = {
    ["game_id"] = "",
    ["password"] = ""
}

local host_game = function()
    term.clear()
    term.setCursorPos(tw / 2 - 12, th / 2)
    write("Enter a password for the game")
    term.setCursorPos(tw / 2 - 5, th / 2 + 2)
    
    local pword = ""
    local p = {}
    while true do
        local _, key, _ = os.pullEvent("key")
        local _p = {}
        if keys.getName(key) == "enter" then
            pword = table.concat(p)
            break
        else
            p[#p+1] = keys.getName(key)
            _p[#_p+1] = keys.getName(key)
            write(table.concat(_p)) 
        end
    end    
    hosted_game.game_id = get_game_id()
    hosted_game.password = pword
    rednet.host(protocol, hosted_game.game_id)
    am_host = true
    
    term.clear()
    term.setCursorPos(tw / 2 - 5, th / 2 - 4)
    write("Game: " .. hosted_game.game_id)
    term.setCursorPos(tw / 2 - (string.len(hosted_game.password) / 2) - 4, th / 2 - 3)
    write("Password: " .. hosted_game.password)
    term.setCursorPos(tw / 2 - 10, th / 2)
    write("Waiting for opponent...")
    local back_btn = {
        tw / 2 - 4,
        th / 2 + 1,
        tw / 2 + 4,
        th / 2 + 3,
        tw / 2 - 3,
        th / 2 + 3,
        "(B)ack"
    }
    local go_back = function()
       rednet.unhost(protocol)
       am_host = false
       game_state = "menu"
    end
    draw_btn(back_btn, colors.lightGray)
    local evt
    while true do
        evt = {os.pullEvent()}
        if evt[1] == "mouse_click" then
            if evt[3] >= back_btn[1] and evt[3] <= back_btn[3]
                and evt[4] >= back_btn[2] - 1 and evt[4] <= back_btn[4] then
                    draw_btn(back_btn, colors.gray)
            end
        elseif evt[1] == "mouse_up" then
            if evt[3] >= back_btn[1] and evt[3] <= back_btn[3]
                and evt[4] >= back_btn[2] - 1 and evt[4] <= back_btn[4] then
                    draw_btn(back_btn, colors.lightGray)
                    return go_back()            
            end
        elseif evt[1] == "key" then
            if keys.getName(evt[2]) == "b" then
                return go_back()
            end
        elseif evt[1] == "rednet_message" then
            if evt[4] == protocol then
                local parsed = parse_msg(evt[3])
                if parsed.evt == join_evt then
                    if parsed.data == hosted_game.password then
                        state[notyou].id = evt[2]
                        send_msg(accept_evt)
                        game_state = "countdown"
                        rednet.unhost(protocol)
                        return
                    else
                        send_msg(reject_evt, evt[2])
                    end
                else
                    send_msg(reject_evt .. parsed, evt[2])
                end 
            end
        end
    end
end

local join_game = function()
    term.clear()
    local btns = {
        [1] = {
            2,
            2,
            6,
            3,
            4,
            3,
            "Ref"
        }
    }

    local game_list, choice, evt

    local fetch_games = function()
        return {rednet.lookup(protocol)}
    end

    local render_game_list = function()
        paintutils.drawFilledBox(
            tw / 4, 3,
            3 * tw / 4, th - 3,
            colors.black
        )
        game_list = fetch_games()
        if game_list then
            for i, host in ipairs(game_list) do
                btns[i+1] = {
                    tw / 4 + 1,
                    3 + 2 * i,
                    3 * tw / 4 - 1,
                    3 + 4 * i,
                    tw / 4 + 2,
                    3 + 3 * i,
                    "Game: " .. host
                }
            end
        end
        for i, btn in ipairs(btns) do
            if i == 1 then
                draw_btn(btn, colors.blue)
            else
                draw_btn(btn, colors.lightGray)
            end
        end
    end
    
    render_game_list()
    am_host = false

    local need_fresh_render = false

    while true do
        evt = {os.pullEvent()}
        if evt[1] == "mouse_click" then
            for i, btn in ipairs(btns) do
                if evt[3] >= btn[1] and evt[3] <= btn[3]
                and evt[4] >= btn[2] - 1 and evt[4] <= btn[4] then
                        if i == 1 then
                            draw_btn(btn, colors.packRGB(0, 0, 0.4))
                        else
                            draw_btn(btn, colors.gray)
                            choice = i
                        end
                end
            end
        elseif evt[1] == "mouse_up" then
            for i, btn in ipairs(btns) do
                if evt[3] >= btn[1] and evt[3] <= btn[3]
                and evt[4] >= btn[2] - 1 and evt[4] <= btn[4] then
                        if i == 1 then
                            game_list = fetch_games()
                            render_game_list()
                        elseif i == choice then
                            print(choice)
                            term.clear()
                            term.setCursorPos(tw / 2 - 6, th / 2)
                            write("Enter password: ")
                            term.setCursorPos(tw / 2 - 6, th / 2 + 1)
                            local pword = ""
                            local p = {}
                            while true do
                                local _, key, _ = os.pullEvent("key")
                                local _p = {}
                                if keys.getName(key) == "enter" then
                                    pword = table.concat(p)
                                    -- id starts after 'Game: ' which is 6 characters
                                    local id = string.sub(btn[7], 7)
                                    send_msg(join_evt .. pword, tonumber(id))
                                    local _id, msg = rednet.receive(protocol, 5)
                                    if not _id then
                                        break
                                    else
                                        local parsed = parse_msg(msg)
                                        if parsed.evt == accept_evt then
                                            state[notyou].id = _id
                                            game_state = "countdown"
                                            return
                                        elseif parsed.evt == reject_evt then
                                            term.clear()
                                            term.setCursorPos(tw / 2 - 6, th / 2)
                                            write("Wrong password")
                                            sleep(2)
                                            need_fresh_render = true
                                            break
                                        end
                                    end
                                else
                                    p[#p+1] = keys.getName(key)
                                    _p[#_p+1] = keys.getName(key)
                                    write(table.concat(_p)) 
                                end
                            end 
                        end
                if need_fresh_render then
                    render_game_list()
                    need_fresh_render = false
                else
                    draw_btn(btn, i == 1 and colors.blue or colors.lightGray)
                end
                end
            end
        end
    end
end

local exit_game = function()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, th)
    return 0
end

local menu_choices = {
    function()
        game_state = "hosting"
    end,
    function()
        game_state = "joining"
    end,
    function()
        game_state = "exiting"
    end,
    function()
        game_state = "login"
    end,
}

local menu = function()
    term.clear()
    paintutils.drawFilledBox(0, 0, tw, th, colors.black)
    local menu_opts = {
        "(H)ost",
        "(J)oin",
        "(E)xit",
        current_user.name or "(L)ogin"
    }
    local menu_btn = {
        [1] = {},
        [2] = {},
        [3] = {},
        [4] = {}
        
    }
    local menu_btn_bg = colors.lightGray
    local menu_btn_down = colors.gray
    
    for i, opt in ipairs(menu_opts) do
        if i == 4 then
            menu_btn[i] = {
                2,
                2,
                10,
                4,
                3,
                3,
                opt
            }
        else
            menu_btn[i] = {
                tw / 3,
                ((i - 1) * th / 3) + 2,
                2 * tw / 3,
                (i * th / 3) - 2,
                tw / 2 - 2,
                i * th / 3 - 3,
                opt
            }
        end
        if i == 4 then
            if current_user.name then
                draw_btn(menu_btn[i], colors.green) 
            else
                draw_btn(menu_btn[i], menu_btn_bg)
            end
        else
            draw_btn(menu_btn[i], menu_btn_bg)
        end
    end

    local choice, evt
    while true do
        evt = {os.pullEvent()}
        if evt[1] == "key" then
            if keys.getName(evt[2]) == "h" then
                return menu_choices[1]()   
            elseif keys.getName(evt[2]) == "j" then
                return menu_choices[2]()
            elseif keys.getName(evt[2]) == "e" then
                return menu_choices[3]()
            elseif not current_user.name and keys.getName(evt[2]) == "l" then
                return menu_choices[4]()
            end       
        elseif evt[1] == "mouse_click" then
            for i, btn in ipairs(menu_btn) do
                if evt[3] >= btn[1] and evt[3] <= btn[3]
                    and evt[4] >= btn[2] - 1 and evt[4] <= btn[4] then
                        if i ~= 4 or not current_user.name then
                            draw_btn(menu_btn[i], menu_btn_down)
                        end
                        choice = i
                end
            end
        elseif evt[1] == "mouse_up" then
            for i, btn in ipairs(menu_btn) do
                if evt[3] >= btn[1] and evt[3] <= btn[3]
                    and evt[4] >= btn[2] - 1 and evt[4] <= btn[4] then
                        if i == 4 and current_user.name then
                            draw_btn(menu_btn[i], colors.green)
                        else
                            draw_btn(menu_btn[i], menu_btn_bg)
                        end
                        if i == choice then
                            if choice ~= 4 or not current_user.name then
                                return menu_choices[i]()
                            end    
                        end
                end
            end                   
        end
    end
end

local check_login = function(username, password, callback)
    local users_dir = shell.resolve("./users")
    if not fs.isDir(users_dir) then
        fs.makeDir(users_dir)
    end
    if not fs.exists(users_dir .. "/" .. username) then
        local user_file = fs.open(users_dir .. "/_" .. username, "w")
        user_file.write("wins,0,losses,0")
        user_file.close()
        -- 'encrypt' with password
        local user_file_bytes = fs.open(users_dir .. "/_" .. username, "rb")
        local user_file_enc = fs.open(users_dir .. "/" .. username, "wb")
        local size = fs.getSize(users_dir .. "/_" .. username)
        local next_byte
        for i = 0, size - 1 do
            user_file_bytes.seek("set", i)
            next_byte = user_file_bytes.read(1)
            xor = bit.bxor(string.byte(next_byte), string.byte(string.sub(password, i % string.len(password) + 1, i % string.len(password) + 1)))
            user_file_enc.write(xor)
        end
        user_file_bytes.close()
        user_file_enc.close()
        fs.delete(users_dir .. "/_" .. username)
    else
        -- read the 'encrypted' file
        local user_file_enc = fs.open(users_dir .. "/" .. username, "rb")
        local size = fs.getSize(users_dir .. "/" .. username)
        local checker = {}
        local record = {}
        for i = 0, 3 do
            user_file_enc.seek("set", i)
            next_byte = user_file_enc.read(1)
            xor = bit.bxor(string.byte(next_byte), string.byte(string.sub(password, i % string.len(password) + 1, i % string.len(password) + 1)))
            checker[#checker+1] = string.char(xor)
        end
        if table.concat(checker) == "wins" then
            for i = 0, size - 1 do
                user_file_enc.seek("set", i)
                next_byte = user_file_enc.read(1)
                xor = bit.bxor(string.byte(next_byte), string.byte(string.sub(password, i % string.len(password) + 1, i % string.len(password) + 1)))
                record[#record+1] = string.char(xor)
            end
            callback(username, table.concat(record), password)
            user_file_enc.close()
            return true
        else
            user_file_enc.close()
            return false
        end
    end
end

local update_user_record = function()
    local users_dir = shell.resolve("./users")
    local user_file_enc = fs.open(users_dir .. "/" .. current_user.name, "r+b")
    local size = string.len(current_user.record)
    local checker = {}
    local record = {}
    for i = 0, 3 do
        user_file_enc.seek("set", i)
        next_byte = user_file_enc.read(1)
        xor = bit.bxor(string.byte(next_byte), string.byte(string.sub(current_user.password, i % string.len(current_user.password) + 1, i % string.len(current_user.password) + 1)))
        checker[#checker+1] = string.char(xor)
    end
    if table.concat(checker) == "wins" then
        for i = 0, size - 1 do
            next_byte = string.sub(current_user.record, i+1, i+1)
            xor = bit.bxor(string.byte(next_byte), string.byte(string.sub(current_user.password, i % string.len(current_user.password) + 1, i % string.len(current_user.password) + 1)))
            record[#record+1] = string.char(xor)
        end
        user_file_enc.seek("set", 0)
        user_file_enc.write(table.concat(record))
        user_file_enc.close()
        return true
    else
        user_file_enc.close()
        return false
    end
end

local login = function()
    term.clear()
    paintutils.drawFilledBox(
        tw / 4,
        th / 4,
        3 * tw / 4,
        3 * th / 4,
        colors.black
    )
    term.setCursorPos(tw / 4 + 1, th / 4 + 1)
    write("Name")
    term.setCursorPos(tw / 4 + 1, th / 4 + 3)
    write("Password")
    local btns = {
        [1] = {
            tw / 4 + 10,
            th / 4 + 1,
            3 * tw / 4 - 1,
            th / 4 + 1,
            tw / 4 + 10,
            th / 4 + 1,
            "",
            function()
                term.setCursorPos(tw / 4 + 10, th / 4 + 1)
            end,
            colors.gray,
            colors.lightGray
        },
        [2] = {
            tw / 4 + 10,
            th / 4 + 3,
            3 * tw / 4 - 1,
            th / 4 + 3,
            tw / 4 + 10,
            th / 4 + 3,
            "",
            function()
                term.setCursorPos(tw / 4 + 10, th / 4 + 3)
            end,
            colors.gray,
            colors.lightGray
        },
        [3] = {
            tw / 3 - 1,
            3 * th / 4 - 3,
            tw / 3 + 6,
            3 * th / 4 - 1,
            tw / 3,
            3 * th / 4 - 2,
            "Login",
            function(user, pass, callback)
                local succ = check_login(user, pass, callback)
                if succ then
                    game_state = "menu"
                    return true
                end
                return false
            end,
            colors.lime,
            colors.green
        },
        [4] = {
            tw / 3 + 9,
            3 * th / 4 - 3,
            tw / 3 + 16,
            3 * th / 4 - 1,
            tw / 3 + 10,
            3 * th / 4 - 2,
            "Cancel",
            function()
                game_state = "menu"
                return true
            end,
            colors.red,
            colors.magenta
        }
    }
    for i, btn in ipairs(btns) do
        draw_btn(btn, btn[9])
    end
    local choice, evt, selected_input
    local p = {
        [1] = {},
        [2] = {}
    }
    local handle_login_success = function(username, record, password)
        current_user.name = username
        current_user.record = record
        current_user.password = password
    end
    while true do
        evt = {os.pullEvent()}
        if evt[1] == "key" then
            if selected_input == 1 or selected_input == 2 then
                term.setCursorPos(btns[selected_input][1], btns[selected_input][2])
                p[selected_input][#p[selected_input]+1] = keys.getName(evt[2])
                write(table.concat(p[selected_input]))
                btns[selected_input][7] = table.concat(p[selected_input])
            end
        elseif evt[1] == "mouse_click" then
            for i, btn in ipairs(btns) do
                if evt[3] >= btn[1] and evt[3] <= btn[3]
                    and evt[4] >= btn[2] - 1 and evt[4] <= btn[4] then
                        draw_btn(btn, btn[10])
                        choice = i
                        if i == 1 or i == 2 then
                            selected_input = i
                        end
                end
            end
        elseif evt[1] == "mouse_up" then
            for i, btn in ipairs(btns) do
                if evt[3] >= btn[1] and evt[3] <= btn[3]
                    and evt[4] >= btn[2] - 1 and evt[4] <= btn[4] then
                        if i == choice then
                            local needs_return = btn[8](table.concat(p[1]), table.concat(p[2]), handle_login_success)
                            if needs_return then
                                return
                            end
                        end
                end
                if i ~= selected_input then
                    draw_btn(btn, btn[9])
                end
            end                   
        end
    end
end

local countdown = function()
    if current_user.name ~= nil then
        send_msg(name_evt .. current_user.name)
        send_msg(record_evt .. current_user.record)
    else 
        send_msg(name_evt .. os.getComputerLabel())
        send_msg(record_evt .. "wins,-1,losses,-1")
    end
    local timestart = os.clock()
    local wait_for_record = false
    local wait_for_name = false
    while true do
        evt = {os.pullEvent()}
        if os.clock() - timestart > 5 and not wait_for_record and not wait_for_name then
            write("Failed to get opponent name.")
            sleep(2)
            term.clear()
            game_state = "menu"
            return
        elseif os.clock() - timestart > 5 and (wait_for_record or wait_for_name) then
            break
        elseif evt[1] == "rednet_message" then
            if evt[4] == protocol then
                local parsed = parse_msg(evt[3])
                if parsed.evt == name_evt then
                    state[notyou].name = parsed.data
                    wait_for_record = true
                elseif parsed.evt == record_evt then
                    state[notyou].record = parsed.data
                    wait_for_name = true
                end
            end
        elseif state[notyou].name ~= nil and state[notyou].record ~= nil then
            break
        end
    end
    term.clear()
    term.setCursorPos(tw / 2 - 5, th / 2)
    write("Game start in...")
    term.setCursorPos(tw / 2 - 3, th / 2 + 2)
    textutils.slowWrite("5 4 3 2 1 ", 2)

    send_msg(start_evt)
    local evt
    timestart = os.clock()
    while true do
        evt = {os.pullEvent()}
        if os.clock() - timestart > 5 then
            write("Failed to start.")
            sleep(2)
            term.clear()
            game_state = "menu"
            return
        elseif evt[1] == "rednet_message" then
            if evt[4] == protocol then
                local parsed = parse_msg(evt[3])
                if parsed.evt == ackstart_evt then
                    game_state = "game"
                    return
                elseif parsed.evt == start_evt then
                    send_msg(ackstart_evt)
                    game_state = "game"
                    return
                end
            end
        end
    end
end

local end_game = function()
    term.clear()
    paintutils.drawFilledBox(0, 0, tw, th, colors.black)
    term.setCursorPos(tw / 2 - 2, th / 2)
    local winner = state[you].score > state[notyou].score and you or notyou
    local winner_name
    local winner_record
    if winner == you then
        if current_user.name ~= nil then
            winner_name = current_user.name
            local p = parse_record(current_user.record)
            p.wins = p.wins + 1
            current_user.record = "wins," .. p.wins .. ",losses," .. p.losses
            update_user_record()
            winner_record = current_user.record
        else
            winner_name = os.getComputerLabel()
            winner_record = "wins,-1,losses,-1"
        end
    else
        winner_name = state[notyou].name
        winner_record = state[notyou].record
        local p = parse_record(winner_record)
        p.wins = p.wins + 1
        winner_record = "wins," .. p.wins .. ",losses," .. p.losses
        if current_user.name ~= nil then
            local _p = parse_record(current_user.record)
            _p.losses = _p.losses + 1
            current_user.record = "wins," .. _p.wins .. ",losses," .. _p.losses
            update_user_record()
        end
    end
    write(winner_name .. " wins!")
    term.setCursorPos(tw / 2 - 5, th / 2 + 2)
    local parsed_record = parse_record(winner_record)
    if parsed_record.wins ~= -1 and parsed_record.losses ~= -1 then
        write(string.format("They've won %d games", parsed_record.wins))
        term.setCursorPos(tw / 2 - 3, th / 2 + 3)
        write(string.format("and lost %d", parsed_record.losses))
    end
    term.setCursorPos(tw / 2 - 8, th - 2)
    write("Press any key to leave")
    local evt
    while true do
        evt = {os.pullEvent()}
        if evt[1] == "key" then
            game_state = "menu"
            state = reset_state()
            return
        end
    end
end

while true do
    if game_state == "menu" then
        parallel.waitForAny(
            menu
        )
    elseif game_state == "login" then
        parallel.waitForAny(
            login
        )
    elseif game_state == "joining" then
        parallel.waitForAny(
            join_game
        )
    elseif game_state == "hosting" then
        parallel.waitForAny(
            host_game
        )
    elseif game_state == "countdown" then
        parallel.waitForAny(
            countdown
        )            
    elseif game_state == "game" then
        parallel.waitForAny(
            process_input,
            update_state,
            sync_state
        )
        render()
    elseif game_state == "end_game" then
        parallel.waitForAny(
            end_game
        )
    elseif game_state == "exiting" then
        return exit_game()
    end
end
