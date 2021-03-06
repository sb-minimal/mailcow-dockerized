#!/bin/bash

trap "postfix stop" EXIT

[[ ! -d /opt/postfix/conf/sql/ ]] && mkdir -p /opt/postfix/conf/sql/
if [[ -z $(grep null /etc/aliases) ]]; then
	echo null: /dev/null >> /etc/aliases;
	newaliases;
fi

cat <<EOF > /opt/postfix/conf/sql/mysql_relay_recipient_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT DISTINCT CASE WHEN '%d' IN (SELECT domain FROM domain WHERE relay_all_recipients=1 AND domain='%d' AND backupmx=1) THEN '%s' ELSE (SELECT goto FROM alias WHERE address='%s' AND active='1') END AS result;
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_tls_enforce_in_policy.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT IF( EXISTS( SELECT 'TLS_ACTIVE' FROM alias LEFT OUTER JOIN mailbox ON mailbox.username = alias.goto WHERE (address='%s' OR address IN (SELECT CONCAT('%u', '@', target_domain) FROM alias_domain WHERE alias_domain='%d')) AND mailbox.tls_enforce_in = '1' AND mailbox.active = '1'), 'reject_plaintext_session', NULL) AS 'tls_enforce_in';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_sender_dependent_default_transport_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT GROUP_CONCAT(transport SEPARATOR '') AS transport_maps
  FROM (
    SELECT IF(EXISTS(SELECT 'smtp_type' FROM alias LEFT OUTER JOIN mailbox ON mailbox.username = alias.goto WHERE (address = '%s' OR address IN (SELECT CONCAT('%u', '@', target_domain) FROM alias_domain WHERE alias_domain = '%d')) AND mailbox.tls_enforce_out = '1' AND mailbox.active = '1'), 'smtp_enforced_tls:', 'smtp:') AS 'transport'
    UNION ALL
    SELECT hostname AS transport FROM relayhosts LEFT OUTER JOIN domain ON domain.relayhost = relayhosts.id WHERE relayhosts.active = '1' AND domain = '%d' OR domain IN (SELECT target_domain FROM alias_domain WHERE alias_domain = '%d')
  )
  AS transport_view;
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_sasl_passwd_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT CONCAT_WS(':', username, password) AS auth_data FROM relayhosts WHERE id IN (SELECT relayhost FROM domain WHERE CONCAT('@', domain) = '%s');
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_alias_domain_catchall_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT goto FROM alias,alias_domain WHERE alias_domain.alias_domain = '%d' and alias.address = CONCAT('@', alias_domain.target_domain) AND alias.active = 1 AND alias_domain.active='1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_alias_domain_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT username FROM mailbox,alias_domain WHERE alias_domain.alias_domain = '%d' and mailbox.username = CONCAT('%u', '@', alias_domain.target_domain) AND mailbox.active = 1 AND alias_domain.active='1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_alias_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT goto FROM alias WHERE address='%s' AND active='1';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_domains_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query          = SELECT alias_domain from alias_domain WHERE alias_domain='%s' AND active='1' UNION SELECT domain FROM domain WHERE domain='%s' AND active = '1' AND backupmx = '0'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_mailbox_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT maildir FROM mailbox WHERE username='%s' AND active = '1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_relay_domain_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT domain FROM domain WHERE domain='%s' AND backupmx = '1' AND active = '1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_sender_acl.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT goto FROM alias WHERE address='%s' AND active='1' AND (domain IN (SELECT domain FROM domain WHERE domain='%d' AND active='1') OR domain in (SELECT target_domain FROM alias_domain WHERE alias_domain='%d' AND active='1')) UNION SELECT logged_in_as FROM sender_acl WHERE send_as='@%d' OR send_as='%s' OR send_as IN ( SELECT CONCAT ('@',target_domain) FROM alias_domain WHERE alias_domain = '%d') OR send_as IN ( SELECT CONCAT ('%u','@',target_domain) FROM alias_domain WHERE alias_domain = '%d' ) AND logged_in_as NOT IN (SELECT goto FROM alias WHERE address='%s') UNION SELECT username FROM mailbox,alias_domain WHERE alias_domain.alias_domain = '%d' AND mailbox.username = CONCAT('%u','@',alias_domain.target_domain) AND mailbox.active ='1' AND alias_domain.active='1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_spamalias_maps.cf
user = ${DBUSER}
password = ${DBPASS}
hosts = mysql-mailcow
dbname = ${DBNAME}
query = SELECT goto FROM spamalias WHERE address='%s' AND validity >= UNIX_TIMESTAMP()
EOF

# Reset GPG key permissions
mkdir -p /var/lib/zeyple/keys
chmod 700 /var/lib/zeyple/keys
chown -R 600:600 /var/lib/zeyple/keys

# Fix Postfix permissions
chgrp -R postdrop /var/spool/postfix/public
chgrp -R postdrop /var/spool/postfix/maildrop
postfix set-permissions

# Check Postfix configuration
postconf -c /opt/postfix/conf

if [[ $? != 0 ]]; then
	echo "Postfix configuration error, refusing to start."
	exit 1
else
	postfix -c /opt/postfix/conf start
	sleep 126144000
fi
