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
