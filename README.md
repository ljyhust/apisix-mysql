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
	id int auto_increment comment '主'
		primary key,
	uri varchar(255) null,
	method_list varchar(255) default '' not null,
	route_name varchar(64) default '' not null,
	vars varchar(255) default '' null,
	upstream_code varchar(32) default '' null,
	enable_websocket tinyint default 0 not null,
	delete_flag tinyint(1) default 0 not null,
	create_time datetime default CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP not null,
	update_time datetime default CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP not null
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
	create_time datetime default CURRENT_TIMESTAMP  ON UPDATE CURRENT_TIMESTAMP not null,
	update_time datetime default CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP not null
);
```

### apisix配置
config.yaml 配置
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
