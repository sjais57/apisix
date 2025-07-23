test 1:

-- File: apisix/plugins/kafka-logger.lua

local core = require("apisix.core")
local plugin = require("apisix.plugin")
local producer_lib = require("resty.kafka.producer")
local ngx = ngx
local tostring = tostring

local schema = {
    type = "object",
    properties = {
        brokers = {
            type = "array",
            minItems = 1,
            items = {
                type = "object",
                properties = {
                    host = { type = "string" },
                    port = { type = "integer", minimum = 1 }
                },
                required = { "host", "port" }
            }
        },
        kafka_topic = { type = "string", minLength = 1 },
        sasl_config = {
            type = "object",
            properties = {
                user = { type = "string" },
                password = { type = "string" },
                mechanism = { type = "string", enum = {"PLAIN"}, default = "PLAIN" }
            },
            required = { "user", "password" }
        },
        producer_type = { type = "string", enum = { "async", "sync" }, default = "async" },
        key = { type = "string" },
        include_req_body = { type = "boolean", default = false },
        ssl_cert = { type = "string" },
        ssl_key = { type = "string" },
        ssl_verify = { type = "boolean", default = true }
    },
    required = { "brokers", "kafka_topic" }
}

local plugin_name = "kafka-logger"

local _M = {
    version = 0.1,
    priority = 1011,
    name = plugin_name,
    schema = schema,
}

function _M.log(conf, ctx)
    local log_data = {
        request_uri = ngx.var.request_uri,
        request_method = ngx.req.get_method(),
        request_headers = ngx.req.get_headers(),
        status = ngx.status,
        client_ip = core.request.get_remote_client_ip(ctx),
        timestamp = ngx.time()
    }

    if conf.include_req_body then
        ngx.req.read_body()
        log_data.body = ngx.req.get_body_data()
    end

    local brokers = {}
    for _, b in ipairs(conf.brokers) do
        brokers[#brokers + 1] = b.host .. ":" .. b.port
    end

    local kafka_conf = {
        broker_list = brokers,
        producer_type = conf.producer_type or "async",
        sasl_config = conf.sasl_config and {
            mechanism = conf.sasl_config.mechanism,
            user = conf.sasl_config.user,
            password = conf.sasl_config.password
        } or nil,
        ssl = true,
        ssl_cert = conf.ssl_cert,
        ssl_key = conf.ssl_key,
        ssl_verify = conf.ssl_verify
    }

    local producer, err = producer_lib.new(kafka_conf)

    if not producer then
        core.log.error("Failed to create Kafka producer: ", err)
        return
    end

    local ok, err = producer:send(conf.kafka_topic,
                                  conf.key or nil,
                                  core.json.encode(log_data))

    if not ok then
        core.log.error("Failed to send log to Kafka: ", err)
    end
end

return _M



==================

test 2:

-- kafka-logger.lua
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

local core       = require("apisix.core")
local producer   = require("resty.kafka.producer")
local batch_processor = require("apisix.utils.batch-processor")
local plugin_name = "kafka-logger"
local pairs      = pairs
local ipairs     = ipairs
local tostring   = tostring
local table      = table
local ngx        = ngx
local string     = string
local type       = type

local schema = {
    type = "object",
    properties = {
        bootstrap = {
            type = "array",
            items = {
                type = "string",
                pattern = "^.+%:%d+$"
            },
            minItems = 1,
            uniqueItems = true
        },
        kafka_topic = {type = "string"},
        key = {type = "string"},
        timeout = {type = "integer", minimum = 1, default = 3},
        name = {type = "string", default = "kafka logger"},
        max_retry_count = {type = "integer", minimum = 0, default = 0},
        retry_delay = {type = "integer", minimum = 0, default = 1},
        buffer_duration = {type = "integer", minimum = 1, default = 60},
        inactive_timeout = {type = "integer", minimum = 1, default = 5},
        batch_max_size = {type = "integer", minimum = 1, default = 1000},
        include_req_body = {type = "boolean", default = false},
        include_resp_body = {type = "boolean", default = false},
        include_req_body_expr = {
            type = "array",
            items = {
                type = "array"
            }
        },
        include_resp_body_expr = {
            type = "array",
            items = {
                type = "array"
            }
        },
        meta_format = {type = "string", enum = {"default", "origin"}, default = "default"},
        producer_type = {type = "string", enum = {"async", "sync"}, default = "async"},
        required_acks = {type = "integer", minimum = 0, maximum = 2, default = 1},
        partition_id = {type = "integer", minimum = 0, default = 0},
        sasl_username = {type = "string"},
        sasl_password = {type = "string"},
        sasl_mechanism = {type = "string", enum = {"PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512"}, default = "PLAIN"},
        ssl_verify = {type = "boolean", default = true},
    },
    required = {"bootstrap", "kafka_topic"}
}

local metadata_schema = {
    type = "object",
    properties = {
        log_format = core.logger.metadata_schema.properties.log_format
    }
}

local _M = {
    version = 0.1,
    priority = 403,
    name = plugin_name,
    schema = schema,
    metadata_schema = metadata_schema
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    return core.schema.check(schema, conf)
end

local function get_partition_id(conf)
    if conf.partition_id then
        return conf.partition_id
    end
    return 0
end

local function create_producer(conf)
    local producer_config = {
        producer_type = conf.producer_type,
        required_acks = conf.required_acks,
        socket_timeout = conf.timeout * 1000,
        keepalive_timeout = 60000,
        refresh_interval = 5000,
        max_retry = conf.max_retry_count,
        retry_backoff = conf.retry_delay * 1000,
    }

    if conf.sasl_username and conf.sasl_password then
        producer_config.sasl_config = {
            username = conf.sasl_username,
            password = conf.sasl_password,
            mechanism = conf.sasl_mechanism
        }
    end

    if conf.ssl_verify ~= nil then
        producer_config.ssl_verify = conf.ssl_verify
    end

    return producer:new(conf.bootstrap, producer_config)
end

local function send_to_kafka(conf, log_message)
    local prod = create_producer(conf)
    local ok, err = prod:send(conf.kafka_topic, get_partition_id(conf), conf.key, log_message)
    if not ok then
        core.log.error("failed to send data to Kafka topic[", conf.kafka_topic,
                      "] err:", err)
        return false, err
    end
    return true
end

local function combine_logs(conf, entries)
    local combined = {}
    for _, entry in ipairs(entries) do
        if conf.meta_format == "origin" then
            table.insert(combined, core.json.encode(entry))
        else
            table.insert(combined, string.format("%s %s %s %s %s",
                entry.request and entry.request.upstream or "-",
                entry.request and entry.request.uri or "-",
                entry.response and entry.response.status or "-",
                entry.latency or "-",
                entry.service and entry.service.name or "-"
            ))
        end
    end
    return table.concat(combined, "\n")
end

function _M.log(conf, ctx)
    local entry
    if conf.meta_format == "origin" then
        entry = core.log.get_full_log(ngx, conf)
    else
        entry = core.log.get_log(ngx, conf)
    end

    local log_buffer = core.tablepool.fetch("kafka_log_buffer", 0, 4)
    log_buffer.entry = entry
    log_buffer.conf = conf

    local process = function(entries)
        local data = combine_logs(conf, entries)
        return send_to_kafka(conf, data)
    end

    local config = {
        name = conf.name,
        retry_delay = conf.retry_delay,
        batch_max_size = conf.batch_max_size,
        max_retry_count = conf.max_retry_count,
        buffer_duration = conf.buffer_duration,
        inactive_timeout = conf.inactive_timeout,
    }

    local ok, err = batch_processor:add_entry(conf, log_buffer, process, config)
    if not ok then
        core.log.error("error when adding entry to batch processor: ", err)
        core.tablepool.release("kafka_log_buffer", log_buffer)
    end
end

return _M
