Test 1:

local core = require("apisix.core")
local producer_lib = require("resty.kafka.producer")
local plugin_name = "kafka-logger"

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
        include_req_body = { type = "boolean", default = false }
    },
    required = { "brokers", "kafka_topic" }
}

local _M = {
    version = 0.1,
    priority = 1011,
    name = plugin_name,
    schema = schema,
}

function _M.log(conf, ctx)
    -- Collect request data
    local log_data = {
        uri = ngx.var.request_uri,
        method = ngx.req.get_method(),
        headers = ngx.req.get_headers(),
        status = ngx.status,
        client_ip = core.request.get_remote_client_ip(ctx),
        time = ngx.time()
    }

    if conf.include_req_body then
        ngx.req.read_body()
        log_data.body = ngx.req.get_body_data()
    end

    -- Convert brokers array to broker_list table
    local broker_list = {}
    for _, broker in ipairs(conf.brokers or {}) do
        local host_port = broker.host .. ":" .. tostring(broker.port)
        broker_list[host_port] = 1
    end

    if not next(broker_list) then
        core.log.error("broker_list is empty or invalid")
        return
    end

    -- Init Kafka producer
    local producer, err = producer_lib.new({
        broker_list = broker_list,
        producer_type = conf.producer_type or "async",
        sasl_config = conf.sasl_config,
        ssl = true
    })

    if not producer then
        core.log.error("Failed to create Kafka producer: ", err)
        return
    end

    -- Send message
    local ok, err = producer:send(conf.kafka_topic,
                                  conf.key or nil,
                                  core.json.encode(log_data))

    if not ok then
        core.log.error("Failed to send log to Kafka: ", err)
    end
end

return _M


==================================
Test 2:

-- kafka-logger.lua
local core       = require("apisix.core")
local producer   = require("resty.kafka.producer")
local batch_processor = require("apisix.utils.batch-processor")
local plugin_name = "kafka-logger"
local ngx        = ngx

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

local _M = {
    version = 0.1,
    priority = 403,
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function create_producer(conf)
    -- Convert bootstrap to broker_list format expected by resty.kafka
    local broker_list = {}
    for _, broker in ipairs(conf.bootstrap) do
        local host, port = broker:match("^(.+):(%d+)$")
        if host and port then
            table.insert(broker_list, {host = host, port = port})
        end
    end

    if #broker_list == 0 then
        return nil, "no valid brokers configured"
    end

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

    return producer:new(broker_list, producer_config)
end

local function send_to_kafka(conf, log_message)
    local prod, err = create_producer(conf)
    if not prod then
        core.log.error("failed to create Kafka producer: ", err)
        return false, err
    end

    local ok, err = prod:send(conf.kafka_topic, conf.partition_id or 0, conf.key, log_message)
    if not ok then
        core.log.error("failed to send data to Kafka topic[", conf.kafka_topic, "]: ", err)
        return false, err
    end
    return true
end

function _M.log(conf, ctx)
    local entry = core.log.get_full_log(ngx, conf)

    local process = function(entries)
        local data = core.json.encode(entries)
        return send_to_kafka(conf, data)
    end

    local log_buffer = {
        entry = entry,
        conf = conf
    }

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
    end
end

return _M
