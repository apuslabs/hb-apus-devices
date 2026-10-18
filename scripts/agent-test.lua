--- @module agent-test
--- Integration checks for agent@1.0 called through ao.resolve from a Lua
--- process. Requests carry only agent inputs: the model runtime and its
--- credentials are node options of the node's inference device. The checks
--- call the model, so they run only when the request or the base message
--- sets `agent-test-live` to true; otherwise they return a skipped result.
--- The flag is a message key, so the checks work under the node's default
--- Lua sandbox.

local function enabled(value)
    return value == true or value == 1 or value == "true" or value == "1"
end

local function live(base, req)
    return (type(req) == "table" and enabled(req["agent-test-live"]))
        or (type(base) == "table" and enabled(base["agent-test-live"]))
end

local function skip(name)
    ao.event(name, { skipped = "agent-test-live is not set" })
    return "ok", { skipped = true }
end

local function report(name, status, res)
    if type(res) ~= "table" then
        ao.event(name, { status = status, result = tostring(res) })
        return
    end
    ao.event(name, {
        status = status,
        answer = res["agent-answer"],
        iterations = res["agent-iterations"],
        error = res["agent-error"]
    })
end

--- @function agent_resolve_test
--- The agent fetches a public page with the http_request tool and answers
--- from the result.
function agent_resolve_test(base, req)
    if not live(base, req) then
        return skip("agent_test")
    end

    local status, res = ao.resolve({
        path = "/~agent@1.0/run",
        ["agent-user-prompt"] = "Use the http_request tool to GET https://example.com/ and reply with the page title.",
        ["agent-tools"] = "http_request",
        ["agent-max-iterations"] = 5
    })
    report("agent_test", status, res)
    return status, res
end

--- @function agent_simple_test
--- The agent answers a simple question without tools.
function agent_simple_test(base, req)
    if not live(base, req) then
        return skip("agent_simple_test")
    end

    local status, res = ao.resolve({
        path = "/~agent@1.0/run",
        ["agent-user-prompt"] = "What is 2+2? Answer with just the number.",
        ["agent-disable-tools"] = true,
        ["agent-max-iterations"] = 3
    })
    report("agent_simple_test", status, res)
    return status, res
end
