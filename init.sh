echo "NETWORKING=yes" > /etc/sysconfig/network
mkdir chash
echo "bob" > chash/bob.log
service memcached start
service dnsmasq start
memcached -d -p 11211 -u memcached &
sleep 10
python /data/serveit.py 1985 &>/var/log/bob.log &
/usr/local/openresty/bin/openresty