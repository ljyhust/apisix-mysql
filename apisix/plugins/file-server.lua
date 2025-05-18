

local core      = require("apisix.core")
local http      = require("resty.http")
local plugin    = require("apisix.plugin")
local ngx       = ngx
local upload    = require("apisix.core.requpload")
local ipairs    = ipairs
local pairs     = pairs
local str_match = string.match
local str_find  = core.string.find
local file_open = io.open
local pl_path   = require("pl.path")

local default_file_dir = "/home/jeang/temp"
local default_uri = "/apisix/fileServer/*"

local FILE_OPT_UPLOAD = "upload"
local FILE_OPT_DOWNLOAD = "view"

local schema = {
    type = "object",
}

local _M = {
    version = 0.1,
    priority = 2005,
    name = "file-server",
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function check_file_upload(ctx)
    -- 获取请求的 Content-Type
    local content_type = core.request.header(ctx, "Content-Type")
    -- 检查是否为 multipart/form-data
    if content_type and str_find(content_type, "multipart/form-data", 1) then
        core.log.info("upload_file_check true")
        return true
    end

    return false
end

local function handle_upload(ctx)
    -- 处理文件上传
    local file_store_path = default_file_dir
    local form, err = upload:new(4096) -- 1MB buffer size
    if not form then
        core.log.error("failed to new upload: ", err)
        return nil
    end
    -- 超时时间可以配置化
    form:set_timeout(1000)

    local file_name
    local file

    while true do
        local typ, res, err = form:read()
        if not typ then
            core.log.info("failed to read ", err)
            return nil
        end
    
        if typ == "header" then
            -- 处理文件头
            if res[1] == "Content-Disposition" then
                -- 获取文件名
                local filename = str_match(res[2], 'filename="([^"]+)"')
                if filename then
                    file_name = filename
                    file = file_open(file_store_path .. "/" .. file_name, "w+")
                    if not file then
                        core.log.error("failed to open file: ", file_name)
                        return nil
                    end
                end
            end
        elseif typ == "body" then
            -- 写入文件内容
            if file then
                file:write(res)
            end
        elseif typ == "part_end" then
            -- 关闭文件
            if file then
                file:close()
                file = nil
            end
        elseif typ == "eof" then
            -- 上传结束
            break
        end
    end
    return 200, {file_uri = file_store_path .. "/" .. file_name}
end

local function handle_download(ctx)
    -- 获取文件名
    local file_name = ctx.var.arg_file_name
    if not file_name then
        return 400, {error_msg = "request failed: 参数错误"}
    end

    local is_attack_path = str_find(file_name, "..", 1, true)
    if is_attack_path then
        return 403, {error_msg = "Forbidden"}
    end

    local file_dir = default_file_dir
    local real_file_path = file_dir .. "/" .. file_name
    if not pl_path.exists(real_file_path) then
        return 404, {error_msg = "file not found"}
    end

    local file = file_open(real_file_path, "rb")
    if not file then
        return 500, {error_msg = "server error"}
    end

    -- 优化文件分块流读取
    local content = file:read("*a")
    file:close()

    return 200, content
end

local function file_operate_handler(ctx)
    -- 解析uri获取文件操作类型
    local uri = ngx.var.uri
    local file_opt = str_match(uri, "/([^/]+)/?$")
    core.log.info("fileServer ",uri, ",operation:",file_opt)
    -- 文件上传
    if FILE_OPT_UPLOAD == file_opt then
        local is_file_upload = check_file_upload(ctx)
        if not is_file_upload then
            return 403, {error_msg = "request failed: " .. "非法操作"}
        end

        return handle_upload(ctx)
    end
    -- 文件预览
    if FILE_OPT_DOWNLOAD == file_opt then
        return handle_download(ctx)
    end

    return 403, {error_msg = "request failed: " .. "非法操作"}
end

function _M.api()
    local uri = default_uri
    -- TODO support attr_schema
    return {
        {
            methods = {"POST", "GET"},
            uri = uri,
            handler = file_operate_handler,
        }
    }
end

return _M