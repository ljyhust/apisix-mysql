--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

--- Get configuration information in Stand-alone mode.
--
-- @module core.config_yaml

local config_local = require("apisix.core.config_local")
local config_util  = require("apisix.core.config_util")
local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local new_tab      = require("table.new")
local check_schema = require("apisix.core.schema").check
local profile      = require("apisix.core.profile")
local exiting      = ngx.worker.exiting
local insert_tab   = table.insert
local type         = type
local ipairs       = ipairs
local pairs        = pairs
local setmetatable = setmetatable
local ngx_sleep    = require("apisix.core.utils").sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local sub_str      = string.sub
local tostring     = tostring
local pcall        = pcall
local ngx          = ngx
local apisix_yaml_path = profile:yaml_path("apisix")
local created_obj  = {}
local mysql_def    = require("apisix.core.mysql_def")


local _M = {
    version = 0.2,
    local_conf = config_local.local_conf,
    clear_local_cache = config_local.clear_cache,
}


local mt = {
    __index = _M,
    __tostring = function(self)
        return "apisix_mysql_table key: " .. (self.key or "")
    end
}


local apisix_mysql
local apisix_mysql_ctime
-- mysql db 连接配置
local mysql_config
local mysql_cli
-- local route_last_ctime = "0000-00-00 00:00:00"

--[[
    获取最新更新的routes
    2024-04-03
--]]
local function merge_change_routes(start_ctime, end_ctime, old_routes)
    local u_routes, u_route_map = mysql_cli.query_routes_by_time(mysql_cli, start_ctime, end_ctime)

    --无变更， 返回旧的
    if not u_routes or next(u_routes) == nil then
        log.info("routes配置无变更....")
        return old_routes
    end
    log.info("routes 配置变更  ", json.delay_encode(u_routes))

    if nil == old_routes or next(old_routes) == nil then
        return u_routes
    end

    log.info("增量合并: ", json.delay_encode(u_route_map, true))
    -- @TODO增量合并，先复制后转引用，防止并发内存数据中断
    -- clone
    local new_routes = new_tab(1, 0)

    log.info("合并之前: ", json.delay_encode(old_routes, true))
    for i, v in ipairs(old_routes) do
        local key = "r" .. v.id
        if u_route_map[key] then
            -- 如果存在，放入new_routes中，并删除u_route_map中的数据
            insert_tab(new_routes, u_route_map[key])
            u_route_map[key] = {}
        else
            -- 如果原来已存在，本次无更新，继承存入
            insert_tab(new_routes, v)
        end
    end
    --合并u_route_map新的内容
    log.info("新增部分配置: ", json.delay_encode(u_route_map, true))
    for k, v in pairs(u_route_map) do
        if v and next(v) ~= nil then
            insert_tab(new_routes, v)
        end
    end
    log.info("routes合并之后: ", json.delay_encode(new_routes, true))
    return new_routes
end

--[[
    获取最新更新的upstreams
    2024-04-03
--]]
local function merge_change_upstreams(start_ctime, end_ctime, old_upstreams)
    local u_upstreams, u_upstream_map = mysql_cli.query_upstreams_by_time(mysql_cli, start_ctime, end_ctime)

    --无变更，返回原数据
    if not u_upstreams or next(u_upstreams) == nil then
        log.info("upstreams配置无变更....")
        return old_upstreams
    end
    log.info("upstreams 配置变更  ", json.delay_encode(u_upstreams))

    if nil == old_upstreams or next(old_upstreams) == nil then
        return u_upstreams
    end

    log.info("增量合并: ", json.delay_encode(u_upstream_map, true))
    --@TODO增量合并，先复制后转引用，防止并发内存数据中断
    --clone
    local new_upstreams = new_tab(1, 0)

    log.info("合并之前: ", json.delay_encode(old_upstreams, true))
    for i, v in ipairs(old_upstreams) do
        local key = "u" .. v.id
        if u_upstream_map[key] then
            -- 如果存在，放入new_upstreams中，并删除u_route_map中的数据
            insert_tab(new_upstreams, u_upstream_map[key])
            u_upstream_map[key] = {}
        else
            -- 如果原来已存在，本次无更新，继承存入
            insert_tab(new_upstreams, v)
        end
    end
    -- 合并u_route_map新的内容
    log.info("新增部分配置: ", json.delay_encode(u_upstream_map, true))
    for k, v in pairs(u_upstream_map) do
        if v and next(v) ~= nil then
            insert_tab(new_upstreams, v)
        end
    end
    log.info("合并之后: ", json.delay_encode(new_upstreams, true))
    return new_upstreams
end

--[[
    获取最新更新的插件配置
--]]
local function merge_change_plugin_confs(start_ctime, end_ctime, old_plugin_confs)
    local u_plugin_confs, u_plugin_conf_map = mysql_cli.query_plugin_configs_by_time(mysql_cli, start_ctime, end_ctime)

    --无变更，返回原数据
    if not u_plugin_confs or next(u_plugin_confs) == nil then
        log.info("plugin_confs配置无变更....")
        return old_plugin_confs
    end
    log.info("plugin_confs 配置变更  ", json.delay_encode(u_plugin_confs))

    if nil == old_plugin_confs or next(old_plugin_confs) == nil then
        return u_plugin_confs
    end

    log.info("增量合并: ", json.delay_encode(u_plugin_conf_map, true))
    --@TODO增量合并，先复制后转引用，防止并发内存数据中断
    --clone
    local new_plugin_confs = new_tab(1, 0)

    log.info("合并之前: ", json.delay_encode(old_plugin_confs, true))
    for i, v in ipairs(old_plugin_confs) do
        local key = "p" .. v.id
        if u_plugin_conf_map[key] then
            -- 如果存在，放入new中，并删除map中的数据
            insert_tab(new_plugin_confs, u_plugin_conf_map[key])
            u_plugin_conf_map[key] = {}
        else
            -- 如果原来已存在，本次无更新，继承存入
            insert_tab(new_plugin_confs, v)
        end
    end
    -- 合并_map新的内容
    log.info("新增部分配置: ", json.delay_encode(u_plugin_conf_map, true))
    for k, v in pairs(u_plugin_conf_map) do
        if v and next(v) ~= nil then
            insert_tab(new_plugin_confs, v)
        end
    end
    log.info("合并之后: ", json.delay_encode(new_plugin_confs, true))
    return new_plugin_confs
end

-- @TODO 第一次获取全部数据；后几次根据时间增量刷新
local function read_apisix_mysql(premature, pre_mtime)
    if premature then
        return
    end

    local current_time = ngx.time()
    if apisix_mysql_ctime == current_time then
        log.info("无时间变化，不拉最新数据")
       return 
    end

    local old_routes = nil
    local old_upstreams = nil
    local old_plugin_confs = nil
    if nil ~= apisix_mysql and next(apisix_mysql) ~= nil then
        old_routes = apisix_mysql["routes"]
    end

    if nil ~= apisix_mysql and next(apisix_mysql) ~= nil then
        old_upstreams = apisix_mysql["upstreams"]
    end

    if nil ~= apisix_mysql and next(apisix_mysql) ~= nil then
        old_plugin_confs = apisix_mysql["plugin_configs"]
    end

    local new_routes = merge_change_routes(apisix_mysql_ctime, current_time, old_routes)
    local new_upstreams = merge_change_upstreams(apisix_mysql_ctime, current_time, old_upstreams)
    local new_plugin_cons = merge_change_plugin_confs(apisix_mysql_ctime, current_time, old_plugin_confs)
    
    apisix_mysql.routes = new_routes
    apisix_mysql.upstreams = new_upstreams
    apisix_mysql.plugin_configs = new_plugin_cons

    apisix_mysql_ctime = current_time
    log.info("当前配置为 ", json.delay_encode(apisix_mysql, true))
end

--[[
    同步配置到模块对象内存中
先清除self.values，再新增self.values=new_tab()
--]]
local function sync_data(self)
    if not self.key then
        return nil, "missing 'key' arguments"
    end

    if not apisix_mysql_ctime then
        log.warn("wait for more time")
        return nil, "failed to read local file " .. apisix_yaml_path
    end

    if self.conf_version == apisix_mysql_ctime then
        return true
    end

    local items = apisix_mysql[self.key]
    log.info(self.key, " items: ", json.delay_encode(items))
    if not items then
        self.values = new_tab(8, 0)
        self.values_hash = new_tab(0, 8)
        self.conf_version = apisix_mysql_ctime
        return true
    end

    if self.values then
        for _, item in ipairs(self.values) do
            config_util.fire_all_clean_handlers(item)
        end
        self.values = nil
    end

    if self.single_item then
        -- treat items as a single item
        self.values = new_tab(1, 0)
        self.values_hash = new_tab(0, 1)

        local item = items
        local conf_item = {value = item, modifiedIndex = apisix_mysql_ctime,
                           key = "/" .. self.key}

        local data_valid = true
        local err
        if self.item_schema then
            data_valid, err = check_schema(self.item_schema, item)
            if not data_valid then
                log.error("failed to check item data of [", self.key,
                          "] err:", err, " ,val: ", json.delay_encode(item))
            end

            if data_valid and self.checker then
                data_valid, err = self.checker(item)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.delay_encode(item))
                end
            end
        end

        if data_valid then
            insert_tab(self.values, conf_item)
            self.values_hash[self.key] = #self.values
            conf_item.clean_handlers = {}

            if self.filter then
                self.filter(conf_item)
            end
        end

    else
        self.values = new_tab(#items, 0)
        self.values_hash = new_tab(0, #items)

        local err
        for i, item in ipairs(items) do
            local id = tostring(i)
            local data_valid = true
            if type(item) ~= "table" then
                data_valid = false
                log.error("invalid item data of [", self.key .. "/" .. id,
                          "], val: ", json.delay_encode(item),
                          ", it should be an object")
            end

            local key = item.id or "arr_" .. i
            local conf_item = {value = item, modifiedIndex = apisix_mysql_ctime,
                            key = "/" .. self.key .. "/" .. key}

            if data_valid and self.item_schema then
                data_valid, err = check_schema(self.item_schema, item)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.delay_encode(item))
                end
            end

            if data_valid and self.checker then
                data_valid, err = self.checker(item)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.delay_encode(item))
                end
            end

            if data_valid then
                insert_tab(self.values, conf_item)
                local item_id = conf_item.value.id or self.key .. "#" .. id
                item_id = tostring(item_id)
                -- 元素位置，通过values_hash[item_id]可找到对应最新数据索引位置
                self.values_hash[item_id] = #self.values
                conf_item.value.id = item_id
                conf_item.clean_handlers = {}

                if self.filter then
                    self.filter(conf_item)
                end
            end
        end
    end
    
    self.conf_version = apisix_mysql_ctime

    -- 同步完成后，配置被修改，导致无法json化
    log.info("同步完成后，当前配置为 ", json.delay_encode(apisix_mysql, true))
    
    return true
end


function _M.get(self, key)
    if not self.values_hash then
        return
    end

    local arr_idx = self.values_hash[tostring(key)]
    if not arr_idx then
        return nil
    end

    return self.values[arr_idx]
end


local function _automatic_fetch(premature, self)
    if premature then
        return
    end

    local i = 0
    while not exiting() and self.running and i <= 32 do
        i = i + 1
        local ok, ok2, err = pcall(sync_data, self)
        if not ok then
            err = ok2
            log.error("failed to fetch data from local file " .. apisix_yaml_path .. ": ",
                      err, ", ", tostring(self))
            ngx_sleep(3)
            break

        elseif not ok2 and err then
            if err ~= "timeout" and err ~= "Key not found"
               and self.last_err ~= err then
                log.error("failed to fetch data from local file " .. apisix_yaml_path .. ": ",
                          err, ", ", tostring(self))
            end

            if err ~= self.last_err then
                self.last_err = err
                self.last_err_time = ngx_time()
            else
                if ngx_time() - self.last_err_time >= 30 then
                    self.last_err = nil
                end
            end
            ngx_sleep(0.5)

        elseif not ok2 then
            ngx_sleep(0.05)

        else
            ngx_sleep(0.1)
        end
    end

    if not exiting() and self.running then
        ngx_timer_at(10, _automatic_fetch, self)
    end
end


function _M.new(key, opts)
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end

    local automatic = opts and opts.automatic
    local item_schema = opts and opts.item_schema
    local filter_fun = opts and opts.filter
    -- 是否只有一条数据item
    local single_item = opts and opts.single_item
    local checker = opts and opts.checker

    -- like /routes and /upstreams, remove first char `/`
    if key then
        key = sub_str(key, 2)
    end

    local obj = setmetatable({
        automatic = automatic,
        item_schema = item_schema,
        checker = checker,
        sync_times = 0,
        running = true,
        conf_version = 0,
        values = nil,
        routes_hash = nil,
        prev_index = nil,
        last_err = nil,
        last_err_time = nil,
        key = key,
        single_item = single_item,
        filter = filter_fun,
    }, mt)

    if automatic then
        if not key then
            return nil, "missing `key` argument"
        end

        local ok, ok2, err = pcall(sync_data, obj)
        if not ok then
            err = ok2
        end

        if err then
            log.error("failed to fetch data from mysql datasource ", mysql_config.host, ": ",
                      err, ", ", key)
        end

        ngx_timer_at(10, _automatic_fetch, obj)
    end

    if key then
        created_obj[key] = obj
    end

    return obj
end


function _M.close(self)
    self.running = false
end


function _M.server_version(self)
    return "apisix_mysql " .. _M.version
end


function _M.fetch_created_obj(key)
    return created_obj[sub_str(key, 2)]
end


function _M.init()
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end
    mysql_config = local_conf.deployment.mysql
    log.info("mysql config ", json.delay_encode(mysql_config))
    mysql_cli = mysql_def:new(mysql_config)

    if not apisix_mysql then
        apisix_mysql = {}
    end
    read_apisix_mysql()
    return true
end


function _M.init_worker()
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end
    mysql_config = local_conf.deployment.mysql
    log.info("mysql config ", json.delay_encode(mysql_config))
    mysql_cli = mysql_def:new(mysql_config)
    -- sync data in each non-master process
    ngx.timer.every(30, read_apisix_mysql)

    return true
end

return _M
