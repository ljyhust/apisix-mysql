# 在apisix中实现自定义接口
> apisix除了可以代理后端接口，可支持用插件方式实现并暴露接口，不需要经过转发由apisix本身对外接口服务，在插件中实现接口的业务逻辑。文中以实现文件上传下载接口为例，说明实践过程：定义插件实现功能、注册插件、配置暴露的接口。

## 实践过程
### 基本原理
apisix工作进程启动时，初始化了两类接口(代码参考`apisix/router.lua::http_init_worker()`)：  
1. 来源于数据库(如etcd等)配置的接口代理，由`apisix/router.lua -> _M.router_http`对象维护;
2. 所有启用的插件中注册的接口代理(插件`_M.api()`方法注册的接口)，由`apisix/router.lua -> _M.api`对象维护;  
apisix代理接口在请求准入`access_phase`阶段(参考代码`apisix/init.lua::http_access_phase()`方法)处理过程是：匹配route路由代理配置、调用路由关联的插件、调用upstream_handler处理路由代理转发。 

如果路由使用了`public-api`插件配置，apisix在请求准备阶段调用`public-api`插件中的`access()`方法，及主要调用链路如下。可以发现在插件`api()`方法中实现对应uri的拦截并处理。
> 插件`api()`方法定义路径+回调钩子，由`api_route.lua`扫描并缓存维护; 
路由准入阶段，对于配置有`public-api`插件的配置，将路由代理转发至配置的uri路径


```lua
-- public-api.lua插件
function _M.access(conf, ctx)
    -- overwrite the uri in the ctx when the user has set the target uri
    ctx.var.uri = conf.uri or ctx.var.uri

    -- 使用apisix/router.lua -> _M.api = api_router.lua`
    if router.api.match(ctx) then
        return
    end

    return 404
end

-- apisix/api_router.lua，懒加载fetch_api_router所有启用插件中注册的api()方法
function _M.match(api_ctx)
    local api_router = core.lrucache.global("api_router", plugin_mod.load_times, fetch_api_router)
    if not api_router then
        core.log.error("failed to fetch valid api router")
        return false
    end

    core.table.clear(match_opts)
    match_opts.method = api_ctx.var.request_method

    local ok = api_router:dispatch(api_ctx.var.uri, match_opts, api_ctx)
    return ok
end
```

### 文件上传下载插件
在`api()`方法中定义属性：接口路径、回调处理方法; 表示注册`/apisix/fileServer/*`接口路径，使用对应回调方法`file_operate_handler`处理。

```lua
local default_file_dir = "/home/xxx/temp" --文件缓存
local default_uri = "/apisix/fileServer/*"  -- 接口地址

local FILE_OPT_UPLOAD = "upload"  -- 上传操作
local FILE_OPT_DOWNLOAD = "view" -- 预览操作

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
```

### 注册路由插件配置
接口路由`/apisix/fileServerApi/*`配置public-api插件：将access_phase阶段交由`/apisix/fileServer/*`的api实现插件处理。
```sql
-- 添加配置
insert into plugin_configs(plugin_config_code, plugins, mark_desc)
values ('file-server-api',
        '{"public-api": {"uri": "/apisix/fileServer/*"}}',
        '文件上传下载插件配置');
-- 添加route
insert int routes(name, uri, methods, plugin_config_id) values 
('文件上传预览'， '/apisix/fileServerApi/*', '["GET","POST"]', #{id});
```

### 自测效果


## 运行机制
待添加图