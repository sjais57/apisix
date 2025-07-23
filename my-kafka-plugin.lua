local core = require("apisix.core")
local kafka_producer = require("resty.kafka.producer")
local kafka_client = require("resty.kafka.client")

local plugin_name = "my-kafka-plugin"

local _M = {
    version = 0.1,
    priority = 1000,
    name = plugin_name,
}

function _M.access(conf, ctx)
    local brokers = {
        { host = "your.kafka.host", port = 9093 }
    }

    local client = kafka_client:new(brokers, {
        ssl = true,
        ssl_verify = false,
        ssl_cert_file = "/path/to/client-cert.pem",
        ssl_key_file = "/path/to/client-key.pem",
        ssl_ca_file = "/path/to/ca-cert.pem"
    })

    local producer = kafka_producer:new(brokers, {
        client = client,
        ssl = true,
        ssl_verify = false,
        ssl_cert_file = "/path/to/client-cert.pem",
        ssl_key_file = "/path/to/client-key.pem",
        ssl_ca_file = "/path/to/ca-cert.pem"
    })

    local msg = "APISIX message at " .. ngx.now()
    local ok, err = producer:send("your-kafka-topic", nil, msg)

    if not ok then
        core.log.error("Kafka send failed: ", err)
    else
        core.log.info("Kafka send success")
    end
end

return _M


================================================


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
        include_req_body = { type = "boolean", default = false }
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

    local producer, err = producer_lib.new({
        broker_list = brokers,
        producer_type = conf.producer_type or "async",
        sasl_config = conf.sasl_config and {
            mechanism = conf.sasl_config.mechanism,
            user = conf.sasl_config.user,
            password = conf.sasl_config.password
        } or nil,
        ssl = true
    })

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
