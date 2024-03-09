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
-- 1. mysql库表设计；  调研yaml文件json化后内容，可先简单key - json设计；
-- 2. 如何获取mysql连接，查询内容；
-- 3. mysql按增量查询；
-- 4. 内存存储格式
-- @module core.config_mysql

local config_local = require("apisix.core.config_local")
local config_util  = require("apisix.core.config_util")
local yaml         = require("tinyyaml")
local mysql        = require("resty.mysql")
local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local new_tab      = require("table.new")
local check_schema = require("apisix.core.schema").check
local profile      = require("apisix.core.profile")
local lfs          = require("lfs")
local file         = require("apisix.cli.file")
local exiting      = ngx.worker.exiting
local insert_tab   = table.insert
local nkeys_tab    = table.nkeys
local type         = type
local ipairs       = ipairs
local setmetatable = setmetatable
local ngx_sleep    = require("apisix.core.utils").sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local sub_str      = string.sub
local tostring     = tostring
local pcall        = pcall
local io           = io
local ngx          = ngx
local format       = string.format
local re_find      = ngx.re.find
local apisix_yaml_path = profile:yaml_path("apisix")
local created_obj  = {}


local _M = {
    version = 0.1,
    local_conf = config_local.local_conf,
    clear_local_cache = config_local.clear_cache,
}


local mt = {
    __index = _M,
    __tostring = function(self)
        return "mysql_rep key: " .. (self.key or "")
    end
}


local apisix_yaml
local apisix_yaml_ctime

-- mysql变量
local apisix_mysql_config
local route_last_ctime = "0000-00-00 00:00:00"

local query_routes_sql_template = [[
    select uri, route_name, enable_websocket, upstream_code
    from apisix.routes where delete_flag = 0 and update_time between '%s' and '%s'
]]

local query_upstreams_sql_template = [[
    select upstream_code, node_address, weight, type 
    from apisix.upstream where delete_flag = 0 and upstream_code IN (%s)
]]

--- 查找apisix routes
--[[
    routes list<map> 格式如下
    [
        {
            "uri": "/index.html",
            "methods": ["PUT", "GET"],
            "enable_websocket": true,
            "upstream": {
                "type": "roundrobin",
                "nodes": {
                    "127.0.0.1:1980": 1,
                    "127.0.0.1:1981": 2
                }
            }
        },
        {
            
        }
    ]
--]]
---@param self 本模块指针
local function query_routes(last_fetch_time, self)
    local nowStr = os.date("%Y-%m-%d %H:%M:%S", last_fetch_time)
    if route_last_ctime == nowStr then
        return
    end

    local db_cli, err = mysql:new()
    if not db_cli then
        log.error("failed to instantiate mysql: ", err)
        return
    end
    db_cli:set_timeout(3000)
    
    log.info("mysql config is ", json.delay_encode(apisix_mysql_config))
    local ok, err, errcode, sqlstate = db_cli:connect(apisix_mysql_config)
    if not ok then
        log.error("failed to connect mysql: ", err, ", ", errcode, ", ", sqlstate)
        return
    end

    local query_routes_sql = format(query_routes_sql_template, route_last_ctime, nowStr)
    log.info("query routes ", query_routes_sql)
    local res, err, errcode, sqlstate = db_cli:query(query_routes_sql)
    if not ok then
        log.error("query routes error: ", err, ", ", errcode, ", ", sqlstate)
        return    
    end

    if not #res then
        log.info("not routes info")
        route_last_ctime = nowStr
        return
    end

    local route_map = new_tab(0, 1)
    local upstream_list = new_tab(1, 0)
    for i, route in ipairs(res) do
        insert_tab(upstream_list, "'" .. route["upstream_code"] .. "'")
        route_map[route.uri] = route
        -- route特殊处理
        route.enable_websocket = (route.enable_websocket == 1 or false)
    end
    
    -- 查询upstream
    local upstream_str = table.concat(upstream_list, ",")
    local query_upstreams_sql = format(query_upstreams_sql_template, upstream_str)
    local res_upstream, err_upstream, errcode_upstream, sqlstate_upstream = db_cli:query(query_upstreams_sql)
    log.info("query upstream-sql ", query_upstreams_sql)
    if not res_upstream then
        log.info("query upstream config")
        return
    end

    if not #res_upstream then
        log.info("no upstream config")
        return
    end

    --[[ upstream_map schema  聚合upstream_map
        {
            "type": "chash",
            "key": "remote_addr",
            "nodes": {
                "127.0.0.1:80": 1,
                "httpbin.org:80": 2
            }
        }
    --]] 
    local upstream_map = new_tab(0, 1)
    for i, v in ipairs(res_upstream) do
        if nil == upstream_map[v.upstream_code] then
            upstream_map[v.upstream_code] = v
            v.nodes = {}
        end
        upstream_map[v.upstream_code].nodes[v.node_address] = v.weight
        -- -- 如果已经存在，把nodes追加进去
        -- if upstream_map[v.upstream_code] then
        --     upstream_map[v.upstream_code].nodes[v.node_address] = v.weight
        -- else
        --     -- 不存在，新建nodes
        --     upstream_map[v.upstream_code] = v
        --     v.nodes = {}
        --     v.nodes[v.node_address] = v.weight
        -- end
    end

    for k, v in pairs(route_map) do
        local uri_upstream = upstream_map[v.upstream_code]
        if nil ~= uri_upstream and uri_upstream then
            v.upstream = uri_upstream
        end
    end

    -- 按json格式封装数据 route_list
    local num_uri = nkeys_tab(route_map)
    log.info("num of uri is ", num_uri)

    local route_list = new_tab(num_uri, 0)
    local route_idx_map = new_tab(0, num_uri)

    for k, v in pairs(route_map) do
        insert_tab(route_list, v)
        route_idx_map[k] = #route_map
    end

    log.info("query routes res", json.delay_encode(route_map))
    if not err then
        db_cli:set_keepalive(120 * 1000, 1)
    end

    return route_list
end


-- @TODO 第一次获取全部数据；后几次根据时间增量刷新
local function read_apisix_mysql(premature, pre_mtime)
    if premature then
        return
    end

    local last_fetch_time = ngx.time()

    local routes = query_routes(last_fetch_time)

    if not routes then
        log.info("无变化 ", last_fetch_time)
        return
    end

    local apisix_mysql_new = {}
    apisix_mysql_new['routes'] = routes

    apisix_yaml = apisix_mysql_new
    apisix_yaml_ctime = last_fetch_time
end


-- @TODO 定时任务调用时，如何改成增量

local function read_apisix_yaml(premature, pre_mtime)
    if premature then
        return
    end
    local attributes, err = lfs.attributes(apisix_yaml_path)
    if not attributes then
        log.error("failed to fetch ", apisix_yaml_path, " attributes: ", err)
        return
    end
    -- 监控yaml文件变更时间
    log.info("lfs attributes change: ", json.encode(attributes))
    local last_change_time = attributes.change
    if apisix_yaml_ctime == last_change_time then
        return
    end
    log.info("read apisix_yaml_file ", apisix_yaml_path)
    local f, err = io.open(apisix_yaml_path, "r")
    if not f then
        log.error("failed to open file ", apisix_yaml_path, " : ", err)
        return
    end

    f:seek('end', -10)
    local end_flag = f:read("*a")
    -- log.info("flag: ", end_flag)
    local found_end_flag = re_find(end_flag, [[#END\s*$]], "jo")

    if not found_end_flag then
        f:close()
        log.warn("missing valid end flag in file ", apisix_yaml_path)
        return
    end

    f:seek('set')
    local yaml_config = f:read("*a")
    f:close()

    local apisix_yaml_new = yaml.parse(yaml_config)
    if not apisix_yaml_new then
        log.error("failed to parse the content of file " .. apisix_yaml_path)
        return
    end

    local ok, err = file.resolve_conf_var(apisix_yaml_new)
    if not ok then
        log.error("failed: failed to resolve variables:" .. err)
        return
    end

    apisix_yaml = apisix_yaml_new
    apisix_yaml_ctime = last_change_time
end
 
local function sync_data(self)
    if not self.key then
        return nil, "missing 'key' arguments"
    end

    if not apisix_yaml_ctime then
        log.warn("wait for more time")
        return nil, "failed to read local file " .. apisix_yaml_path
    end

    if self.conf_version == apisix_yaml_ctime then
        return true
    end

    local items = apisix_yaml[self.key]
    log.info(self.key, " items: ", json.delay_encode(items))
    if not items then
        self.values = new_tab(8, 0)
        self.values_hash = new_tab(0, 8)
        self.conf_version = apisix_yaml_ctime
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
        local conf_item = {value = item, modifiedIndex = apisix_yaml_ctime,
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
            local conf_item = {value = item, modifiedIndex = apisix_yaml_ctime,
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
                self.values_hash[item_id] = #self.values
                conf_item.value.id = item_id
                conf_item.clean_handlers = {}

                if self.filter then
                    self.filter(conf_item)
                end
            end
        end
    end

    self.conf_version = apisix_yaml_ctime
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
        ngx_timer_at(0, _automatic_fetch, self)
    end
end


function _M.new(key, opts)
    log.info("创建实例...", key)
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end

    local automatic = opts and opts.automatic
    local item_schema = opts and opts.item_schema
    local filter_fun = opts and opts.filter
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
        log.info("调用sync_data同步")
        local ok, ok2, err = pcall(sync_data, obj)
        if not ok then
            err = ok2
        end

        if err then
            log.error("failed to fetch data from local file ", apisix_yaml_path, ": ",
                      err, ", ", key)
        end

        ngx_timer_at(0, _automatic_fetch, obj)
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
    return "apisix.yaml " .. _M.version
end


function _M.fetch_created_obj(key)
    return created_obj[sub_str(key, 2)]
end


function _M.init()
    -- mysql 数据库配置
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end
    apisix_mysql_config = local_conf.deployment.mysql
    log.info("mysql config ", json.delay_encode(apisix_mysql_config))

    read_apisix_mysql()

    -- 全量查mysql配置  
    -- read_apisix_yaml()
    return true
end


function _M.init_worker()
    -- mysql db config from yaml-config
    local local_conf, err = config_local.local_conf()
    if not local_conf then
        return nil, err
    end
    apisix_mysql_config = local_conf.deployment.mysql
    log.info("mysql config ", json.delay_encode(apisix_mysql_config))
    -- sync data in each non-master process
    ngx.timer.every(30, read_apisix_mysql)
    -- ngx.timer.every(1, read_apisix_yaml)

    return true
end


return _M
