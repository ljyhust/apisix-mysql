# 代码学习
1. 安装依赖
curl https://raw.githubusercontent.com/apache/apisix/${分支}utils/install-dependencies.sh -sL | bash -  

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
ops.lua脚本 start方法启动，调用init检查相关配置，生成nginx.conf配置&启动nginx进程；  
apisix.init.lua启动  
http_init()方法 初始化配置，调用config_etcd或config_yaml两种模块的init方法；其中config_ymal:init是初始化第一波读取apisix.yaml配置，并放入模块缓存中；  
nginx进程启动；  
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
apisix.http_init_worker()，启动config_yaml或config_etcd的初始化方法`core.config.init_worker()`；(这是worker启动的模块缓存，与上一次master进程启动缓存不一样)   

其它模块配置初始化(搜索`config.new`看调用)，这些方法都会去调用core.config.new(key) 创建进程配置；  
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


# mysql配置改造
## mysql 库表结构
```sql
create schema apisix collate utf8mb4_0900_ai_ci;

create table routes
(
	id int auto_increment comment '主'
		primary key,
	uri varchar(255) null,
	method_list varchar(255) default '' not null,
	route_name varchar(64) default '' not null,
	upstream_code varchar(32) default '' null,
	enable_websocket tinyint default 0 not null,
	delete_flag tinyint(1) default 0 not null,
	create_time datetime default CURRENT_TIMESTAMP null,
	update_time datetime default CURRENT_TIMESTAMP not null
);


create table upstream
(
	id int auto_increment
		primary key,
	upstream_code varchar(32) default '' not null,
	upstream_name varchar(32) default '' null,
	upstream_type varchar(10) default '' null,
	node_address varchar(255) default '' not null,
	weight int default 1 not null,
	type varchar(32) default '' not null,
	delete_flag tinyint(1) default 0 not null,
	create_time datetime default CURRENT_TIMESTAMP not null,
	update_time datetime default CURRENT_TIMESTAMP not null
);


```



