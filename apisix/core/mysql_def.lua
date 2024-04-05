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

--- mysql配置，连接定义、查询语句定义
-- @module core.mysql_def

local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local new_tab      = require("table.new")
local mysql        = require("resty.mysql")
local format       = string.format
local ipairs       = ipairs
local setmetatable = setmetatable

local _M = {version = 0.1}

-- 按时间查询路由配置sql样本
_M.query_routes_sql_template = [[
    select id, uris, name, mark_desc, methods, enable_websocket, vars, upstream_id
    from routes where delete_flag = 0 and update_time between '%s' and '%s'
]]

-- 按时间查询上游配置sql样本
_M.query_upstreams_sql_template = [[
    select id, name, mark_desc, retries, timeout, nodes, type, scheme 
    from upstreams where delete_flag = 0 and update_time between '%s' and '%s'
]]

-- 按时间查询路由
function _M.query_routes_by_time(self, fetch_start_time, fetch_end_time)
    local nowStr = os.date("%Y-%m-%d %H:%M:%S", fetch_end_time)
    local route_last_ctime = "0000-00-00 00:00:00"
    if nil ~= fetch_start_time then
        route_last_ctime = os.date("%Y-%m-%d %H:%M:%S", fetch_start_time)
    end

    local query_routes_sql = format(self.query_routes_sql_template, route_last_ctime, nowStr)
    log.info("query routes ", query_routes_sql)
    
    local res, err, errcode, sqlstate = self.db_cli:query(query_routes_sql)
    if not res then
        log.error("query routes error: ", err, ", ", errcode, ", ", sqlstate)
        return    
    end
    -- res, err, errcode, sqlstate = self.db_cli:read_result()
    if nil == next(res) then
        log.info("no new routes info")
        return
    end
    log.info("query route: ", err)
    local route_list = res
    local route_map = new_tab(0, #route_list)
    for i, route in ipairs(route_list) do
        route.enable_websocket = (route.enable_websocket == 1)
        if route.uris then
            route.uris = json.decode(route.uris)
        end
        if route.methods then
            route.methods = json.decode(route.methods)
        end
        if route.hosts then
            route.hosts = json.decode(route.hosts)
        end
        if route.vars then
            route.vars = json.decode(route.vars)
        end

        route_map["r" .. route.id] = route
    end
    
    -- res, err, errcode, sqlstate = self.db_cli:read_result()
    log.info("query route: ", err)
    log.info("query routes list ", json.delay_encode(route_list), ", ", json.delay_encode(route_map))
    -- local ok, err = self.db_cli:set_keepalive(self.db_config, 5)
    -- if not ok then
    --     log.info("mysql keepalive err: ", err)
    -- end

    return route_list, route_map
end

--[[
根据时间段查询上游配置
--]]
function _M.query_upstreams_by_time(self, fetch_start_time, fetch_end_time)
    local nowStr = os.date("%Y-%m-%d %H:%M:%S", fetch_end_time)
    local last_ctime = "0000-00-00 00:00:00"
    if nil ~= fetch_start_time then
        last_ctime = os.date("%Y-%m-%d %H:%M:%S", fetch_start_time)
    end

    local query_upstreams_sql = format(self.query_upstreams_sql_template, last_ctime, nowStr)
    log.info("query upstreams ", query_upstreams_sql)

    local res, err, errcode, sqlstate = self.db_cli:query(query_upstreams_sql)
    if not res then
        log.error("query upstreams error: ", err, ", ", errcode, ", ", sqlstate)
        return    
    end
    
    if nil == next(res) then
        log.info("no new upstreams info")
        return
    end

    local upstream_list = res
    local upstream_map = new_tab(0, #upstream_list)
    for i, upstream in ipairs(upstream_list) do
        if upstream.nodes then
            upstream.nodes = json.decode(upstream.nodes)
        end
        if upstream.timeout then
            upstream.timeout = json.decode(upstream.timeout)
        end

        upstream_map["u" .. upstream.id] = upstream
    end
    
    -- res, err, errcode, sqlstate = self.db_cli:read_result()
    log.info("query routes list ", json.delay_encode(upstream_list), ", ", json.delay_encode(upstream_map))
    -- local ok, err = self.db_cli:set_keepalive(self.db_config, 5)
    -- if not ok then
    --     log.info("mysql keepalive err: ", err)
    -- end

    return upstream_list, upstream_map
end

-- 创建实例
function _M.new(self, db_config)
    -- 创建连接
    local db_cli, err = mysql:new()
    if not db_cli then
        log.error("failed to instantiate mysql: ", err)
        return
    end
    db_cli:set_timeout((db_config.timeout or 3000))

    local ok, err, errcode, sqlstate = db_cli:connect(db_config)
    if not ok then
        log.error("failed to connect mysql: ", err, ", ", errcode, ", ", sqlstate)
        return
    end

    return setmetatable({
        db_cli = db_cli,
        db_config = db_config
    }, {
        __index = _M
    })
end

return _M