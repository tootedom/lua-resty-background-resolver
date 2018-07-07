<!-- TOC -->

- [Name](#name)
- [Status](#status)
- [Synopsis](#synopsis)
- [Pre Requistes](#pre-requistes)
- [Description](#description)
- [Creating a Background Resolution](#creating-a-background-resolution)
- [Quick Example](#quick-example)
    - [Init and Access block](#init-and-access-block)
    - [Access Block](#access-block)
    - [API Specification](#api-specification)
- [Local Testing](#local-testing)
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

Implementation of Background DNS Resolver

----

# Pre Requistes

- Nginx that can use Lua.  For example [Openresty](https://github.com/openresty/)
-- Needs the nginx lua development kit: [lua-nginx-module](https://github.com/openresty/lua-nginx-module)
- Luajit

- A compiled version of lua-resty-chash from lua-resty-balancer : [lua-resty-chash](https://github.com/openresty/lua-resty-balancer).
- Lua Resty DNS: [lua-resty-dns](https://github.com/openresty/lua-resty-dns)


----

# Description

Resolves DNS names in the background using [ngx.timer.at](https://github.com/openresty/lua-nginx-module#ngxtimerat).  The rate at which the dns
is updated is defined at creation time, and is executed per worker (each worker has it's own copy of the resolved addresses).

The TTL on DNS name is not honoured.  The previously resolved addresses are kept.  A black list of ips can be specifed, that are ignored if returned.
The defualt of 127.0.53.53 is ignored.

The module is intended for use with `balancer_by_lua_block` in an upstream, for example:

```
balancer_by_lua_block {
            local b = require "ngx.balancer"
            assert(b.set_current_peer(backend_bgdns.next(ngx.var.arg_key),1985))
}
```

# Creating a Background Resolution

You create a background resolver in the `init_worker_by_lua_block`.
First import the background-resolver:

```
local background_resolver = require 'resty.greencheek.dynamic.background-resolver'
```

You can create a by calling the `new` method.  This returns the background resolver instance, upon which you will call the `next` method to
obtain the peer to set.

The `new` method accepts a configuration table that configures various aspects of the resolution



```
    init_worker_by_lua_block {
        local resolver = require 'resty.greencheek.dynamic.background-resolver'
        local config = { dns_resolver = { { '127.0.0.1', 53 } }, refresh_interval = 2 }
        local round_robin_config = { dns_resolver = { { '127.0.0.1', 53 } }, refresh_interval = 2,balancing_type = 'round_robin' }
        memcached_bgdns = resolver.new('mymemcached',config)
        backend_bgdns = resolver.new('localhost',round_robin_config)

    }
```

# Quick Example

There's a couple of ways to set up the rate limiting:

- A combination of `init_by_lua_block` and `access_by_lua_block`
- Entirely the `access_by_lua_block`

Which is entirely up to you.  For either, you need to set up the `lua_shared_dict` in the `http` regardless.


## Init and Access block

Inside the http block, set up the `init_by_lua_block` and the shared dict
```
http {
    ...
    lua_shared_dict ratelimit_circuit_breaker 10m;

    init_by_lua_block {
        local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
        local red = { host = "127.0.0.1", port = 6379, timeout = 100}
        login, err = ratelimit.new("login", "100r/s", red)

        if not login then
            error("failed to instantiate a resty.greencheek.redis.ratelimiter.limiter object")
        end
    }

    include /etc/nginx/conf.d/*.conf;
}
```

Inside a `server` in one of the `/etc/nginx/conf.d/*.conf` includes, use the rate limit in a location or location blocks:

```
server {
    ....

    location /login {

        access_by_lua_block {
            if login:is_rate_limited(ngx.var.remote_addr) then
                return ngx.exit(429)
            end
        }

        #
        # return 200 "ok"; will not work, return in nginx does not run any of the access phases.  It just returns
        #
        content_by_lua_block {
             ngx.say('Hello,world!')
        }
    }
}
```

## Access Block


Inside the http block, set up thethe shared dict
```
http {
    ...
    lua_shared_dict ratelimit_circuit_breaker 10m;

    ...

    include /etc/nginx/conf.d/*.conf;

}
```


Inside a `server` in one of the `/etc/nginx/conf.d/*.conf` includes:
```
    location /login {
        access_by_lua_block {

            local ratelimit = require "resty.greencheek.redis.ratelimiter.limiter"
            local red = { host = "127.0.0.1", port = 6379, timeout = 100}
            local lim, err = ratelimit.new("login", "100r/s", red)

            if not lim then
                ngx.log(ngx.ERR,
                        "failed to instantiate a resty.greencheek.redis.ratelimiter.limiter object: ", err)
                return ngx.exit(500)
            end

            local is_rate_limited = lim:is_rate_limited(ngx.var.remote_addr)

            if is_rate_limited then
                return ngx.exit(429)
            end

        }

        content_by_lua_block {
             ngx.say('Hello,world!')
        }
    }
```

----

## API Specification


----

# Local Testing

There's a `Dockerfile` that can be used to build a local docker image for testing.  Build the image:

```
docker build --no-cache -t dynamic .
```

And then run from the root of the repo:


```
docker run --name dynamic --rm -it \
-v $(pwd)/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf \
-v $(pwd):/data \
-v $(pwd)/mymemcached.conf:/etc/mymemcached.conf \
-v $(pwd)/dnsmasq.conf:/etc/dnsmasq.conf \
-v $(pwd)/librestychash.so:/usr/local/openresty/lualib/librestychash.so \
-v $(pwd)/chash.lua:/usr/local/openresty/lualib/resty/chash.lua \
-v $(pwd)/lib/resty/greencheek/dynamic/background-resolver.lua:/usr/local/openresty/lualib/resty/greencheek/dynamic/background-resolver.lua \
dynamic:latest /bin/bash
```

when in the contain run the `/data/init.sh` to start openresty and a local redis.  OpenResty will be running on port `9090`.
Gil Tene's fork of [wrk](https://github.com/giltene/wrk2) is also complied during the build of the docker image.

```
/data/init.sh
curl localhost:9090/login
wrk -t1 -c1 -d30s -R2 http://localhost:9090/login
```

There is a `nginx.config` and a `conf.d/default.config` example in the project for you to work with,



----

# See Also

* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)


----

# 3rd Party Licenses

- librestychash.so in the root of this project is licensed under BSD from: https://github.com/openresty/lua-resty-balancer 
  You should install and compile for your platform/distribution.  It is here as a means for testing

- chash.lus in the root of this project is licensed under BSD from: https://github.com/openresty/lua-resty-balancer 

- TestDNS.pm is licensed under BSD from: https://raw.githubusercontent.com/openresty/lua-resty-dns

