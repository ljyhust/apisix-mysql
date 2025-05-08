local require   = require
local core = require("apisix.core")
local json = require("apisix.core.json")
local ngx  = ngx
local arg = ngx.arg
local ipairs    = ipairs
local pcall     = pcall
local table_sort = table.sort
local table_insert = table.insert
local get_uri_args = ngx.req.get_uri_args
local pairs = pairs

local _M = {}

function _M.handler(api_ctx)
    -- TODO 设置判断uri是否需要处理
    local res_data = core.response.hold_body_chunk(api_ctx, true)
    core.log.info("res_data:", json.delay_encode(res_data, true))
    -- 处理返回chunk
end

return _M