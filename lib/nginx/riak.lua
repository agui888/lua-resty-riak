local _M = {}

_M._VERSION = '0.0.1'

-- https://wiki.basho.com/PBC-API.html

-- this is insired by the riak ruby client

-- pb is pure Lua.  The interface is pretty easy, but we can switch it out if needed.
local pb = require "pb"

require "pack"

-- riak_kv.proto should be in the include path
local riak = pb.require "nginx.riak.protos.riak"
local riak_kv = require "nginx.riak.protos.riak_kv"
local bit = require "bit"

local RpbGetReq = riak_kv.RpbGetReq
local RpbGetResp = riak_kv.RpbGetResp
local RpbPutReq = riak_kv.RpbPutReq
local RpbPutResp = riak_kv.RpbPutResp
local RpbErrorResp = riak.RpbErrorResp

local mt = {}
local client_mt = {}
local bucket_mt = {}
local object_mt = {}

local insert = table.insert
local tcp = ngx.socket.tcp
local mod = math.mod
local pack = string.pack
local unpack = string.unpack


-- bleah, this is ugly
local MESSAGE_CODES = {
    ErrorResp = "0",
    ["0"] = "ErrorResp",
    PingReq = "1",
    ["1"] = "PingReq",
    PingResp = "2",
    ["2"] = "PingResp",
    GetClientIdReq = "3",
    ["3"] = "GetClientIdReq",
    GetClientIdResp = "4",
    ["4"] = "GetClientIdResp",
    SetClientIdReq = "5",
    ["5"] = "SetClientIdReq",
    SetClientIdResp = "6",
    ["6"] = "SetClientIdResp",
    GetServerInfoReq = "7",
    ["7"] = "GetServerInfoReq",
    GetServerInfoResp = "8",
    ["8"] = "GetServerInfoResp",
    GetReq = "9",
    ["9"] = "GetReq",
    GetResp = "10",
    ["10"] = "GetResp",
    PutReq = "11",
    ["11"] = "PutReq",
    PutResp = "12",
    ["12"] = "PutResp",
    DelReq = "13",
    ["13"] = "DelReq",
    DelResp = "14",
    ["14"] = "DelResp",
    ListBucketsReq = "15",
    ["15"] = "ListBucketsReq",
    ListBucketsResp = "16",
    ["16"] = "ListBucketsResp",
    ListKeysReq = "17",
    ["17"] = "ListKeysReq",
    ListKeysResp = "18",
    ["18"] = "ListKeysResp",
    GetBucketReq = "19",
    ["19"] = "GetBucketReq",
    GetBucketResp = "20",
    ["20"] = "GetBucketResp",
    SetBucketReq = "21",
    ["21"] = "SetBucketReq",
    SetBucketResp = "22",
    ["22"] = "SetBucketResp",
    MapRedReq = "23",
    ["23"] = "MapRedReq",
    MapRedResp = "24",
    ["24"] = "MapRedResp",
    IndexReq = "25",
    ["25"] = "IndexReq",
    IndexResp = "26",
    ["26"] = "IndexResp",
    SearchQueryReq = "27",
    ["27"] = "SearchQueryReq",
    SearchQueryResp = "28",
    ["28"] = "SearchQueryResp"
}

-- servers should be in the form { {:host => host/ip, :port => :port }
function _M.new(servers, options)
    options = options or {}
    local r = {
        servers = {},
        _current_server = 1,
        timeout = options.timeout,
        keepalive_timeout = options.keepalive_timeout,
        keepalive_pool_size = options.keepalive_pool_size,
        really_close = options.really_close
    }
    servers = servers or {{ host = "127.0.0.1", port = 8087 }}
    for _,server in ipairs(servers) do
        if "table" == type(server) then
            insert(r.servers, { host = server.host or "127.0.0.1", port = server.port or 8087 })
        else
            insert(r.servers, { host = server, port = 8087 })
        end
    end
    
    setmetatable(r, { __index = mt })
    return r
end

-- TODO: nginx socket pool stuff?
local function rr_connect(self)
    local sock = self.sock
    local servers = self.riak.servers
    local curr = mod(self.riak._current_server + 1, #servers) + 1
    self.riak._current_server = curr
    local server = servers[curr]

    if self.timeout then
        sock:settimeout(timeout)
    end

    local ok, err = sock:connect(server.host, server.port)
    if not ok then
        return nil, err
    end
    return true, nil
end

function mt.connect(self)
    local c = {
        riak = self,
        sock = tcp()
    }
    local ok, err = rr_connect(c)
    if not ok then
        return nil, err
    end
    setmetatable(c,  { __index = client_mt })
    return c
end

function client_mt.bucket(self, name)
    local b = {
        name = name,
        client = self
    }
    setmetatable(b, { __index = bucket_mt })
    return b
end

function bucket_mt.new(self, key)
    local o = {
        bucket = self,
        key = key,
        meta = {}
    }
    setmetatable(o,  { __index = object_mt })
    return o
end

local response_funcs = {}

function response_funcs.GetResp(msg)
    local response, off = RpbGetResp():Parse(msg)
    -- we only support single gets currently
    local content = response.content[1]
    -- there is probably a more effecient way to do this    
    local o = {
        bucket = self,
        --vclock = response.vclock,
        value = content.value,
        charset = content.charset,
        content_encoding =  content.content_encoding,
        content_type = content.value,
        last_mod = content.last_mod
    }
    
    local meta = {}
    if content.usermeta then 
        for _,m in ipairs(content.usermeta) do
            meta[m.key] = m.val
        end
    end
    o.meta = meta
    setmetatable(o,  { __index = object_mt })
    return o
end

function response_funcs.ErrorResp(msg)
    local response, off = RpbErrorResp():Parse(msg)
    return nil, errmsg, errcode
end

function response_funcs.PutResp(msg)
    local response, off = RpbPutResp():Parse(msg)
    -- we don't really do anything here...
    return true
end

local empty_response_okay = {
    PingResp = 1,
    SetClientIdResp = 1,
    PutResp = 1,
    DelResp = 1,
    SetBucketResp = 1
}

function client_mt.handle_response(client)
    local sock = client.sock
    local bytes, err, partial = sock:receive(5)
    if not bytes then
        return nil, err
    end
    
    local _, length, msgcode = unpack(bytes, ">Ib")
    local msgtype = MESSAGE_CODES[tostring(msgcode)]
    
    if not msgtype then
        return nil, "unhandled response type"
    end
    
    bytes = length - 1
    if bytes <= 0 then
        if empty_response_okay[msgtype] then
            return true, nil
        else
            client:close(true)
            return nil, "empty response"
        end
    end
    -- hack: some messages can return no body on success?
    local msg, err = sock:receive(bytes)
    if not msg then
        client:close(true)
        return nil, err
    end
    
    local func = response_funcs[msgtype]
    return func(msg)
end

-- ugly...
local function send_request(client, msgcode, encoder, request)
    local msg = encoder(request)
    local bin = msg:Serialize()
    
    local info = pack(">Ib", #bin + 1, msgcode)

    local bytes, err = client.sock:send({ info, bin })
    if not bytes then
        return nil, err
    end
    return true, nil
end

local request_encoders = {
    GetReq = RpbGetReq,
    PutReq = RpbPutReq
}

for k,v in pairs(request_encoders) do
    client_mt[k] = function(client, request) 
                       return send_request(client, MESSAGE_CODES[k], v, request)
                   end
end

function bucket_mt.get(self, key)
    local request = {
        bucket = self.name,
        key = key
    }
    local client = self.client
    local rc, err = client:GetReq(request)
    if not rc then
        return rc, err
    end
    local o, err = client:handle_response()
    if not o then
        return nil, err
    end
    o.key = key
    return o
end

function bucket_mt.get_or_new(self, key)
    local o, err = self:get(key)
    if not o and "not found" == err then
        o, err = self:new(key)
    end
    return o, err
end

function client_mt.close(self, really_close)
    if really_close or self.really_close then
        return self.sock:close()
    else
        if self.keepalive_timeout or self.keepalive_pool_size then
            return self.sock:setkeepalive(self.keepalive_timeout, self.keepalive_pool_size)
        else
            return self.sock:setkeepalive()
        end
    end
end

-- only support named keys for now
function object_mt.store(self)
    if not self.content_type then
        return nil, "content_type is required"
    end

    if not self.key then
        return nil, "only support named keys for now"
    end
    
    local meta = {}
    for k,v in pairs(self.meta) do
        insert(meta, { key = k, value = v })
    end

    local request = {
        bucket = self.bucket.name,
        key = self.key,
        --vclock = self.vclock,
        content = {
            value = self.value or "",
            content_type = self.content_type,
            charset = self.charset,
            content_encoding = self.content_encoding, 
            usermeta = meta
        }
    }
    
    local client = self.bucket.client
     
    local rc, err = client:PutReq(request)
    
    rc, err = client:handle_response()
    
    if rc then
        return true, nil
    else
        return rc, err
    end
end

function object_mt.reload(self, force)
end


return _M
