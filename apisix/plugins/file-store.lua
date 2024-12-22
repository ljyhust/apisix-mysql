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
-- 文件上传下载拦截

local ipairs = ipairs
local core   = require("apisix.core")
local table  = table
local upload = require("apisix.core.requpload")
local req_read_body = ngx.req.read_body
local str_find = string.find
local req_get_body_file = ngx.req.get_body_file
local file_open = io.open


local schema = {
    type = "object",
    properties = {
        storageConf = {
            type = "string",
            default = "#storageConf#"
        },
        localStorage = {
            type = "object",
            properties = {
                path = {
                    type = "string",
                    default = "/home/jeang/temp"
                }
            }
        },
        oosStorage = {
            type = "object",
            properties = {
                uri = {
                    type = "string"
                },
                timeout = {
                    type = "integer",
                    minimum = 1,
                    maximum = 60000,
                    default = 3000,
                    description = "timeout in milliseconds",
                },
            },
        },
        keepalive = {type = "boolean", default = true},
        keepalive_timeout = {type = "integer", minimum = 1000, default = 60000},
        keepalive_pool = {type = "integer", minimum = 1, default = 5},
    },
    required = {"storageConf"}
}


local _M = {
    version = 0.1,
    priority = 2003,
    name = "file-store",
    schema = schema,
}

local function split_storage_conf(str, delimiter)
    -- body
    local res = {}
    for match in (str .. delimiter):gmatch("(.-)" .. delimiter) do
        table.insert(res, match)
    end

    local params = {}
    for _, param in ipairs(res) do
        local key, value = param:match("([^=]+)=([^=]+)")
        if key and value then
            params[key] = value  -- 假设你在 OpenResty 中运行
        end
    end
    return params
end


function _M.check_schema(conf)
    core.log.info("file-store schema ....")
    return core.schema.check(schema, conf)
end

local function check_file_upload(ctx)
    -- 获取请求的 Content-Type
    local content_type = core.request.header(ctx, "Content-Type")
    -- 检查是否为 multipart/form-data
    if content_type and str_find(content_type, "multipart/form-data", 1, true) then
        core.log.info("upload_file_check true")
        return true
    end

    return false
end

function _M.access(conf, ctx)
    
    core.log.info("file-store start....")
    local storageConf = core.request.header(ctx, conf.storageConf)
    core.log.info("file-store config", storageConf)
    -- 解析配置
    local storage_headers = split_storage_conf(storageConf, "&")

    -- 如果是本地存储
    if storage_headers["type"] == "local" then
        -- 校验判断是否文件上传类型
        core.log.info("upload type is local")
        local check_file_req = check_file_upload(ctx)
        if check_file_req then
            -- 获取文件并存储
            req_read_body()
            local file_name = req_get_body_file()
            core.log.info("upload_file, uri:", ctx.var.request_uri, ",file_name:", file_name)

            -- local content = core.request.get_body()
            if file_name then
                local content = core.io.get_file()
                core.log.info("upload_file_content ", content)
                -- 写文件
                local dest_file = file_open(conf.localStorage.path .. file_name, "wb")
                dest_file.write(content)
                dest_file.close()
            end
            -- todo 文件不再传给下游，更改为存储路径
            
        end
    end

end




return _M
