-- Encoding and identity checks for ReMagic lifecycle protocol v2.

return function(options)
    local json = assert(options.json)
    local app_id = assert(options.app_id)
    local app_pid = assert(options.app_pid)
    local app_generation = assert(options.app_generation)
    local current_foreground_epoch = assert(options.current_foreground_epoch)
    local current_lease_id = assert(options.current_lease_id)
    local is_decimal = assert(options.is_decimal)
    local event_sequence = 0
    local protocol = {}

    function protocol:encode_event(event, fields)
        event_sequence = event_sequence + 1
        local generation_sentinel = "__REMAGIC_GENERATION__"
        local lease_sentinel = "__REMAGIC_LEASE_ID__"
        local lease_id = current_lease_id()
        local body = {
            event = event,
            app_id = app_id,
            generation = generation_sentinel,
            foreground_epoch = current_foreground_epoch(),
        }
        if is_decimal(lease_id) then
            body.lease_id = lease_sentinel
        end
        if fields then
            for key, value in pairs(fields) do
                body[key] = value
            end
        end
        local envelope = {
            protocol = 2,
            request_id = "koreader-" .. app_pid .. "-" .. app_generation
                .. "-" .. tostring(event_sequence),
            body = body,
        }
        local encoded = json.encode(envelope)
        -- dkjson represents large Lua numbers through floating point. Inject
        -- already validated decimal tokens verbatim to preserve u64 identity.
        encoded = encoded:gsub('"' .. generation_sentinel .. '"', app_generation, 1)
        if is_decimal(lease_id) then
            encoded = encoded:gsub('"' .. lease_sentinel .. '"', lease_id, 1)
        end
        return encoded
    end

    function protocol:matches_instance(line, body)
        if body.app_id ~= app_id then
            return false, "app-id"
        end
        local raw_generation = line:match('"generation"%s*:%s*"?(%d+)"?')
        if raw_generation ~= app_generation then
            return false, "generation"
        end
        return true
    end

    function protocol.normalized_command(value)
        if type(value) ~= "string" then
            return nil
        end
        return value:gsub("%-", "_"):gsub("(%l)(%u)", "%1_%2"):lower()
    end

    return protocol
end
