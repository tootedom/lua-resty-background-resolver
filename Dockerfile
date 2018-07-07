FROM amazonlinux:1

RUN yum install -y git \
    && yum install -y wget \
    && yum install -y make autoconf automake libtool build-essential gcc gcc-c++ \
    && yum install -y openssl-devel \
    && yum install -y which \
    && yum install -y jq \
    && yum install -y perl-CPAN \
    && yum install -y perl-YAML \
    && yum install -y pcre \
    && yum install -y pcre-devel \
    && yum install -y memcached \
    && yum install -y dnsmasq \
    && yum install -y telnet \
    && yum install -y bind-utils \
    && yum groupinstall -y "Development Tools" \
    && yum groupinstall -y "Development Libraries" \
    && export PERL_MM_USE_DEFAULT=1 \
    && PERL_MM_USE_DEFAULT=1 yum install perl-CPAN perl-Test-Base -y \
    && PERL_MM_USE_DEFAULT=1 yum install perl-List-MoreUtils -y \
    && export PATH="/root/perl5/bin${PATH:+:${PATH}}" \
    && export PERL5LIB="/root/perl5/lib/perl5${PERL5LIB:+:${PERL5LIB}}" \
    && export PERL_LOCAL_LIB_ROOT="/root/perl5${PERL_LOCAL_LIB_ROOT:+:${PERL_LOCAL_LIB_ROOT}}" \
    && export PERL_MB_OPT="--install_base \"/root/perl5\"" \
    && export PERL_MM_OPT="INSTALL_BASE=/root/perl5" \
    && PERL_MM_USE_DEFAULT=1 cpan -i R/RG/RGARCIA/Test-LongString-0.17.tar.gz \
    && cpan -i A/AG/AGENT/Test-Nginx-0.26.tar.gz \
    && yum clean all \
    && wget https://openresty.org/download/openresty-1.13.6.2.tar.gz \
    && wget https://github.com/bpaquet/ngx_http_enhanced_memcached_module/archive/v0.2.tar.gz \
    && wget https://github.com/openresty/luajit2/archive/v2.1-20180420.tar.gz \
    && tar -xzvf openresty-1.13.6.2.tar.gz \
    && tar -xzvf v0.2.tar.gz \
    && tar -xzvf v2.1-20180420.tar.gz \
    && cd luajit2-2.1-20180420 \
    && make \
    && make install \
    && cd .. \
    && cd openresty-1.13.6.2 \
    && ./configure --add-module=../ngx_http_enhanced_memcached_module-0.2 \
    && make \
    && make install \
    && cd .. \
    && git clone https://github.com/giltene/wrk2.git \
    && cd wrk2 \
    && make \
    && cp wrk /usr/local/bin \
    && cd .. && rm -rf wrk2 \
    && echo "NETWORKING=yes" > /etc/sysconfig/network


