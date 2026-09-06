-- Minimal v0.20.5 test dashboard on device loopback. Never executes commands
-- from an agent. Native hyper-h2 tests independently cover general transport.
local nx = require "nixio"
local fs = require "nixio.fs"
local json = require "luci.jsonc"
local port, dir, rounds, period = tonumber(arg[1]), arg[2], tonumber(arg[3]), tonumber(arg[4])
assert(port and dir:match("^/tmp/nezha%-zig%-test%-%x+$") and rounds and period)
local status_path = dir .. "/status.json"
local stats = {running=true, complete=false, round=0, results=0, states=0, hosts=0,
    task_connections=0, duplicate_results=0, samples={}, batches={}, errors={}}
local clients, expected, deferred = {}, {}, {}
local task_client, task_stream, base, last_state, next_id = nil, nil, nil, nil, 1
local pending, last_save, max_gap = 0, 0, 0
local finish_time
local disconnect_at

local function now()
    local sec, usec = nx.gettimeofday()
    return sec + usec / 1000000
end
local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function save()
    stats.max_state_gap_s = max_gap
    stats.elapsed_s = base and now() - base or 0
    local f = assert(io.open(status_path .. ".tmp", "w"))
    f:write(json.stringify(stats)); f:close()
    assert(os.rename(status_path .. ".tmp", status_path))
    last_save = now()
end
local function be(value, width)
    local bytes = {}
    for i=width,1,-1 do bytes[i]=string.char(value % 256); value=math.floor(value/256) end
    return table.concat(bytes)
end
local function uint(data, start, width)
    local value=0
    for i=start,start+width-1 do value=value*256+data:byte(i) end
    return value
end
local function varint(value)
    local out={}
    repeat local b=value%128; value=math.floor(value/128)
        out[#out+1]=string.char(b+(value>0 and 128 or 0))
    until value==0
    return table.concat(out)
end
local function decode(data)
    local out, p={},1
    local function vi()
        local value, scale=0,1
        for _=1,10 do
            local b=assert(data:byte(p), "truncated varint"); p=p+1
            value=value+(b%128)*scale
            if b<128 then return value end
            scale=scale*128
        end
        error("invalid varint")
    end
    while p<=#data do
        local key=vi(); local field,wire=math.floor(key/8),key%8
        if wire==0 then out[field]=vi()
        elseif wire==2 then local n=vi(); assert(p+n-1<=#data); out[field]=data:sub(p,p+n-1); p=p+n
        elseif wire==1 then assert(p+7<=#data); p=p+8
        elseif wire==5 then assert(p+3<=#data); p=p+4
        else error("unexpected protobuf wire type") end
    end
    return out
end
local function frame(c, typ, flags, sid, payload)
    if c.closed then return end
    c.output=c.output..be(#payload,3)..string.char(typ,flags)..be(sid,4)..payload
    assert(#c.output<262144, "fixture output overflow")
end
local function hp(text)
    if #text<127 then return string.char(#text)..text end
    return string.char(127)..varint(#text-127)..text
end
local function header(name,value) return "\0"..hp(name)..hp(value) end
local function envelope(data) return "\0"..be(#data,4)..data end
local function receipt(c,sid,accepted)
    frame(c,1,4,sid,header(":status","200")..header("content-type","application/grpc"))
    frame(c,0,0,sid,envelope(accepted and "\8\1" or "\8\0"))
    frame(c,1,5,sid,header("grpc-status","0"))
end
local function close(c)
    if c.closed then return end
    c.closed=true; c.socket:close()
    if task_client==c then task_client,task_stream=nil,nil end
end
local function control(typ)
    if task_client then
        frame(task_client,0,0,task_stream,envelope("\8\0\16"..varint(typ)))
    end
end
local function rpc(c,sid,entry)
    local body=entry.body
    assert(#body>=5 and body:byte(1)==0 and uint(body,2,4)==#body-5, "invalid envelope")
    local fields=decode(body:sub(6))
    if entry.path=="RequestTask" then
        task_client,task_stream=c,sid
        stats.task_connections=stats.task_connections+1
        if not base then base=now(); stats.start_unix=base end
        frame(c,1,4,sid,header(":status","200")..header("content-type","application/grpc"))
        return
    elseif entry.path=="ReportSystemInfo" then
        assert(fields[7]=="aarch64", "unexpected architecture")
        stats.hosts=stats.hosts+1
        stats.memory_total=fields[4]; stats.platform=fields[1]; stats.cpu=fields[3]
        if stats.refresh_requested then stats.refresh_observed=true end
    elseif entry.path=="ReportSystemState" then
        local t=now()
        if last_state then max_gap=math.max(max_gap,t-last_state) end
        last_state=t; stats.states=stats.states+1
        assert(fields[3] and fields[3]>0, "missing memory state")
        stats.last_memory_used=fields[3]; stats.last_uptime=fields[10]
    elseif entry.path=="ReportTask" then
        local id=fields[1]
        local job=assert(expected[id], "unrequested result "..tostring(id))
        if job.done then
            stats.duplicate_results=stats.duplicate_results+1
            error("duplicate result")
        end
        assert(fields[2]==2 and fields[5]==1, "ICMP failed: "..tostring(fields[4]))
        job.done=true; pending=pending-1; stats.results=stats.results+1
        local batch=stats.batches[job.round]
        batch.completed=batch.completed+1
        batch.max_result_s=math.max(batch.max_result_s, now()-job.sent)
        if job.round==4 then
            deferred[#deferred+1]={at=now()+0.15,client=c,sid=sid}
            return
        end
    else error("unknown RPC") end
    receipt(c,sid,not fs.stat(dir.."/reject"))
end
local function parse(c)
    if not c.preface then
        if #c.input<24 then return end
        assert(c.input:sub(1,24)=="PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "bad preface")
        c.input=c.input:sub(25); c.preface=true
        frame(c,4,0,0,"")
    end
    while #c.input>=9 do
        local length=uint(c.input,1,3)
        assert(length<=16384, "unexpected frame size")
        if #c.input<9+length then return end
        local typ,flags,sid=c.input:byte(4),c.input:byte(5),uint(c.input,6,4)%2147483648
        local payload=c.input:sub(10,9+length); c.input=c.input:sub(10+length)
        if typ==4 then
            if flags%2==0 then frame(c,4,1,0,"") end
        elseif typ==6 then
            if flags%2==0 then frame(c,6,1,0,payload) end
        elseif typ==1 then
            assert(payload:find("local-test",1,true), "unexpected test credential")
            local path=assert(payload:match("/proto%.NezhaService/([%w_]+)"), "missing RPC path")
            c.streams[sid]={path=path,body=""}
        elseif typ==0 then
            local entry=assert(c.streams[sid], "DATA without HEADERS")
            entry.body=entry.body..payload
            assert(#entry.body<=65536)
            frame(c,8,0,0,be(length,4)); frame(c,8,0,sid,be(length,4))
            if flags%2==1 then rpc(c,sid,entry); c.streams[sid]=nil end
        elseif typ==7 then close(c); return
        elseif typ~=8 and typ~=3 then error("unexpected frame") end
    end
end
local function sample()
    local pid=tonumber(read(dir.."/agent.pid") or "")
    assert(pid and pid>1)
    local status=assert(read("/proc/"..pid.."/status"), "agent exited")
    local stat=assert(read("/proc/"..pid.."/stat"))
    local values={}
    for value in stat:match("%) (.*)"):gmatch("%S+") do values[#values+1]=value end
    local cpu={}
    for value in assert(read("/proc/stat")):match("^cpu ([^\n]+)"):gmatch("%d+") do cpu[#cpu+1]=tonumber(value) end
    local sum=0; for i=1,8 do sum=sum+cpu[i] end
    local item={time=now(),rss_kib=tonumber(status:match("VmRSS:%s*(%d+)")),
        vms_kib=tonumber(status:match("VmSize:%s*(%d+)")),
        threads=tonumber(status:match("Threads:%s*(%d+)")),
        proc_ticks=tonumber(values[12])+tonumber(values[13]),system_ticks=sum}
    local smaps=read("/proc/"..pid.."/smaps_rollup")
    if smaps then item.pss_kib=tonumber(smaps:match("\nPss:%s*(%d+)")) end
    local count=0; for _ in fs.dir("/proc/"..pid.."/fd") do count=count+1 end
    item.fd_count=count
    assert(item.threads==36, "worker count changed")
    stats.samples[#stats.samples+1]=item
end
local function burst()
    local round=stats.round+1
    local count=round==1 and 8 or (round==2 and 16 or 32)
    local target=round%4==0 and "::1" or (round%4==3 and "localhost" or "127.0.0.1")
    local batch={round=round,count=count,completed=0,target=target,max_result_s=0,started=now()}
    stats.batches[round]=batch
    local messages={}
    for _=1,count do
        local id=next_id; next_id=next_id+1
        expected[id]={round=round,sent=now(),done=false}; pending=pending+1
        local data="\8"..varint(id).."\16\2\26"..varint(#target)..target
        messages[#messages+1]=envelope(data)
    end
    frame(task_client,0,0,task_stream,table.concat(messages))
    stats.round=round; control(7)
end
local listener=assert(nx.socket("inet","stream"))
assert(listener:bind("127.0.0.1",port)); assert(listener:listen(16))
assert(listener:setblocking(false))
stats.listening_port=port; save()
local ok,err=xpcall(function()
    while true do
        local poll={{fd=listener,events=nx.poll_flags("in")}}
        for _,c in ipairs(clients) do
            if not c.closed then
                poll[#poll+1]={fd=c.socket,events=#c.output>0 and nx.poll_flags("in","out") or nx.poll_flags("in")}
            end
        end
        nx.poll(poll,50)
        while true do
            local socket=listener:accept(); if not socket then break end
            socket:setblocking(false)
            clients[#clients+1]={socket=socket,input="",output="",streams={}}
        end
        for _,c in ipairs(clients) do
            if not c.closed then
                local data,code=c.socket:recv(65536)
                if data and #data>0 then c.input=c.input..data; parse(c)
                elseif data=="" or (not data and code~=11) then close(c) end
            end
        end
        local t=now()
        for i=#deferred,1,-1 do
            local item=deferred[i]
            if t>=item.at then receipt(item.client,item.sid,true); table.remove(deferred,i) end
        end
        if base and pending==0 then
            local batch=stats.batches[stats.round]
            if batch and not batch.sampled then
                assert(batch.max_result_s<period, "batch exceeded scheduling period")
                sample(); batch.sampled=true
                if stats.round==6 and not stats.reconnect_injected then
                    -- Deliver the last task receipt before testing connection
                    -- loss; otherwise an ambiguous acknowledgement legitimately
                    -- causes a duplicate retry and tests the wrong condition.
                    disconnect_at=now()+1
                elseif stats.round==7 then stats.refresh_requested=true; control(10) end
                save()
            end
            if stats.round==rounds then
                assert(stats.states>(rounds-1)*period/2, "insufficient state reports")
                assert(max_gap<8, "state reporting stalled")
                assert(stats.task_connections>=2 and stats.refresh_observed, "recovery/control not verified")
                local min,max=math.huge,0
                for _,s in ipairs(stats.samples) do min=math.min(min,s.rss_kib); max=math.max(max,s.rss_kib) end
                assert(max-min<=1024, "memory growth exceeds 1 MiB")
                stats.rss_min_kib,stats.rss_max_kib=min,max
                finish_time=finish_time or now()
                local drained=#deferred==0
                for _,c in ipairs(clients) do if not c.closed and #c.output>0 then drained=false end end
                if now()-finish_time>=3 and drained then
                    stats.complete=true; stats.running=false; save()
                    break
                end
            end
            if stats.round<rounds and task_client and t>=base+stats.round*period then burst(); save() end
        end
        for i=#clients,1,-1 do
            local c=clients[i]
            if not c.closed and #c.output>0 then
                local n,code=c.socket:send(c.output)
                if n and n>0 then c.output=c.output:sub(n+1)
                elseif code~=11 then close(c) end
            end
            if c.closed then table.remove(clients,i) end
        end
        if disconnect_at and now()>=disconnect_at then
            local drained=true
            for _,c in ipairs(clients) do if #c.output>0 then drained=false end end
            if drained then
                for _,c in ipairs(clients) do close(c) end
                stats.reconnect_injected=true; disconnect_at=nil
            end
        end
        if now()-last_save>=2 then save() end
        if base and now()-base>rounds*period+90 then error("fixture exceeded test deadline") end
    end
end,debug.traceback)
if not ok then stats.running=false; stats.error=err; save() end
for _,c in ipairs(clients) do close(c) end
listener:close()
if not ok then io.stderr:write(err.."\n"); os.exit(1) end
