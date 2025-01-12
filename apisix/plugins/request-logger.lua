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
local lfs          =   require("lfs")
local timers       =   require("apisix.timers")
local process      =   require("ngx.process")
local signal       =   require("resty.signal")
local ngx          =   ngx
local ngx_now      =   ngx.now
local ngx_time     =   ngx.time
local ngx_update_time = ngx.update_time
local io_open      =   io.open
local shared       =   ngx.shared["worker-events"]
local math         =   math
local os_date      =   os.date
local os_rename    =   os.rename
local str_format   =   string.format

local plugin_name = "request-logger"
local get_worker_pid = ngx.worker.pid()


local schema = {
    type = "object",
    properties = {
        path = {
            type = "string"
        },
        log_format = {type = "string"},
        log_file_max_size = {type = "integer", default = 100, minimum = 10},
        log_file_max_kept = {type = "integer"}
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

local last_log_rotate_date = ngx_time()
local LOG_PATH_CACHE = nil
local LOG_FILE_MAX_SIZE = 100

local open_file_cache
if get_worker_pid then
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
        local last_reopen_time = shared:get("worker_start_time_" .. ngx.worker.pid()) * 1000

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
    --local msg = core.json.encode(log_message)
    local msg = log_message
    local file, err
    if open_file_cache then
        core.log.info("cached open file")
        file, err = open_file_cache(conf)
    else
        core.log.info("open file without cache")
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
    local latency = math.floor((now_time - ngx.req.start_time()) * 1000)

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

local function file_size(file)
    local attr = lfs.attributes(file)
    if attr then
        return attr.size
    end
    return 0
end

--[[
判断文件是否存在
--]]
local function file_exists(path)
    local file = io_open(path, "r")
    if file then
        file:close()
    end
    return file ~= nil
end

--[[
重命令文件
--]]
local function rename_file(file_path, date_str)
    local new_file_path = str_format(file_path .. "-%s", date_str)
    if file_exists(new_file_path) then
        core.log.info("file exist: ", new_file_path)
        return new_file_path
    end
    
    local ok, err = os_rename(file_path, new_file_path)
    if not ok then
        core.log.error("move file from ", file_path, " to ", new_file_path,
                       " res:", ok, " msg:", err)
        return
    end

    return new_file_path

end

--[[
滚动文件
--]]
local function rotate_file(file_path, current_time)
    core.log("rotate_file starting...")
    local now_date = os_date("%Y-%m-%d_%H-%M-%S", current_time)
    local new_file = rename_file(file_path, now_date)
    if not new_file then
        return
    end
    -- 重新打开日志文件
    local pid = process.get_master_pid()
    core.log.warn("send USR1 signal to master process [", pid, "] for reopening log file")
    local ok, err = signal.kill(pid, signal.signum("USR1"))
    if not ok then
        core.log.error("failed to send USR1 signal for reopening log file: ", err)
    end
end

--[[
判断日志滚动条件，按日期及大小滚动，如果是隔天，则滚动；如果文件大小也超过，则滚动
--]]
local function rotate()
    local file_path = LOG_PATH_CACHE
    if not file_path then
        return
    end
    ngx_update_time()
    local now_time = ngx_time()
    -- 判断上次滚动时间与本次是否同一天，如果不是，则需要滚动
    local current_date = os_date("*.t", now_time)
    local last_date = os_date("*t", last_log_rotate_date)
    if not (current_date.year == last_date.year 
        and current_date.month == last_date.month 
        and current_date.day == last_date.day) then
        core.log("日志两次不是同一天，需要滚动")
        rotate_file(file_path, now_time)
        last_log_rotate_date = now_time
        return
    end

    local max_size = LOG_FILE_MAX_SIZE
    -- 判断当前路径的日志path 大小
    local log_size = file_size(file_path)
    if log_size >= max_size then
        rotate_file(file_path, now_time)
    end
    last_log_rotate_date = now_time

end

function _M.init()
    -- 记录worker进程启动时间
    local start_time = ngx_now() * 1000
    core.log.info("worker process start ", ngx.worker.pid())
    shared:set("worker_start_time_" .. ngx.worker.pid(), start_time)
    -- 启动日志滚动定时任务
    timers.register_timer("plugin#request-logger", rotate, true)
end

function _M.destroy()
    -- 清除worker进程时间
    shared:delete("worker_start_time_" .. ngx.worker.pid())
    -- 清除定时任务
    timers.unregister_timer("plugin#request-logger", true)
end

function _M.log(conf, ctx)
    core.log.info("file-logger starting")
    local conf_render = template.compile(conf.log_format)
    local info_map = request_info(ctx)
    local entry = conf_render(info_map)
    write_file_data(conf, entry)

    -- 缓存配置
    if not LOG_PATH_CACHE then
        LOG_PATH_CACHE = conf.path
    end
    LOG_FILE_MAX_SIZE = conf.log_file_max_size
end


return _M
