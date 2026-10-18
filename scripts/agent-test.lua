--- @module agent-test
--- Integration checks for agent@1.0 called through ao.resolve from a Lua
--- process. Requests carry only agent inputs: the model runtime and its
--- credentials are node options of the node's inference device. The checks
--- call the model, so they run only when AGENT_TEST_LIVE is set to a value
--- other than 0 on a node whose runtime is configured.

local function live()
    local flag = os.getenv("AGENT_TEST_LIVE")
    return flag ~= nil and flag ~= "" and flag ~= "0"
end

local function report(name, status, res)
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
function agent_resolve_test()
    if not live() then
        ao.event("agent_test", { skipped = "AGENT_TEST_LIVE is not set" })
        return "ok", { skipped = true }
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
function agent_simple_test()
    if not live() then
        ao.event("agent_simple_test", { skipped = "AGENT_TEST_LIVE is not set" })
        return "ok", { skipped = true }
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
