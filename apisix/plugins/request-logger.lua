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
-- api请求日志监控
--
-- local log_util     =   require("apisix.utils.log-util")
local core         =   require("apisix.core")
local template     =   require("resty.template")
local ngx          =   ngx
local ngx_now      =   ngx.now
local io_open      =   io.open
local shared       =   ngx.shared["worker-events"]

local plugin_name = "request-logger"
local worker_start_time = shared:get("worker_start_time_" .. ngx.worker.pid())


local schema = {
    type = "object",
    properties = {
        path = {
            type = "string"
        },
        log_format = {type = "string"}
    },
    required = {"path", "log_format"}
}



local _M = {
    version = 0.1,
    priority = 493,
    name = plugin_name,
    schema = schema
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local open_file_cache
if worker_start_time then
    -- TODO: switch to a cache which supports inactive time,
    -- so that unused files would not be cached
    local path_to_file = core.lrucache.new({
        type = "plugin",
    })

    local function open_file_handler(conf, handler)
        local file, err = io_open(conf.path, 'a+')
        if not file then
            return nil, err
        end

        -- it will case output problem with buffer when log is larger than buffer
        file:setvbuf("no")

        handler.file = file
        handler.open_time = ngx.now() * 1000
        return handler
    end

    --[[
        把文件句柄缓存到lru中，避免多进程多次打开
    --]]
    function open_file_cache(conf)
        local last_reopen_time = worker_start_time * 1000

        local handler, err = path_to_file(conf.path, 0, open_file_handler, conf, {})
        if not handler then
            return nil, err
        end
        -- 如果文件句柄时间 小于 进程打开时间，则表示worker进程重启过，关闭文件句柄重新打开
        if handler.open_time < last_reopen_time then
            core.log.notice("reopen cached log file: ", conf.path)
            handler.file:close()

            local ok, err = open_file_handler(conf, handler)
            if not ok then
                return nil, err
            end
        end

        return handler.file
    end
end


local function write_file_data(conf, log_message)
    local msg = core.json.encode(log_message)

    local file, err
    if open_file_cache then
        core.log.info("require resty-apisix-process true")
        file, err = open_file_cache(conf)
    else
        core.log.info("require resty-apisix-process false")
        file, err = io_open(conf.path, 'a+')
    end

    if not file then
        core.log.error("failed to open file: ", conf.path, ", error info: ", err)
    else
        -- file:write(msg, "\n") will call fwrite several times
        -- which will cause problem with the log output
        -- it should be atomic
        msg = msg .. "\n"
        -- write to file directly, no need flush
        local ok, err = file:write(msg)
        if not ok then
            core.log.error("failed to write file: ", conf.path, ", error info: ", err)
        end

        -- file will be closed by gc, if open_file_cache exists
        if not open_file_cache then
            file:close()
        end
    end
end

-- function _M.body_filter(conf, ctx)
--     log_util.collect_body(conf, ctx)
-- end

local function request_info(ctx)
    local var = ctx.var
    local now_time = ngx_now()

    local log_time = os.date("%Y-%m-%d %H:%M:%S", now_time)
    local latency = (now_time - ngx.req.start_time()) * 1000

    local log =  {
        log_time = log_time,
        request_uri = var.request_uri,
        start_time = ngx.req.start_time() * 1000,
        host = var.host,
        method = ngx.req.get_method(),
        status = ngx.status,
        upstream = var.upstream_addr,
        client_ip = core.request.get_remote_client_ip(ngx.ctx.api_ctx),
        cost_time = latency
    }
    return log
end

function _M.log(conf, ctx)
    core.log.info("file-logger starting")
    local conf_render = template.compile(conf.log_format)
    local info_map = request_info(ctx)
    local entry = conf_render(info_map)
    write_file_data(conf, entry)
end


return _M
