--- @class agentic.SessionStartAttempt
--- @field _agent agentic.acp.ACPClient
--- @field _completed boolean
--- @field _completion_queued boolean
--- @field _cancelled boolean
--- @field _request_sent boolean
--- @field _replaying boolean
--- @field _claimed_session_id? string
--- @field _cancelled_session_ids table<string, boolean>
--- @field _callback? fun(result: agentic.SessionStartResult|nil, err: agentic.acp.ACPError|nil)
local SessionStartAttempt = {}
SessionStartAttempt.__index = SessionStartAttempt

--- @class agentic.SessionStarter
local SessionStarter = {}

local CANCELLED_ERROR = {
    code = -32800,
    message = "Session startup cancelled",
}

local INVALID_SPEC_ERROR = {
    code = -32602,
    message = "Invalid session start specification",
}

--- @param agent agentic.acp.ACPClient
--- @return agentic.SessionStartAttempt attempt
local function new_attempt(agent)
    return setmetatable({
        _agent = agent,
        _completed = false,
        _completion_queued = false,
        _cancelled = false,
        _request_sent = false,
        _replaying = false,
        _claimed_session_id = nil,
        _cancelled_session_ids = {},
        _callback = nil,
    }, SessionStartAttempt)
end

--- @param result agentic.SessionStartResult|nil
--- @param err agentic.acp.ACPError|nil
function SessionStartAttempt:_complete(result, err)
    if self._completed or self._completion_queued then
        return
    end

    self._completion_queued = true

    vim.schedule(function()
        if self._completed then
            return
        end

        self._completion_queued = false
        self._completed = true
        self._replaying = false
        self._claimed_session_id = nil

        local callback = self._callback
        self._callback = nil
        if callback then
            if self._cancelled and result then
                callback(nil, CANCELLED_ERROR)
            else
                callback(result, err)
            end
        end
    end)
end

--- @param session_id string|nil
function SessionStartAttempt:_cancel_provider_session(session_id)
    if not session_id or self._cancelled_session_ids[session_id] then
        return
    end

    self._cancelled_session_ids[session_id] = true
    self._agent:cancel_session(session_id)
end

--- @param spec agentic.SessionStartSpec
--- @param handlers agentic.acp.ClientHandlers
--- @param callback fun(result: agentic.SessionStartResult|nil, err: agentic.acp.ACPError|nil)
function SessionStartAttempt:_start(spec, handlers, callback)
    self._callback = callback

    if spec.kind == "load" then
        self._claimed_session_id = spec.session_id
    elseif spec.kind ~= "new" then
        self:_complete(nil, INVALID_SPEC_ERROR)
        return
    end

    self._agent:when_ready(function()
        if self._cancelled then
            return
        end

        self._request_sent = true
        if spec.kind == "new" then
            self._agent:create_session(handlers, function(response, err)
                if self._cancelled then
                    self:_cancel_provider_session(
                        response and response.sessionId or nil
                    )
                    return
                end

                if err or not response then
                    self._request_sent = false
                    self:_complete(nil, err or INVALID_SPEC_ERROR)
                    return
                end

                self._claimed_session_id = response.sessionId
                --- @type agentic.SessionStartResult
                local result = {
                    kind = "new",
                    session_id = response.sessionId,
                    response = response,
                }
                self:_complete(result, nil)
            end)
        else
            self._replaying = true
            self._agent:load_session(
                spec.session_id,
                vim.fn.getcwd(),
                {},
                handlers,
                function(response, err)
                    if self._cancelled then
                        self:_cancel_provider_session(spec.session_id)
                        return
                    end

                    if err or not response then
                        self._request_sent = false
                        self:_complete(nil, err or INVALID_SPEC_ERROR)
                        return
                    end

                    --- @type agentic.SessionStartResult
                    local result = {
                        kind = "load",
                        session_id = spec.session_id,
                        response = response,
                    }
                    self:_complete(result, nil)
                end
            )
        end
    end, function(err)
        self:_complete(nil, err)
    end)
end

--- @param session_id string
--- @return boolean owns_id
function SessionStartAttempt:has_session_id(session_id)
    return self._claimed_session_id == session_id
end

--- @return boolean replaying
function SessionStartAttempt:is_replaying()
    return self._replaying
end

function SessionStartAttempt:cancel()
    if self._cancelled or self._completed then
        return
    end

    self._cancelled = true
    if self._request_sent then
        self:_cancel_provider_session(self._claimed_session_id)
    end
    if not self._completion_queued then
        self:_complete(nil, CANCELLED_ERROR)
    end
end

--- Starts one ACP conversation and returns its cancellation/query handle.
--- @param agent agentic.acp.ACPClient
--- @param spec agentic.SessionStartSpec
--- @param prepare_handlers fun(is_replaying: fun(): boolean): agentic.acp.ClientHandlers|nil, agentic.acp.ACPError|nil
--- @param callback fun(result: agentic.SessionStartResult|nil, err: agentic.acp.ACPError|nil)
--- @return agentic.SessionStartAttempt attempt
function SessionStarter.start(agent, spec, prepare_handlers, callback)
    local attempt = new_attempt(agent)
    local handlers, err = prepare_handlers(function()
        return attempt:is_replaying()
    end)
    if not handlers then
        --- @diagnostic disable-next-line: invisible
        attempt._callback = callback
        --- @diagnostic disable-next-line: invisible
        attempt:_complete(nil, err or INVALID_SPEC_ERROR)
        return attempt
    end

    --- @diagnostic disable-next-line: invisible
    attempt:_start(spec, handlers, callback)
    return attempt
end

return SessionStarter
