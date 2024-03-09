local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local mysql        = require("resty.mysql")
local setmetatable = setmetatable

local _M = {}


local mt = {
    __index = _M,
    -- __tostring = function(self)
    --     return "apisix.yaml key: " .. (self.key or "")
    -- end
}

-- instance
function _M.new(self, db_config)
    log.info("mysql_client init ")
    -- init mysql 
    local db, err = mysql:new()
    if not db then
        log.error("failed to instantiate mysql: ", err)
    end
    
    self.mysql_db = db
    self.config = db_config

    local obj = setmetatable({
        db_client = db
    }, mt)

    return obj
end

local function mysql_connect(db, config)
    db:set_timeout(1000)
    local ok, err, errcode, sqlstate = db:connect(config)
    if not ok then
        log.info("failed to connect: ", err, ": ", errcode, " ", sqlstate)
        return
    end
    
    log.info("connected to mysql.")

    -- local ok, err = db:set_keepalive(10000, 100)
    -- if not ok then
    --     ngx.log(ngx.ERR, "failed to set keepalive: ", err)
    --     return
    -- end
    -- body
end

-- sql查询routes
function _M.query(self, sql)
    
    mysql_connect(self.mysql_db, self.config)

    local res, err, errcode, sqlstate =
        self.mysql_db:query(sql)

    if not res then
        log.info("bad result: ", err, ": ", errcode, ": ", sqlstate, ".")
        return nil
    end

    local ok, err = self.mysql_db:set_keepalive(10000, 100)
    if not ok then
        log.info("failed to set keepalive: ", err)
        return
    end

    return res
end

-- 查询
function _M.query_with_param(self, sql, params)
    local start_time = params.start_time
    local end_time = params.end_time

    local res, err, errcode, sqlstate =
        self.mysql_db:query(sql .. start_time .. " and " .. end_time)

    if not res then
        log.info("bad result: ", err, ": ", errcode, ": ", sqlstate, ".")
        return nil
    end

    return res
end

return _M