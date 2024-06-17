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
local yaml         = require("tinyyaml")
local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local new_tab      = require("table.new")
local check_schema = require("apisix.core.schema").check
local profile      = require("apisix.core.profile")
local lfs          = require("lfs")
local file         = require("apisix.cli.file")
local exiting      = ngx.worker.exiting
local insert_tab   = table.insert
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
local re_find      = ngx.re.find
local apisix_yaml_path = profile:yaml_path("apisix")
local created_obj  = {}


local _M = {
    version = 0.2,
    local_conf = config_local.local_conf,
    clear_local_cache = config_local.clear_cache,
}


local mt = {
    __index = _M,
    __tostring = function(self)
        return "apisix.yaml key: " .. (self.key or "")
    end
}


local apisix_yaml
local apisix_yaml_ctime
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
    log.info("read_apisix_yaml_file ", apisix_yaml_path, ", last_change_time ", last_change_time)
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
    _M.apisix_config = apisix_yaml_new
    log.info("last_change_time ", last_change_time, ", resolve_apisix_yaml_file ", json.encode(_M.apisix_config))
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
    log.info("apisix_yaml: ", json.delay_encode(apisix_yaml))
    log.info(self.key, " items: ", json.delay_encode(items))
    if not items then
        -- 创建数组:size = 8
        self.values = new_tab(8, 0)
        -- 创建map:size=8
        self.values_hash = new_tab(0, 8)
        self.conf_version = apisix_yaml_ctime
        return true
    end

    -- 原self.values数据
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
        -- 创建values  list 和 map
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
                -- 检查格式
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

function _M.yaml_config(self)
    return self.apisix_config
end

function _M.init()
    read_apisix_yaml()
    return true
end


function _M.init_worker()
    -- sync data in each non-master process
    ngx.timer.every(30, read_apisix_yaml)

    return true
end


return _M
