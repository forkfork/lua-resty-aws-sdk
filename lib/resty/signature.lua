local ngx = require 'ngx'
local sha256 = require 'resty.sha256'
local str = require 'resty.string'
local ffi = require "ffi"
local ffi_new = ffi.new
local ffi_str = ffi.string
local C = ffi.C

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local _M = {}

ffi.cdef [[
typedef struct env_md_st EVP_MD;
typedef struct env_md_ctx_st EVP_MD_CTX;
unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
            const unsigned char *d, size_t n, unsigned char *md,
            unsigned int *md_len);
const EVP_MD *EVP_sha256(void);
]]



local digest_len = ffi_new("int[?]", 64)
local buf = ffi_new("char[?]", 64)



local function hmac_sha256(key, msg)
    C.HMAC(C.EVP_sha256(), key, #key, msg, #msg, buf, digest_len)
    return ffi_str(buf, 32)
end



-- @see http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
local function sha256_hex(payload)
    local hasher = sha256:new()
    hasher:update(payload)
    local hashed = hasher:final()
    return str.to_hex(hashed)
end


-- @see http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
local function encode_headers(headers)
    local header
    local result = ''
    for i = 1, #headers do
        header = headers[i]
        result = result .. string.lower(header[1]) .. ':' .. header[2] .. '\n'
    end
    return result
end


-- @see http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
local function create_sign_headers(headers)
    local names = new_tab(#headers, 0)
    local header
    for i = 1, #headers do
        header = headers[i]
        names[i] = string.lower(header[1])
    end
    return table.concat(names, ';')
end


-- @see http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
local function encode_args(to_encode)
    local args = new_tab(#to_encode, 0)
    local arg
    for i = 1, #to_encode do
        arg = to_encode[i]
        args[i] = arg[1] .. '=' .. ngx.escape_uri(arg[2])
    end
    return table.concat(args, '&')
end


--
-- local c = canonical_req(
--     'GET',
--     '/',
--     {{'Action','ListUsers'}, {'Version','2010-05-08'}},
--     {
--         {'content-type', 'application/x-www-form-urlencoded; charset=utf-8'},
--         {'HOST', 'iam.amazonaws.com'},
--         {'x-amz-date', '20150830T123600Z'}
--     },
--     '')
-- @see http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
local function canonical_req(method, uri, query, headers, payload)
    return string.upper(method)         .. '\n' ..
           uri                          .. '\n' ..
           encode_args(query)           .. '\n' ..
           encode_headers(headers)      .. '\n' ..
           create_sign_headers(headers) .. '\n' ..
           sha256_hex(payload)
end



_M.new_canonical_request = canonical_req
_M.hash_canonical = sha256_hex



-- @see http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
local function amz_date()
    local date = ngx.re.gsub(ngx.utctime(), '(-|:)', '')

    return string.format('%sT%sZ',
                         string.sub(date, 1, 8),
                         string.sub(date, 10, string.len(date)))
end



-- @see http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
local function date()
    local d = ngx.re.gsub(ngx.utctime(), '-', '')
    return string.sub(d, 1, 8)
end



_M.amz_date = amz_date
_M.date = date



local function string_to_sign(canonical_hash, headers, region, service)
    local amz_d

    for i = 1, #headers do
        if string.lower(headers[i][1]) == 'x-amz-date' then
            amz_d = headers[i][2]
        end
    end

    if not amz_d then
        amz_d = amz_date()
        table.insert(headers, { 'x-amz-date', amz_d })
    end

    return 'AWS4-HMAC-SHA256\n' ..
           amz_d .. '\n' ..
           string.sub(amz_d, 1, 8) .. '/' .. region .. '/' .. service .. '/aws4_request\n' ..
           canonical_hash
end



-- print(derive_key('wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', '20150830', 'us-east-1', 'iam'))
local function derive_key(aws_secret, d, region, service)
    local ord = { region, service, 'aws4_request' }
    local len = #ord
    local k

    k = hmac_sha256('AWS4' .. aws_secret, d)

    for i=1, len do
        k = hmac_sha256(k, ord[i])
    end

    return k
end


function _M.create_signiture(aws_secret, d, region, service, data)
    return str.to_hex( hmac_sha256(derive_key(aws_secret, d, region, service), data))
end



local headers = {
    {'content-type', 'application/x-www-form-urlencoded; charset=utf-8'},
    {'HOST', 'iam.amazonaws.com'},
    {'x-amz-date', '20150830T123600Z'}
} 
local c = canonical_req(
    'GET',
    '/',
    {{'Action','ListUsers'}, {'Version','2010-05-08'}},
    headers,
    '')

local chash = sha256_hex(c)
local sts = string_to_sign(chash, headers, 'us-east-1', 'iam')
print(sts)
print('----------------------------------------------------------------------------------------\n')
print(_M.create_signiture('wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', '20150830', 'us-east-1', 'iam', sts))

--return _M
