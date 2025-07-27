local schema = {
    type = "object",
    properties = {
        brokers = {
            type = "array",
            minItems = 1,
            items = { type = "string" }
        },
        kafka_topic = { type = "string" },
        required_acks = { type = "integer", enum = { -1, 0, 1 }, default = 1 },
        key = { type = "string", default = nil },

        -- ✅ Insert these lines here:
        ssl = { type = "boolean", default = false },
        ssl_verify = { type = "boolean", default = false },
        ssl_ca_cert = { type = "string", default = nil },
        ssl_cert = { type = "string", default = nil },
        ssl_key = { type = "string", default = nil },

        -- (rest of original properties continue here)
        batch_num = { type = "integer", minimum = 1, default = 100 },
        batch_size = { type = "integer", minimum = 1, default = 4096 },
        inactive_timeout = { type = "integer", minimum = 1, default = 3 },
        max_retry = { type = "integer", minimum = 0, default = 1 },
        name = { type = "string", minLength = 1 },
    },
    required = { "brokers", "kafka_topic" },
}
