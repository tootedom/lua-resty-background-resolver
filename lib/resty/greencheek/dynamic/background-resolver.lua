-- Copyright [2018] [Dominic Tootell]

-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at

--     http://www.apache.org/licenses/LICENSE-2.0

-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local resty_chash = require "resty.chash"
local resolver = require "resty.dns.resolver"
local ngx = ngx
local ngx_log = ngx.log
local ngx_timer = ngx.timer

local default_refresh_interval = 30
local default_dns_resolver = {{ '8.8.8.8', 53 }}
local default_dns_timeout = 2
local default_dns_retries = 5
local balancing_type_round_robin = "round_robin"
local balancing_type_chash = "chash"

background_resolver = {}

function background_resolver.new(dns_name, cfg)

    local current_servers = {
        ['addresses'] = {},
        ['addresses_as_string'] = "",
        ['addresses_as_array'] = {},
        ['size'] = 0,
        ['no_of_updates'] = 0
    }


    -- private funtions

    local function _defaults(cfg)
        if cfg['dns_timeout'] == nil then
            cfg['dns_timeout'] = default_dns_timeout
        end

        if cfg['dns_retries'] == nil then
            cfg['dns_retries'] = default_dns_retries
        end

        if cfg['dns_resolver'] == nil then
            cfg['dns_resolver'] = default_dns_resolver
        end

        if cfg['refresh_interval'] == nil then
            cfg['refresh_interval'] = default_refresh_interval
        end

        if cfg['ip_black_list'] == nil then
            cfg['ip_black_list'] = {
                ['127.0.53.53'] = true
            }
        end

        if cfg['balancing_type'] == nil then
            cfg['balancing_type'] = balancing_type_chash
        end

        return cfg
    end

    local function is_diff(resolved_addresses,current_servers)
        for k,v in pairs(resolved_addresses) do
            if current_servers[k] == nil then
                return true
            end
        end
        return false
    end

    local function update_servers(dns_name, resolved_addresses, resolved_addresses_array, resolved_addresses_size, balancing_type)
        local new_current_servers = {
            ['addresses'] = resolved_addresses,
            ['addresses_as_string'] = table.concat(resolved_addresses_array,","),
            ['size'] = resolved_addresses_size,
            ['no_of_updates'] = (current_servers['no_of_updates'] + 1)
        }

        if balancing_type == balancing_type_round_robin then
            new_current_servers['balancing'] = {
                ['addresses_as_array'] = resolved_addresses_array,
                ['current_rr_index'] = -1,
                ['size'] = resolved_addresses_size
            }
        else
            new_current_servers['balancing'] = {
                ['chash'] = resty_chash:new(resolved_addresses),
                ['addresses'] = resolved_addresses
            }
        end

        current_servers = new_current_servers

    end

    local function _maybe_update_servers(dns_name, resolved_addresses, resolved_addresses_array, resolved_addresses_size, balancing_type)

        if current_servers == nil or current_servers['size'] ~= resolved_addresses_size then
            ngx_log(ngx.INFO,"Different in number of available addresses.  Updating Available Addresses for:" .. dns_name)
            update_servers(dns_name,resolved_addresses,resolved_addresses_array, resolved_addresses_size, balancing_type)
        else
            if is_diff(resolved_addresses,current_servers['addresses']) then
                ngx_log(ngx.INFO,"Difference in addresses.  Updating Available Addresses for:" .. dns_name)
                update_servers(dns_name,resolved_addresses,resolved_addresses_array, resolved_addresses_size, balancing_type)
            end
        end
    end

    local function refresh(premature, dns_name, cfg)
        if premature then
            return
        end

        local dns_resolver, err =  resolver:new{
            nameservers = cfg['dns_resolver'],
            timeout = cfg['dns_timeout'],
            retrans = cfg['dns_retries'],
        }

        if err then
            ngx_log(ngx.CRIT, "Failed to create resolver.  Unable to Resolve dns for:" .. dns_name, err)
        else
            if cfg['dns_resolver_id'] then
                dns_resolver._id = cfg['dns_resolver_id']
            end


            local answers, err, tries = dns_resolver:query(dns_name, { qtype = resolver.TYPE_A }, {})

            if answers then
                if not answers.errcode then
                    local current_servers = {}
                    local current_servers_array = {}
                    local number_of_valid_addresses = 0
                    for i, ans in ipairs(answers) do
                        local address = ans.address
                        if cfg['ip_black_list'][address] == nil then
                            current_servers[ans.address] = 1
                            number_of_valid_addresses = number_of_valid_addresses + 1
                            current_servers_array[number_of_valid_addresses] = ans.address
                        end
                    end

                    if number_of_valid_addresses>0 then
                        _maybe_update_servers( dns_name, current_servers, current_servers_array, number_of_valid_addresses, cfg['balancing_type'])
                    end
                end
            end
        end

        local ok, err = ngx_timer.at(cfg['refresh_interval'], refresh, dns_name, cfg)
        if not ok then
            ngx_log(ngx.CRIT, "Failed to schedule background dns resolution", err)
        end
    end

    local function round_robin(key)
        local balancer = current_servers['balancing']
        local next_index = balancer['current_rr_index'] + 1
        local current_index = ( ( next_index ) % balancer['size'] ) + 1
        balancer['current_rr_index'] = next_index
        return balancer['addresses_as_array'][current_index]
    end

    local function chash(key)
        local balancer = current_servers['balancing']
        local chash = balancer['chash']
        local index = chash:find(key)
        return index
    end

    -- Init

    if type(cfg) ~= "table" then
        cfg = {}
    end

    _defaults(cfg)


    local ok, err = ngx_timer.at(0, refresh, dns_name, cfg)
    if not ok then
        ngx_log(ngx.CRIT, "Failed to start background dns resolution", err)
        return nil
    end

    local self = {
    }

    if cfg['balancing_type'] == balancing_type_round_robin then
        self['balancer'] = round_robin
    end

    if  cfg['balancing_type'] == balancing_type_chash then
        self['balancer'] = chash
    end
    -- public functions

    function self.get_addresses_as_string()
        return current_servers['addresses_as_string']
    end

    function self.updated()
        return current_servers['no_of_updates']
    end

    function self.next(key)
        return self.balancer(key)
    end

    return self


end

return background_resolver