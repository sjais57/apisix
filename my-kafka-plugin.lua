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

local core = require("apisix.core")
local producer_lib = require("resty.kafka.producer")
local batch_processor = require("apisix.utils.batch-processor")
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
        include_req_body = { type = "boolean", default = false },
        timeout = { type = "integer", minimum = 1, default = 3 },
        batch_max_size = { type = "integer", minimum = 1, default = 1000 },
        buffer_duration = { type = "integer", minimum = 1, default = 60 },
        max_retry_count = { type = "integer", minimum = 0, default = 0 },
        retry_delay = { type = "integer", minimum = 0, default = 1 }
    },
    required = { "brokers", "kafka_topic" }
}

local _M = {
    version = 0.1,
    priority = 1011,
    name = plugin_name,
    schema = schema,
}

local function create_producer(conf)
    local broker_list = {}
    for _, broker in ipairs(conf.brokers) do
        table.insert(broker_list, {
            host = broker.host,
            port = broker.port
        })
    end

    local producer_config = {
        producer_type = conf.producer_type,
        socket_timeout = conf.timeout * 1000,
        max_retry = conf.max_retry_count,
        retry_backoff = conf.retry_delay * 1000
    }

    if conf.sasl_config then
        producer_config.sasl_config = {
            username = conf.sasl_config.user,
            password = conf.sasl_config.password,
            mechanism = conf.sasl_config.mechanism
        }
    end

    return producer_lib.new(broker_list, producer_config)
end

local function send_to_kafka(conf, log_message)
    local producer, err = create_producer(conf)
    if not producer then
        core.log.error("failed to create Kafka producer: ", err)
        return false, err
    end

    local ok, err = producer:send(conf.kafka_topic, conf.key or nil, log_message)
    if not ok then
        core.log.error("failed to send data to Kafka: ", err)
        return false, err
    end
    return true
end

function _M.log(conf, ctx)
    -- Get basic request info using core.request which is safe in log phase
    local log_data = {
        uri = ctx.var.request_uri or ctx.var.uri,
        method = ctx.var.request_method,
        status = ctx.var.status or ngx.status,
        client_ip = core.request.get_remote_client_ip(ctx),
        time = ngx.time()
    }

    -- For request body, we need to capture it earlier (not in log phase)
    if conf.include_req_body and ctx.var.request_body then
        log_data.body = ctx.var.request_body
    end

    -- Use batch processor for better performance
    local process = function(entries)
        return send_to_kafka(conf, core.json.encode(entries))
    end

    local config = {
        name = "kafka logger",
        retry_delay = conf.retry_delay,
        batch_max_size = conf.batch_max_size,
        max_retry_count = conf.max_retry_count,
        buffer_duration = conf.buffer_duration,
    }

    local ok, err = batch_processor:add_entry(conf, log_data, process, config)
    if not ok then
        core.log.error("failed to add entry to batch processor: ", err)
    end
end

return _M
