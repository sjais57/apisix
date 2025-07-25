Test 1:
local core = require("apisix.core")
local plugin = require("apisix.plugin")
local batch_processor = require("apisix.utils.batch-processor")
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
        key = { type = "string" },
        sasl_config = {
            type = "object",
            properties = {
                user = { type = "string" },
                password = { type = "string" },
                mechanism = { type = "string", enum = { "PLAIN" }, default = "PLAIN" }
            },
            required = { "user", "password" }
        },
        ssl_config = {
            type = "object",
            properties = {
                cafile = { type = "string" },
                certfile = { type = "string" },
                keyfile = { type = "string" }
            },
            required = { "cafile", "certfile", "keyfile" }
        },
        include_req_body = { type = "boolean", default = false },
        producer_type = { type = "string", enum = { "sync", "async" }, default = "async" },
        timeout = { type = "integer", default = 3 },
        max_retry_count = { type = "integer", default = 0 },
        retry_delay = { type = "integer", default = 1 },
        batch_max_size = { type = "integer", default = 1000 },
        buffer_duration = { type = "integer", default = 60 },
    },
    required = { "brokers", "kafka_topic", "sasl_config", "ssl_config" }
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
        retry_backoff = conf.retry_delay * 1000,
        ssl = true,
        ssl_verify = false,
        sasl_config = {
            mechanism = conf.sasl_config.mechanism,
            username = conf.sasl_config.user,
            password = conf.sasl_config.password,
        },
        ssl_config = {
            cafile = conf.ssl_config.cafile,
            certfile = conf.ssl_config.certfile,
            keyfile = conf.ssl_config.keyfile,
        }
    }

    return producer_lib.new(broker_list, producer_config)
end

local function send_to_kafka(conf, log_message)
    local producer, err = create_producer(conf)
    if not producer then
        core.log.error("failed to create Kafka producer: ", err)
        return false
    end

    local ok, err = producer:send(conf.kafka_topic, conf.key or nil, log_message)
    if not ok then
        core.log.error("failed to send message to Kafka: ", err)
        return false
    end

    return true
end

function _M.log(conf, ctx)
    local log_data = {
        uri = ctx.var.request_uri,
        method = ctx.var.request_method,
        status = ctx.var.status,
        client_ip = core.request.get_remote_client_ip(ctx),
        time = ngx.time(),
    }

    if conf.include_req_body and ctx.var.request_body then
        log_data.body = ctx.var.request_body
    end

    local process = function(entries)
        return send_to_kafka(conf, core.json.encode(entries))
    end

    local bp_conf = {
        name = plugin_name,
        retry_delay = conf.retry_delay,
        batch_max_size = conf.batch_max_size,
        max_retry_count = conf.max_retry_count,
        buffer_duration = conf.buffer_duration,
    }

    local ok, err = batch_processor.append_entry(conf, log_data, process, bp_conf)
    if not ok then
        core.log.error("failed to add entry to batch processor: ", err)
    end
end

return _M

==================================
Test 2:

local core = require("apisix.core")
local plugin = require("apisix.plugin")
local batch_processor = require("apisix.utils.batch-processor")
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
                mechanism = {
                    type = "string",
                    enum = { "PLAIN" },
                    default = "PLAIN"
                }
            },
            required = { "user", "password" }
        },

        ssl_config = {
            type = "object",
            properties = {
                cafile = { type = "string" },
                certfile = { type = "string" },
                keyfile = { type = "string" }
            },
            required = { "cafile", "certfile", "keyfile" }
        },

        producer_type = {
            type = "string",
            enum = { "sync", "async" },
            default = "async"
        },
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
        retry_backoff = conf.retry_delay * 1000,
    }

    -- Add SASL auth if configured
    if conf.sasl_config then
        producer_config.sasl_config = {
            mechanism = conf.sasl_config.mechanism,
            username = conf.sasl_config.user,
            password = conf.sasl_config.password,
        }
    end

    -- Add SSL config if present
    if conf.ssl_config then
        producer_config.ssl = true
        producer_config.ssl_verify = false -- you may change to true if needed
        producer_config.ssl_config = {
            cafile = conf.ssl_config.cafile,
            certfile = conf.ssl_config.certfile,
            keyfile = conf.ssl_config.keyfile
        }
    end

    return producer_lib.new(broker_list, producer_config)
end

local function send_to_kafka(conf, log_message)
    local producer, err = create_producer(conf)
    if not producer then
        core.log.error("failed to create Kafka producer: ", err)
        return false
    end

    local ok, err = producer:send(conf.kafka_topic, conf.key or nil, log_message)
    if not ok then
        core.log.error("failed to send message to Kafka: ", err)
        return false
    end

    return true
end

function _M.log(conf, ctx)
    local log_data = {
        uri = ctx.var.request_uri,
        method = ctx.var.request_method,
        status = ctx.var.status,
        client_ip = core.request.get_remote_client_ip(ctx),
        time = ngx.time(),
    }

    if conf.include_req_body and ctx.var.request_body then
        log_data.body = ctx.var.request_body
    end

    local process = function(entries)
        local encoded = core.json.encode(entries)
        return send_to_kafka(conf, encoded)
    end

    local bp_conf = {
        name = plugin_name,
        retry_delay = conf.retry_delay,
        batch_max_size = conf.batch_max_size,
        max_retry_count = conf.max_retry_count,
        buffer_duration = conf.buffer_duration,
    }

    local ok, err = batch_processor.append_entry(conf, log_data, process, bp_conf)
    if not ok then
        core.log.error("failed to add entry to batch processor: ", err)
    end
end

return _M


===================

Test 3:

local core        = require("apisix.core")
local producer    = require("resty.kafka.producer")
local plugin_name = "kafka-logger"
local ngx         = ngx

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
            uniqueItems = true,
            description = "List of Kafka brokers in host:port format"
        },
        kafka_topic = {
            type = "string",
            description = "Kafka topic to publish logs to"
        },
        key = {
            type = "string",
            description = "Optional key for Kafka messages"
        },
        timeout = {
            type = "integer", 
            minimum = 1, 
            default = 3,
            description = "Timeout in seconds for Kafka operations"
        },
        max_retry_count = {
            type = "integer", 
            minimum = 0, 
            default = 3,
            description = "Maximum number of retries for failed Kafka operations"
        },
        retry_delay = {
            type = "integer", 
            minimum = 0, 
            default = 1,
            description = "Delay in seconds between retries"
        },
        buffer_duration = {
            type = "integer", 
            minimum = 1, 
            default = 60,
            description = "Maximum duration in seconds to buffer logs before flushing"
        },
        batch_max_size = {
            type = "integer", 
            minimum = 1, 
            default = 1000,
            description = "Maximum number of logs to buffer before flushing"
        },
        include_req_body = {
            type = "boolean", 
            default = false,
            description = "Whether to include request body in logs"
        },
        include_resp_body = {
            type = "boolean", 
            default = false,
            description = "Whether to include response body in logs"
        },
        producer_type = {
            type = "string", 
            enum = {"async", "sync"}, 
            default = "async",
            description = "Kafka producer type (async or sync)"
        },
        required_acks = {
            type = "integer", 
            minimum = 0, 
            maximum = 2, 
            default = 1,
            description = "Number of acknowledgments required (0=none, 1=leader, 2=all)"
        },
        sasl_username = {
            type = "string",
            description = "Username for SASL authentication"
        },
        sasl_password = {
            type = "string",
            description = "Password for SASL authentication"
        },
        sasl_mechanism = {
            type = "string", 
            enum = {"PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512"}, 
            default = "PLAIN",
            description = "SASL authentication mechanism"
        },
        ssl_verify = {
            type = "boolean", 
            default = true,
            description = "Whether to verify SSL certificates"
        },
        meta_format = {
            type = "string", 
            enum = {"default", "original"}, 
            default = "default",
            description = "Format of log metadata"
        }
    },
    required = {"bootstrap", "kafka_topic"}
}

local _M = {
    version = 1.0,
    priority = 403,
    name = plugin_name,
    schema = schema
}

local function create_producer(conf)
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

    local ok, err = prod:send(conf.kafka_topic, nil, log_message)
    if not ok then
        core.log.error("failed to send data to Kafka topic[", conf.kafka_topic, "]: ", err)
        return false, err
    end
    return true
end

local function process_log_entry(conf, ctx)
    local entry
    if conf.meta_format == "original" then
        entry = core.log.get_full_log(ngx, conf)
    else
        entry = core.log.get_log(ngx, conf)
    end

    if conf.include_req_body then
        ngx.req.read_body()
        entry.request_body = ngx.req.get_body_data()
    end

    if conf.include_resp_body and ngx.var.response_body then
        entry.response_body = ngx.var.response_body
    end

    return entry
end

function _M.log(conf, ctx)
    local entry = process_log_entry(conf, ctx)
    local log_buffer = core.tablepool.fetch("kafka_log_buffer", 0, 4)
    log_buffer.entry = entry
    log_buffer.conf = conf

    local process = function(entries)
        local data = core.json.encode(entries)
        return send_to_kafka(conf, data)
    end

    local config = {
        name = "kafka-logger",
        retry_delay = conf.retry_delay,
        batch_max_size = conf.batch_max_size,
        max_retry_count = conf.max_retry_count,
        buffer_duration = conf.buffer_duration,
    }

    local ok, err = core.batch_processor:add_entry(conf, log_buffer, process, config)
    if not ok then
        core.log.error("failed to add entry to batch processor: ", err)
        core.tablepool.release("kafka_log_buffer", log_buffer)
    end
end

return _M
