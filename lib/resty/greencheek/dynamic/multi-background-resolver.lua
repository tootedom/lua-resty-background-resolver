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
local ngx_info = ngx.INFO
local ngx_crit = ngx.CRIT
local ngx_warn = ngx.WARN
local ngx_timer = ngx.timer

local default_refresh_interval = 30
local default_dns_resolver = {{ '8.8.8.8', 53 }}
local default_dns_timeout = 1000
local default_dns_retries = 2
local balancing_type_round_robin = "round_robin"
local balancing_type_chash = "chash"
local default_balancing_type = balancing_type_round_robin

local data = {}
local _M = {}

local round_robin = function(key, id)
    local balancer = data[id]['balancing']
    if balancer['size']>0 then
        local next_index = balancer['current_rr_index'] + 1
        local current_index = ( ( next_index ) % balancer['size'] ) + 1
        balancer['current_rr_index'] = next_index
        return balancer['addresses_as_array'][current_index]
    else
        return nil,"no_peers_available"
    end
end

local chash = function(key, id)
    local balancer = data[id]['balancing']
    if balancer['size']>0 then
        local chash = balancer['chash']
        local index = chash:find(key)
        return index
    else
        return nil,"no_peers_available"
    end
end

function _M.start(dns_names, cfg)

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
            cfg['balancing_type'] = default_balancing_type
        end

        return cfg
    end

    local function is_diff(dns_id,resolved_addresses,resolved_addresses_array,current_servers)
        for k,v in pairs(resolved_addresses) do
            if current_servers[k] == nil then
                return true
            end
        end
        return false
    end

    local function update_servers(dns_name, resolved_addresses, resolved_addresses_array, resolved_addresses_size, balancing_type)
        local dns_entry_info = data[dns_name['id']]
        local new_current_servers = {
            ['addresses'] = resolved_addresses,
            ['addresses_as_string'] = table.concat(resolved_addresses_array,", "),
            ['size'] = resolved_addresses_size,
            ['no_of_updates'] = (dns_entry_info['no_of_updates'] + 1),
            ['balancer_method'] = dns_entry_info['balancer_method'],
            ['fallback'] = dns_entry_info['fallback'],
            ['allow_zero_ips'] = dns_entry_info['allow_zero_ips']
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
                ['addresses'] = resolved_addresses,
                ['size'] = resolved_addresses_size
            }
        end

        data[dns_name['id']] = new_current_servers

    end

    local function _maybe_update_servers(dns_name, resolved_addresses, resolved_addresses_array, resolved_addresses_size, balancing_type)
        local dns_entry_info = data[dns_name['id']]

        if dns_entry_info == nil or dns_entry_info['size'] ~= resolved_addresses_size then
            if resolved_addresses_size>0 then
                ngx_log(ngx_info,"Addresses changed (",dns_name['id'],") from [", dns_entry_info['addresses_as_string'], "] to [",table.concat(resolved_addresses_array,", "),"]")
            else
                ngx_log(ngx_info,"Addresses changed (",dns_name['id'],") from [", dns_entry_info['addresses_as_string'], "] to []")
            end
            update_servers(dns_name,resolved_addresses,resolved_addresses_array, resolved_addresses_size, balancing_type)
        else
            if is_diff(dns_name['id'],resolved_addresses,resolved_addresses_array,dns_entry_info['addresses']) then
                ngx_log(ngx_info,"Addresses changed (",dns_name['id'],") from [", dns_entry_info['addresses_as_string'], "] to [",table.concat(resolved_addresses_array,", "),"]")
                update_servers(dns_name,resolved_addresses,resolved_addresses_array, resolved_addresses_size, balancing_type)
            end
        end
    end

    local function _can_update_servers(number_of_ips, had_blacklisted_ips, dns_name)
        if number_of_ips>0 then
            return true
        end

        if dns_name['allow_zero_ips'] ~= nil and dns_name['allow_zero_ips'] == true then
            return true
        end

        -- If dns actually returned no addresses.
        if dns_name['fallback'] ~= nil and had_blacklisted_ips == false then
            return true
        end

        return false
    end

    local function _resolve_name(dns_resolver, dns_name,cfg)


        local answers, err, tries = dns_resolver:query(dns_name['dns_name'], { qtype = resolver.TYPE_A }, {})

        if err ~= nil then
            ngx_log(ngx_crit,"failure in dns of (",dns_name['dns_name'],"):",err)
        end

        if answers then
            local resolved_servers = {}
            local resolved_servers_array = {}
            local number_of_valid_addresses = 0
            local had_blacklisted_ips = false

            if not answers.errcode then
                for i, ans in ipairs(answers) do
                    local address = ans.address
                    if address ~= nil then
                        if cfg['ip_black_list'][address] == nil then
                            resolved_servers[ans.address] = 1
                            number_of_valid_addresses = number_of_valid_addresses + 1
                            resolved_servers_array[number_of_valid_addresses] = ans.address
                        else
                            had_blacklisted_ips = true
                        end
                    end
                end

                if _can_update_servers(number_of_valid_addresses,had_blacklisted_ips, dns_name) then
                    _maybe_update_servers( dns_name, resolved_servers, resolved_servers_array, number_of_valid_addresses, dns_name['balancing_type'])
                end
            else
                if answers.errcode == 3 or answers.errcode == 5 then
                    ngx_log(ngx_warn,"No resolved addresses for: ",dns_name['dns_name'])
                    if _can_update_servers(number_of_valid_addresses, had_blacklisted_ips, dns_name) then
                        _maybe_update_servers( dns_name, resolved_servers, resolved_servers_array, number_of_valid_addresses, dns_name['balancing_type'])
                    end
                end
            end
        end

    end

    local function refresh(premature, dns_names, cfg)
        if premature then
            return
        end

        local dns_resolver, err =  resolver:new{
            nameservers = cfg['dns_resolver'],
            timeout = cfg['dns_timeout'],
            retrans = cfg['dns_retries'],
        }

        if err then
            ngx_log(ngx_crit, "Failed to create resolver!", err)
        else
            if cfg['dns_resolver_id'] then
                dns_resolver._id = cfg['dns_resolver_id']
            end


            for i, dns_name in ipairs(dns_names) do
                _resolve_name(dns_resolver, dns_name, cfg)
            end

            local ok, err = ngx_timer.at(cfg['refresh_interval'], refresh, dns_names, cfg)
            if not ok then
                ngx_log(ngx_crit, "Failed to schedule background dns resolution", err)
            end
        end
    end



    local function get_balancer(type)
        if type == balancing_type_round_robin then
            return round_robin
        end

        if  type == balancing_type_chash then
            return chash
        end

        return round_robin
    end

    -- Init


    if type(cfg) ~= "table" then
        cfg = {}
    end

    _defaults(cfg)

    local names_to_lookup = {}

    if type(dns_names) == "string" then
        dns_names = { dns_names }
    end

    for i,dns_name in ipairs(dns_names) do
        local name_info = {}
        if type(dns_name) ~= "table" then
            name_info['id'] = dns_name
            name_info['dns_name'] = dns_name
            name_info['balancing_type'] = cfg['balancing_type']
        else
            name_info = dns_name
        end

        if name_info['id'] == nil then
            name_info['id'] = dns_name
        end

        if data[name_info['id']] == nil then
            local config = {
                ['addresses'] = {},
                ['addresses_as_string'] = "",
                ['addresses_as_array'] = {},
                ['size'] = 0,
                ['no_of_updates'] = 0,
                ['balancing'] = {
                    ['size'] = 0
                }
            }

            if name_info['fallback'] ~= nil then
                config['fallback'] = name_info['fallback']
            end

            if name_info['balancing_type'] == nil then
                config['balancer_method'] = get_balancer(cfg['balancing_type'])
                name_info['balancing_type'] = cfg['balancing_type']
            else
                config['balancer_method'] = get_balancer(name_info['balancing_type'])
            end

            data[name_info['id']] = config
            table.insert(names_to_lookup,name_info)
        end

    end


    local ok, err = ngx_timer.at(0, refresh, names_to_lookup, cfg)
    if not ok then
        ngx_log(ngx_crit, "Failed to start background dns resolution", err)
        return nil,"failed_to_start_timer"
    end


end

function _M.get_addresses_as_string(id)
    return data[id]['addresses_as_string']
end

function _M.updated(id)
    return data[id]['no_of_updates']
end

function _M.next(key,id)
    local primary = data[id]
    local fallback_dns_id = primary['fallback']
    local server, err = primary['balancer_method'](key,id)
    if server == nil and fallback_dns_id ~= nil then
        ngx_log(ngx_warn,"Using fallback of(",fallback_dns_id,") for ",id)
        server, err = data[fallback_dns_id]['balancer_method'](key,fallback_dns_id)
    end

    return server, err
end

return _M