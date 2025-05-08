# 代码学习

1. 安装依赖

`curl https://raw.githubusercontent.com/apache/apisix/${分支}utils/install-dependencies.sh -sL | bash -`

或者

```
bash utils/install-dependencies.sh
```

2. 下载代码

`make deps`  安装依赖：luajit luarocks包管理  插件依赖 等等

## 启动详解

apisix.lua::start启动 openresty

> jeang       5747       1  0 20:03 ?        00:00:00 nginx: master process /usr/bin/openresty -p /home/jeang/open-codes/apisix -c /home/jeang/open-codes/apisix/conf/nginx.conf

其中 -p 表示工作目录
-c 表示配置位置

## nginx说明

```
lua_package_path  "$prefix/deps/share/lua/5.1/?.lua;$prefix/deps/share/lua/5.1/?/init.lua;/home/jeang/open-codes/apisix/?.lua;/home/jeang/open-codes/apisix/?/init.lua;;./?.lua;/usr/local/openresty/luajit/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua;;";
    lua_package_cpath "$prefix/deps/lib64/lua/5.1/?.so;$prefix/deps/lib/lua/5.1/?.so;;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;";
```

`$prefix`表示openresty工作区或目录

## vscode快捷键

`Ctrl + Alt + '-' 返回上一处 Go back`
`Ctrl + Alt + '+' Go forward`
`Ctrl + P  搜索文件`

## 源码说明

- ops.lua脚本 start方法启动，调用init检查相关配置，生成nginx.conf配置&启动nginx进程；

- apisix.init.lua启动

- http_init()方法 初始化配置，调用config_etcd或config_yaml两种模块的init方法；其中 config_ymal:init是初始化第一波读取apisix.yaml配置，并放入模块缓存中；

- nginx进程启动;

```
init_by_lua_block {
        require "resty.core"
        -- 引入apisix文件模块，调用文件夹下的init.lua       
        apisix = require("apisix")

        local dns_resolver = { "127.0.0.53", }
        local args = {
            dns_resolver = dns_resolver,
        }
        -- master进程启动调用
        apisix.http_init(args)

        -- set apisix_lua_home into constans module
        -- it may be used by plugins to determine the work path of apisix
        local constants = require("apisix.constants")
        constants.apisix_lua_home = "/home/jeang/open-codes/apisix"
    }
    -- worker进程启动调用
    init_worker_by_lua_block {
        apisix.http_init_worker()
    }
```

> apisix.http_init_worker()，启动config_yaml或config_etcd的初始化方法`core.config.init_worker()`；(这是worker启动的模块缓存，与上一次master进程启动缓存不一样)

- 其它模块配置初始化(搜索`config.new`看调用)，这些方法都会去调用core.config.new(key) 创建进程配置；

```
plugin.init_worker()
    router.http_init_worker()
    require("apisix.http.service").init_worker()
    plugin_config.init_worker()
    require("apisix.consumer").init_worker()
    consumer_group.init_worker()
    apisix_secret.init_worker()

    apisix_upstream.init_worker()
    require("apisix.plugins.ext-plugin.init").init_worker()
```

core.config_yaml.new(key) 从本地模块缓存配置中获取对应的key的配置；

## 配置
local_config读取本地配置，如config_default.yaml + config.yaml文件的综合体

配置文件范式定义在`schema.lua`文件

### 生成nginx配置
apisix.init用ngx_tpl模板文件写入配置

## 请求链路
9080 端口是数据面

9180 是admin控制面

1. apisix/init.lua   http_access_phase()方法接收请求，解析uri及route，调用handle_upstream；
2. apisix/init.lua  handle_upstream() 方法获取上游upstream配置；
3. apisix/init.lua  http_balancer_phase()

# apisix改造及功能实现
- [x] mysql配置化改造  
- [x] 特殊代理服务实现  
- [x] 文件上传中转  
- [x] 个性化日志插件  
- [x] 插件注册接口  
- [ ] Redis配置变更通知改造

## mysql配置改造
apisix中的每个worker单独有缓存，不全局共享，mysql的配置由于是主动定时拉取，因此并不能保证每个worker的实时一致性，但在某些B端业务中仍然有其使用场景，是一个成本较低的实现方式。  
- [ ] 通过插件注册的接口API修改配置数据 或 查询内存中的配置

### mysql 库表结构

```sql
create schema apisix collate utf8mb4_0900_ai_ci;

create table routes
(
    id               int auto_increment  primary key,
    name             varchar(100)  default ''                null,
    uri              varchar(4096) default ''                null comment '接口地址',
    uris             varchar(4096) default ''                null comment '接口地址',
    priority         int           default 0                 null comment '优先级',
    methods          varchar(1024) default ''                null comment '方法集合，json_array',
    hosts            varchar(2048) default ''                null comment '来源hosts，json_array',
    remote_addrs     varchar(2048) default ''                null comment '客户来源IP集合，json_array',
    vars             varchar(1024) default ''                null,
    enable_websocket tinyint(1)    default 0                 null,
    upstream_id      varchar(64)   default ''                null comment '上游id，关联键',
    service_id       varchar(64)   default ''                null,
    plugin_config_id varchar(64)   default ''                null comment '配置ID',
    mark_desc        varchar(256)  default ''                null,
    status           tinyint       default 1                 null comment '状态',
    delete_flag      tinyint(1)    default 0                 null,
    create_time      datetime      default CURRENT_TIMESTAMP not null,
    update_time      datetime      default CURRENT_TIMESTAMP not null on update CURRENT_TIMESTAMP
)
    comment '服务路由及接口';


create table upstreams
(
    id            int auto_increment primary key,
    name          varchar(64)   default ''                null,
    upstream_code varchar(64)   default ''                null comment '唯一标识',
    type          varchar(10)   default ''                not null,
    nodes         text                                    not null comment '服务地址，json串',
    retries       int           default 0                 null comment '重试次数',
    timeout       varchar(1024) default ''                not null comment '超时时间',
    retry_timeout int           default 0                 null comment '重试时间',
    scheme        varchar(32)   default ''                null,
    hash_on       varchar(20)   default ''                null,
    upstream_key  varchar(256)  default ''                null,
    mark_desc     varchar(256)  default ''                null,
    delete_flag   tinyint(1)    default 0                 null,
    create_time   datetime      default CURRENT_TIMESTAMP not null,
    update_time   datetime      default CURRENT_TIMESTAMP null on update CURRENT_TIMESTAMP
)
    comment '上游服务';

create table plugin_configs
(
    id                 int auto_increment primary key,
    plugin_config_code varchar(64)  default ''                not null,
    plugins            text                                   null comment '插件参数配置',
    mark_desc          varchar(256) default ''                null,
    delete_flag        tinyint      default 0                 not null,
    create_time        datetime     default CURRENT_TIMESTAMP not null,
    update_time        datetime     default CURRENT_TIMESTAMP not null on update CURRENT_TIMESTAMP
)
    comment '插件配置';

create table sys_dict
(
    id              int auto_increment  primary key,
    dict_key        varchar(32) default ''                null comment '字典项',
    dict_item_key   varchar(32)                           null comment '配置项key',
    dict_item_value text                                  null comment '配置项值',
    delete_flag     tinyint     default 0                 not null comment '删除标识',
    update_time     datetime    default CURRENT_TIMESTAMP null on update CURRENT_TIMESTAMP
)
    comment '公共字典';

```
## rewrite实现  
config-default默认加上rewrite插件，每个route配置中都可打开这个插件并配置对应规则

## 文件上传及预览插件
1. 插件实现，配置拦截接口：上传接口、下载或预览文件接口
2. 这些接口需要在routes中配置，header或form-data中增加特殊标志表示此上传接口被apisix拦截并处理
3. 插件配置结构
```javascript
{
    #uploadConf: type=local&path=test
    #downloadConf: type=local&path=test
}

{
    "file-store": {
        "storageConf": storageConf
    }
}
```

4. 测试  
```sh
# 测试上传文件由apisix存储
curl -i -F "file=@/home/jeang/logs/nacos/config.log" -H "storageConf:type=local" -H "Content-Type: multipart/form-data" http://localhost:9080/apisix-config/manage/plugin/upload

# 普通由后台服务存储
curl -i -F "file=@/home/jeang/logs/nacos/config.log" -H "Content-Type: multipart/form-data" http://localhost:9080/apisix-config/manage/plugin/upload

# 其它接口无影响
curl -X GET --location "http://localhost:9080/apisix-config/manage/upstream/listAll"
```

## 个性化日志插件
apisix日志默认为error.log，且所有级别的日志全放在一个文件中，不便于分类管理及监控，实现插件自定义打印日志：支持自定义格式、级别，每种插件只做一个级别的日志，一个文件；多种格式的日志，则配置多个插件。

实现方式  
1. 模板格式化文本，参考ops.lua  
```
{* log_time *} - INFO - {* host *} - {* request_uri *} - {* upstream *} - {* cost_time *} - {* status *}
```

2. table存储变量，tpl渲染成文本
```lua
local conf_render = template.compile(ngx_tpl)
local ngxconf = conf_render(sys_conf)
```

3. 添加全局插件配置
```sql
insert apisix.sys_dict(dict_key, dict_item_key, dict_item_value)
values ('global_rules', 'plugins', '{"request-logger": {"path": "logs/custom-request.log", "log_format":"{* log_time *} - INFO - {* host *} - {* request_uri *} - {* upstream *} - {* cost_time *}ms - {* status *}"}}');
```

## 日志滚动插件，参考file-rotate.lua插件  
按日期及大小滚动，如果是隔天，则滚动；如果文件大小也超过，则滚动；  
重命名日志，并触发主进程开启原日志；  
是否压缩命名后的日志；  
如需要则清除旧日志（可配置化）  
注册以上方法启动定时任务  
(建议系统脚本处理)  

## 插件注册接口
> 用插件的方式实现文件服务器，而不用nginx配置  

实现插件注册上传和下载(文件预览)接口，插件只能注册一个方法处理接口，接口采用正则处理上传和下载；  
采用正则注册路由并配置使用public-api插件;  
路由配置为暴露的api路径，public-api插件中配置为文件服务插件注册的内部接口；    
```sql
-- 添加配置
insert into plugin_configs(plugin_config_code, plugins, mark_desc)
values ('file-server-api',
        '{"public-api": {"uri": "/apisix/fileServer/*"}}',
        '文件上传下载插件配置');
-- 添加route
insert int routes(name, uri, methods, plugin_config_id) values 
('文件上传预览'， '/apisix/fileServer/*', '["GET","POST"]', #{id});
```
测试  
```sh
curl -i -F "file=@/home/jeang/logs/nacos/config.log" -H "storageConf:type=local" -H "Content-Type: multipart/form-data" http://localhost:9080/apisix/fileServer/upload

curl -i http://localhost:9080/apisix/fileServer/view?file_name=config.log
```
