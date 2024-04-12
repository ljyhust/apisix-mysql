<!--
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
-->

# apisix-mysql适配

[官方apisix](https://apisix.apache.org/zh/docs/apisix/3.2/getting-started/)采用etcd存储配置，满足其高性能要求。但很多场景下比如中小型系统、B端私有化系统部署，很难有能力维护etcd存储，多引入一个中间件同时也提升了系统复杂度，更多的系统是React+Java+mysql+ng(apisix)即完成一套系统的开发部署。  
项目基于apisix-3.2版本，引入mysql作为配置存储源，满足轻量化部署。apisix仅读取mysql配置，而不写入；配置项可另外基于Java开发，引入一套管理机制实现（待实现）。apisix启动时其进程+工作进程主动拉取mysql全局配置缓存本地，在运行过程中增量获取变更配置同步。

## 部署

源码部署，参考[官网说明](https://apisix.apache.org/zh/docs/apisix/3.2/building-apisix/)

### mysql脚本

```SQL
create table routes
(
	id int auto_increment
		primary key,
	name varchar(100) default '' null,
	uris varchar(4096) default '' null comment '服务地址',
	priority int default 0 null comment '优先级',
	methods varchar(1024) default '' null comment '方法集合，json_array',
	hosts varchar(2048) default '' null comment '来源hosts，json_array',
	remote_addrs varchar(2048) default '' null comment '客户来源IP集合，json_array',
	vars varchar(1024) default '' null,
	enable_websocket tinyint(1) default 0 null,
	upstream_id varchar(64) default '' null comment '上游id，关联键',
	service_id varchar(64) default '' null,
	plugin_config_id varchar(64) default '' null,
	mark_desc varchar(256) default '' null,
	delete_flag tinyint(1) default 0 null,
	create_time datetime default CURRENT_TIMESTAMP not null,
	update_time datetime default CURRENT_TIMESTAMP not null on update CURRENT_TIMESTAMP
)
comment '服务路由';

create table upstreams
(
	id int auto_increment
		primary key,
	name varchar(64) default '' null,
	upstream_code varchar(64) default '' null comment '唯一标识',
	type varchar(10) default '' not null,
	nodes text not null comment '服务地址，json串',
	retries int default 0 null comment '重试次数',
	timeout varchar(1024) default '' not null comment '超时时间',
	retry_timeout int default 0 null comment '重试时间',
	scheme varchar(32) default '' null,
	hash_on varchar(20) default '' null,
	`key` varchar(256) default '' null,
	mark_desc varchar(256) default '' null,
	delete_flag tinyint(1) default 0 null,
	create_time datetime default CURRENT_TIMESTAMP not null,
	update_time datetime default CURRENT_TIMESTAMP null on update CURRENT_TIMESTAMP
)
comment '上游服务';
```

### apisix配置

config.yaml 配置数据库

```yml
deployment:
  role: data_plane
  role_data_plane:
    config_provider: mysql
  mysql:
    host: 127.0.0.1
    port: 3306
    database: apisix
    user: xxx
    password: xxx
    charset: utf8
```


### 启动

参考apisix官网
https://apisix.apache.org/zh/docs/apisix/3.2/building-apisix/


## 计划

目前仅支持配置route路由，其它配置如Service、plugins等待启动
- [ ] 配置管理系统
- [ ] service、plugins配置项