# vegardit/openldap <a href="https://github.com/vegardit/docker-openldap/" title="GitHub Repo"><img height="30" src="https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/github.svg?sanitize=true"></a>

[![Build Status](https://travis-ci.com/vegardit/docker-openldap.svg?branch=master "Tavis CI")](https://travis-ci.com/vegardit/docker-openldap)
[![License](https://img.shields.io/github/license/vegardit/docker-openldap.svg?label=license)](#license)
[![Docker Pulls](https://img.shields.io/docker/pulls/vegardit/openldap.svg)](https://hub.docker.com/r/vegardit/openldap)
[![Docker Stars](https://img.shields.io/docker/stars/vegardit/openldap.svg)](https://hub.docker.com/r/vegardit/openldap)
[![Docker Image Size](https://images.microbadger.com/badges/image/vegardit/openldap.svg)](https://hub.docker.com/r/vegardit/openldap)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-v2.0%20adopted-ff69b4.svg)](CODE_OF_CONDUCT.md)

1. [What is it?](#what-is-it)
1. [Configuration](#config)
   1. [Initial configuration](#initial-config)
   1. [Customizing the Password Policy](#ppolicy)
   1. [Changing UID/GID of OpenLDAP service user](#uidgid)
   1. [Periodic LDAP Backup](#backup)
   1. [Synchronizing timezone/time with docker host](#timesync)
   1. [Performance tuning](#performance-tuning)
   1. [Troubleshooting](#troubleshooting)
1. [References](#references)
1. [License](#license)


## <a name="what-is-it"></a>What is it?

Opinionated docker image based on [minideb](https://github.com/bitnami/minideb) (Debian 10 "buster") to run an [OpenLDAP 2.4](https://www.openldap.org/doc/admin24/) server.

To keep the image light and simple, it does not configure TLS. Instead we recommend configuring a [Traefik 2.x](https://traefik.io) [TCP service](https://docs.traefik.io/routing/services/#configuring-tcp-services) with e.g. an auto-renewing [Let's Encrypt configuration](https://docs.traefik.io/https/acme/) in front of the OpenLDAP service.


## <a name="config"></a>Configuration

### <a name="initial-config"></a>Initial configuration

Various parts of the LDAP server can be configured via environment variables. All environment variables starting with `LDAP_INIT_`
are only evaluated on the **first** container launch. Changing their values later has no effect when restarting or updating the container.

To customize the initial configuration you can set the following environment variables:

```sh
LDAP_INIT_ORG_DN='dc=example,dc=com'
LDAP_INIT_ORG_NAME='Example Corporation'
LDAP_INIT_ADMIN_GROUP_DN='cn=ldapadmins,ou=Groups,${LDAP_INIT_ORG_DN}'
LDAP_INIT_ROOT_USER_DN='uid=admin,${LDAP_INIT_ORG_DN}'
LDAP_INIT_ROOT_USER_PW='changeit'
LDAP_INIT_RFC2307BIS_SCHEMA=0 # 0=use NIS (RFC2307) schema, 1=use RFC2307bis schema
```

Environment variables can for example be set using `docker run` with `-e`, e.g.

```sh
docker run -itd \
  -e LDAP_INIT_ORG_DN='o=yourorg' \
  -e LDAP_INIT_ROOT_USER_PW='newpassword' \
  -e LDAP_INIT_ORG_NAME='Company Inc' \
  -e LDAP_INIT_PPOLICY_PW_MIN_LENGTH='12' \
  vegardit/openldap
```

Alternatively you can use an [env-file](https://docs.docker.com/compose/env-file/) to store all changed variables and use the option `--env-file` with `docker run`, e.g.:

```sh
docker run -itd --env-file environment vegardit/openldap
```

In environment file values must not be enclosed using quotes (`'` or `"`), please remove them. See this example file: [example/docker/example.env].

The initial LDAP tree structure is imported from [/opt/ldifs/init_org_tree.ldif](image/ldifs/init_org_tree.ldif).
You can mount a custom file at `/opt/ldifs/init_org_tree.ldif` if you require changes.

LDAP entries (users, groups) are imported from [/opt/ldifs/init_org_entries.ldif](image/ldifs/init_org_entries.ldif).
You can mount a custom file at `/opt/ldifs/init_org_entries.ldif` if you require changes.

### <a name="ppolicy"></a>Customizing the Password Policy

On **initial** container launch, the [password policy](https://www.openldap.org/doc/admin24/overlays.html#Password%20Policies) is imported from [/opt/ldifs/init_org_ppolicy.ldif](image/ldifs/init_org_ppolicy.ldif)

The following parameters can be modified via environment variables **before** initial container launch:

```sh
LDAP_INIT_PPOLICY_DEFAULT_DN='cn=DefaultPasswordPolicy,ou=Policies,${LDAP_INIT_ORG_DN}'
LDAP_INIT_PPOLICY_PW_MIN_LENGTH=8
LDAP_INIT_PPOLICY_MAX_FAILURES=3
LDAP_INIT_PPOLICY_LOCKOUT_DURATION=300
```

If more customizations are required, simply mount a custom policy file at `/opt/ldifs/init_org_ppolicy.ldif` **before** initial container launch.

**Password Quality Checker:**

[pqChecker](https://www.meddeb.net/pqchecker/) is configured as default password quality checker using the rule `0|01010101` with
the following meaning:

|Pos. |Value  |Effective Rule
|----:|:-----:|:----------
|0-1  | `0\|`|Don't broadcast passwords.
|2-4  | `01` |Minimum 1 uppercase character.
|5-6  | `01` |Minimum 1 lowercase character.
|7-8  | `01` |Minimum 1 digit.
|9-10 | `01` |Minimum 1 special character.
|11-..| empty | No characters are disallowed in passwords.

The pqChecker rule syntax is explained here in more detail: https://www.meddeb.net/pqchecker/?Idx=2

A custom rule can be provided via an environment variable, e.g.:

```sh
LDAP_PPOLICY_PQCHECKER_RULE='0|01020101@!+-#'
```

### <a name="uidgid"></a>Changing UID/GID of OpenLDAP service user

The UID/GID of the user running the OpenLDAP service can be aligned with the docker host, using the environment variables
`LDAP_OPENLDAP_UID` and `LDAP_OPENLDAP_GID`.

During each container start it is verified that the given UID/GID matches the currently effective UID/GID. If not, the UID/GID
of the `openldap` user are changed accordingly and `chown` on `/etc/ldap` and `/var/lib/slapd` is executed before the OpenLDAP service is started.

### <a name="backup"></a>Periodic LDAP Backup

This image automatically generates a daily LDIF export at `2 a.m.` to `/var/lib/ldap/data.ldif`.

The following environment variables can be used to configure the automatic LDAP backup:
```bash
LDAP_BACKUP_TIME='02:00'  # Format is "HH:MM", i.e. 24-hour format with minute precision
LDAP_BACKUP_FILE='/var/lib/ldap/data.ldif'
```

To disable automatic backup set an empty value for the environment variable `LDAP_BACKUP_TIME`.

### <a name="timesync"></a>Synchronizing timezone/time with docker host

To use the same timezone and/or time of the docker host you can run the docker image with `--volume /etc/localtime:/etc/localtime:ro --volume /etc/timezone:/etc/timezone:ro`

Docker compose file example:
```yaml
version: '3.7'
services:
  openldap:
    image: vegardit/openldap:latest
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
```

### <a name="performance-tuning"></a>Performance tuning

#### DB Indexes

The database indexes that are configured during initial container launch are imported from [/opt/ldifs/init_backend_indexes.ldif](image/ldifs/init_mdb_indexes.ldif)

To use other indexes, simply mount a custom file at `/opt/ldifs/init_backend_indexes.ldif` **before** initial container launch.

#### Memory usage

The maximum number of open files is set to `1024` by default to prevent excessive RAM consumption as reported [here](https://github.com/docker/docker/issues/8231).

The following environment variable can be used to increase this limit:

```sh
LDAP_NOFILE_LIMIT=2048
```

### <a name="troubleshooting"></a>Troubleshooting

The slapd service logs to stdout. You can change the active log levels by setting this environment variable:

```sh
LDAP_LOG_LEVELS='Config Stats'
```

The following [log levels](https://www.openldap.org/doc/admin24/slapdconfig.html#loglevel%20%3Clevel%3E) are available:
```
Any     (-1)     enable all debugging
Trace   (1)      trace function calls
Packets (2)      debug packet handling
Args    (4)      heavy trace debugging
Conns   (8)      connection management
BER     (16)     print out packets sent and received
Filter  (32)     search filter processing
Config  (64)     configuration processing
ACL     (128)    access control list processing
Stats   (256)    stats log connections/operations/results
Stats2  (512)    stats log entries sent
Shell   (1024)   print communication with shell backends
Parse   (2048)   print entry parsing debugging
Sync    (16384)  syncrepl consumer processing
None    (32768)  only messages that get logged whatever log level is set
```


## <a name="references"></a>References

- OpenLDAP Software 2.4 Administrator's Guide https://www.openldap.org/doc/admin24/guide.html
- OpenLDAP Online Configuration Reference https://tylersguides.com/guides/openldap-online-configuration-reference/
- slapd-config(5) - Linux man page https://linux.die.net/man/5/slapd-config


## <a name="license"></a>License

All files in this repository are released under the [Apache License 2.0](LICENSE.txt).
