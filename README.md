<!-- TOC -->

- [Name](#name)
- [Status](#status)
- [Synopsis](#synopsis)
    - [Motivation for Development.](#motivation-for-development)
- [Pre Requistes](#pre-requistes)
- [Deprecated](#deprecated)
- [Description](#description)
- [Creating a Background Resolution](#creating-a-background-resolution)
    - [Legacy Configuration](#legacy-configuration)
- [Quick Example](#quick-example)
    - [Legacy Example](#legacy-example)
- [Configuration](#configuration)
    - [Configuration Defaults](#configuration-defaults)
- [Limitations](#limitations)
- [API Specification](#api-specification)
    - [Create a background resolution](#create-a-background-resolution)
    - [Legacy Create a background resolution](#legacy-create-a-background-resolution)
    - [Obtaining the server to send traffic to](#obtaining-the-server-to-send-traffic-to)
    - [Legacy Obtaining the server to send traffic to](#legacy-obtaining-the-server-to-send-traffic-to)
- [Local Testing](#local-testing)
    - [Reload openresty](#reload-openresty)
- [See Also](#see-also)
- [3rd Party Licenses](#3rd-party-licenses)

<!-- /TOC -->


# Name

Background Resolver

----

# Status

In Development

----

# Synopsis

Implementation of Background DNS Resolver.

## Motivation for Development.

This lua module was developed as a means to dynamically resolve a set of memcached servers from a dns entry, and use this in combination
with `balancer_by_lua_block` to consistently hash to the set of dynamically resolved set of memcached servers.  The intention is to use it in
combination with some sort of service discovery mechanism, for which servers are dynamically removed and added to a dns entry.

It can be used more generically to resolve hosts from dns and round robin load balance over those set of servers (indeed this is the default).

----

# Pre Requistes

- Nginx that can use Lua.  For example [Openresty](https://github.com/openresty/)
-- Needs the nginx lua development kit: [lua-nginx-module](https://github.com/openresty/lua-nginx-module)
- Luajit

- A compiled version of lua-resty-chash from lua-resty-balancer : [lua-resty-chash](https://github.com/openresty/lua-resty-balancer).
- Lua Resty DNS: [lua-resty-dns](https://github.com/openresty/lua-resty-dns)

----

# Deprecated

`resty.greencheek.dynamic.background-resolver` is deprecated.  Please use `resty.greencheek.dynamic.multi-background-resolver`

```
local background_resolver = require 'resty.greencheek.dynamic.background-resolver'
```

`resty.greencheek.dynamic.background-resolver` is deprecated as it encourages the use of Global Variables in nginx, which is not advised (less performant).

As a result it has been deprecated, and replaced `multi-background-resolver` that uses lua module storage to share dns resolutions in workers, as per https://github.com/openresty/lua-nginx-module#data-sharing-within-an-nginx-worker


----

# Description

Resolves DNS names in the background using [ngx.timer.at](https://github.com/openresty/lua-nginx-module#ngxtimerat).  The rate at which the dns
is updated is defined at creation time, and is executed per nginx worker (each worker has it's own copy of the resolved addresses).

As ngx timers are used to schedule the background resolution.  Please be wary of the settings the number of pending timers, and those that are
allowed to be running at any one give point:

```
The maximal number of pending timers allowed in an Nginx worker is controlled by the lua_max_pending_timers directive. The maximal number of running timers is controlled by the lua_max_running_timers directive.
```

- [lua_max_pending_timers](https://github.com/openresty/lua-nginx-module#lua_max_pending_timers)
- [lua_max_running_timers](https://github.com/openresty/lua-nginx-module#lua_max_running_timers)


You also need to be aware that each running timer will decrement the number of available workers (https://github.com/openresty/lua-nginx-module#ngxtimerat):

```
The maximal number of pending timers allowed in an Nginx worker is controlled by the lua_max_pending_timers directive. The maximal number of running timers is controlled by the lua_max_running_timers directive.

According to the current implementation, each "running timer" will take one (fake) connection record from the global connection record list configured by the standard worker_connections directive in nginx.conf. So ensure that the worker_connections directive is set to a large enough value that takes into account both the real connections and fake connections required by timer callbacks (as limited by the lua_max_running_timers directive).
```

The TTL on DNS name is not honoured.  The previously resolved addresses are kept in memory.
A black list of ips can be specifed, that are ignored if returned.  The defualt of 127.0.53.53 is ignored.

The module is intended for use with `balancer_by_lua_block` in an upstream, for example:

```
balancer_by_lua_block {
    local b = require "ngx.balancer"
    local peer = dns.next(ngx.var.arg_key, ngx.var.lookup_id)
    if peer ~= nil then
        assert(b.set_current_peer(peer,80))
    end
}
```

----

# Creating a Background Resolution

You create a background resolver in the `init_worker_by_lua_block`.
First import the multi-background-resolve:

```
local dns = require 'resty.greencheek.dynamic.multi-background-resolver'
```

You can create a background resolver instance by calling the `start` method.  This starts the resolve in a nginx timer resolving one or more dns names
periodically.

The `start` method accepts a configuration table that configures various aspects of the resolution, as the second parameter.

The first parameter is list of dns names to resolve, which can be either a list of dns names to resolve or a table that contains:

- The dns name to resolve
- An identifer (lookup id) that is subsequently used to lookup the ip to set the next peer

If the first parameter is an array:

```
    dns.start({ "www.amazon.co.uk", "news.bbc.co.uk" } , dns_resolution_config)
```

Then the `lookup_id` is the dns hostname


An example initialisation is as follows:
```
    init_worker_by_lua_block {
        local dns = require 'resty.greencheek.dynamic.multi-background-resolver'
        local dns_resolution_config = { dns_resolver = { { '8.8.4.4', 53 } }, refresh_interval = 30 }


        local addresses_to_lookup = {}
        table.insert(addresses_to_lookup,{ ['id'] = 'bbc', ['dns_name'] = 'www.bbc.co.uk' })
        table.insert(addresses_to_lookup,{ ['id'] = 'google', ['dns_name'] = 'www.google.co.uk' })

        local obj, err = dns.start(addresses_to_lookup, dns_resolution_config)
        if err ~= nil then
            ngx.log(ngx.CRIT,"Unable to start dns resolution",err)
        end
    }
```

```
    init_worker_by_lua_block {
        local dns = require 'resty.greencheek.dynamic.multi-background-resolver'
        local dns_resolution_config = { dns_resolver = { { '8.8.4.4', 53 } }, refresh_interval = 30 }

        local obj, err = dns.start({ "www.amazon.co.uk", "news.bbc.co.uk" } , dns_resolution_config)
        if err ~= nil then
            ngx.log(ngx.CRIT,"Unable to start dns resolution",err)
        end
    }
```

The `start` method uses an nginx timer to periodically resolve each hostname in the given list/table.  The resolution of each host is performed within the same timer invocation.  As a result you should take care to set `dns_timeout` and `dns_retries` appropriately given the number of host names you are resolving at a time.

The `start` method can be call multiple times, to setup resolution of dns names in separate timers.



## Legacy Configuration

You create a background resolver in the `init_worker_by_lua_block`.
First import the background-resolver:

```
local background_resolver = require 'resty.greencheek.dynamic.background-resolver'
```

You can create a background resolver instance by calling the `new` method.  This returns the background resolver instance, upon which you will call the `next` method toobtain the peer to set.

The `new` method accepts a configuration table that configures various aspects of the resolution, as the second parameter.  The first parameter is the dns name
that this background resolver is configured to periodically resolve

An example initialisation is as follows:
```
    init_worker_by_lua_block {
        local background_resolver = require 'resty.greencheek.dynamic.background-resolver'
        bbc_bgdns = background_resolver.new('www.bbc.co.uk')
    }
```

----

# Quick Example

The use of background resolver is a combination of 2 steps:

- start the background resolution of dns in `init_worker_by_lua_block`
- use that resolver to set the next peer in `balancer_by_lua_block`


```
    init_worker_by_lua_block {
        local dns = require 'resty.greencheek.dynamic.multi-background-resolver'
        local dns_resolution_config = { dns_resolver = { { '8.8.4.4', 53 } }, refresh_interval = 30 }

        local addresses_to_lookup = {}
        table.insert(addresses_to_lookup,{ ['id'] = 'bbc', ['dns_name'] = 'www.bbc.co.uk' })

        local obj, err = dns.start(addresses_to_lookup, dns_resolution_config)
        if err ~= nil then
            ngx.log(ngx.CRIT,"Unable to start dns resolution",err)
        end

    }

    upstream bbc_upstream {
        server 0.0.0.1;
        balancer_by_lua_block {
            local b = require "ngx.balancer"
            local dns = require 'resty.greencheek.dynamic.multi-background-resolver'

            local server, err = dns.next(ngx.var.uri, ngx.var.appname)
            if err == nil then
                assert(b.set_current_peer(server,ngx.var.appname_port))
            end
        }
        keepalive 10;
    }

    server {
        listen 81;

        location /bbc {
            set $appname "bbc";
            set $appname_port "443";
            proxy_pass https://bbc_upstream;
            proxy_set_header "Host" "www.bbc.co.uk";
            proxy_set_header Connection "";
            proxy_http_version 1.1;
            proxy_set_header "User-Agent" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/66.0.3359.139 Safari/537.36";
            proxy_redirect     off;
        }
    }
```


## Legacy Example

The use of background resolver is a combination of 2 steps:

- start the background resolution of dns in `init_worker_by_lua_block`
- use that resolver to set the next peer in `balancer_by_lua_block`

```
    init_worker_by_lua_block {
        local background_resolver = require 'resty.greencheek.dynamic.background-resolver'
        bbc_bgdns = background_resolver.new('www.bbc.co.uk',{ balancing_type = 'round_robin' })
    }

    upstream bbc_upstream {
        server 0.0.0.1;
        balancer_by_lua_block {
            local b = require "ngx.balancer"
            local server = bbc_bgdns.next(ngx.var.arg_key)
            if server ~= nil then
                assert(b.set_current_peer(server,443))
            end
        }
        keepalive 10;
    }

    server {
        listen 81;

        location /bbc {
            proxy_pass https://bbc_upstream;
            proxy_set_header "User-Agent" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/66.0.3359.139 Safari/537.36";
            proxy_redirect     off;
        }
    }
```

# Configuration

The background resolver accepts a table as a second parameter which controls certain aspects of the background resolution:

- The dns server to use
- The dns resolution timeout
- The interval, in seconds, at which the period dns resolution is performed
- A black list of IPs that should not be used/considered as good
- The type of load balancing that should be performed over the set of resolved addresses

The configuration is specified as the second parameter:

```
    init_worker_by_lua_block {
        local background_resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
        bbc_bgdns = background_resolver.new({"www.bbc.co.uk"},
            {
                balancing_type = 'chash',
                dns_timeout = 2000,
                dns_retries = 2,
                dns_resolver = {
                    { '10.10.0.2', 53},
                    { '8.8.8.8', 53}
                },
                ip_black_list = {
                    ['127.0.0.1'] = true
                }
            }
        )
    }
```

## Configuration Defaults

The following is an example of the configuration defaults.  Any parameter not overriden has the default applied:

```
{
    balancing_type = 'round_robin',
    dns_timeout = 1000,
    dns_retries = 2,
    dns_resolver = {
        { '8.8.8.8', 53}
    },
    ip_black_list = {
        ['127.0.53.53'] = true
    }
}
```

----

# Limitations

- Only IPv4 support.
- Only resolves 1 IP address
- Does not accumulate IPs based on DNS TTL


----

# API Specification


## Create a background resolution

**syntax:**  bgdns, err =  background_resolver.start(dns_name,[ configuration_table ])

**example:** bgdns, err =  background_resolver.start({'www.bbc.co.uk'}, { dns_resolver = { { '10.10.0.2', 53 } } })


## Legacy Create a background resolution

**syntax:**  bgdns, err =  background_resolver.new(dns_name,[ configuration_table ])

**example:** bgdns, err =  background_resolver.new('www.bbc.co.uk', { dns_resolver = { { '10.10.0.2', 53 } } })

---

## Obtaining the server to send traffic to

**syntax:**  peer, err =  background_resolver.next(key, lookup_id)

**example:** bgdns, err =  background_resolver.next(ngx.var.uri, ngx.var.lookup_id)


The `next` method takes a "key" argument, and a "lookup_id".

The "key" argument is used by the consistent hash mechanism to chose the server the key should be directed at.
In otherwords, when you have a selection of memcached servers.  The key is hashed against the available servers, and the server that key is stored
is consistently returned.

The "lookup_id" is used to choose which dns name entry from the internal lua module's internal storage.

`err` is set to something (not nil) when no address are available for the given domain name.

The `next` method is intended for use within a `balancer_by_lua_block` inside an `upstream` block.

example:
```
upstream bbc_upstream {
    server 0.0.0.1;
    balancer_by_lua_block {
        local b = require "ngx.balancer"
        local dns = require 'resty.greencheek.dynamic.multi-background-resolver'

        local server = dns.next(ngx.var.arg_key, ngx.var.dns_lookup_id)
        if server ~= nil then
            assert(b.set_current_peer(server,443))
        end
    }
    keepalive 10;
}
```

The upstream is used within a `proxy_pass` as normal: http://nginx.org/en/docs/http/ngx_http_upstream_module.html




## Legacy Obtaining the server to send traffic to

**syntax:**  peer, err =  bgdns.next(key)

**example:** bgdns, err =  bgdns.next(ngx.var.uri)

----

# Local Testing

There's a `Dockerfile` that can be used to build a local docker image for testing.  Build the image:

```
docker build --no-cache -t dynamic .
```

And then run from the root of this git repo, execute the following to get into the docker container:

```
docker run --name dynamic --rm -it \
-v $(pwd)/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf \
-v $(pwd)/upstream.include:/usr/local/openresty/nginx/conf/upstream.include \
-v $(pwd):/data \
-v $(pwd)/mymemcached.conf:/etc/mymemcached.conf \
-v $(pwd)/dnsmasq.conf:/etc/dnsmasq.conf \
-v $(pwd)/librestychash.so:/usr/local/openresty/lualib/librestychash.so \
-v $(pwd)/chash.lua:/usr/local/openresty/lualib/resty/chash.lua \
-v $(pwd)/lib/resty/greencheek/dynamic/background-resolver.lua:/usr/local/openresty/lualib/resty/greencheek/dynamic/background-resolver.lua \
-v $(pwd)/lib/resty/greencheek/dynamic/multi-background-resolver.lua:/usr/local/openresty/lualib/resty/greencheek/dynamic/multi-background-resolver.lua \
dynamic:latest /bin/bash
```

When in the container run the `/data/init.sh` to:

- Start openresty on port 81.
- Start a local memcached on port 11211.
- Start a simply python server this is serving all files on / as root, on port 1985
- Start dnsmasq on localhost

Gil Tene's fork of [wrk](https://github.com/giltene/wrk2) is also complied during the build of the docker image.

```
/data/init.sh
curl localhost:81/bbc -v -o /dev/null
```

This will/should return a 200:
```
bash-4.2# curl localhost:81/bbc -v -o /dev/null
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0*   Trying 127.0.0.1...
* TCP_NODELAY set
* Connected to localhost (127.0.0.1) port 81 (#0)
> GET /bbc HTTP/1.1
> Host: localhost:81
> User-Agent: curl/7.53.1
> Accept: */*
>
< HTTP/1.1 200 OK
< Server: openresty/1.13.6.2
< Date: Sun, 08 Jul 2018 10:41:53 GMT
< Content-Type: text/html; charset=utf-8
< Content-Length: 294195
< Connection: keep-alive
< X-Cache-Action: HIT
< X-Cache-Hits: 905
< Vary: Accept-Encoding, X-CDN, X-BBC-Edge-Scheme
< X-Cache-Age: 100
< Cache-Control: private, max-age=0, must-revalidate
< ETag: W/"47d33-Xs9uP6GE1BfmAz9v/+B8MgQvY9c"
< Set-Cookie: BBC-UID=c58bc4313eaa06482dc5e92fc1de6617c277e90d876464264a10670256512c0c0Mozilla/5.0%20(Macintosh%3b%20Intel%20Mac%20OS%20X%2010_12_6)%20AppleWebKit/537.36%20(KHTML%2c%20like%20Gecko)%20Chrome/66.0.335; expires=Thu, 07-Jul-22 10:41:44 GMT; path=/; domain=.bbc.co.uk
< X-Frame-Options: SAMEORIGIN
<
```

There is a `nginx.config` that defines:

- A upstream connection to the python server
- A upstream to the local memcached server using dnsmasq
- Uses [srcache-nginx-module](https://github.com/openresty/srcache-nginx-module) to write an cache in memcached.

After exexuting /data/init.sh you can run work against the local server

```
wrk -t1 -c1 -d30s -R2 http://localhost:81/chash/etc/passwd
```

## Reload openresty

/usr/local/openresty/bin/openresty -s reload


----

# See Also

* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)


----

# 3rd Party Licenses

- librestychash.so in the root of this project is licensed under BSD from: https://github.com/openresty/lua-resty-balancer 
  You should install and compile for your platform/distribution.  It is here as a means for testing

- chash.lua in the root of this project is licensed under BSD from: https://github.com/openresty/lua-resty-balancer 
  Is it here as a mean for testing.  You should install it from the  https://github.com/openresty/lua-resty-balancer repo for
  your platform

- TestDNS.pm is licensed under BSD from: https://raw.githubusercontent.com/openresty/lua-resty-dns
  Is it here as a mean for testing.
