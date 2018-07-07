#!/usr/bin/env bash

export PATH=/usr/local/openresty/nginx/sbin:$PATH
export PERL5LIB=/root/perl5/lib/perl5:${PERL5LIB}

cd /data/t

prove sanity.t