echo "NETWORKING=yes" > /etc/sysconfig/network
mkdir chash
echo "bob" > chash/bob.log
#service memcached start
service dnsmasq start
memcached -d -p 11211 -u memcached -vvv &
sleep 10
python /data/serveit.py 1985 &>/var/log/bob.log &
/usr/local/openresty/bin/openresty
curl -v localhost:81/chash
curl -v localhost:81/chash/bob.log
curl -v localhost:81/chash/bob.log
curl -v localhost:81/chash/bob.log
curl -v localhost:81/chash/bob.log
curl -v localhost:81/chash/bob.log
curl -v localhost:81/chash/bob.log
curl -v localhost:81/chash/etc/hosts
curl -v localhost:81/chash/etc/hosts
curl -v localhost:81/chash/etc/hosts
curl -v localhost:81/chash/etc/passwd
curl -v localhost:81/chash/etc/shadow
curl -v localhost:81/chash/etc/shadow
curl -v localhost:81/chash/etc/group
curl -v localhost:81/chash/var/log/bob.log
curl -v localhost:81/chash/var/log/messages
curl -v localhost:81/chash/var/log/bob.log
curl -v localhost:81/chash/var/log/messages
curl -v localhost/stats
curl -v localhost/stats2