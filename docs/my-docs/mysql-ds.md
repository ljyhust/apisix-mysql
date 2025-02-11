# apisix配置mysql存储改造
> apisix默认使用etcd存储配置，具有分布式、一致性、高并发、实时监听通知、目录存储、支持前缀遍历查询等特性，非常适合做路由配置，当配置变更时也能及时被客户端监听消费，较关系性数据库如mysql等存储更有优势。
但在某些不涉及高并发、对于配置生效实时要求亦不高的场景，或没有条件安装etcd，可尝试使用mysql存储配置及管理，助于降低系统服务组件数量、简化系统架构。此文中笔者实现了apisix如route、upstream、plugin等主要配置mysql存储改造，自测能跑通基本功能。水平有限，不对的地方请大佬轻喷~

## 基本方案


## 具体实现
### mysql数据源配置
实现`config.yaml`文件支持mysql类型的数据源配置如下所示，便于数据源可配置化。修改`apisix/cli/schema.lua`文件，增加`data_plane.role_data_plane.config_provider`支持mysql枚举项。
```yaml
deployment:
  role: data_plane
  role_data_plane:
    config_provider: mysql
  mysql:
    host: 127.0.0.1
    port: 3306
    database: apisix
    user: jeang
    password: xxxxxx
    charset: utf8
    keepalive: 60000
    pool_size: 20
    backlog: 200
```
`apisix/cli/schema.lua`文件
```lua
local deployment_schema = {
    traditional = {...}, -- 示例省略
    control_plane = {...}, -- 示例省略
    data_plane = {
        properties = {
            role_data_plane = {
                properties = {
                    config_provider = {
                        enum = {"control_plane", "yaml", "xds", "mysql"}  -- 增加msql项
                    } -- ....
                }
            }
        }
    },
    --其它配置...
}
```


### 配置数据查询封装

### 增量配置同步

## 自测效果