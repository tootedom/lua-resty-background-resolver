# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);
use Test::Nginx::Socket 'no_plan';

my $pwd = cwd();

use TestDNS;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/openresty/lualib/resty/?.lua;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: single returned server
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2 }
  resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(4)
            ngx.say("records: ",resolver.get_addresses_as_string('www.google.com'))
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records: 127.0.0.2
--- timeout: 600

=== TEST 2: multi returned server
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2 }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(4)
            ngx.say("records: ",resolver.get_addresses_as_string('www.google.com'))
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.0.1", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records: 127.0.0.1, 127.0.0.2
--- timeout: 600

=== TEST 3: round robin next test
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2, balancing_type = 'round_robin' }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(10)
            local server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.0.1", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records_updated: 127.0.0.1
records_updated: 127.0.0.1
--- timeout: 600


=== TEST 4: round robin many addresses
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2, balancing_type = 'round_robin' }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(10)
            local server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.0.1", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.3", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records_updated: 127.0.0.1
records_updated: 127.0.0.2
records_updated: 127.0.0.3
records_updated: 127.0.0.1
records_updated: 127.0.0.2
--- timeout: 600

=== TEST 5: consistent hashing keys on single server
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2, balancing_type = 'chash' }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(10)
            local server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.0.1", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records_updated: 127.0.0.1
records_updated: 127.0.0.1
records_updated: 127.0.0.1
records_updated: 127.0.0.1
records_updated: 127.0.0.1
--- timeout: 600

=== TEST 6: consitent hashing keys on multiple server
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2, balancing_type = 'chash' }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(10)
            local server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(2,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(2,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(12345,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(99999,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(4847575,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3874755756,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3874755756,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3874755756,'www.google.com')
            ngx.say("records_updated: ",server)
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.0.1", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.3", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records_updated: 127.0.0.1
records_updated: 127.0.0.1
records_updated: 127.0.0.2
records_updated: 127.0.0.1
records_updated: 127.0.0.1
records_updated: 127.0.0.3
records_updated: 127.0.0.2
records_updated: 127.0.0.2
records_updated: 127.0.0.2
records_updated: 127.0.0.2
records_updated: 127.0.0.2
--- timeout: 600

=== TEST 7: consistent hashing keys on multiple server, same hashes
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2, balancing_type = 'chash' }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(10)
            local server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(2,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(2,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(1,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(12345,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(99999,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(4847575,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3874755756,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3874755756,'www.google.com')
            ngx.say("records_updated: ",server)
            server = resolver.next(3874755756,'www.google.com')
            ngx.say("records_updated: ",server)
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.0.1", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.3", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records_updated: 127.0.0.1
records_updated: 127.0.0.1
records_updated: 127.0.0.2
records_updated: 127.0.0.1
records_updated: 127.0.0.1
records_updated: 127.0.0.3
records_updated: 127.0.0.2
records_updated: 127.0.0.2
records_updated: 127.0.0.2
records_updated: 127.0.0.2
records_updated: 127.0.0.2
--- timeout: 600


=== TEST 8: default black list
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2 }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(4)
            ngx.say("records: ",resolver.get_addresses_as_string('www.google.com'))
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.53.53", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records: 127.0.0.2
--- timeout: 600


=== TEST 9: custom black list
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2 , ip_black_list = { ['127.0.53.53'] = true, ['127.0.0.98'] = true } }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(4)
            ngx.say("records: ",resolver.get_addresses_as_string('www.google.com'))
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.53.53", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.98", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records: 127.0.0.2
--- timeout: 600

=== TEST 10: custom black list, and chash
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2 , ip_black_list = { ['127.0.53.53'] = true, ['127.0.0.98'] = true } }
  bgdns = resolver.start('www.google.com',config)
}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(4)
            local server = resolver.next(ngx.var.host,'www.google.com')
            ngx.say("records: ",server)
            server = resolver.next(ngx.var.host,'www.google.com')
            ngx.say("records: ",server)
            server = resolver.next(ngx.var.host,'www.google.com')
            ngx.say("records: ",server)
            server = resolver.next(ngx.var.host,'www.google.com')
            ngx.say("records: ",server)
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.google.com',
    answer => [{ name => "www.google.com", ipv4 => "127.0.53.53", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.2", ttl => 123456 },{ name => "www.google.com", ipv4 => "127.0.0.98", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records: 127.0.0.2
records: 127.0.0.2
records: 127.0.0.2
records: 127.0.0.2
--- timeout: 600

=== TEST 11: test fallback is used
--- http_config eval
"
$::HttpConfig
lua_shared_dict dns_entries 1m;

init_worker_by_lua_block {
  local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'
  local config = { dns_resolver = { { '127.0.0.1', 1953 } }, dns_resolver_id = 125, refresh_interval = 2 }

  resolver.start( { { ['id'] = 'bbc', ['dns_name'] = 'www.bbc.com' } }, config)
  resolver.start( { { ['id'] = 'google', ['dns_name'] = 'www.google.com', ['fallback'] = 'bbc' } }, config)


}
"

--- config
    location /t {
        content_by_lua_block {
            local resolver = require 'resty.greencheek.dynamic.multi-background-resolver'

            ngx.sleep(10)
            ngx.say("records: ",resolver.next(1,'google'))
            ngx.say("records: ",resolver.next(1,'google'))
        }
    }
--- udp_listen: 1953
--- udp_reply dns
{
    id => 125,
    opcode => 0,
    qname => 'www.bbc.com',
    answer => [{ name => "www.bbc.com", ipv4 => "127.0.0.2", ttl => 123456 }],
}
--- request
GET /t
--- response_body
records: 127.0.0.2nil
records: 127.0.0.2nil
--- timeout: 600
