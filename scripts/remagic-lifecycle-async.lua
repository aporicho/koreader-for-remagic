-- Nonblocking process adapter for KOReader lifecycle helper transports.
--
-- The caller owns protocol encoding and the outbound queue. This module owns
-- only forked helper I/O, bounded polling, retries, timeouts, and cancellation.

return function(options)
    local FFIUtil = assert(options.ffiutil)
    assert(type(FFIUtil.runInSubProcess) == "function")
    assert(type(FFIUtil.isSubProcessDone) == "function")
    assert(type(FFIUtil.getNonBlockingReadSize) == "function")
    assert(type(FFIUtil.readAllFromFD) == "function")
    assert(type(FFIUtil.writeToFD) == "function")
    local ffi = assert(require("ffi"))
    local helper_path = assert(options.helper_path)
    local log = options.log or function() end
    local tick_seconds = assert(options.tick_seconds)
    local poll_ticks = math.max(1, math.ceil(options.poll_seconds / tick_seconds))
    local retry_ticks = math.max(1, math.ceil(options.retry_seconds / tick_seconds))
    local timeout_seconds = assert(options.timeout_seconds)
    local input_limit = options.input_limit or 256 * 1024
    local deployment_lock_fd_text = os.getenv("REMAGIC_KOREADER_DEPLOYMENT_LOCK_FD")
    local deployment_lock_fd = deployment_lock_fd_text
        and deployment_lock_fd_text:match("^[0-9]+$") and tonumber(deployment_lock_fd_text)
    local clock = options.monotonic_now
    if not clock then
        local time_ok, time = pcall(require, "ui/time")
        if time_ok and type(time.now) == "function" and type(time.to_s) == "function" then
            clock = function() return time.to_s(time.now()) end
        end
    end

    local function shell_quote(value)
        return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
    end

    local function helper_pipe(mode, pipe_mode)
        return io.popen(shell_quote(helper_path) .. " " .. mode, pipe_mode)
    end

    local function send_lines(lines)
        local process = helper_pipe("emit-batch", "w")
        if not process then
            return false
        end
        local wrote = process:write(table.concat(lines, "\n"), "\n")
        local closed = process:close()
        return wrote ~= nil and closed ~= nil
    end

    local function read_commands()
        local process = helper_pipe("poll", "r")
        if not process then
            return ""
        end
        local contents = process:read(input_limit + 1) or ""
        process:close()
        if #contents > input_limit then
            log("input-dropped", "reason=oversize")
            return ""
        end
        return contents
    end

    local function write_result(fd, result)
        if result == "" then
            return FFIUtil.writeToFD(fd, "", true)
        end
        local offset = 1
        while offset <= #result do
            local finish = math.min(offset + 4095, #result)
            local final = finish == #result
            if not FFIUtil.writeToFD(fd, result:sub(offset, finish), final) then
                if not final then pcall(FFIUtil.writeToFD, fd, "", true) end
                return false
            end
            offset = finish + 1
        end
        return true
    end

    local function now_seconds()
        if not clock then return nil end
        local ok, value = pcall(clock)
        if ok and type(value) == "number" then return value end
    end

    local function close_inherited_deployment_lock()
        if deployment_lock_fd then pcall(ffi.C.close, deployment_lock_fd) end
    end

    local function start_worker(kind, lines)
        local snapshot = lines or {}
        local launched, pid, read_fd = pcall(FFIUtil.runInSubProcess, function(_, child_write_fd)
            close_inherited_deployment_lock()
            local result = ""
            if kind == "poll" then
                local ok, contents = pcall(read_commands)
                if ok then
                    result = contents
                end
            elseif kind == "emit" then
                local ok, delivered = pcall(send_lines, snapshot)
                result = tostring(ok and delivered and #snapshot or 0) .. "\n"
            end
            pcall(write_result, child_write_fd, result)
        end, true)
        if not launched or not pid then
            log("launch-failed", "kind=" .. kind .. " error=" .. tostring(pid))
            return nil
        end
        return {
            pid = pid,
            read_fd = read_fd,
            kind = kind,
            age = 0,
            started_at = now_seconds(),
            cancelled = false,
            count = #snapshot,
            chunks = {},
            output_bytes = 0,
            output_limit = kind == "poll" and input_limit or 64,
            oversize = false,
        }
    end

    local read_buffer = ffi.new("char[?]", 8192)
    local read_pointer = ffi.cast("void *", read_buffer)

    local function append_output(worker, chunk)
        worker.output_bytes = worker.output_bytes + #chunk
        if worker.output_bytes > worker.output_limit then
            worker.oversize = true
            return
        end
        worker.chunks[#worker.chunks + 1] = chunk
    end

    local function drain_available(worker)
        if not worker.read_fd then return end
        local size_ok, available = pcall(FFIUtil.getNonBlockingReadSize, worker.read_fd)
        if not size_ok or type(available) ~= "number" or available <= 0 then return end
        while available > 0 do
            local requested = math.min(available, 8192)
            local read_ok, count = pcall(function()
                return tonumber(ffi.C.read(worker.read_fd, read_pointer, requested))
            end)
            if not read_ok or not count or count <= 0 then
                log("result-failed", "kind=" .. worker.kind .. " reason=pipe-read")
                return
            end
            append_output(worker, ffi.string(read_buffer, count))
            available = available - count
        end
    end

    local function terminate_worker_process(worker)
        local checked, done = pcall(FFIUtil.isSubProcessDone, worker.pid)
        if checked and done then return end
        -- Do not waitpid between these signals: an unreaped PID cannot be
        -- reused, while the positive fallback closes the fork-to-setpgid race.
        pcall(ffi.C.kill, -worker.pid, 9)
        pcall(ffi.C.kill, worker.pid, 9)
    end

    local function collect_worker(worker)
        if not worker then
            return nil, false, nil
        end
        drain_available(worker)
        local checked, done = pcall(FFIUtil.isSubProcessDone, worker.pid)
        if checked and done then
            local read_ok, result = pcall(FFIUtil.readAllFromFD, worker.read_fd)
            if not read_ok then
                log("result-failed", "kind=" .. worker.kind .. " error=" .. tostring(result))
                result = ""
            end
            append_output(worker, result)
            if worker.oversize then
                log("input-dropped", "kind=" .. worker.kind .. " reason=oversize")
                return nil, true, ""
            end
            local output = table.concat(worker.chunks)
            if worker.cancelled then
                if worker.kind ~= "poll" then return nil, true, "" end
                local complete_boundary = output:match("^.*()\n")
                output = complete_boundary and output:sub(1, complete_boundary) or ""
            end
            return nil, true, output
        end

        local now = now_seconds()
        local timed_out
        if now and worker.started_at then
            timed_out = now - worker.started_at >= timeout_seconds
        else
            worker.age = worker.age + tick_seconds
            timed_out = worker.age >= timeout_seconds
        end
        if timed_out and not worker.cancelled then
            worker.cancelled = true
            terminate_worker_process(worker)
            log("timeout", "kind=" .. worker.kind)
        end
        return worker, false, nil
    end

    local poll_worker
    local emit_worker
    local retired_workers = {}
    local poll_countdown = 0
    local emit_countdown = 0

    local adapter = {}

    local function retire_worker(worker)
        if not worker then return end
        terminate_worker_process(worker)
        worker.cancelled = true
        retired_workers[#retired_workers + 1] = worker
    end

    local function collect_retired()
        for index = #retired_workers, 1, -1 do
            local worker, completed = collect_worker(retired_workers[index])
            if completed then
                table.remove(retired_workers, index)
            else
                retired_workers[index] = worker
            end
        end
    end

    local function collect_poll()
        local completed, result
        local worker = poll_worker
        poll_worker, completed, result = collect_worker(poll_worker)
        if completed then
            if worker.cancelled then poll_countdown = 0 end
            return result or ""
        end
        return ""
    end

    function adapter:pump_poll()
        collect_retired()
        local contents = collect_poll()
        if poll_worker or emit_worker then
            return contents
        end
        if poll_countdown > 0 then
            poll_countdown = poll_countdown - 1
            return contents
        end
        poll_countdown = poll_ticks - 1
        poll_worker = start_worker("poll")
        if not poll_worker then
            poll_countdown = retry_ticks - 1
            return contents
        end
        -- WNOHANG makes this safe when a real child is still running, while a
        -- fast bridge can deliver without an additional UI tick.
        return contents .. collect_poll()
    end

    local function collect_emit(outbound)
        if not emit_worker then
            return
        end
        local worker = emit_worker
        local completed, result
        emit_worker, completed, result = collect_worker(worker)
        if not completed then
            return
        end
        local sent = math.max(0, math.min(tonumber(result) or 0, worker.count))
        for _ = 1, sent do
            table.remove(outbound, 1)
        end
        if sent < worker.count then
            emit_countdown = retry_ticks
            log("emit-incomplete", "sent=" .. tostring(sent) .. " count=" .. tostring(worker.count))
        else
            emit_countdown = 0
        end
    end

    function adapter:pump_emit(outbound)
        collect_retired()
        collect_emit(outbound)
        if poll_worker then return false end
        if emit_worker or not outbound[1] then
            return emit_worker == nil
        end
        if emit_countdown > 0 then
            emit_countdown = emit_countdown - 1
            return false
        end
        local snapshot = {}
        for index, line in ipairs(outbound) do
            snapshot[index] = line
        end
        emit_worker = start_worker("emit", snapshot)
        if not emit_worker then
            emit_countdown = retry_ticks
            return false
        end
        collect_emit(outbound)
        return emit_worker == nil and not outbound[1]
    end

    function adapter:invoke(mode)
        local launched, pid = pcall(FFIUtil.runInSubProcess, function()
            close_inherited_deployment_lock()
            local process = helper_pipe(mode, "r")
            if process then
                process:read("*a")
                process:close()
            end
        end, false, true)
        if not launched or not pid then
            log("launch-failed", "kind=" .. mode .. " error=" .. tostring(pid))
            return false
        end
        return true
    end

    function adapter:emit_final(lines, outbound)
        local batch = {}
        for _, line in ipairs(outbound or {}) do batch[#batch + 1] = line end
        for _, line in ipairs(lines) do batch[#batch + 1] = line end
        if #batch == 0 then
            return true
        end
        retire_worker(poll_worker)
        poll_worker = nil
        poll_countdown = 0
        retire_worker(emit_worker)
        emit_worker = nil
        emit_countdown = 0
        -- The parent may terminate as soon as Device:exit returns. One child
        -- owns the locked ordered batch, so a late ready cannot follow it.
        local launched, pid = pcall(FFIUtil.runInSubProcess, function()
            close_inherited_deployment_lock()
            pcall(send_lines, batch)
        end, false, true)
        if not launched or not pid then
            log("launch-failed", "kind=final-events error=" .. tostring(pid))
            return false
        end
        if outbound then
            for index = #outbound, 1, -1 do outbound[index] = nil end
        end
        return true
    end

    function adapter:cancel_poll()
        if not poll_worker then
            return
        end
        retire_worker(poll_worker)
        poll_worker = nil
    end

    function adapter:cancel_all()
        retire_worker(poll_worker)
        poll_worker = nil
        retire_worker(emit_worker)
        emit_worker = nil
        poll_countdown = 0
        emit_countdown = 0
    end

    return adapter
end
